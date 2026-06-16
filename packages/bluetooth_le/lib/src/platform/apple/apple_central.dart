import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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
import 'apple_bindings.dart';

/// macOS + iOS backend over CoreBluetooth (one source for both — CoreBluetooth
/// is identical). Calls into the C ABI in `src/native/apple/` via `dart:ffi`;
/// native events arrive as `NativeCallable.listener` events on this isolate.
///
/// Built incrementally: adapter state, scanning, connect and service discovery
/// are wired; read/write/subscribe land next.
class AppleBleCentral extends BleCentralPlatform {
  AppleBleCentral() {
    bleRegister(
      _scanCb.nativeFunction,
      _stateCb.nativeFunction,
      _opCb.nativeFunction,
      _notifyCb.nativeFunction,
    );
  }

  static int _nextScanToken = 1;
  static StreamController<BleScanResult>? _scanController;
  static int _scanToken = 0;

  static int _nextConnToken = 1;
  static int _nextReqId = 1;
  static final Map<int, AppleGattConnection> _connections = {};
  static final Map<int, Completer<_OpResult>> _ops = {};

  static final ffi.NativeCallable<ScanCbNative> _scanCb =
      ffi.NativeCallable<ScanCbNative>.listener(_onScan);
  static final ffi.NativeCallable<StateCbNative> _stateCb =
      ffi.NativeCallable<StateCbNative>.listener(_onState);
  static final ffi.NativeCallable<OpCbNative> _opCb =
      ffi.NativeCallable<OpCbNative>.listener(_onOp);
  static final ffi.NativeCallable<NotifyCbNative> _notifyCb =
      ffi.NativeCallable<NotifyCbNative>.listener(_onNotify);

  @override
  Future<bool> isSupported() async =>
      bleAdapterState() != _AdapterCode.unavailable;

  @override
  Future<BluetoothAdapterState> adapterState() async =>
      _AdapterCode.toEnum(bleAdapterState());

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() async* {
    yield await adapterState();
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async =>
      throw const BleUnsupportedException(
        'Apps cannot toggle the Bluetooth radio on macOS/iOS.',
      );

  @override
  Stream<BleScanResult> startScan({List<Uuid>? withServices}) {
    final token = _nextScanToken++;
    late StreamController<BleScanResult> controller;
    controller = StreamController<BleScanResult>.broadcast(
      onListen: () {
        _scanController = controller;
        _scanToken = token;
        final csv = (withServices == null || withServices.isEmpty)
            ? ''
            : withServices.map((u) => u.value).join(',');
        final ptr = csv.toNativeUtf8();
        try {
          bleStartScan(token, ptr.cast());
          logScan.fine('scan started');
        } finally {
          calloc.free(ptr);
        }
      },
      onCancel: () {
        if (_scanToken == token) {
          bleStopScan();
          _scanController = null;
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    bleStopScan();
    if (_scanController != null && !_scanController!.isClosed) {
      await _scanController!.close();
    }
    _scanController = null;
  }

  @override
  Future<GattConnection> connect(DeviceId id, {Duration? timeout}) async {
    final token = _nextConnToken++;
    final conn = AppleGattConnection(token);
    _connections[token] = conn;
    logConnection.fine(() => 'connecting to ${id.value}');
    final idPtr = id.value.toNativeUtf8();
    final int rc;
    try {
      rc = bleConnect(token, idPtr.cast());
    } finally {
      calloc.free(idPtr);
    }
    if (rc != 0) {
      _connections.remove(token);
      throw DeviceNotFoundException(
        'Unknown peripheral ${id.value}; scan for it first',
        code: rc,
      );
    }
    try {
      await conn.waitConnected(timeout);
    } catch (_) {
      _connections.remove(token);
      rethrow;
    }
    return conn;
  }

  // --- native callback dispatch --------------------------------------------

  static void _onScan(int token, ffi.Pointer<ffi.Char> json) {
    try {
      final controller = _scanController;
      if (controller == null ||
          controller.isClosed ||
          _scanToken != token ||
          json == ffi.nullptr) {
        return;
      }
      final map =
          jsonDecode(json.cast<Utf8>().toDartString()) as Map<String, dynamic>;
      controller.add(_scanResultFromJson(map));
    } catch (e) {
      logNative.fine(() => 'skipped malformed scan result: $e');
    } finally {
      if (json != ffi.nullptr) bleFree(json.cast());
    }
  }

  static void _onState(int connToken, int state) {
    _connections[connToken]?._onStateNative(state);
  }

  static void _onOp(
    int reqId,
    int status,
    ffi.Pointer<ffi.Char> json,
    ffi.Pointer<ffi.Uint8> data,
    int len,
  ) {
    try {
      String? jsonStr;
      Uint8List? bytes;
      if (json != ffi.nullptr) jsonStr = json.cast<Utf8>().toDartString();
      if (data != ffi.nullptr && len > 0) {
        bytes = Uint8List.fromList(data.asTypedList(len));
      }
      _ops.remove(reqId)?.complete(_OpResult(status, jsonStr, bytes));
    } finally {
      if (json != ffi.nullptr) bleFree(json.cast());
      if (data != ffi.nullptr) bleFree(data.cast());
    }
  }

  static void _onNotify(
    int connToken,
    ffi.Pointer<ffi.Char> characteristic,
    ffi.Pointer<ffi.Uint8> data,
    int len,
  ) {
    // Notification routing is wired in the read/write/subscribe revision.
    if (characteristic != ffi.nullptr) bleFree(characteristic.cast());
    if (data != ffi.nullptr) bleFree(data.cast());
  }

  static BleScanResult _scanResultFromJson(Map<String, dynamic> j) {
    final rssi = (j['rssi'] as num?)?.toInt();
    final device = BleDevice(
      id: DeviceId.opaque(j['id'] as String),
      name: j['name'] as String?,
      rssi: rssi,
    );
    final serviceUuids =
        (j['serviceUuids'] as List?)
            ?.map((s) => Uuid(s as String))
            .toList(growable: false) ??
        const <Uuid>[];
    final manufacturerData = <int, Uint8List>{};
    (j['manufacturerData'] as Map?)?.forEach((k, v) {
      manufacturerData[int.parse(k as String)] = _hexToBytes(v as String);
    });
    final serviceData = <Uuid, Uint8List>{};
    (j['serviceData'] as Map?)?.forEach((k, v) {
      serviceData[Uuid(k as String)] = _hexToBytes(v as String);
    });
    return BleScanResult(
      device: device,
      timestamp: DateTime.now(),
      rssi: rssi,
      serviceUuids: serviceUuids,
      manufacturerData: manufacturerData,
      serviceData: serviceData,
      connectable: (j['connectable'] as bool?) ?? true,
    );
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// A live CoreBluetooth GATT connection.
class AppleGattConnection implements GattConnection {
  AppleGattConnection(this._token);

  final int _token;
  final StreamController<BleConnectionState> _stateController =
      StreamController<BleConnectionState>.broadcast();
  final Completer<void> _connected = Completer<void>();
  BleConnectionState _current = BleConnectionState.connecting;
  bool _closed = false;

  void _onStateNative(int code) {
    final s = code == 2
        ? BleConnectionState.connected
        : BleConnectionState.disconnected;
    _current = s;
    if (!_stateController.isClosed) _stateController.add(s);
    if (s == BleConnectionState.connected) {
      if (!_connected.isCompleted) _connected.complete();
    } else {
      if (!_connected.isCompleted) {
        _connected.completeError(
          const BleConnectionException('failed to connect'),
          StackTrace.current,
        );
      }
      _teardown();
    }
  }

  Future<void> waitConnected(Duration? timeout) {
    if (timeout == null) return _connected.future;
    return _connected.future.timeout(
      timeout,
      onTimeout: () {
        bleDisconnect(_token);
        _teardown();
        throw BleTimeoutException('connect timed out', timeout: timeout);
      },
    );
  }

  @override
  Stream<BleConnectionState> get stateChanges => _stateController.stream;

  @override
  BleConnectionState get state => _current;

  @override
  Future<List<BleService>> discoverServices() async {
    final reqId = AppleBleCentral._nextReqId++;
    final completer = Completer<_OpResult>();
    AppleBleCentral._ops[reqId] = completer;
    logGatt.fine(() => 'discoverServices conn $_token');
    bleDiscoverServices(reqId, _token);
    final r = await completer.future;
    if (r.status != 0 || r.json == null) {
      throw BleGattException('service discovery failed', code: r.status);
    }
    return _parseServices(r.json!);
  }

  @override
  Future<Uint8List> readCharacteristic(
    Uuid service,
    Uuid characteristic,
  ) async => throw const BleUnsupportedException('GATT read is not wired yet');

  @override
  Future<void> writeCharacteristic(
    Uuid service,
    Uuid characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  }) async =>
      throw const BleUnsupportedException('GATT write is not wired yet');

  @override
  Stream<Uint8List> subscribe(Uuid service, Uuid characteristic) =>
      throw const BleUnsupportedException('GATT subscribe is not wired yet');

  @override
  Future<int> requestMtu(int mtu) async =>
      throw const BleUnsupportedException('requestMtu is not wired yet');

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    bleDisconnect(_token);
    _teardown();
  }

  void _teardown() {
    AppleBleCentral._connections.remove(_token);
    if (_current != BleConnectionState.disconnected) {
      _current = BleConnectionState.disconnected;
      if (!_stateController.isClosed) {
        _stateController.add(BleConnectionState.disconnected);
      }
    }
    if (!_stateController.isClosed) _stateController.close();
  }

  static List<BleService> _parseServices(String json) {
    final list = jsonDecode(json) as List;
    return list.map((s) {
      final m = s as Map<String, dynamic>;
      final serviceUuid = Uuid(m['uuid'] as String);
      final chars = (m['characteristics'] as List).map((c) {
        final cm = c as Map<String, dynamic>;
        final props = <CharacteristicProperty>{};
        for (final p in cm['properties'] as List) {
          for (final cp in CharacteristicProperty.values) {
            if (cp.name == p) props.add(cp);
          }
        }
        return BleCharacteristic(
          serviceUuid: serviceUuid,
          uuid: Uuid(cm['uuid'] as String),
          properties: props,
        );
      }).toList();
      return BleService(uuid: serviceUuid, characteristics: chars);
    }).toList();
  }
}

class _OpResult {
  const _OpResult(this.status, this.json, this.data);
  final int status;
  final String? json;
  final Uint8List? data;
}

abstract final class _AdapterCode {
  static const int unavailable = 1;
  static BluetoothAdapterState toEnum(int code) => switch (code) {
    1 => BluetoothAdapterState.unavailable,
    2 => BluetoothAdapterState.unauthorized,
    3 => BluetoothAdapterState.off,
    5 => BluetoothAdapterState.on,
    _ => BluetoothAdapterState.unknown,
  };
}
