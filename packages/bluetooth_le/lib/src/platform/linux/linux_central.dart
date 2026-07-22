import 'dart:async';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import '../../exceptions.dart';
import '../../logging.dart';
import '../../models/ble_characteristic.dart';
import '../../models/ble_device.dart';
import '../../models/ble_service.dart';
import '../../models/device_id.dart';
import '../../models/enums.dart';
import '../../models/scan_result.dart';
import '../../models/uuid.dart';
import '../platform_interface.dart';

/// Linux BLE central over BlueZ's D-Bus API (`org.bluez`).
///
/// Pure Dart — no native build. Works on any distro shipping BlueZ 5.x
/// (including Raspberry Pi OS). Adapter state, scanning and connection come from
/// `Adapter1`/`Device1`; GATT is the `GattService1`/`GattCharacteristic1`
/// object tree BlueZ exposes once a device's services are resolved.
class LinuxBleCentral extends BleCentralPlatform {
  LinuxBleCentral({DBusClient? bus, String adapter = 'hci0'})
    : _bus = bus ?? DBusClient.system(),
      _ownsBus = bus == null,
      _adapterName = adapter;

  final DBusClient _bus;

  /// Whether [dispose] may close [_bus]: only when this backend created it. A
  /// caller-injected client is theirs to manage (mirrors the rfcomm backend).
  final bool _ownsBus;

  final String _adapterName;

  static const String _service = 'org.bluez';
  static const String _adapterIface = 'org.bluez.Adapter1';
  static const String _deviceIface = 'org.bluez.Device1';
  static const String _propsIface = 'org.freedesktop.DBus.Properties';
  static const String _omIface = 'org.freedesktop.DBus.ObjectManager';

  // Backstop so a wedged or absent D-Bus / BlueZ can never hang adapter or scan
  // control calls forever (a missing org.bluez may otherwise block on bus
  // service activation). Normal calls resolve in milliseconds.
  static const Duration _busTimeout = Duration(seconds: 10);

  DBusObjectPath get _adapterPath => DBusObjectPath('/org/bluez/$_adapterName');

  DBusRemoteObject _obj(DBusObjectPath path) =>
      DBusRemoteObject(_bus, name: _service, path: path);

  @override
  Future<bool> isSupported() async {
    try {
      await _obj(
        _adapterPath,
      ).getProperty(_adapterIface, 'Address').timeout(_busTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  // --- Adapter state -------------------------------------------------------

  @override
  Future<BluetoothAdapterState> adapterState() async {
    try {
      final powered = await _obj(
        _adapterPath,
      ).getProperty(_adapterIface, 'Powered').timeout(_busTimeout);
      if (powered is DBusBoolean) {
        return powered.value
            ? BluetoothAdapterState.on
            : BluetoothAdapterState.off;
      }
      return BluetoothAdapterState.unknown;
    } catch (_) {
      return BluetoothAdapterState.unavailable;
    }
  }

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() {
    late StreamController<BluetoothAdapterState> controller;
    StreamSubscription<DBusPropertiesChangedSignal>? sub;
    // Bumped on every listen AND cancel, so an in-flight onListen can detect it
    // was superseded mid-await (and not wire up a dead subscription) without a
    // one-way `cancelled` latch that would leave a re-listened stream (broadcast
    // onListen re-fires on 0 -> 1) permanently silent.
    var epoch = 0;
    controller = StreamController<BluetoothAdapterState>.broadcast(
      onListen: () async {
        final myEpoch = ++epoch;
        final initial = await adapterState();
        if (epoch != myEpoch) return;
        controller.add(initial);
        final created = _obj(_adapterPath).propertiesChanged.listen(
          (sig) async {
            if (sig.propertiesInterface == _adapterIface &&
                sig.changedProperties.containsKey('Powered')) {
              controller.add(await adapterState());
            }
          },
          // A malformed signal must not become an unhandled zone error (the
          // dbus dispatcher addErrors signature mismatches into this stream).
          onError: (Object e) =>
              logAdapter.warning(() => 'adapter signal error: $e'),
        );
        if (epoch != myEpoch) {
          await created.cancel();
        } else {
          sub = created;
        }
      },
      onCancel: () async {
        epoch++;
        await sub?.cancel();
        sub = null;
      },
    );
    return controller.stream;
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async {
    try {
      await _obj(
        _adapterPath,
      ).setProperty(_adapterIface, 'Powered', DBusBoolean(enabled));
    } catch (e) {
      _mapDbus(e, 'setAdapterEnabled');
    }
  }

  // --- Scanning ------------------------------------------------------------

  /// Live scan streams, so [stopScan] can close them (matching the
  /// Apple/Android backends) and so BlueZ StartDiscovery/StopDiscovery can be
  /// reference-counted: discovery is scoped to the D-Bus client, and this
  /// backend shares ONE client, so a stream tearing down must only ask BlueZ to
  /// stop when it is the last local scan — otherwise cancelling one scan stream
  /// would kill a concurrent one's inquiry.
  final Set<StreamController<BleScanResult>> _scanControllers = {};
  int _scanRefs = 0;

  /// Serializes StartDiscovery/StopDiscovery calls so a stop issued by a
  /// just-cancelled stream can't land after — and silently kill — the
  /// StartDiscovery of a stream that began a moment later.
  Future<void> _scanOps = Future<void>.value();

  Future<void> _enqueueScanOp(Future<void> Function() op) {
    final result = _scanOps.then((_) => op());
    // Keep the chain alive past failures; the caller sees the error.
    _scanOps = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Filter of the scan currently driving the BlueZ inquiry (one shared client
  /// has one filter), kept so a suspend/resume recovery can re-issue the same
  /// StartDiscovery.
  List<Uuid>? _activeFilter;

  /// Whether this client's BlueZ discovery session is believed to be running.
  /// Cleared when the adapter powers off (BlueZ silently tears the session
  /// down on suspend/rfkill) so the recovery path knows to restart it.
  bool _discovering = false;

  /// Adapter Powered/Discovering watch, armed while local scans are live.
  /// Signal-driven (no polling): on Powered=false the internal discovering
  /// flag is cleared; on Powered=true — or on an externally-dropped
  /// Discovering while scans are live — a serialized restart op re-fires
  /// SetDiscoveryFilter + StartDiscovery, so a scan stream survives a
  /// laptop lid-close/open instead of going silently dead.
  StreamSubscription<DBusPropertiesChangedSignal>? _adapterScanWatch;

  void _armAdapterScanWatch() {
    _adapterScanWatch ??= _obj(_adapterPath).propertiesChanged.listen(
      (sig) {
        if (sig.propertiesInterface != _adapterIface) return;
        final powered = sig.changedProperties['Powered'];
        final discovering = sig.changedProperties['Discovering'];
        if (powered is DBusBoolean && !powered.value) {
          // Adapter went down: the discovery session is gone with it. Mark it
          // so the power-on path below restarts, and don't try now (BlueZ
          // would answer NotReady).
          _discovering = false;
          logScan.warning(
            'adapter powered off during scan; discovery will restart on '
            'power-on',
          );
          return;
        }
        final poweredBackOn = powered is DBusBoolean && powered.value;
        final discoveryDropped =
            discovering is DBusBoolean && !discovering.value;
        if (discoveryDropped) _discovering = false;
        if ((poweredBackOn || discoveryDropped) &&
            _scanRefs > 0 &&
            !_discovering) {
          unawaited(
            _enqueueScanOp(() async {
              // Re-checked at execution: the last scan may have cancelled (or
              // an earlier restart already succeeded) while this op queued.
              if (_scanRefs <= 0 || _discovering) return;
              try {
                await _startBluezDiscovery(_activeFilter);
                logScan.fine('discovery restarted after adapter power-cycle');
              } catch (e) {
                // Powered may still be off mid-transition; the next
                // Powered=true signal retries.
                logScan.warning(() => 'discovery restart failed: $e');
              }
            }),
          );
        }
      },
      onError: (Object e) =>
          logScan.warning(() => 'adapter scan-watch signal error: $e'),
    );
  }

  Future<void> _disarmAdapterScanWatch() async {
    final watch = _adapterScanWatch;
    _adapterScanWatch = null;
    await watch?.cancel();
  }

  /// Configures the discovery filter and starts the BlueZ inquiry. Must run
  /// inside the serialized scan-op chain.
  Future<void> _startBluezDiscovery(List<Uuid>? withServices) async {
    // Restrict to LE and (optionally) the requested services so we don't
    // surface Classic-only devices on a dual-mode adapter.
    final filter = <String, DBusValue>{'Transport': const DBusString('le')};
    if (withServices != null && withServices.isNotEmpty) {
      filter['UUIDs'] = DBusArray.string(
        withServices.map((u) => u.value).toList(),
      );
    }
    await _obj(_adapterPath)
        .callMethod(_adapterIface, 'SetDiscoveryFilter', [
          DBusDict.stringVariant(filter),
        ], replySignature: DBusSignature(''))
        .timeout(_busTimeout);
    if (_scanRefs <= 0) return;
    try {
      await _obj(
        _adapterPath,
      ).callMethod(_adapterIface, 'StartDiscovery', []).timeout(_busTimeout);
    } on DBusMethodResponseException catch (e) {
      // A discovery already running on this client (a race with a stop
      // still in flight) reports InProgress — the radio is already doing
      // what we want, so that's success, not an error.
      if (e.errorName != 'org.bluez.Error.InProgress') rethrow;
    }
    _discovering = true;
  }

  @override
  Stream<BleScanResult> startScan({List<Uuid>? withServices}) {
    late StreamController<BleScanResult> controller;
    StreamSubscription<DBusSignal>? addedSub;
    StreamSubscription<DBusSignal>? changedSub;

    Future<void> begin() async {
      final om = DBusRemoteObject(
        _bus,
        name: _service,
        path: DBusObjectPath('/'),
      );
      addedSub =
          DBusRemoteObjectSignalStream(
            object: om,
            interface: _omIface,
            name: 'InterfacesAdded',
          ).listen(
            (signal) {
              try {
                if (signal.values.length < 2) return;
                final ifaces = _ifacesFromDict(signal.values[1] as DBusDict);
                final props = ifaces[_deviceIface];
                if (props != null) controller.add(_scanResultFromProps(props));
              } catch (_) {
                // Skip a malformed signal rather than erroring the scan stream.
              }
            },
            onError: (Object e) {
              logScan.warning(() => 'InterfacesAdded signal error: $e');
            },
          );
      // RSSI/name updates on already-known devices arrive as PropertiesChanged
      // from each device's own path, so match the adapter path namespace.
      changedSub =
          DBusSignalStream(
            _bus,
            sender: _service,
            interface: _propsIface,
            name: 'PropertiesChanged',
            pathNamespace: _adapterPath,
          ).listen(
            (signal) async {
              try {
                if (signal.values.isEmpty) return;
                if ((signal.values[0] as DBusString).value != _deviceIface) {
                  return;
                }
                final props = await _allProps(signal.path, _deviceIface);
                // The controller can close (stopScan) while we awaited the
                // props — guard explicitly rather than relying on the catch.
                if (!controller.isClosed) {
                  controller.add(_scanResultFromProps(props));
                }
              } catch (_) {
                // Device vanished mid-update / malformed signal.
              }
            },
            onError: (Object e) {
              logScan.warning(() => 'PropertiesChanged signal error: $e');
            },
          );

      // Only the FIRST local scan configures and starts the BlueZ inquiry; a
      // concurrent scan rides the one already running (with its filter — one
      // shared client has one filter).
      if (_scanRefs != 1) return;
      _activeFilter = withServices;
      // Watch Powered/Discovering while scans are live, so a suspend/resume
      // (which silently kills the BlueZ session) restarts discovery instead of
      // leaving the stream dead.
      _armAdapterScanWatch();
      await _enqueueScanOp(() async {
        // Cancels that landed while this op was queued — or during the filter
        // call below — must not let StartDiscovery run after StopDiscovery, or
        // nothing would ever stop the adapter again. Checked against the live
        // refcount (not a per-stream flag) so cancelling this stream doesn't
        // starve a concurrent scan that is riding this StartDiscovery.
        if (_scanRefs <= 0) return;
        await _startBluezDiscovery(withServices);
        logScan.fine('scan started');
      });
    }

    controller = StreamController<BleScanResult>.broadcast(
      onListen: () {
        // Broadcast onListen re-fires on 0 -> 1, so a re-listen after a full
        // cancel re-runs begin() and re-arms the stream.
        _scanControllers.add(controller);
        _scanRefs++;
        begin().catchError((Object e) {
          controller.addError(
            BleScanException('StartDiscovery failed', cause: e),
          );
          // A scan that failed to start will never produce results or complete
          // on its own — close it so listeners see a terminal event, not a
          // hung stream.
          if (!controller.isClosed) unawaited(controller.close());
        });
      },
      onCancel: () async {
        _scanControllers.remove(controller);
        _scanRefs--;
        await addedSub?.cancel();
        await changedSub?.cancel();
        addedSub = null;
        changedSub = null;
        // Only the LAST local scan stops the radio inquiry (and drops the
        // adapter watch — disarmed FIRST, so our own StopDiscovery's
        // Discovering=false signal can't be mistaken for a dropped session).
        if (_scanRefs <= 0) {
          _scanRefs = 0;
          await _disarmAdapterScanWatch();
          await _enqueueScanOp(_stopBluezDiscovery);
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    // Close live scan streams (mirrors Apple/Android, whose stopScan closes
    // the active scan controller) so their listeners get a terminal done
    // instead of a silently-dead stream; each close drains the refcount via
    // its onCancel, and the last one stops the BlueZ inquiry.
    for (final c in _scanControllers.toList()) {
      if (!c.isClosed) unawaited(c.close());
    }
    // Backstop for an inquiry with no live stream to drain (e.g. one left
    // running by an external orchestration quirk). Checked at execution time —
    // after the queued closes above — so a scan started right after stopScan()
    // (whose refcount is live again) is never starved of its inquiry.
    await _enqueueScanOp(() async {
      if (_scanRefs > 0) return;
      await _stopBluezDiscovery();
    });
  }

  Future<void> _stopBluezDiscovery() async {
    _discovering = false;
    try {
      await _obj(
        _adapterPath,
      ).callMethod(_adapterIface, 'StopDiscovery', []).timeout(_busTimeout);
    } catch (_) {
      // Not scanning / wedged bus — ignore.
    }
  }

  // --- Connect -------------------------------------------------------------

  @override
  Future<GattConnection> connect(DeviceId id, {Duration? timeout}) async {
    if (!id.isAddress) {
      throw const BleConnectionException(
        'Linux requires a MAC-address DeviceId to connect',
      );
    }
    final path = _devicePath(id);
    logConnection.fine(() => 'connecting to ${id.value}');
    final conn = LinuxGattConnection(
      bus: _bus,
      devicePath: path,
      service: _service,
    );
    await conn.open(timeout);
    return conn;
  }

  @override
  Future<void> dispose() async {
    await _disarmAdapterScanWatch();
    // Vacate the platform-level singleton slot so a later default construction
    // gets a fresh backend, not this disposed one.
    BleCentralPlatform.detachInstance(this);
    // A caller-injected bus is theirs to manage; only close one we created.
    if (_ownsBus) await _bus.close();
  }

  // --- Helpers -------------------------------------------------------------

  Never _mapDbus(Object e, String op) {
    if (e is BleException) throw e;
    if (e is TimeoutException) {
      throw BleTimeoutException('timed out during $op', cause: e);
    }
    if (e is DBusServiceUnknownException) {
      throw BleDisabledException(
        'BlueZ (org.bluez) is unavailable — is the bluetooth service running?',
        cause: e,
      );
    }
    if (e is DBusAccessDeniedException) {
      throw BlePermissionException('Permission denied during $op', cause: e);
    }
    if (e is DBusUnknownObjectException) {
      throw DeviceNotFoundException('Unknown object during $op', cause: e);
    }
    if (e is DBusMethodResponseException) {
      throw switch (e.errorName) {
        // Adapter powered off — the retry story is "wait for the adapter",
        // exactly what BleDisabledException documents.
        'org.bluez.Error.NotReady' => BleDisabledException(
          'Bluetooth adapter is powered off',
          cause: e,
        ),
        'org.bluez.Error.NotAuthorized' ||
        'org.bluez.Error.AuthenticationRejected' => BlePermissionException(
          'Not authorized during $op',
          cause: e,
        ),
        'org.bluez.Error.DoesNotExist' => DeviceNotFoundException(
          'Unknown device during $op',
          cause: e,
        ),
        _ => BleException('BlueZ error during $op', cause: e),
      };
    }
    throw BleException('D-Bus error during $op', cause: e);
  }

  DBusObjectPath _devicePath(DeviceId id) {
    final mac = id.address.replaceAll(':', '_').toUpperCase();
    return DBusObjectPath('/org/bluez/$_adapterName/dev_$mac');
  }

  Future<Map<String, DBusValue>> _allProps(
    DBusObjectPath path,
    String iface,
  ) async {
    final result = await _obj(path).callMethod(_propsIface, 'GetAll', [
      DBusString(iface),
    ], replySignature: DBusSignature('a{sv}'));
    return (result.returnValues.first as DBusDict).children.map(
      (k, v) => MapEntry((k as DBusString).value, (v as DBusVariant).value),
    );
  }

  static Map<String, Map<String, DBusValue>> _ifacesFromDict(DBusDict dict) {
    return dict.children.map(
      (k, v) => MapEntry(
        (k as DBusString).value,
        (v as DBusDict).children.map(
          (pk, pv) =>
              MapEntry((pk as DBusString).value, (pv as DBusVariant).value),
        ),
      ),
    );
  }

  BleScanResult _scanResultFromProps(Map<String, DBusValue> props) {
    final address = (props['Address'] as DBusString?)?.value;
    final name =
        (props['Name'] as DBusString?)?.value ??
        (props['Alias'] as DBusString?)?.value;
    final rssi = (props['RSSI'] as DBusInt16?)?.value;

    final serviceUuids = <Uuid>[];
    for (final e
        in (props['UUIDs'] as DBusArray?)?.children ?? const <DBusValue>[]) {
      if (e is! DBusString) continue;
      try {
        serviceUuids.add(Uuid(e.value));
      } catch (_) {
        // Skip a malformed peer-supplied UUID.
      }
    }

    final manufacturerData = <int, Uint8List>{};
    final mfg = props['ManufacturerData'];
    if (mfg is DBusDict) {
      mfg.children.forEach((k, v) {
        // Guard per entry (like serviceUuids/serviceData): one malformed
        // peer-supplied entry must not discard the whole sighting.
        if (k is! DBusUint16) return;
        try {
          manufacturerData[k.value] = _bytesOf((v as DBusVariant).value);
        } catch (_) {
          // Skip a malformed manufacturer-data entry.
        }
      });
    }

    final serviceData = <Uuid, Uint8List>{};
    final sd = props['ServiceData'];
    if (sd is DBusDict) {
      sd.children.forEach((k, v) {
        try {
          serviceData[Uuid((k as DBusString).value)] = _bytesOf(
            (v as DBusVariant).value,
          );
        } catch (_) {
          // Skip a malformed service-data UUID.
        }
      });
    }

    return BleScanResult(
      device: BleDevice(
        id: address != null
            ? DeviceId.address(address)
            : const DeviceId.opaque('unknown'),
        name: name,
        rssi: rssi,
      ),
      timestamp: DateTime.now(),
      rssi: rssi,
      serviceUuids: serviceUuids,
      manufacturerData: manufacturerData,
      serviceData: serviceData,
      // BlueZ only publishes devices it considers connectable.
      connectable: true,
    );
  }

  static Uint8List _bytesOf(DBusValue v) {
    if (v is DBusArray) {
      return Uint8List.fromList(
        v.children.map((e) => (e as DBusByte).value).toList(growable: false),
      );
    }
    return Uint8List(0);
  }
}

/// A live BlueZ GATT connection. Reads/writes/notifies operate on the
/// `GattCharacteristic1` objects under the device's D-Bus path.
class LinuxGattConnection implements GattConnection {
  LinuxGattConnection({
    required DBusClient bus,
    required DBusObjectPath devicePath,
    required String service,
  }) : _bus = bus,
       _devicePath = devicePath,
       _service = service;

  final DBusClient _bus;
  final DBusObjectPath _devicePath;
  final String _service;

  static const String _deviceIface = 'org.bluez.Device1';
  static const String _serviceIface = 'org.bluez.GattService1';
  static const String _charIface = 'org.bluez.GattCharacteristic1';
  static const String _omIface = 'org.freedesktop.DBus.ObjectManager';

  /// Resolved characteristic object paths, keyed `"service|char"`.
  final Map<String, DBusObjectPath> _charPaths = {};
  final StreamController<BleConnectionState> _stateController =
      StreamController<BleConnectionState>.broadcast();
  StreamSubscription<DBusPropertiesChangedSignal>? _deviceSub;
  // Active notify subscriptions, so a disconnect-driven teardown cancels their
  // D-Bus match rules and closes their controllers (the stream onCancel won't
  // fire just because the link dropped).
  final Set<StreamController<Uint8List>> _notifyCtrls = {};
  final Set<StreamSubscription<DBusPropertiesChangedSignal>> _notifySubs = {};
  Future<void> _opChain = Future<void>.value();
  BleConnectionState _current = BleConnectionState.connecting;
  bool _closed = false;

  DBusRemoteObject _obj(DBusObjectPath path) =>
      DBusRemoteObject(_bus, name: _service, path: path);

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _opChain.then((_) => op());
    _opChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> open(Duration? timeout) async {
    // Watch the device for disconnects before we connect, so we never miss the
    // transition.
    _deviceSub = _obj(_devicePath).propertiesChanged.listen(
      (sig) {
        if (sig.propertiesInterface != _deviceIface) return;
        final connected = sig.changedProperties['Connected'];
        if (connected is DBusBoolean && !connected.value) {
          _setState(BleConnectionState.disconnected);
          _teardown();
        }
      },
      // A malformed signal must not become an unhandled zone error.
      onError: (Object e) => logConnection.warning(
        () =>
            'device signal error: '
            '$e',
      ),
    );
    final device = _obj(_devicePath);
    final connect = device.callMethod(
      _deviceIface,
      'Connect',
      [],
      replySignature: DBusSignature(''),
    );
    try {
      if (timeout != null) {
        await connect.timeout(timeout);
      } else {
        await connect;
      }
      // BlueZ's Connect usually returns once services are resolved, but for
      // cached/re-connected devices ServicesResolved can briefly lag — making
      // the first discoverServices() see an empty tree. Wait for it (bounded).
      await _awaitServicesResolved(timeout);
    } on TimeoutException {
      unawaited(close());
      throw BleTimeoutException('connect timed out', timeout: timeout);
    } catch (e) {
      await _deviceSub?.cancel();
      _deviceSub = null;
      _mapDbus(e, 'connect');
    }
    // A disconnect that fired during the handshake already tore us down; don't
    // resurrect a dead link as "connected".
    if (_closed || _current == BleConnectionState.disconnected) {
      throw const BleConnectionException('disconnected during connect');
    }
    _setState(BleConnectionState.connected);
  }

  Future<void> _awaitServicesResolved(Duration? timeout) async {
    final device = _obj(_devicePath);
    try {
      final resolved = await device
          .getProperty(_deviceIface, 'ServicesResolved')
          .timeout(LinuxBleCentral._busTimeout);
      if (resolved is DBusBoolean && resolved.value) return;
    } catch (_) {
      return; // property absent / bus issue — discoverServices lazy-resolves
    }
    final done = Completer<void>();
    final sub = device.propertiesChanged.listen(
      (sig) {
        if (sig.propertiesInterface != _deviceIface) return;
        final r = sig.changedProperties['ServicesResolved'];
        if (r is DBusBoolean && r.value && !done.isCompleted) done.complete();
        final c = sig.changedProperties['Connected'];
        if (c is DBusBoolean && !c.value && !done.isCompleted) {
          done.complete(); // disconnect; the device watch handles teardown
        }
      },
      onError: (Object e) => logConnection.warning(
        () =>
            'device signal error: '
            '$e',
      ),
    );
    try {
      await done.future.timeout(timeout ?? LinuxBleCentral._busTimeout);
    } on TimeoutException {
      // Proceed; discoverServices() lazy-resolves and surfaces a clear error.
    } finally {
      await sub.cancel();
    }
  }

  @override
  Stream<BleConnectionState> get stateChanges => _stateController.stream;

  @override
  BleConnectionState get state => _current;

  @override
  Future<List<BleService>> discoverServices() async {
    try {
      final managed = await _managedObjects();
      final prefix = '${_devicePath.value}/';
      // Map service object-path -> its UUID.
      final serviceUuidByPath = <String, Uuid>{};
      managed.forEach((path, ifaces) {
        if (!path.value.startsWith(prefix)) return;
        final s = ifaces[_serviceIface];
        if (s == null) return;
        final uuid = (s['UUID'] as DBusString?)?.value;
        if (uuid != null) serviceUuidByPath[path.value] = Uuid(uuid);
      });

      final charsByService = <String, List<BleCharacteristic>>{};
      // Build into a local map and swap atomically at the end, so a concurrent
      // op resolving a cached path never sees a transiently-empty map.
      final newPaths = <String, DBusObjectPath>{};
      managed.forEach((path, ifaces) {
        if (!path.value.startsWith(prefix)) return;
        final c = ifaces[_charIface];
        if (c == null) return;
        final uuid = (c['UUID'] as DBusString?)?.value;
        final servicePath = (c['Service'] as DBusObjectPath?)?.value;
        if (uuid == null || servicePath == null) return;
        final serviceUuid = serviceUuidByPath[servicePath];
        if (serviceUuid == null) return;
        final flags = ((c['Flags'] as DBusArray?)?.children ?? const [])
            .whereType<DBusString>()
            .map((e) => e.value)
            .toList();
        final charUuid = Uuid(uuid);
        newPaths['${serviceUuid.value}|${charUuid.value}'] = path;
        charsByService
            .putIfAbsent(servicePath, () => [])
            .add(
              BleCharacteristic(
                serviceUuid: serviceUuid,
                uuid: charUuid,
                properties: parseCharacteristicProperties(flags),
              ),
            );
      });
      _charPaths
        ..clear()
        ..addAll(newPaths);

      return serviceUuidByPath.entries
          .map(
            (e) => BleService(
              uuid: e.value,
              characteristics: charsByService[e.key] ?? const [],
            ),
          )
          .toList();
    } catch (e) {
      _mapDbus(e, 'discoverServices');
    }
  }

  @override
  Future<Uint8List> readCharacteristic(Uuid service, Uuid characteristic) {
    return _enqueue(() async {
      final path = await _charPath(service, characteristic);
      logGatt.fine(() => 'read ${characteristic.value}');
      try {
        final reply = await _obj(path).callMethod(_charIface, 'ReadValue', [
          DBusDict.stringVariant(const {}),
        ], replySignature: DBusSignature('ay'));
        return LinuxBleCentral._bytesOf(reply.returnValues.first);
      } catch (e) {
        _mapGatt(e, 'read');
      }
    });
  }

  @override
  Future<void> writeCharacteristic(
    Uuid service,
    Uuid characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  }) {
    return _enqueue(() async {
      final path = await _charPath(service, characteristic);
      logData.finest(
        () => 'write ${characteristic.value} ${describeBytes(value)}',
      );
      final options = <String, DBusValue>{
        'type': DBusString(withoutResponse ? 'command' : 'request'),
      };
      try {
        await _obj(path).callMethod(_charIface, 'WriteValue', [
          DBusArray.byte(value),
          DBusDict.stringVariant(options),
        ], replySignature: DBusSignature(''));
      } catch (e) {
        _mapGatt(e, 'write');
      }
    });
  }

  @override
  Stream<Uint8List> subscribe(Uuid service, Uuid characteristic) {
    late StreamController<Uint8List> controller;
    StreamSubscription<DBusPropertiesChangedSignal>? sub;
    // Bumped on every listen AND cancel (see adapterStateChanges): guards the
    // in-flight onListen against a cancel mid-await without latching a
    // re-listened stream (broadcast onListen re-fires on 0 -> 1) dead.
    var epoch = 0;
    controller = StreamController<Uint8List>.broadcast(
      onListen: () async {
        final myEpoch = ++epoch;
        _notifyCtrls.add(controller);
        try {
          final path = await _charPath(service, characteristic);
          if (epoch != myEpoch) return;
          sub = _obj(path).propertiesChanged.listen(
            (sig) {
              if (sig.propertiesInterface != _charIface) return;
              final value = sig.changedProperties['Value'];
              if (value != null && !controller.isClosed) {
                controller.add(LinuxBleCentral._bytesOf(value));
              }
            },
            // A malformed signal must not become an unhandled zone error.
            onError: (Object e) =>
                logGatt.warning(() => 'notify signal error: $e'),
          );
          _notifySubs.add(sub!);
          await _obj(path).callMethod(
            _charIface,
            'StartNotify',
            [],
            replySignature: DBusSignature(''),
          );
          logGatt.fine(() => 'subscribe ${characteristic.value}');
        } catch (e) {
          // Don't leak the match rule if StartNotify failed after listening.
          if (sub != null) {
            _notifySubs.remove(sub);
            await sub!.cancel();
            sub = null;
          }
          // The link can drop while we were parked at an await above, and
          // _teardown() then closes this controller before we get here —
          // addError on a closed controller is a StateError that would land as
          // an UNHANDLED zone error (process death in a CLI). Guard it.
          if (!controller.isClosed) {
            controller.addError(_gattError(e, 'subscribe'));
          } else {
            logGatt.fine(() => 'subscribe failed after teardown: $e');
          }
        }
      },
      onCancel: () async {
        epoch++;
        if (sub != null) {
          _notifySubs.remove(sub);
          await sub!.cancel();
          sub = null;
        }
        _notifyCtrls.remove(controller);
        try {
          final path = await _charPath(service, characteristic);
          await _obj(path).callMethod(
            _charIface,
            'StopNotify',
            [],
            replySignature: DBusSignature(''),
          );
        } catch (_) {
          // Connection may already be gone.
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<int> requestMtu(int mtu) async {
    // BlueZ negotiates the ATT MTU automatically; there's no request API. Report
    // the negotiated value from a characteristic's MTU property when BlueZ
    // exposes it (5.62+), else the ATT default.
    const attDefault = 23;
    if (_charPaths.isEmpty) return attDefault;
    final path = _charPaths.values.first;
    try {
      final v = await _obj(path).getProperty(_charIface, 'MTU');
      if (v is DBusUint16) return v.value;
    } catch (_) {
      // Property absent on older BlueZ.
    }
    return attDefault;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _obj(_devicePath).callMethod(
        _deviceIface,
        'Disconnect',
        [],
        replySignature: DBusSignature(''),
      );
    } catch (_) {
      // Already disconnected.
    }
    _setState(BleConnectionState.disconnected);
    await _teardown();
  }

  // --- Helpers -------------------------------------------------------------

  Future<DBusObjectPath> _charPath(Uuid service, Uuid characteristic) async {
    final key = '${service.value}|${characteristic.value}';
    final cached = _charPaths[key];
    if (cached != null) return cached;
    // Resolve lazily if discoverServices wasn't called first.
    await discoverServices();
    final path = _charPaths[key];
    if (path == null) {
      throw CharacteristicNotFoundException(
        'No characteristic ${characteristic.value} in service ${service.value}',
      );
    }
    return path;
  }

  void _setState(BleConnectionState s) {
    if (_current == s) return;
    _current = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  Future<void> _teardown() async {
    await _deviceSub?.cancel();
    _deviceSub = null;
    for (final s in _notifySubs.toList()) {
      await s.cancel();
    }
    _notifySubs.clear();
    for (final c in _notifyCtrls.toList()) {
      if (!c.isClosed) await c.close();
    }
    _notifyCtrls.clear();
    if (!_stateController.isClosed) await _stateController.close();
  }

  Future<Map<DBusObjectPath, Map<String, Map<String, DBusValue>>>>
  _managedObjects() async {
    final om = DBusRemoteObject(
      _bus,
      name: _service,
      path: DBusObjectPath('/'),
    );
    final reply = await om.callMethod(
      _omIface,
      'GetManagedObjects',
      [],
      replySignature: DBusSignature('a{oa{sa{sv}}}'),
    );
    final dict = reply.returnValues.first as DBusDict;
    return dict.children.map(
      (path, ifaces) => MapEntry(
        path as DBusObjectPath,
        LinuxBleCentral._ifacesFromDict(ifaces as DBusDict),
      ),
    );
  }

  Never _mapDbus(Object e, String op) {
    if (e is BleException) throw e;
    if (e is TimeoutException) {
      throw BleTimeoutException('timed out during $op', cause: e);
    }
    if (e is DBusServiceUnknownException) {
      throw BleDisabledException('BlueZ unavailable during $op', cause: e);
    }
    if (e is DBusAccessDeniedException) {
      throw BlePermissionException('Permission denied during $op', cause: e);
    }
    if (e is DBusUnknownObjectException) {
      throw DeviceNotFoundException('Unknown object during $op', cause: e);
    }
    if (e is FormatException) {
      throw BleGattException('malformed data during $op', cause: e);
    }
    if (e is DBusMethodResponseException) {
      // BlueZ's typed errors carry the real story (mirrors the rfcomm Linux
      // mapper): NotReady is the adapter being off (isTransient=false — park
      // on adapterStateChanges, don't hammer BlueZ in a retry loop), and
      // DoesNotExist is an unknown device.
      throw switch (e.errorName) {
        'org.bluez.Error.NotReady' => BleDisabledException(
          'Bluetooth adapter is powered off',
          cause: e,
        ),
        'org.bluez.Error.NotAuthorized' ||
        'org.bluez.Error.AuthenticationRejected' => BlePermissionException(
          'Not authorized during $op',
          cause: e,
        ),
        'org.bluez.Error.DoesNotExist' => DeviceNotFoundException(
          'Unknown device during $op',
          cause: e,
        ),
        _ => BleConnectionException('BlueZ error during $op', cause: e),
      };
    }
    throw BleConnectionException('D-Bus error during $op', cause: e);
  }

  Never _mapGatt(Object e, String op) {
    throw _gattError(e, op);
  }

  BleException _gattError(Object e, String op) {
    if (e is BleException) return e;
    if (e is TimeoutException) {
      return BleTimeoutException('GATT $op timed out', cause: e);
    }
    return BleGattException('GATT $op failed', cause: e);
  }

  /// Maps BlueZ `GattCharacteristic1.Flags` to [CharacteristicProperty]. Public
  /// and pure so it can be unit-tested without a live bus.
  static Set<CharacteristicProperty> parseCharacteristicProperties(
    List<String> flags,
  ) {
    final out = <CharacteristicProperty>{};
    for (final f in flags) {
      switch (f) {
        case 'read':
          out.add(CharacteristicProperty.read);
        case 'write':
          out.add(CharacteristicProperty.write);
        case 'write-without-response':
          out.add(CharacteristicProperty.writeWithoutResponse);
        case 'notify':
          out.add(CharacteristicProperty.notify);
        case 'indicate':
          out.add(CharacteristicProperty.indicate);
      }
    }
    return out;
  }
}
