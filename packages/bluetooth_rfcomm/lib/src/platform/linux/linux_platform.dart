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
    var cancelled = false;
    controller = StreamController<BluetoothAdapterState>.broadcast(
      onListen: () async {
        // Broadcast onListen refires when listeners return after dropping to
        // zero — reset the latch or a re-listened stream stays silent forever.
        cancelled = false;
        final initial = await adapterState();
        if (cancelled) return; // listener went away during the await
        controller.add(initial);
        final created = _obj(_adapterPath).propertiesChanged.listen((
          sig,
        ) async {
          if (sig.propertiesInterface == _adapterIface &&
              sig.changedProperties.containsKey('Powered')) {
            controller.add(await adapterState());
          }
        });
        if (cancelled) {
          await created.cancel(); // cancelled while we were subscribing
        } else {
          sub = created;
        }
      },
      onCancel: () async {
        cancelled = true;
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
          ).listen((signal) {
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
          });
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
          ).listen((signal) async {
            try {
              if (signal.values.isEmpty) return;
              if ((signal.values[0] as DBusString).value != _deviceIface) {
                return;
              }
              final props = await _allDeviceProps(signal.path);
              controller.add(_discoveryFromProps(props));
            } catch (_) {
              /* device vanished mid-update / malformed signal */
            }
          });
      // Ask BlueZ to start inquiring — the op itself checks (serialized, so
      // against FRESH state) whether discovery is already running. A
      // concurrent discovery on this client (race with a stop still in
      // flight) reports InProgress — the radio is already doing what we want,
      // so that's success, not an error.
      await _enqueueDiscoveryOp(() async {
        if (_bluezDiscovering) return;
        if (_discoveryRefs <= 0) return; // everyone left while we queued
        try {
          await _obj(
            _adapterPath,
          ).callMethod(_adapterIface, 'StartDiscovery', []);
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
      await _obj(_adapterPath).callMethod(_adapterIface, 'StopDiscovery', []);
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
    return _LinuxRfcommProfile.connect(
      bus: _bus,
      devicePath: _devicePath(device),
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
    // Only close the client we created; a caller-injected bus is theirs.
    if (_ownsBus) await _bus.close();
  }

  // --- Helpers -------------------------------------------------------------

  /// Translates raw D-Bus failures into this package's domain exceptions so
  /// callers never have to handle `DBus*Exception` directly. Always throws.
  Never _mapDbus(Object e, String op) {
    if (e is BluetoothException) throw e;
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

  DBusObjectPath _devicePath(DeviceId device) {
    final mac = device.address.replaceAll(':', '_').toUpperCase();
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

/// Registers a transient `org.bluez.Profile1` to obtain an RFCOMM file
/// descriptor for SPP, then exposes it as an [RfcommTransport].
class _LinuxRfcommProfile implements RfcommTransport {
  _LinuxRfcommProfile._(this._socket, this._bus, this._profile) {
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

  final DBusClient _bus;
  final DBusObject _profile;

  static int _profileCounter = 0;

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
    // Profile1 object's NewConnection method. We export such an object, register
    // the profile, then trigger Device1.ConnectProfile; the fd that arrives is
    // adopted as a dart:io Socket for duplex I/O.
    final completer = Completer<RfcommTransport>();
    // `settled` covers ALL terminal paths (success, timeout, RegisterProfile /
    // ConnectProfile failure) — `completer.isCompleted` alone misses timeout,
    // because `.timeout()` completes the returned future, not this completer.
    var settled = false;
    final profilePath = DBusObjectPath(
      '/lol/carson/bluetooth_rfcomm/profile${_profileCounter++}',
    );
    late final _Profile1 profile;
    profile = _Profile1(profilePath, (socket) {
      if (settled) {
        // Arrived after a timeout/error — don't leak the fd or the profile.
        socket.destroy();
        unawaited(_unregisterProfile(bus, profile));
        return;
      }
      settled = true;
      final transport = _LinuxRfcommProfile._(socket, bus, profile);
      // BlueZ tells us to drop the link via RequestDisconnection/Release; wire
      // it to the transport's (idempotent) close so the Dart side actually tears
      // down instead of staying "connected" with a leaked fd.
      profile.onDisconnect = () => unawaited(transport.close());
      completer.complete(transport);
    });
    await bus.registerObject(profile);

    final mgr = DBusRemoteObject(
      bus,
      name: 'org.bluez',
      path: DBusObjectPath('/org/bluez'),
    );
    final options = <String, DBusValue>{'Role': const DBusString('client')};
    if (channel != null && channel > 0) {
      options['Channel'] = DBusUint16(channel);
    }
    try {
      await mgr.callMethod(
        'org.bluez.ProfileManager1',
        'RegisterProfile',
        [
          profilePath,
          DBusString(serviceUuid.value),
          DBusDict.stringVariant(options),
        ],
        replySignature: DBusSignature(''),
      );
    } catch (e) {
      settled = true;
      await bus.unregisterObject(profile);
      _throwConnectError(e, 'RegisterProfile');
    }

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
      if (!completer.isCompleted) {
        settled = true;
        unawaited(_unregisterProfile(bus, profile));
        throw BluetoothTimeoutException(
          'RFCOMM connect timed out',
          timeout: deadline,
        );
      }
    } catch (e) {
      // BlueZ can also deliver NewConnection and THEN report an error from
      // ConnectProfile; if the transport exists, the link is up — prefer it
      // over throwing (and over leaking its adopted fd).
      if (!completer.isCompleted) {
        settled = true;
        await _unregisterProfile(bus, profile);
        _throwConnectError(e, 'ConnectProfile');
      }
      logConnection.fine(
        () => 'ConnectProfile errored after NewConnection; using the link: $e',
      );
    }
    if (completer.isCompleted) return completer.future;

    // Wait out the REMAINDER of the deadline for NewConnection.
    final remaining = deadline - sw.elapsed;
    return completer.future.timeout(
      remaining > Duration.zero ? remaining : const Duration(milliseconds: 1),
      onTimeout: () {
        settled = true;
        unawaited(_unregisterProfile(bus, profile));
        throw BluetoothTimeoutException(
          'RFCOMM connect timed out',
          timeout: deadline,
        );
      },
    );
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
        'org.bluez.Error.NotAuthorized' => BluetoothPermissionException(
          'Not authorized during $op',
          cause: e,
        ),
        'org.bluez.Error.DoesNotExist' => DeviceNotFoundException(
          'Unknown device during $op',
          cause: e,
        ),
        _ => BluetoothConnectionException('$op failed', cause: e),
      };
    }
    throw BluetoothConnectionException('$op failed', cause: e);
  }

  /// Unregisters both the BlueZ profile (so bluetoothd forgets it) and the
  /// local D-Bus object. Best-effort; safe to call more than once.
  static Future<void> _unregisterProfile(
    DBusClient bus,
    DBusObject profile,
  ) async {
    try {
      final mgr = DBusRemoteObject(
        bus,
        name: 'org.bluez',
        path: DBusObjectPath('/org/bluez'),
      );
      await mgr.callMethod(
        'org.bluez.ProfileManager1',
        'UnregisterProfile',
        [profile.path],
        replySignature: DBusSignature(''),
      );
    } catch (_) {
      /* already gone */
    }
    try {
      await bus.unregisterObject(profile);
    } catch (_) {
      /* already gone */
    }
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

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<ConnectionState> get stateChanges => _state.stream;

  @override
  ConnectionState get state => _current;

  @override
  void send(Uint8List data) {
    if (_closed) throw const BluetoothWriteException('transport closed');
    try {
      _socket.add(data);
    } catch (e) {
      // e.g. StateError once the socket's sink has already errored/closed.
      throw BluetoothWriteException('write failed', cause: e);
    }
  }

  @override
  Future<void> flush() async {
    if (_closed) return;
    try {
      await _socket.flush();
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
    await _unregisterProfile(_bus, _profile);
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

/// A transient `org.bluez.Profile1` exported on the bus. BlueZ invokes
/// `NewConnection(object device, fd handle, dict props)` with the connected
/// RFCOMM socket as a Unix fd, which we adopt as a dart:io [Socket].
class _Profile1 extends DBusObject {
  _Profile1(super.path, this.onConnection);

  final void Function(Socket socket) onConnection;

  /// Set once the transport exists; invoked when BlueZ asks us to drop the link.
  void Function()? onDisconnect;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.bluez.Profile1') {
      switch (methodCall.name) {
        case 'NewConnection':
          if (methodCall.values.length < 2) {
            // Reject so BlueZ tears down the connection instead of leaking its fd.
            return DBusMethodErrorResponse.failed('missing fd');
          }
          final socket = methodCall.values[1].asUnixFd().toSocket();
          onConnection(socket);
          return DBusMethodSuccessResponse([]);
        case 'RequestDisconnection':
        case 'Release':
          onDisconnect?.call();
          return DBusMethodSuccessResponse([]);
      }
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}
