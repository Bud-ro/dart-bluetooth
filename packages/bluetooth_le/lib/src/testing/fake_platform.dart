import 'dart:async';
import 'dart:typed_data';

import '../exceptions.dart';
import '../models/ble_device.dart';
import '../models/ble_service.dart';
import '../models/device_id.dart';
import '../models/enums.dart';
import '../models/scan_result.dart';
import '../models/uuid.dart';
import '../platform/platform_interface.dart';

/// A scriptable, in-memory [BleCentralPlatform] for tests.
class FakeBleCentralPlatform extends BleCentralPlatform {
  FakeBleCentralPlatform({
    this.supported = true,
    BluetoothAdapterState adapterState = BluetoothAdapterState.on,
  }) : _adapterState = adapterState;

  bool supported;
  BluetoothAdapterState _adapterState;

  /// Sightings emitted (in order) when [startScan] is listened to.
  final List<BleScanResult> scanResults = [];

  /// If set, the scan stream emits this error after any [scanResults].
  Object? scanError;

  /// If set, [connect] throws this instead of returning a connection.
  Object? connectError;

  /// Connections handed out by [connect], in order.
  final List<FakeGattConnection> connections = [];

  bool scanStarted = false;
  bool scanStopped = false;

  final StreamController<BluetoothAdapterState> _adapterController =
      StreamController<BluetoothAdapterState>.broadcast();

  /// A ready-made sample device.
  static BleDevice sampleDevice({
    String address = 'AA:BB:CC:DD:EE:FF',
    String name = 'Test Device',
    int? rssi,
  }) => BleDevice(id: DeviceId.address(address), name: name, rssi: rssi);

  void emitAdapterState(BluetoothAdapterState state) {
    _adapterState = state;
    _adapterController.add(state);
  }

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<BluetoothAdapterState> adapterState() async => _adapterState;

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() {
    late StreamController<BluetoothAdapterState> proxy;
    StreamSubscription<BluetoothAdapterState>? sub;
    proxy = StreamController<BluetoothAdapterState>.broadcast(
      onListen: () {
        proxy.add(_adapterState);
        sub = _adapterController.stream.listen(proxy.add);
      },
      onCancel: () async => sub?.cancel(),
    );
    return proxy.stream;
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async {
    emitAdapterState(
      enabled ? BluetoothAdapterState.on : BluetoothAdapterState.off,
    );
  }

  @override
  Stream<BleScanResult> startScan({List<Uuid>? withServices}) {
    late StreamController<BleScanResult> controller;
    controller = StreamController<BleScanResult>.broadcast(
      onListen: () {
        scanStarted = true;
        for (final r in scanResults) {
          if (withServices == null ||
              withServices.any(r.serviceUuids.contains)) {
            controller.add(r);
          }
        }
        if (scanError != null) controller.addError(scanError!);
      },
      onCancel: () => scanStopped = true,
    );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    scanStopped = true;
  }

  @override
  Future<GattConnection> connect(DeviceId id, {Duration? timeout}) async {
    final err = connectError;
    if (err != null) throw err;
    final conn = FakeGattConnection(id);
    connections.add(conn);
    return conn;
  }

  @override
  Future<void> dispose() async {
    await _adapterController.close();
  }
}

/// A controllable [GattConnection] for tests.
class FakeGattConnection implements GattConnection {
  FakeGattConnection(this.id);

  /// The device id this connection was opened for.
  final DeviceId id;

  /// Services returned by [discoverServices].
  final List<BleService> services = [];

  /// Values [readCharacteristic] returns, keyed by characteristic UUID.
  final Map<Uuid, Uint8List> readValues = {};

  /// Everything written, in order, as (characteristic, value, withoutResponse).
  final List<({Uuid characteristic, Uint8List value, bool withoutResponse})>
  writes = [];

  /// MTU returned by [requestMtu] (capped to the request).
  int mtu = 23;

  final Map<Uuid, StreamController<Uint8List>> _notify = {};
  final StreamController<BleConnectionState> _state =
      StreamController<BleConnectionState>.broadcast();
  BleConnectionState _current = BleConnectionState.connected;
  bool _closed = false;

  /// Pushes [bytes] as a notification on [characteristic].
  void deliver(Uuid characteristic, List<int> bytes) {
    _notify[characteristic]?.add(Uint8List.fromList(bytes));
  }

  @override
  Stream<BleConnectionState> get stateChanges => _state.stream;

  @override
  BleConnectionState get state => _current;

  @override
  Future<List<BleService>> discoverServices() async => services;

  @override
  Future<Uint8List> readCharacteristic(
    Uuid service,
    Uuid characteristic,
  ) async => readValues[characteristic] ?? Uint8List(0);

  @override
  Future<void> writeCharacteristic(
    Uuid service,
    Uuid characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  }) async {
    if (_closed) throw const BleGattException('GATT connection is closed');
    writes.add((
      characteristic: characteristic,
      value: Uint8List.fromList(value),
      withoutResponse: withoutResponse,
    ));
  }

  @override
  Stream<Uint8List> subscribe(Uuid service, Uuid characteristic) {
    final c = _notify.putIfAbsent(
      characteristic,
      () => StreamController<Uint8List>.broadcast(),
    );
    return c.stream;
  }

  @override
  Future<int> requestMtu(int requested) async {
    mtu = requested.clamp(23, 517);
    return mtu;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _current = BleConnectionState.disconnected;
    if (!_state.isClosed) {
      _state.add(BleConnectionState.disconnected);
      await _state.close();
    }
    for (final c in _notify.values) {
      if (!c.isClosed) await c.close();
    }
  }
}
