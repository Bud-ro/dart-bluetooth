import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import '../../exceptions.dart';
import '../../logging.dart';
import '../../models/bluetooth_device.dart';
import '../../models/bluetooth_service.dart';
import '../../models/device_id.dart';
import '../../models/discovery_result.dart';
import '../../models/enums.dart';
import '../../models/uuid.dart';
import '../platform_interface.dart';

/// Linux backend over BlueZ's D-Bus API (`org.bluez`).
///
/// Pure Dart — no native build. Works out of the box on Raspberry Pi OS and any
/// distro shipping BlueZ 5.x. Device discovery, bonded enumeration and adapter
/// state come from the standard `Adapter1`/`Device1` interfaces; the RFCOMM byte
/// stream is obtained by registering a `Profile1` for the SPP UUID and reading
/// the file descriptor BlueZ hands back on `NewConnection`.
class LinuxBluetoothRfcomm extends BluetoothRfcommPlatform {
  /// [adapter] selects the BlueZ adapter (default `hci0`); hosts whose only
  /// adapter has another name (`hci1` after an adapter swap) must pass it —
  /// there is no automatic enumeration. A caller-supplied [bus] is NOT closed
  /// by [dispose]; the default client is.
  LinuxBluetoothRfcomm({DBusClient? bus, String adapter = 'hci0'})
    : _bus = bus ?? DBusClient.system(),
      _ownsBus = bus == null,
      _adapterName = adapter;

  final DBusClient _bus;
  final bool _ownsBus;
  final String _adapterName;

  static const String _service = 'org.bluez';
  static const String _adapterIface = 'org.bluez.Adapter1';
  static const String _deviceIface = 'org.bluez.Device1';
  static const String _propsIface = 'org.freedesktop.DBus.Properties';
  static const String _omIface = 'org.freedesktop.DBus.ObjectManager';

  DBusObjectPath get _adapterPath => DBusObjectPath('/org/bluez/$_adapterName');

  DBusRemoteObject _obj(DBusObjectPath path) =>
      DBusRemoteObject(_bus, name: _service, path: path);

  @override
  Future<bool> isSupported() async {
    try {
      await _adapterProperty('Address');
      return true;
    } catch (_) {
      return false;
    }
  }

  // --- Adapter state -------------------------------------------------------

  @override
  Future<BluetoothAdapterState> adapterState() async {
    try {
      final powered = await _adapterProperty('Powered');
      if (powered is DBusBoolean) {
        return powered.value
            ? BluetoothAdapterState.on
            : BluetoothAdapterState.off;
      }
      return BluetoothAdapterState.unknown;
    } on BluetoothException {
      return BluetoothAdapterState.unavailable;
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
        if (epoch != myEpoch) return; // superseded during the await
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
          await created.cancel(); // superseded while we were subscribing
        } else {
          sub = created;
        }
      },
      onCancel: () async {
        epoch++;
        final s = sub;
        sub = null;
        await s?.cancel();
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

  // --- Devices -------------------------------------------------------------

  @override
  Future<List<BluetoothDevice>> bondedDevices() async {
    try {
      final managed = await _managedObjects();
      final result = <BluetoothDevice>[];
      final prefix = '${_adapterPath.value}/';
      managed.forEach((path, ifaces) {
        // Only devices under the configured adapter (multi-adapter hosts).
        if (!path.value.startsWith(prefix)) return;
        final props = ifaces[_deviceIface];
        if (props == null) return;
        final paired = (props['Paired'] as DBusBoolean?)?.value ?? false;
        if (!paired) return;
        result.add(_deviceFromProps(props));
      });
      return result;
    } catch (e) {
      _mapDbus(e, 'bondedDevices');
    }
  }

  /// Live discovery streams, so [stopDiscovery] can close them (matching the
  /// macOS/Android backends) and so BlueZ StartDiscovery/StopDiscovery can be
  /// reference-counted: discovery is scoped to the D-Bus client, and this
  /// backend shares ONE client, so a stream tearing down must only ask BlueZ to
  /// stop when it is the last local discovery — otherwise cancelling the
  /// background scan would kill a concurrent one-shot discovery's inquiry.
  final Set<StreamController<BluetoothDiscoveryResult>> _discoveryControllers =
      {};
  int _discoveryRefs = 0;

  /// Whether WE have asked BlueZ to discover (and not yet asked it to stop).
  /// Start/stop decisions are made against THIS flag *inside* the serialized
  /// ops — never against a refcount snapshot taken at enqueue time, which goes
  /// stale while stopDiscovery's deferred teardown drains (a new stream would
  /// then skip StartDiscovery and be silently starved).
  bool _bluezDiscovering = false;

  /// Backstop so a wedged or restarting bluetoothd can never hang discovery
  /// control or profile (un)registration forever. Load-bearing here more than
  /// anywhere: discovery ops are SERIALIZED and profile registration is
  /// MEMOIZED, so without a bound one hung call starves every later
  /// startDiscovery/stopDiscovery — and every later connect on that UUID —
  /// process-wide. (The LE central has carried the same constant, with the
  /// same rationale, since its hardening pass.)
  static const Duration _busTimeout = Duration(seconds: 10);

  /// Watches Adapter1 for BlueZ dropping our discovery session behind our back
  /// (suspend/resume power-cycles the adapter; bluetoothd also stops discovery
  /// on its own). Without this, [_bluezDiscovering] goes stale-true and every
  /// later serialized start op skips StartDiscovery — the background scan and
  /// all one-shot discoveries would be silently starved forever.
  StreamSubscription<DBusPropertiesChangedSignal>? _discoveryInvalidation;

  /// Lazily (once, on first discovery) subscribes to the adapter's
  /// PropertiesChanged. Powered=false, or Discovering=false while we believe
  /// we're discovering, clears [_bluezDiscovering] so the next serialized start
  /// op re-issues StartDiscovery. A false clear (e.g. a late echo of our own
  /// stop) is harmless: the re-issued StartDiscovery treats InProgress as
  /// success.
  void _ensureDiscoveryInvalidationWatch() {
    _discoveryInvalidation ??= _obj(_adapterPath).propertiesChanged.listen(
      (sig) {
        if (sig.propertiesInterface != _adapterIface) return;
        final powered = sig.changedProperties['Powered'];
        final discovering = sig.changedProperties['Discovering'];
        final poweredOff = powered is DBusBoolean && !powered.value;
        final poweredOn = powered is DBusBoolean && powered.value;
        final dropped = discovering is DBusBoolean && !discovering.value;
        if ((poweredOff || dropped) && _bluezDiscovering) {
          _bluezDiscovering = false;
        }
        // Clearing the flag only unsticks FUTURE streams; the ones already
        // live (incl. the facade's long-held background-scan stream) get no
        // new StartDiscovery unless we issue it. Restart when the adapter
        // comes back (or the session was dropped with the radio still on).
        // Safe against echoes of our own stop: the serialized op re-checks
        // refs and the flag, and our own stop only runs at refs == 0.
        if ((poweredOn || (dropped && !poweredOff)) && _discoveryRefs > 0) {
          unawaited(
            _enqueueDiscoveryOp(() async {
              if (_bluezDiscovering || _discoveryRefs <= 0) return;
              try {
                await _obj(_adapterPath)
                    .callMethod(_adapterIface, 'StartDiscovery', [])
                    .timeout(_busTimeout);
                _bluezDiscovering = true;
                logDiscovery.info(
                  'discovery restarted after adapter power-cycle/session drop',
                );
              } on Object catch (e) {
                logDiscovery.warning(() => 'discovery restart failed: $e');
              }
            }),
          );
        }
      },
      // A malformed signal must not become an unhandled zone error.
      onError: (Object e) =>
          logDiscovery.warning(() => 'discovery watch signal error: $e'),
    );
  }

  /// Serializes StartDiscovery/StopDiscovery calls so a stop issued by a
  /// just-cancelled stream can't land after — and silently kill — the
  /// StartDiscovery of a stream that began a moment later.
  Future<void> _discoveryOps = Future<void>.value();

  Future<void> _enqueueDiscoveryOp(Future<void> Function() op) {
    final result = _discoveryOps.then((_) => op());
    // Keep the chain alive past failures; the caller sees the error.
    _discoveryOps = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Stream<BluetoothDiscoveryResult> startDiscovery() {
    late StreamController<BluetoothDiscoveryResult> controller;
    StreamSubscription<DBusSignal>? addedSub;
    StreamSubscription<DBusSignal>? changedSub;

    Future<void> begin() async {
      _ensureDiscoveryInvalidationWatch();
      final om = DBusRemoteObject(
        _bus,
        name: _service,
        path: DBusObjectPath('/'),
      );
      // New devices appearing.
      addedSub =
          DBusRemoteObjectSignalStream(
            object: om,
            interface: _omIface,
            name: 'InterfacesAdded',
          ).listen(
            (signal) {
              try {
                final values = signal.values;
                if (values.length < 2) return;
                final ifaces = (values[1] as DBusDict).children.map(
                  (k, v) => MapEntry(
                    (k as DBusString).value,
                    (v as DBusDict).children.map(
                      (pk, pv) => MapEntry(
                        (pk as DBusString).value,
                        (pv as DBusVariant).value,
                      ),
                    ),
                  ),
                );
                final props = ifaces[_deviceIface];
                if (props == null) return;
                controller.add(_discoveryFromProps(props));
              } catch (_) {
                // Skip a structurally-unexpected signal rather than erroring the
                // discovery stream (mirrors the PropertiesChanged handler).
              }
            },
            onError: (Object e) {
              // Never let a malformed signal become an unhandled zone error.
              logDiscovery.warning(() => 'InterfacesAdded signal error: $e');
            },
          );
      // Property updates (e.g. RSSI/name) on known devices. PropertiesChanged
      // is emitted from each device's own path, so we match a path NAMESPACE
      // under the adapter — an object scoped to '/' would never match.
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
                final props = await _allDeviceProps(signal.path);
                // The controller can close (stopDiscovery) while we awaited the
                // props — guard explicitly rather than relying on the catch.
                if (!controller.isClosed) {
                  controller.add(_discoveryFromProps(props));
                }
              } catch (_) {
                /* device vanished mid-update / malformed signal */
              }
            },
            onError: (Object e) {
              // Never let a malformed signal become an unhandled zone error.
              logDiscovery.warning(() => 'PropertiesChanged signal error: $e');
            },
          );
      // Ask BlueZ to start inquiring — the op itself checks (serialized, so
      // against FRESH state) whether discovery is already running. A
      // concurrent discovery on this client (race with a stop still in
      // flight) reports InProgress — the radio is already doing what we want,
      // so that's success, not an error.
      await _enqueueDiscoveryOp(() async {
        if (_bluezDiscovering) return;
        if (_discoveryRefs <= 0) return; // everyone left while we queued
        try {
          await _obj(_adapterPath)
              .callMethod(_adapterIface, 'StartDiscovery', [])
              .timeout(_busTimeout);
        } on DBusMethodResponseException catch (e) {
          if (e.errorName != 'org.bluez.Error.InProgress') rethrow;
        }
        _bluezDiscovering = true;
      });
    }

    controller = StreamController<BluetoothDiscoveryResult>.broadcast(
      onListen: () {
        _discoveryControllers.add(controller);
        _discoveryRefs++;
        begin().catchError((Object e) {
          controller.addError(
            BluetoothDiscoveryException('StartDiscovery failed', cause: e),
          );
          // A discovery that failed to start will never produce results or
          // complete on its own — close it so listeners (and the facade's
          // pause bookkeeping) see a terminal event, not a hung stream.
          if (!controller.isClosed) unawaited(controller.close());
        });
      },
      onCancel: () async {
        _discoveryControllers.remove(controller);
        _discoveryRefs--;
        if (_discoveryRefs < 0) _discoveryRefs = 0;
        await addedSub?.cancel();
        await changedSub?.cancel();
        // Only the LAST local discovery stops the radio inquiry — checked
        // inside the serialized op against fresh state, so a stream that
        // started while this teardown was queued keeps its inquiry.
        await _enqueueDiscoveryOp(() async {
          if (_discoveryRefs > 0 || !_bluezDiscovering) return;
          await _stopBluezDiscovery();
        });
      },
    );
    return controller.stream;
  }

  Future<void> _stopBluezDiscovery() async {
    try {
      await _obj(
        _adapterPath,
      ).callMethod(_adapterIface, 'StopDiscovery', []).timeout(_busTimeout);
    } catch (_) {
      // Not discovering — ignore.
    }
    _bluezDiscovering = false;
  }

  @override
  Future<void> stopDiscovery() async {
    // Close live discovery streams (mirrors macOS/Android, whose stopDiscovery
    // closes all discovery controllers) so their listeners get a terminal done
    // instead of a silently-dead stream; each close drains the refcount via
    // its onCancel.
    for (final c in _discoveryControllers.toList()) {
      if (!c.isClosed) unawaited(c.close());
    }
    // Unconditional (this is the global stop), still serialized with the
    // per-stream ops.
    await _enqueueDiscoveryOp(_stopBluezDiscovery);
  }

  @override
  Future<List<BluetoothService>> discoverServices(
    DeviceId device, {
    Uuid? serviceUuid,
  }) async {
    // BlueZ resolves SDP internally and only exposes service-class UUIDs (not
    // RFCOMM channel numbers) on Device1.UUIDs. The channel is selected by BlueZ
    // when the profile connects, so we report the advertised SPP service with a
    // sentinel channel of 0 ("let BlueZ choose"). openRfcomm honours that.
    try {
      final path = _devicePath(device);
      final props = await _allDeviceProps(path);
      final filter = serviceUuid;
      final services = <BluetoothService>[];
      for (final e
          in (props['UUIDs'] as DBusArray?)?.children ?? const <DBusValue>[]) {
        if (e is! DBusString) continue;
        // The peer controls these SDP UUID strings — skip a malformed one
        // rather than letting it discard the whole (possibly-valid) list.
        Uuid u;
        try {
          u = Uuid(e.value);
        } catch (_) {
          continue;
        }
        if (filter == null || u == filter) {
          services.add(BluetoothService(uuid: u, rfcommChannelId: 0));
        }
      }
      return services;
    } catch (e) {
      _mapDbus(e, 'discoverServices');
    }
  }

  @override
  Future<RfcommTransport> openRfcomm(
    DeviceId device, {
    int? channel,
    required Uuid serviceUuid,
    Duration? timeout,
  }) {
    if (!device.isAddress) {
      throw const BluetoothConnectionException(
        'Linux requires a MAC-address DeviceId for RFCOMM connect',
      );
    }
    final DBusObjectPath devicePath;
    try {
      devicePath = _devicePath(device);
    } on ArgumentError catch (e) {
      // Connect callers catch BluetoothException; match the guard above
      // rather than leaking the raw ArgumentError.
      throw BluetoothConnectionException(
        'Malformed Bluetooth device address "${device.value}"',
        cause: e,
      );
    }
    return _LinuxRfcommProfile.connect(
      bus: _bus,
      devicePath: devicePath,
      serviceUuid: serviceUuid,
      channel: channel,
      timeout: timeout,
    );
  }

  @override
  Future<void> pair(DeviceId device) async {
    try {
      await _obj(_devicePath(device)).callMethod(_deviceIface, 'Pair', []);
    } catch (e) {
      _mapDbus(e, 'pair');
    }
  }

  @override
  Future<void> unpair(DeviceId device) async {
    try {
      // RemoveDevice lives on the adapter, not the device.
      await _obj(_adapterPath).callMethod(_adapterIface, 'RemoveDevice', [
        DBusObjectPath(_devicePath(device).value),
      ]);
    } catch (e) {
      _mapDbus(e, 'unpair');
    }
  }

  @override
  Future<void> dispose() async {
    await _discoveryInvalidation?.cancel();
    _discoveryInvalidation = null;
    // Only close the client we created; a caller-injected bus is theirs.
    if (_ownsBus) await _bus.close();
    BluetoothRfcommPlatform.detachInstance(this);
  }

  // --- Helpers -------------------------------------------------------------

  /// Translates raw D-Bus failures into this package's domain exceptions so
  /// callers never have to handle `DBus*Exception` directly. Always throws.
  Never _mapDbus(Object e, String op) {
    if (e is BluetoothException) throw e;
    if (e is ArgumentError) {
      // A malformed device address ([_devicePath]) is invalid input, not a
      // D-Bus failure — don't mislabel it as one.
      throw BluetoothException('Invalid device address during $op', cause: e);
    }
    if (e is DBusServiceUnknownException) {
      throw BluetoothDisabledException(
        'BlueZ (org.bluez) is unavailable — is the bluetooth service running?',
        cause: e,
      );
    }
    if (e is DBusAccessDeniedException) {
      throw BluetoothPermissionException(
        'Permission denied during $op',
        cause: e,
      );
    }
    if (e is DBusUnknownObjectException) {
      throw DeviceNotFoundException(
        'Unknown device/object during $op',
        cause: e,
      );
    }
    if (e is DBusMethodResponseException) {
      throw switch (e.errorName) {
        // Adapter powered off — the retry story is "wait for the adapter",
        // exactly what BluetoothDisabledException documents.
        'org.bluez.Error.NotReady' => BluetoothDisabledException(
          'Bluetooth adapter is powered off',
          cause: e,
        ),
        'org.bluez.Error.NotAuthorized' ||
        'org.bluez.Error.AuthenticationRejected' =>
          BluetoothPermissionException('Not authorized during $op', cause: e),
        'org.bluez.Error.DoesNotExist' => DeviceNotFoundException(
          'Unknown device during $op',
          cause: e,
        ),
        _ => BluetoothException('BlueZ error during $op', cause: e),
      };
    }
    throw BluetoothException('D-Bus error during $op', cause: e);
  }

  Future<DBusValue> _adapterProperty(String name) async {
    try {
      return await _obj(_adapterPath).getProperty(_adapterIface, name);
    } catch (e) {
      throw BluetoothException('No BlueZ adapter "$_adapterName"', cause: e);
    }
  }

  /// Strict `AA:BB:CC:DD:EE:FF` — the form `DeviceId.address` normalizes to.
  static final RegExp _macAddress = RegExp(r'^[0-9A-F]{2}(:[0-9A-F]{2}){5}$');

  /// Builds the BlueZ object path for [device], validating the address shape
  /// FIRST: `DBusObjectPath` throws a raw ArgumentError about D-Bus path
  /// internals on hostile input, which must not leak out of this backend. All
  /// device-path consumers funnel through here, so a malformed address fails
  /// the same way everywhere ([ArgumentError], wrapped into a domain exception
  /// by [_mapDbus] / openRfcomm before reaching callers).
  DBusObjectPath _devicePath(DeviceId device) {
    if (!device.isAddress || !_macAddress.hasMatch(device.address)) {
      throw ArgumentError.value(
        device.value,
        'device',
        'not a valid Bluetooth MAC address',
      );
    }
    final mac = device.address.replaceAll(':', '_');
    return DBusObjectPath('/org/bluez/$_adapterName/dev_$mac');
  }

  Future<Map<String, DBusValue>> _allDeviceProps(DBusObjectPath path) async {
    final result = await _obj(path).callMethod(_propsIface, 'GetAll', [
      const DBusString(_deviceIface),
    ], replySignature: DBusSignature('a{sv}'));
    return (result.returnValues.first as DBusDict).children.map(
      (k, v) => MapEntry((k as DBusString).value, (v as DBusVariant).value),
    );
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
    return dict.children.map((path, ifaces) {
      final ifaceMap = (ifaces as DBusDict).children.map(
        (iface, props) => MapEntry(
          (iface as DBusString).value,
          (props as DBusDict).children.map(
            (pk, pv) =>
                MapEntry((pk as DBusString).value, (pv as DBusVariant).value),
          ),
        ),
      );
      return MapEntry(path as DBusObjectPath, ifaceMap);
    });
  }

  BluetoothDevice _deviceFromProps(Map<String, DBusValue> props) {
    final address =
        (props['Address'] as DBusString?)?.value ?? '00:00:00:00:00:00';
    final name =
        (props['Name'] as DBusString?)?.value ??
        (props['Alias'] as DBusString?)?.value;
    final paired = (props['Paired'] as DBusBoolean?)?.value ?? false;
    final connected = (props['Connected'] as DBusBoolean?)?.value ?? false;
    final rssi = (props['RSSI'] as DBusInt16?)?.value;
    final cls = (props['Class'] as DBusUint32?)?.value;
    return BluetoothDevice(
      id: DeviceId.address(address),
      name: name,
      type: BluetoothDeviceType.classic,
      bondState: paired ? BluetoothBondState.bonded : BluetoothBondState.none,
      rssi: rssi,
      isConnected: connected,
      deviceClass: cls,
    );
  }

  BluetoothDiscoveryResult _discoveryFromProps(Map<String, DBusValue> props) {
    final device = _deviceFromProps(props);
    return BluetoothDiscoveryResult(
      device: device,
      rssi: device.rssi,
      timestamp: DateTime.now(),
    );
  }
}

/// Obtains an RFCOMM file descriptor for SPP through a shared
/// `org.bluez.Profile1` registration ([_SharedProfile]), then exposes it as an
/// [RfcommTransport].
class _LinuxRfcommProfile implements RfcommTransport {
  _LinuxRfcommProfile._(this._socket, this._shared, this._devicePath) {
    _sub = _socket.listen(
      _incoming.add,
      // A hard read error (link reset when the peer powers off) may or may not
      // be followed by onDone, so treat it as a disconnect itself. It is
      // deliberately NOT forwarded to `incoming`: every other backend ends
      // `incoming` with a clean EOF on peer loss, so `await for` must
      // terminate — not throw — on Linux too. The detail goes to the log.
      onError: (Object e, StackTrace st) {
        logConnection.fine(() => 'read failed — treating as disconnect: $e');
        _handleDone();
      },
      onDone: _handleDone,
      cancelOnError: false,
    );
    // Write failures (e.g. EPIPE after the peer vanished) complete socket.done
    // with an error. Nobody would otherwise await that future, and an unhandled
    // async error can take down the whole app — swallow it and fold it into the
    // normal disconnect path instead.
    unawaited(
      _socket.done.then(
        (_) {},
        onError: (Object _) {
          _handleDone();
        },
      ),
    );
  }

  /// The shared per-UUID profile registration this transport holds one
  /// reference on (released by [close]).
  final _SharedProfile _shared;

  /// The BlueZ device object path this link belongs to, for routing
  /// RequestDisconnection and rejecting duplicate fds in [_SharedProfile].
  final String _devicePath;

  /// Internal upper bound applied when the caller passes no `timeout`, so a peer
  /// that never drives Profile1.NewConnection can't hang the connect forever and
  /// leak the registered BlueZ profile.
  static const Duration _connectSafetyTimeout = Duration(minutes: 1);

  static Future<RfcommTransport> connect({
    required DBusClient bus,
    required DBusObjectPath devicePath,
    required Uuid serviceUuid,
    int? channel,
    Duration? timeout,
  }) async {
    // BlueZ delivers the connected RFCOMM socket as a Unix fd to a registered
    // Profile1 object's NewConnection method — and it matches profiles by
    // UUID, so concurrent connects must share ONE Profile1 per UUID (see
    // _SharedProfile) whose NewConnection routes each fd by the device
    // object-path argument. Here we enlist as the pending connect for
    // [devicePath], trigger Device1.ConnectProfile, and adopt the routed fd as
    // a dart:io Socket for duplex I/O.
    final _SharedProfile shared;
    try {
      shared = await _SharedProfile.acquire(
        bus: bus,
        serviceUuid: serviceUuid,
        channel: channel,
      );
    } catch (e) {
      _throwConnectError(e, 'RegisterProfile');
    }
    // Terminal-path bookkeeping: every failure below must BOTH withdraw the
    // pending entry (so a late fd for this device is destroyed, not delivered
    // to nobody) and release the acquired profile reference. On success the
    // reference is handed to the transport instead (net zero at hand-off).
    final pending = shared.addPending(devicePath.value);

    // ONE deadline covers the whole connect: ConnectProfile itself (BlueZ can
    // block for its own page timeout, 10-40s, against an absent peer — the
    // caller's deadline must bound that too) plus the NewConnection wait.
    final deadline = timeout ?? _connectSafetyTimeout;
    final sw = Stopwatch()..start();
    final device = DBusRemoteObject(bus, name: 'org.bluez', path: devicePath);
    try {
      await device
          .callMethod('org.bluez.Device1', 'ConnectProfile', [
            DBusString(serviceUuid.value),
          ], replySignature: DBusSignature(''))
          .timeout(deadline);
    } on TimeoutException {
      // The fd may still have arrived while the call was in flight.
      if (!pending.isCompleted) {
        shared.abandonPending(devicePath.value, pending);
        unawaited(shared.release());
        throw BluetoothTimeoutException(
          'RFCOMM connect timed out',
          timeout: deadline,
        );
      }
    } catch (e) {
      // BlueZ can also deliver NewConnection and THEN report an error from
      // ConnectProfile; if the fd arrived, the link is up — prefer it over
      // throwing (and over leaking the adopted fd).
      if (!pending.isCompleted) {
        shared.abandonPending(devicePath.value, pending);
        await shared.release();
        _throwConnectError(e, 'ConnectProfile');
      }
      logConnection.fine(
        () => 'ConnectProfile errored after NewConnection; using the link: $e',
      );
    }

    final Socket socket;
    if (pending.isCompleted) {
      socket = await pending.future;
    } else {
      // Wait out the REMAINDER of the deadline for NewConnection.
      final remaining = deadline - sw.elapsed;
      try {
        socket = await pending.future.timeout(
          remaining > Duration.zero
              ? remaining
              : const Duration(milliseconds: 1),
        );
      } on TimeoutException {
        shared.abandonPending(devicePath.value, pending);
        unawaited(shared.release());
        throw BluetoothTimeoutException(
          'RFCOMM connect timed out',
          timeout: deadline,
        );
      }
    }
    // Success: the pending connect's profile reference becomes the
    // transport's, released by its (idempotent) close. Registering the
    // transport also wires BlueZ's RequestDisconnection/Release to that close
    // (routed per-device by _SharedProfile), so the Dart side actually tears
    // down instead of staying "connected" with a leaked fd.
    final transport = _LinuxRfcommProfile._(socket, shared, devicePath.value);
    shared.addTransport(devicePath.value, transport);
    return transport;
  }

  /// Maps a BlueZ connect-path failure into the domain taxonomy: adapter-off,
  /// permission and unknown-device get their specific types (so isTransient is
  /// truthful); everything else is a transient [BluetoothConnectionException].
  static Never _throwConnectError(Object e, String op) {
    if (e is DBusServiceUnknownException) {
      throw BluetoothDisabledException(
        'BlueZ (org.bluez) is unavailable — is the bluetooth service running?',
        cause: e,
      );
    }
    if (e is DBusAccessDeniedException) {
      throw BluetoothPermissionException(
        'Permission denied during $op',
        cause: e,
      );
    }
    if (e is DBusUnknownObjectException) {
      throw DeviceNotFoundException('Unknown device during $op', cause: e);
    }
    if (e is DBusMethodResponseException) {
      throw switch (e.errorName) {
        'org.bluez.Error.NotReady' => BluetoothDisabledException(
          'Bluetooth adapter is powered off',
          cause: e,
        ),
        'org.bluez.Error.NotAuthorized' ||
        'org.bluez.Error.AuthenticationRejected' =>
          BluetoothPermissionException('Not authorized during $op', cause: e),
        'org.bluez.Error.DoesNotExist' => DeviceNotFoundException(
          'Unknown device during $op',
          cause: e,
        ),
        _ => BluetoothConnectionException('$op failed', cause: e),
      };
    }
    throw BluetoothConnectionException('$op failed', cause: e);
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>(
    sync: false,
  );
  final StreamController<ConnectionState> _state =
      StreamController<ConnectionState>.broadcast();
  ConnectionState _current = ConnectionState.connected;
  bool _closed = false;

  /// Bytes handed to [send] and not yet covered by a successful [flush].
  ///
  /// dart:io's `Socket` hides its internal outbound buffer (there is no public
  /// "bytes not yet written" counter), so this is tracked around flush(): it
  /// counts every byte since the last successful flush. That makes it an UPPER
  /// bound on the true backlog — the kernel may already have taken some of it —
  /// exact (0) immediately after a flush resolves.
  int _bytesSinceFlush = 0;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<ConnectionState> get stateChanges => _state.stream;

  @override
  ConnectionState get state => _current;

  /// BlueZ hands us a stream socket; the kernel fragments writes of any size,
  /// so there is no OS-advertised per-write payload cap to report.
  @override
  int? get maxPayloadSize => null;

  /// See [_bytesSinceFlush]: an upper bound on bytes accepted by [send] but
  /// not yet handed to the OS, refreshed (to 0) by each successful [flush].
  /// Returns 0 once closed.
  @override
  int get pendingWriteBytes => _closed ? 0 : _bytesSinceFlush;

  @override
  void send(Uint8List data) {
    if (_closed) throw const BluetoothWriteException('transport closed');
    try {
      _socket.add(data);
      // Count only bytes the sink actually accepted. Socket.add's internal
      // buffer is unbounded — writers pacing themselves should flush() (which
      // applies real backpressure) or watch pendingWriteBytes.
      _bytesSinceFlush += data.length;
    } catch (e) {
      // e.g. StateError once the socket's sink has already errored/closed.
      throw BluetoothWriteException('write failed', cause: e);
    }
  }

  @override
  Future<void> flush() async {
    if (_closed) return;
    // Snapshot what THIS flush covers: sends racing in while we await are the
    // next flush's business (Socket.flush may or may not have drained them).
    final covered = _bytesSinceFlush;
    try {
      await _socket.flush();
      _bytesSinceFlush -= covered;
      if (_bytesSinceFlush < 0) _bytesSinceFlush = 0;
    } catch (e) {
      // The link died with bytes still queued (peer powered off mid-write).
      // The socket.done handler tears the transport down; report the loss to
      // the caller as a domain exception rather than a raw SocketException.
      throw BluetoothWriteException('flush failed — link lost', cause: e);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final alreadyDisconnected = _current == ConnectionState.disconnected;
    _current = ConnectionState.disconnected;
    await _sub.cancel();
    // destroy() closes both directions immediately and never blocks — unlike
    // close(), which waits for queued bytes to drain and can stall against a
    // peer that just vanished. Callers wanting a drain use flush() first
    // (BluetoothConnection.finish does).
    _socket.destroy();
    // Drop out of the shared profile's routing tables, then give back the
    // reference acquired at connect time (the LAST release unregisters the
    // profile from BlueZ). `_closed` above guarantees this runs once.
    _shared.removeTransport(_devicePath, this);
    await _shared.release();
    if (!_state.isClosed) {
      if (!alreadyDisconnected) _state.add(ConnectionState.disconnected);
      await _state.close();
    }
    if (!_incoming.isClosed) await _incoming.close();
  }

  void _handleDone() {
    if (!_closed) unawaited(close());
  }
}

/// One shared `org.bluez.Profile1` registration per (D-Bus client, service
/// UUID, channel).
///
/// BlueZ matches ConnectProfile results against its registered profiles by
/// UUID, NOT by which client call triggered them — so two concurrent connects
/// each registering their own Profile1 under the same UUID could have BlueZ
/// hand device B's fd to device A's object (cross-wired transports). Instead
/// ONE object per UUID is registered and its `NewConnection(device, fd, opts)`
/// handler routes each fd by the device object-path argument to the pending
/// connect for THAT device.
///
/// Ownership rules:
/// - Every in-flight connect holds one reference ([acquire]); on failure or
///   timeout it releases it, on success it hands it to the transport it built.
/// - Every open transport holds one reference, released by its close().
/// - So refs == pending connects + open transports. The LAST [release]
///   retires this instance: it is removed from the registry SYNCHRONOUSLY (a
///   racing new connect then builds a fresh registration under its own object
///   path rather than reusing a half-unregistered one) and then unregistered
///   from BlueZ and the bus, best-effort.
class _SharedProfile {
  _SharedProfile._(this._bus, this._key, this._serviceUuid, this._channel)
    : _object = _Profile1(
        DBusObjectPath('/lol/carson/bluetooth_rfcomm/profile${_counter++}'),
      ) {
    _object._owner = this;
  }

  /// Live registrations, per D-Bus client (an Expando rather than a plain
  /// static map so backends with injected buses — tests, multi-adapter apps —
  /// never share or leak each other's profile objects).
  static final Expando<Map<String, _SharedProfile>> _registries =
      Expando<Map<String, _SharedProfile>>();

  static int _counter = 0;

  static Map<String, _SharedProfile> _registryFor(DBusClient bus) =>
      _registries[bus] ??= <String, _SharedProfile>{};

  final DBusClient _bus;
  final String _key;
  final Uuid _serviceUuid;
  final int? _channel;
  final _Profile1 _object;

  /// Pending connects + open transports — see the class doc's ownership rules.
  int _refs = 0;

  /// Memoized so concurrent connects for the same UUID await ONE
  /// RegisterProfile instead of racing duplicates.
  Future<void>? _registration;

  /// Connects waiting on NewConnection, FIFO per device object path.
  final Map<String, List<Completer<Socket>>> _pending = {};

  /// Open transports per device object path — consulted to route
  /// RequestDisconnection and to politely reject an fd for an
  /// already-connected device.
  final Map<String, Set<_LinuxRfcommProfile>> _transports = {};

  /// Returns the shared profile for ([serviceUuid], [channel]) on [bus] with
  /// one reference taken and its BlueZ registration completed. On registration
  /// failure the reference is given back before rethrowing.
  static Future<_SharedProfile> acquire({
    required DBusClient bus,
    required Uuid serviceUuid,
    required int? channel,
  }) async {
    // The channel participates in the key because it is fixed at
    // RegisterProfile time (a profile option, not a ConnectProfile argument):
    // connects demanding different channels genuinely need different
    // registrations. Uuid.value is canonical lower-case, so equal UUIDs
    // always share.
    final key = '${serviceUuid.value}#${channel ?? 0}';
    final registry = _registryFor(bus);
    final shared = registry[key] ??= _SharedProfile._(
      bus,
      key,
      serviceUuid,
      channel,
    );
    shared._refs++;
    try {
      await (shared._registration ??= shared._register());
    } catch (_) {
      // Un-memoize: a failed (or timed-out) registration must be retried by
      // the next connect, not replayed to it.
      shared._registration = null;
      await shared.release();
      rethrow;
    }
    return shared;
  }

  Future<void> _register() async {
    await _bus.registerObject(_object);
    final options = <String, DBusValue>{'Role': const DBusString('client')};
    final channel = _channel;
    if (channel != null && channel > 0) {
      options['Channel'] = DBusUint16(channel);
    }
    await _manager()
        .callMethod(
          'org.bluez.ProfileManager1',
          'RegisterProfile',
          [
            _object.path,
            DBusString(_serviceUuid.value),
            DBusDict.stringVariant(options),
          ],
          replySignature: DBusSignature(''),
        )
        .timeout(LinuxBluetoothRfcomm._busTimeout);
  }

  DBusRemoteObject _manager() => DBusRemoteObject(
    _bus,
    name: 'org.bluez',
    path: DBusObjectPath('/org/bluez'),
  );

  /// Enlists a connect waiting for [devicePath]'s fd. The caller MUST pair
  /// this with either a routed completion, or [abandonPending] + [release] on
  /// its terminal failure path.
  Completer<Socket> addPending(String devicePath) {
    final completer = Completer<Socket>();
    _pending
        .putIfAbsent(devicePath, () => <Completer<Socket>>[])
        .add(completer);
    return completer;
  }

  /// Withdraws a timed-out/failed pending connect, so a late fd for that
  /// device is destroyed (see [_handleNewConnection]) instead of completing a
  /// connect nobody is awaiting anymore.
  void abandonPending(String devicePath, Completer<Socket> completer) {
    final queue = _pending[devicePath];
    if (queue == null) return;
    queue.remove(completer);
    if (queue.isEmpty) _pending.remove(devicePath);
  }

  void addTransport(String devicePath, _LinuxRfcommProfile transport) {
    _transports
        .putIfAbsent(devicePath, () => <_LinuxRfcommProfile>{})
        .add(transport);
  }

  void removeTransport(String devicePath, _LinuxRfcommProfile transport) {
    final set = _transports[devicePath];
    if (set == null) return;
    set.remove(transport);
    if (set.isEmpty) _transports.remove(devicePath);
  }

  /// Gives back one reference; the LAST one retires this instance (see the
  /// class doc). The returned future completes once any resulting BlueZ
  /// unregistration has finished, so a transport's close() can await the same
  /// cleanup the old per-connect profile awaited.
  Future<void> release() async {
    _refs--;
    if (_refs > 0) return;
    final registry = _registryFor(_bus);
    // `identical`: a later connect may already have replaced this retired
    // instance under the same key — never evict the newcomer.
    if (identical(registry[_key], this)) registry.remove(_key);
    try {
      // Bounded: this is awaited inside transport.close(), and a wedged
      // bluetoothd must not hang teardown.
      await _manager()
          .callMethod(
            'org.bluez.ProfileManager1',
            'UnregisterProfile',
            [_object.path],
            replySignature: DBusSignature(''),
          )
          .timeout(LinuxBluetoothRfcomm._busTimeout);
    } catch (_) {
      /* already gone / never registered / timed out */
    }
    try {
      await _bus.unregisterObject(_object);
    } catch (_) {
      /* already gone */
    }
  }

  /// Routes `NewConnection(object device, fd handle, dict props)`.
  DBusMethodResponse _handleNewConnection(DBusMethodCall methodCall) {
    final values = methodCall.values;
    if (values.length < 2) {
      // Reject so BlueZ tears down the connection instead of leaking its fd.
      return DBusMethodErrorResponse.failed('missing fd');
    }
    // Adopt the fd FIRST: every rejection below must destroy a real socket,
    // or the duplicated fd would leak in this process.
    final Socket socket;
    try {
      socket = values[1].asUnixFd().toSocket();
    } catch (e) {
      return DBusMethodErrorResponse.failed('bad fd: $e');
    }
    final deviceValue = values[0];
    if (deviceValue is! DBusObjectPath) {
      socket.destroy();
      return DBusMethodErrorResponse.failed('missing device object path');
    }
    final devicePath = deviceValue.value;
    final queue = _pending[devicePath];
    if (queue != null && queue.isNotEmpty) {
      final completer = queue.removeAt(0);
      if (queue.isEmpty) _pending.remove(devicePath);
      completer.complete(socket);
      return DBusMethodSuccessResponse([]);
    }
    // No connect is waiting for this device (it timed out, or BlueZ pushed an
    // unsolicited server-role connection). Destroy our copy of the fd and
    // tell BlueZ no, politely.
    socket.destroy();
    return DBusMethodErrorResponse.failed(
      _transports.containsKey(devicePath)
          ? 'already connected'
          : 'no pending connect for this device',
    );
  }

  /// Handles `RequestDisconnection(object device)` and `Release()`. Closing
  /// the transport(s) is what actually tears the Dart side down — otherwise
  /// we'd stay "connected" with a leaked fd after BlueZ dropped the link.
  void _handleDisconnectRequest(DBusMethodCall methodCall) {
    final values = methodCall.values;
    final target = values.isNotEmpty && values[0] is DBusObjectPath
        ? (values[0] as DBusObjectPath).value
        : null;
    // RequestDisconnection names a device — close only its links. Release
    // (and a malformed call) names nobody: BlueZ is done with the whole
    // profile, so every link it owns goes down. Pending connects are left to
    // their own timeouts, matching the previous per-connect behavior.
    final doomed = target != null
        ? (_transports[target]?.toList() ?? const <_LinuxRfcommProfile>[])
        : _transports.values.expand((s) => s).toList();
    for (final transport in doomed) {
      unawaited(transport.close());
    }
  }
}

/// The `org.bluez.Profile1` D-Bus object exported for a [_SharedProfile];
/// method calls are delegated back to the owning shared profile for routing.
class _Profile1 extends DBusObject {
  _Profile1(super.path);

  /// Set by [_SharedProfile]'s constructor immediately after creation (the
  /// two are mutually referential).
  late final _SharedProfile _owner;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.bluez.Profile1') {
      switch (methodCall.name) {
        case 'NewConnection':
          return _owner._handleNewConnection(methodCall);
        case 'RequestDisconnection':
        case 'Release':
          _owner._handleDisconnectRequest(methodCall);
          return DBusMethodSuccessResponse([]);
      }
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}
