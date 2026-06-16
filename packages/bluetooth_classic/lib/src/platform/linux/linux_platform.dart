import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import '../../exceptions.dart';
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
class LinuxBluetoothClassic extends BluetoothClassicPlatform {
  LinuxBluetoothClassic({DBusClient? bus, String adapter = 'hci0'})
      : _bus = bus ?? DBusClient.system(),
        _adapterName = adapter;

  final DBusClient _bus;
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
    controller = StreamController<BluetoothAdapterState>.broadcast(
      onListen: () async {
        controller.add(await adapterState());
        final adapter = _obj(_adapterPath);
        sub = adapter.propertiesChanged.listen((sig) async {
          if (sig.propertiesInterface == _adapterIface &&
              sig.changedProperties.containsKey('Powered')) {
            controller.add(await adapterState());
          }
        });
      },
      onCancel: () async {
        await sub?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async {
    await _obj(_adapterPath).setProperty(
      _adapterIface,
      'Powered',
      DBusBoolean(enabled),
    );
  }

  // --- Devices -------------------------------------------------------------

  @override
  Future<List<BluetoothDevice>> bondedDevices() async {
    try {
      final managed = await _managedObjects();
      final result = <BluetoothDevice>[];
      managed.forEach((path, ifaces) {
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
      addedSub = DBusRemoteObjectSignalStream(
        object: om,
        interface: _omIface,
        name: 'InterfacesAdded',
      ).listen((signal) {
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
      });
      // Property updates (e.g. RSSI/name) on known devices.
      changedSub = DBusRemoteObjectSignalStream(
        object: om,
        interface: _propsIface,
        name: 'PropertiesChanged',
      ).listen((signal) async {
        if (signal.values.isEmpty) return;
        if ((signal.values[0] as DBusString).value != _deviceIface) return;
        try {
          final props = await _allDeviceProps(signal.path);
          controller.add(_discoveryFromProps(props));
        } catch (_) {
          /* device vanished mid-update */
        }
      });
      await _obj(_adapterPath).callMethod(_adapterIface, 'StartDiscovery', []);
    }

    controller = StreamController<BluetoothDiscoveryResult>.broadcast(
      onListen: () {
        begin().catchError((Object e) {
          controller.addError(
            BluetoothDiscoveryException('StartDiscovery failed', cause: e),
          );
        });
      },
      onCancel: () async {
        await addedSub?.cancel();
        await changedSub?.cancel();
        await stopDiscovery();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopDiscovery() async {
    try {
      await _obj(_adapterPath).callMethod(_adapterIface, 'StopDiscovery', []);
    } catch (_) {
      // Not discovering — ignore.
    }
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
      final uuids = (props['UUIDs'] as DBusArray?)
              ?.children
              .map((e) => Uuid((e as DBusString).value))
              .toList() ??
          const <Uuid>[];
      final filter = serviceUuid;
      return [
        for (final u in uuids)
          if (filter == null || u == filter)
            BluetoothService(uuid: u, rfcommChannelId: 0),
      ];
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
    return _LinuxRfcommProfile.connect(
      bus: _bus,
      devicePath: _devicePath(device),
      serviceUuid: serviceUuid,
      channel: channel,
      timeout: timeout,
    );
  }

  @override
  Stream<ConnectionState> connectionStateChanges(DeviceId device) {
    late StreamController<ConnectionState> controller;
    StreamSubscription<DBusPropertiesChangedSignal>? sub;
    final obj = _obj(_devicePath(device));
    controller = StreamController<ConnectionState>.broadcast(
      onListen: () async {
        try {
          final p = await obj.getProperty(_deviceIface, 'Connected');
          controller.add((p as DBusBoolean).value
              ? ConnectionState.connected
              : ConnectionState.disconnected);
        } catch (_) {/* ignore */}
        sub = obj.propertiesChanged.listen((sig) {
          final c = sig.changedProperties['Connected'];
          if (c is DBusBoolean) {
            controller.add(c.value
                ? ConnectionState.connected
                : ConnectionState.disconnected);
          }
        });
      },
      onCancel: () async => sub?.cancel(),
    );
    return controller.stream;
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
    await _bus.close();
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
      throw BluetoothPermissionException('Permission denied during $op',
          cause: e);
    }
    if (e is DBusMethodResponseException) {
      throw BluetoothException('BlueZ error during $op', cause: e);
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
    final result = await _obj(path).callMethod(
      _propsIface,
      'GetAll',
      [const DBusString(_deviceIface)],
      replySignature: DBusSignature('a{sv}'),
    );
    return (result.returnValues.first as DBusDict).children.map(
          (k, v) => MapEntry(
            (k as DBusString).value,
            (v as DBusVariant).value,
          ),
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
                    (pk, pv) => MapEntry(
                      (pk as DBusString).value,
                      (pv as DBusVariant).value,
                    ),
                  ),
            ),
          );
      return MapEntry(path as DBusObjectPath, ifaceMap);
    });
  }

  BluetoothDevice _deviceFromProps(Map<String, DBusValue> props) {
    final address = (props['Address'] as DBusString?)?.value ?? '00:00:00:00:00:00';
    final name = (props['Name'] as DBusString?)?.value ??
        (props['Alias'] as DBusString?)?.value;
    final paired = (props['Paired'] as DBusBoolean?)?.value ?? false;
    final connected = (props['Connected'] as DBusBoolean?)?.value ?? false;
    final rssi = (props['RSSI'] as DBusInt16?)?.value;
    final cls = (props['Class'] as DBusUint32?)?.value;
    return BluetoothDevice(
      id: DeviceId.address(address),
      name: name,
      type: BluetoothDeviceType.classic,
      bondState:
          paired ? BluetoothBondState.bonded : BluetoothBondState.none,
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
      onError: _incoming.addError,
      onDone: _handleDone,
      cancelOnError: false,
    );
    _state.add(ConnectionState.connected);
  }

  final DBusClient _bus;
  final DBusObject _profile;

  static int _profileCounter = 0;

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
    final profilePath = DBusObjectPath(
        '/lol/carson/bluetooth_classic/profile${_profileCounter++}');
    late final _Profile1 profile;
    profile = _Profile1(profilePath, (socket) {
      if (!completer.isCompleted) {
        completer.complete(_LinuxRfcommProfile._(socket, bus, profile));
      }
    });
    await bus.registerObject(profile);

    final mgr = DBusRemoteObject(bus,
        name: 'org.bluez', path: DBusObjectPath('/org/bluez'));
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
      await bus.unregisterObject(profile);
      throw BluetoothConnectionException('RegisterProfile failed', cause: e);
    }

    final device = DBusRemoteObject(bus, name: 'org.bluez', path: devicePath);
    try {
      await device.callMethod(
        'org.bluez.Device1',
        'ConnectProfile',
        [DBusString(serviceUuid.value)],
        replySignature: DBusSignature(''),
      );
    } catch (e) {
      await bus.unregisterObject(profile);
      throw BluetoothConnectionException('ConnectProfile failed', cause: e);
    }

    return timeout != null
        ? completer.future.timeout(
            timeout,
            onTimeout: () {
              unawaited(bus.unregisterObject(profile));
              throw BluetoothTimeoutException(
                'RFCOMM connect timed out',
                timeout: timeout,
              );
            },
          )
        : completer.future;
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>(sync: false);
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
    if (_closed) return;
    _socket.add(data);
  }

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _current = ConnectionState.disconnected;
    await _sub.cancel();
    try {
      await _socket.close();
    } catch (_) {/* already gone */}
    _socket.destroy();
    try {
      await _bus.unregisterObject(_profile);
    } catch (_) {/* already gone */}
    if (!_state.isClosed) {
      _state.add(ConnectionState.disconnected);
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

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.bluez.Profile1') {
      switch (methodCall.name) {
        case 'NewConnection':
          if (methodCall.values.length >= 2) {
            final socket = methodCall.values[1].asUnixFd().toSocket();
            onConnection(socket);
          }
          return DBusMethodSuccessResponse([]);
        case 'RequestDisconnection':
        case 'Release':
          return DBusMethodSuccessResponse([]);
      }
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}
