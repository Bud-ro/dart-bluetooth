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
/// Full GATT central: adapter state, scanning, connect, service discovery, and
/// characteristic read/write/subscribe/MTU are all wired.
class AppleBleCentral extends BleCentralPlatform {
  // The native CoreBluetooth layer is a process singleton (one central manager,
  // one set of registered callbacks), so the Dart backend is too: constructing
  // it more than once returns the same instance. This keeps the static
  // connection/scan/op state single-owner — `dispose()` on "one" central can't
  // tear down another's connections.
  factory AppleBleCentral() => _instance ??= AppleBleCentral._();
  static AppleBleCentral? _instance;

  AppleBleCentral._() {
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
        // CoreBluetooth runs a single scan; reject a second concurrent one with
        // a clear error rather than silently replacing the first.
        if (_scanController != null && !_scanController!.isClosed) {
          controller.addError(
            const BleScanException('a scan is already in progress'),
          );
          return;
        }
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

  @override
  Future<void> dispose() async {
    for (final c in _connections.values.toList()) {
      await c.close();
    }
    bleStopScan();
    if (_scanController != null && !_scanController!.isClosed) {
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
    try {
      final conn = _connections[connToken];
      if (conn == null || characteristic == ffi.nullptr) return;
      final key = characteristic.cast<Utf8>().toDartString();
      final bytes = (data != ffi.nullptr && len > 0)
          ? Uint8List.fromList(data.asTypedList(len))
          : Uint8List(0);
      conn._onNotifyNative(key, bytes);
    } finally {
      if (characteristic != ffi.nullptr) bleFree(characteristic.cast());
      if (data != ffi.nullptr) bleFree(data.cast());
    }
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
  final Map<String, StreamController<Uint8List>> _notifyControllers = {};
  Future<void> _opChain = Future<void>.value();
  BleConnectionState _current = BleConnectionState.connecting;
  bool _closed = false;

  // CoreBluetooth allows overlapping GATT ops, but serialising keeps ordering
  // simple and matches the other backends (Android requires it).
  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _opChain.then((_) => op());
    _opChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  // reqIds for this connection's in-flight ops, so teardown can fail them
  // instead of leaving their Completers (and the op chain) hung forever.
  final Set<int> _pendingReqs = {};

  // Registers an op, issues the native call, and awaits its result — removing
  // the Completer if the native call throws synchronously (no leak) and on
  // completion (so teardown only sees genuinely in-flight ops).
  Future<_OpResult> _runOp(void Function(int reqId) issue) async {
    final reqId = AppleBleCentral._nextReqId++;
    final completer = Completer<_OpResult>();
    AppleBleCentral._ops[reqId] = completer;
    _pendingReqs.add(reqId);
    try {
      issue(reqId);
    } catch (_) {
      AppleBleCentral._ops.remove(reqId);
      _pendingReqs.remove(reqId);
      rethrow;
    }
    try {
      return await completer.future;
    } finally {
      _pendingReqs.remove(reqId);
    }
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
    // _teardown() may completeError(_connected) after the timeout already fired;
    // a detached handler keeps that from surfacing as an unhandled async error.
    unawaited(_connected.future.catchError((_) {}));
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
  Future<List<BleService>> discoverServices() {
    return _enqueue(() async {
      logGatt.fine(() => 'discoverServices conn $_token');
      final r = await _runOp((reqId) => bleDiscoverServices(reqId, _token));
      if (r.status != 0 || r.json == null) {
        throw BleGattException('service discovery failed', code: r.status);
      }
      try {
        return _parseServices(r.json!);
      } catch (e) {
        throw BleGattException('malformed service discovery payload', cause: e);
      }
    });
  }

  @override
  Future<Uint8List> readCharacteristic(Uuid service, Uuid characteristic) {
    return _enqueue(() async {
      logGatt.fine(() => 'read ${characteristic.value} conn $_token');
      final r = await _runOp((reqId) {
        final sPtr = service.value.toNativeUtf8();
        final cPtr = characteristic.value.toNativeUtf8();
        try {
          bleRead(reqId, _token, sPtr.cast(), cPtr.cast());
        } finally {
          calloc.free(sPtr);
          calloc.free(cPtr);
        }
      });
      if (r.status != 0) {
        throw BleGattException('read failed', code: r.status);
      }
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
      logData.finest(
        () => 'write ${characteristic.value} ${describeBytes(value)}',
      );
      final r = await _runOp((reqId) {
        final sPtr = service.value.toNativeUtf8();
        final cPtr = characteristic.value.toNativeUtf8();
        // ble_write copies the bytes into an NSData synchronously, so freeing
        // the buffer right after the call returns is safe.
        final dPtr = value.isEmpty
            ? ffi.nullptr
            : calloc<ffi.Uint8>(value.length);
        if (value.isNotEmpty) {
          dPtr.asTypedList(value.length).setAll(0, value);
        }
        try {
          bleWrite(
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
      });
      if (r.status != 0) {
        throw BleGattException('write failed', code: r.status);
      }
    });
  }

  @override
  Stream<Uint8List> subscribe(Uuid service, Uuid characteristic) {
    final key = '${service.value}|${characteristic.value}';
    // One shared broadcast controller per characteristic: every subscriber gets
    // the same stream, so notifications fan out to all. The broadcast
    // onListen/onCancel fire on the first/last listener across all subscribers,
    // giving enable-on-first / disable-on-last for free.
    final controller = _notifyControllers.putIfAbsent(key, () {
      late StreamController<Uint8List> c;
      c = StreamController<Uint8List>.broadcast(
        onListen: () {
          _setNotify(service, characteristic, enable: true);
          logGatt.fine(() => 'subscribe ${characteristic.value} conn $_token');
        },
        onCancel: () {
          _setNotify(service, characteristic, enable: false);
          // Drop the (now listener-less) controller so a later subscribe starts
          // a fresh one; teardown closes any that remain.
          _notifyControllers.remove(key);
        },
      );
      return c;
    });
    return controller.stream;
  }

  void _setNotify(Uuid service, Uuid characteristic, {required bool enable}) {
    final sPtr = service.value.toNativeUtf8();
    final cPtr = characteristic.value.toNativeUtf8();
    try {
      bleSubscribe(_token, sPtr.cast(), cPtr.cast(), enable ? 1 : 0);
    } finally {
      calloc.free(sPtr);
      calloc.free(cPtr);
    }
  }

  @override
  Future<int> requestMtu(int mtu) async {
    // CoreBluetooth negotiates the ATT MTU automatically; there's no API to
    // request a specific value. Report the usable size instead.
    return bleMaxWriteLen(_token, 1);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    bleDisconnect(_token);
    _teardown();
  }

  bool _torn = false;

  void _teardown() {
    if (_torn) return;
    _torn = true;
    AppleBleCentral._connections.remove(_token);
    // Fail any in-flight GATT ops so their awaits (and the op chain) don't hang
    // forever when the link drops or close() races a pending op.
    for (final reqId in _pendingReqs.toList()) {
      AppleBleCentral._ops
          .remove(reqId)
          ?.complete(const _OpResult(-1, null, null));
    }
    _pendingReqs.clear();
    if (!_connected.isCompleted) {
      _connected.completeError(
        const BleConnectionException('connection closed'),
        StackTrace.current,
      );
    }
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
    5 => BluetoothAdapterState.on,
    _ => BluetoothAdapterState.unknown,
  };
}
