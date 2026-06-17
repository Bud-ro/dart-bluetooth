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
      _adapterName = adapter;

  final DBusClient _bus;
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
    var cancelled = false;
    controller = StreamController<BluetoothAdapterState>.broadcast(
      onListen: () async {
        final initial = await adapterState();
        if (cancelled) return;
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
          await created.cancel();
        } else {
          sub = created;
        }
      },
      onCancel: () async {
        cancelled = true;
        await sub?.cancel();
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
          ).listen((signal) {
            try {
              if (signal.values.length < 2) return;
              final ifaces = _ifacesFromDict(signal.values[1] as DBusDict);
              final props = ifaces[_deviceIface];
              if (props != null) controller.add(_scanResultFromProps(props));
            } catch (_) {
              // Skip a malformed signal rather than erroring the scan stream.
            }
          });
      // RSSI/name updates on already-known devices arrive as PropertiesChanged
      // from each device's own path, so match the adapter path namespace.
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
              final props = await _allProps(signal.path, _deviceIface);
              controller.add(_scanResultFromProps(props));
            } catch (_) {
              // Device vanished mid-update / malformed signal.
            }
          });

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
      await _obj(
        _adapterPath,
      ).callMethod(_adapterIface, 'StartDiscovery', []).timeout(_busTimeout);
      logScan.fine('scan started');
    }

    controller = StreamController<BleScanResult>.broadcast(
      onListen: () {
        begin().catchError((Object e) {
          controller.addError(
            BleScanException('StartDiscovery failed', cause: e),
          );
        });
      },
      onCancel: () async {
        await addedSub?.cancel();
        await changedSub?.cancel();
        await stopScan();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
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
    await _bus.close();
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
        final company = (k as DBusUint16).value;
        manufacturerData[company] = _bytesOf((v as DBusVariant).value);
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
    _deviceSub = _obj(_devicePath).propertiesChanged.listen((sig) {
      if (sig.propertiesInterface != _deviceIface) return;
      final connected = sig.changedProperties['Connected'];
      if (connected is DBusBoolean && !connected.value) {
        _setState(BleConnectionState.disconnected);
        _teardown();
      }
    });
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
    final sub = device.propertiesChanged.listen((sig) {
      if (sig.propertiesInterface != _deviceIface) return;
      final r = sig.changedProperties['ServicesResolved'];
      if (r is DBusBoolean && r.value && !done.isCompleted) done.complete();
      final c = sig.changedProperties['Connected'];
      if (c is DBusBoolean && !c.value && !done.isCompleted) {
        done.complete(); // disconnect; the device watch handles teardown
      }
    });
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
    var cancelled = false;
    controller = StreamController<Uint8List>.broadcast(
      onListen: () async {
        _notifyCtrls.add(controller);
        try {
          final path = await _charPath(service, characteristic);
          if (cancelled) return;
          sub = _obj(path).propertiesChanged.listen((sig) {
            if (sig.propertiesInterface != _charIface) return;
            final value = sig.changedProperties['Value'];
            if (value != null) {
              controller.add(LinuxBleCentral._bytesOf(value));
            }
          });
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
          controller.addError(_gattError(e, 'subscribe'));
        }
      },
      onCancel: () async {
        cancelled = true;
        if (sub != null) {
          _notifySubs.remove(sub);
          await sub!.cancel();
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
