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
import 'android_bindings.dart';

/// Android backend.
///
/// The Kotlin `BluetoothGatt` implementation (in the bluetooth_le_flutter
/// plugin) does the work; a C JNI shim exposes a plain C ABI that Dart calls via
/// FFI, and the Kotlin side calls back through the same shim into Dart
/// `NativeCallable.listener`s. This keeps the package Flutter-free (no
/// MethodChannel, no `flutter` dependency) while working inside a Flutter Android
/// app, which provides the ambient JVM.
///
/// All BluetoothGatt operations are non-blocking and complete via callbacks, so
/// (unlike the RFCOMM Android socket path) no helper isolate is needed.
class AndroidBleCentral extends BleCentralPlatform {
  AndroidBleCentral() : _lib = AndroidBindings.open() {
    _activeLib = _lib;
    _lib.register(
      _scanCb.nativeFunction,
      _stateCb.nativeFunction,
      _opCb.nativeFunction,
      _notifyCb.nativeFunction,
    );
    _lib.init();
  }

  final AndroidBindings _lib;

  static AndroidBindings? _activeLib;
  static int _nextScanToken = 1;
  static StreamController<BleScanResult>? _scanController;
  static int _scanToken = 0;
  static int _nextConnToken = 1;
  static int _nextReqId = 1;
  static final Map<int, AndroidGattConnection> _connections = {};
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
  Future<bool> isSupported() async {
    _activeLib = _lib;
    return _lib.adapterState() != _AdapterCode.unavailable;
  }

  @override
  Future<BluetoothAdapterState> adapterState() async {
    _activeLib = _lib;
    return _AdapterCode.toEnum(_lib.adapterState());
  }

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() async* {
    yield await adapterState();
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async =>
      throw const BleUnsupportedException(
        'Programmatic radio toggling is restricted on modern Android; prompt '
        'the user via system UI instead.',
      );

  @override
  Stream<BleScanResult> startScan({List<Uuid>? withServices}) {
    _activeLib = _lib;
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
          if (_lib.startScan(token, ptr.cast()) != 0) {
            controller.addError(const BleScanException('startScan failed'));
          } else {
            logScan.fine('scan started');
          }
        } finally {
          calloc.free(ptr);
        }
      },
      onCancel: () {
        if (_scanToken == token) {
          _lib.stopScan();
          _scanController = null;
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    _lib.stopScan();
    if (_scanController != null && !_scanController!.isClosed) {
      await _scanController!.close();
    }
    _scanController = null;
  }

  @override
  Future<GattConnection> connect(DeviceId id, {Duration? timeout}) async {
    if (!id.isAddress) {
      throw const BleConnectionException(
        'Android requires a MAC-address DeviceId to connect',
      );
    }
    _activeLib = _lib;
    final token = _nextConnToken++;
    final conn = AndroidGattConnection(token, _lib);
    _connections[token] = conn;
    logConnection.fine(() => 'connecting to ${id.value}');
    final addrPtr = id.address.toNativeUtf8();
    final int rc;
    try {
      rc = _lib.connect(token, addrPtr.cast());
    } finally {
      calloc.free(addrPtr);
    }
    if (rc != 0) {
      _connections.remove(token);
      throw DeviceNotFoundException('Cannot connect to ${id.value}', code: rc);
    }
    try {
      await conn.waitConnected(timeout);
    } catch (_) {
      _connections.remove(token);
      rethrow;
    }
    return conn;
  }

  @override
  Future<void> dispose() async {
    for (final c in _connections.values.toList()) {
      await c.close();
    }
    if (_scanController != null && !_scanController!.isClosed) {
      _lib.stopScan();
      await _scanController!.close();
    }
    _scanController = null;
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
      if (json != ffi.nullptr) _activeLib?.free(json.cast());
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
      if (json != ffi.nullptr) _activeLib?.free(json.cast());
      if (data != ffi.nullptr) _activeLib?.free(data.cast());
    }
  }

  static void _onNotify(
    int connToken,
    ffi.Pointer<ffi.Char> characteristic,
    ffi.Pointer<ffi.Uint8> data,
    int len,
  ) {
    try {
      final conn = _connections[connToken];
      if (conn == null || characteristic == ffi.nullptr) return;
      final key = characteristic.cast<Utf8>().toDartString();
      final bytes = (data != ffi.nullptr && len > 0)
          ? Uint8List.fromList(data.asTypedList(len))
          : Uint8List(0);
      conn._onNotifyNative(key, bytes);
    } finally {
      if (characteristic != ffi.nullptr) {
        _activeLib?.free(characteristic.cast());
      }
      if (data != ffi.nullptr) _activeLib?.free(data.cast());
    }
  }

  static BleScanResult _scanResultFromJson(Map<String, dynamic> j) {
    final rssi = (j['rssi'] as num?)?.toInt();
    final addr = j['id'] as String?;
    final device = BleDevice(
      id: (addr != null && addr.isNotEmpty)
          ? DeviceId.address(addr)
          : const DeviceId.opaque('android-device'),
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

/// A live Android GATT connection.
class AndroidGattConnection implements GattConnection {
  AndroidGattConnection(this._token, this._lib);

  final int _token;
  final AndroidBindings _lib;
  final StreamController<BleConnectionState> _stateController =
      StreamController<BleConnectionState>.broadcast();
  final Completer<void> _connected = Completer<void>();
  final Map<String, StreamController<Uint8List>> _notifyControllers = {};
  Future<void> _opChain = Future<void>.value();
  BleConnectionState _current = BleConnectionState.connecting;
  bool _closed = false;

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _opChain.then((_) => op());
    _opChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  void _onNotifyNative(String key, Uint8List value) {
    _notifyControllers[key]?.add(value);
  }

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
        _lib.disconnect(_token);
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
    final reqId = AndroidBleCentral._nextReqId++;
    final completer = Completer<_OpResult>();
    AndroidBleCentral._ops[reqId] = completer;
    logGatt.fine(() => 'discoverServices conn $_token');
    _lib.discoverServices(reqId, _token);
    final r = await completer.future;
    if (r.status != 0 || r.json == null) {
      throw BleGattException('service discovery failed', code: r.status);
    }
    return _parseServices(r.json!);
  }

  @override
  Future<Uint8List> readCharacteristic(Uuid service, Uuid characteristic) {
    return _enqueue(() async {
      final reqId = AndroidBleCentral._nextReqId++;
      final completer = Completer<_OpResult>();
      AndroidBleCentral._ops[reqId] = completer;
      logGatt.fine(() => 'read ${characteristic.value} conn $_token');
      final sPtr = service.value.toNativeUtf8();
      final cPtr = characteristic.value.toNativeUtf8();
      try {
        _lib.read(reqId, _token, sPtr.cast(), cPtr.cast());
      } finally {
        calloc.free(sPtr);
        calloc.free(cPtr);
      }
      final r = await completer.future;
      if (r.status != 0) throw BleGattException('read failed', code: r.status);
      return r.data ?? Uint8List(0);
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
      final reqId = AndroidBleCentral._nextReqId++;
      final completer = Completer<_OpResult>();
      AndroidBleCentral._ops[reqId] = completer;
      logData.finest(
        () => 'write ${characteristic.value} ${describeBytes(value)}',
      );
      final sPtr = service.value.toNativeUtf8();
      final cPtr = characteristic.value.toNativeUtf8();
      final dPtr = value.isEmpty
          ? ffi.nullptr
          : calloc<ffi.Uint8>(value.length);
      if (value.isNotEmpty) {
        dPtr.asTypedList(value.length).setAll(0, value);
      }
      try {
        _lib.write(
          reqId,
          _token,
          sPtr.cast(),
          cPtr.cast(),
          dPtr.cast(),
          value.length,
          withoutResponse ? 1 : 0,
        );
      } finally {
        calloc.free(sPtr);
        calloc.free(cPtr);
        if (value.isNotEmpty) calloc.free(dPtr);
      }
      final r = await completer.future;
      if (r.status != 0) throw BleGattException('write failed', code: r.status);
    });
  }

  @override
  Stream<Uint8List> subscribe(Uuid service, Uuid characteristic) {
    final key = '${service.value}|${characteristic.value}';
    late StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>.broadcast(
      onListen: () {
        _notifyControllers[key] = controller;
        _setNotify(service, characteristic, enable: true);
        logGatt.fine(() => 'subscribe ${characteristic.value} conn $_token');
      },
      onCancel: () {
        _setNotify(service, characteristic, enable: false);
        _notifyControllers.remove(key);
      },
    );
    return controller.stream;
  }

  void _setNotify(Uuid service, Uuid characteristic, {required bool enable}) {
    final sPtr = service.value.toNativeUtf8();
    final cPtr = characteristic.value.toNativeUtf8();
    try {
      _lib.subscribe(_token, sPtr.cast(), cPtr.cast(), enable ? 1 : 0);
    } finally {
      calloc.free(sPtr);
      calloc.free(cPtr);
    }
  }

  @override
  Future<int> requestMtu(int mtu) {
    return _enqueue(() async {
      final reqId = AndroidBleCentral._nextReqId++;
      final completer = Completer<_OpResult>();
      AndroidBleCentral._ops[reqId] = completer;
      _lib.requestMtu(reqId, _token, mtu);
      final r = await completer.future;
      final negotiated = (r.json != null)
          ? (jsonDecode(r.json!) as Map<String, dynamic>)['mtu'] as int?
          : null;
      // MTU exchange is best-effort; fall back to the ATT default.
      return negotiated ?? 23;
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _lib.disconnect(_token);
    _teardown();
  }

  void _teardown() {
    AndroidBleCentral._connections.remove(_token);
    if (_current != BleConnectionState.disconnected) {
      _current = BleConnectionState.disconnected;
      if (!_stateController.isClosed) {
        _stateController.add(BleConnectionState.disconnected);
      }
    }
    for (final c in _notifyControllers.values) {
      if (!c.isClosed) c.close();
    }
    _notifyControllers.clear();
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
    4 => BluetoothAdapterState.turningOn,
    5 => BluetoothAdapterState.on,
    6 => BluetoothAdapterState.turningOff,
    _ => BluetoothAdapterState.unknown,
  };
}
