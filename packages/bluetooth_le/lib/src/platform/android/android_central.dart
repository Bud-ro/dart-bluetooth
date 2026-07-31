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
  // The native JNI layer is a process singleton (one registered callback set,
  // one JVM bridge), so the Dart backend is too: constructing it more than once
  // returns the same instance, keeping the static connection/scan/op state
  // single-owner.
  factory AndroidBleCentral() => _instance ??= AndroidBleCentral._();
  static AndroidBleCentral? _instance;

  AndroidBleCentral._() : _lib = AndroidBindings.instance {
    // The callables must pin this isolate while native sources can dial them.
    _setCallablesKeepAlive(true);
    // Order is load-bearing: register FIRST so the process-global callback
    // slots point at THIS isolate's live trampolines, THEN reset to quiesce
    // any sources a hot-restarted predecessor left running — their dying
    // events land here and are token-dropped, instead of dialing destroyed
    // trampolines (a native crash).
    _lib.register(
      _scanCb.nativeFunction,
      _stateCb.nativeFunction,
      _opCb.nativeFunction,
      _notifyCb.nativeFunction,
    );
    _lib.registerScanFailed(_scanFailedCb.nativeFunction);
    _initCode = _lib.init();
    _lib.reset();
  }

  /// Last `ble_and_init` result: 0 ready, 1 no adapter, 2 no Application
  /// context yet, 7 JNI bridge failure (no JVM / Kotlin class missing — e.g.
  /// stripped by R8). Only 0 and 1 are settled; anything else is retried.
  int _initCode = 0;

  /// Fails loudly when the JNI bridge itself is broken instead of letting
  /// every API degrade into empty scans and generic connect failures.
  void _ensureBridge() {
    if (_initCode == 0 || _initCode == 1) return;
    _initCode = _lib.init();
    if (_initCode == 0 || _initCode == 1) return;
    throw BleException(
      _initCode == 7
          ? 'Android JNI bridge failed: the native library cannot reach the '
                'Kotlin backend (is bluetooth_le_flutter in the app, and is '
                'BluetoothLeAndroid kept by R8/ProGuard?)'
          : 'Android backend initialization failed: no Application context',
      code: _initCode,
    );
  }

  static void _setCallablesKeepAlive(bool alive) {
    _scanCb.keepIsolateAlive = alive;
    _stateCb.keepIsolateAlive = alive;
    _opCb.keepIsolateAlive = alive;
    _notifyCb.keepIsolateAlive = alive;
  }

  final AndroidBindings _lib;

  static int _nextScanToken = 1;
  static StreamController<BleScanResult>? _scanController;
  static int _scanToken = 0;
  static int _nextConnToken = 1;
  static int _nextReqId = 1;
  static final Map<int, AndroidGattConnection> _connections = {};
  static final Map<int, Completer<_OpResult>> _ops = {};

  static final ffi.NativeCallable<ScanCbNative> _scanCb =
      ffi.NativeCallable<ScanCbNative>.listener(_onScan);
  static final ffi.NativeCallable<ScanFailedCbNative> _scanFailedCb =
      ffi.NativeCallable<ScanFailedCbNative>.listener(_onScanFailed);
  static final ffi.NativeCallable<StateCbNative> _stateCb =
      ffi.NativeCallable<StateCbNative>.listener(_onState);
  static final ffi.NativeCallable<OpCbNative> _opCb =
      ffi.NativeCallable<OpCbNative>.listener(_onOp);
  static final ffi.NativeCallable<NotifyCbNative> _notifyCb =
      ffi.NativeCallable<NotifyCbNative>.listener(_onNotify);

  @override
  Future<bool> isSupported() async {
    // Throws on a broken JNI bridge: "false" must mean "no BLE radio",
    // never "the plumbing is broken".
    _ensureBridge();
    return _lib.adapterState() != _AdapterCode.unavailable;
  }

  @override
  Future<BluetoothAdapterState> adapterState() async {
    _ensureBridge();
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
    _ensureBridge();
    final token = _nextScanToken++;
    late StreamController<BleScanResult> controller;
    controller = StreamController<BleScanResult>.broadcast(
      onListen: () {
        // One active scan at a time; reject a second concurrent one clearly
        // rather than silently replacing the first.
        if (_scanController != null && !_scanController!.isClosed) {
          controller.addError(
            const BleScanException('a scan is already in progress'),
          );
          // A scan that never started produces no results and no done on its
          // own — close so error-tolerant listeners see a terminal event, not
          // a hang.
          unawaited(controller.close());
          return;
        }
        _scanController = controller;
        _scanToken = token;
        final csv = (withServices == null || withServices.isEmpty)
            ? ''
            : withServices.map((u) => u.value).join(',');
        final ptr = csv.toNativeUtf8();
        try {
          final rc = _lib.startScan(token, ptr.cast());
          if (rc != 0) {
            // Mirrors connect(): distinct codes so a retry loop can't spin
            // forever on a permission/power problem it can never fix.
            controller.addError(switch (rc) {
              -2 => BleDisabledException(
                'Bluetooth adapter is off or unavailable',
                code: rc,
              ),
              -3 => BlePermissionException(
                'Missing BLUETOOTH_SCAN permission',
                code: rc,
              ),
              _ => BleScanException('startScan failed', code: rc),
            });
            _scanController = null;
            unawaited(controller.close());
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
    _ensureBridge();
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
      // The Kotlin side reports distinct codes (additively — older natives
      // still return -1): -2 adapter missing/off, -3 SecurityException
      // (missing BLUETOOTH_CONNECT). Don't collapse those into a transient
      // not-found, or a retry-while-isTransient loop spins forever on a
      // permission/power problem it can never fix.
      throw switch (rc) {
        -2 => BleDisabledException(
          'Bluetooth adapter is off or unavailable',
          code: rc,
        ),
        -3 => BlePermissionException(
          'Missing BLUETOOTH_CONNECT permission',
          code: rc,
        ),
        _ => DeviceNotFoundException('Cannot connect to ${id.value}', code: rc),
      };
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
    // Quiesce every remaining native event source, then null the process
    // callback slots: reset() tears Kotlin sources down asynchronously, and
    // any final callback must find empty slots (the C shim null-checks)
    // rather than dialing this isolate's trampolines after the pin drops.
    _lib.reset();
    _lib.register(ffi.nullptr, ffi.nullptr, ffi.nullptr, ffi.nullptr);
    _lib.registerScanFailed(ffi.nullptr);
    _setCallablesKeepAlive(false);
    _instance = null;
    // Also vacate the platform-level singleton slot so a later default
    // construction gets a fresh backend, not this disposed one.
    BleCentralPlatform.detachInstance(this);
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
      if (json != ffi.nullptr) AndroidBindings.instance.free(json.cast());
    }
  }

  /// Android delivers startScan failures asynchronously via onScanFailed —
  /// notably SCAN_FAILED_SCANNING_TOO_FREQUENTLY (5 starts / 30 s throttle).
  /// Without this bridge the stream would just stay silently empty forever.
  static void _onScanFailed(int token, int errorCode) {
    final controller = _scanController;
    if (controller == null || controller.isClosed || _scanToken != token) {
      return;
    }
    controller.addError(
      BleScanException(
        errorCode == 6
            ? 'scan rejected: too many scan starts (Android throttles >5 '
                  'per 30s); wait ~30s before retrying'
            : 'scan failed (Android ScanCallback error $errorCode)',
        code: errorCode,
      ),
    );
    _scanController = null;
    unawaited(controller.close());
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
      if (json != ffi.nullptr) AndroidBindings.instance.free(json.cast());
      if (data != ffi.nullptr) AndroidBindings.instance.free(data.cast());
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
        AndroidBindings.instance.free(characteristic.cast());
      }
      if (data != ffi.nullptr) AndroidBindings.instance.free(data.cast());
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

  // reqIds for this connection's in-flight ops, so teardown can fail them
  // instead of leaving their Completers (and the op chain) hung forever.
  final Set<int> _pendingReqs = {};
  bool _torn = false;

  /// Bounds every GATT op: some Android stacks are known to swallow a
  /// callback with the link still up, and one lost callback must not wedge
  /// the serialized op chain until disconnect.
  static const Duration _opTimeout = Duration(seconds: 30);

  Future<_OpResult> _runOp(void Function(int reqId) issue) async {
    final reqId = AndroidBleCentral._nextReqId++;
    final completer = Completer<_OpResult>();
    AndroidBleCentral._ops[reqId] = completer;
    _pendingReqs.add(reqId);
    try {
      issue(reqId);
    } catch (_) {
      AndroidBleCentral._ops.remove(reqId);
      _pendingReqs.remove(reqId);
      rethrow;
    }
    try {
      final r = await completer.future.timeout(
        _opTimeout,
        onTimeout: () {
          AndroidBleCentral._ops.remove(reqId);
          throw const BleTimeoutException(
            'GATT operation timed out',
            timeout: _opTimeout,
          );
        },
      );
      if (r.status == -100) {
        // The C shim could not even dispatch/marshal the op (version-skewed
        // .so, OOM) — surface it as the infrastructure failure it is.
        throw const BleException('native bridge failed dispatching GATT op');
      }
      return r;
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
    // No caller timeout still gets a hard cap: if the adapter is toggled
    // mid-connect Android can drop onConnectionStateChange entirely, and
    // "waits forever" is never the right default. 35s clears the framework's
    // own 30s connect supervision.
    timeout ??= const Duration(seconds: 35);
    // _teardown() may completeError(_connected) after the timeout already fired;
    // a detached handler keeps that from surfacing as an unhandled async error.
    unawaited(_connected.future.catchError((_) {}));
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
  Future<List<BleService>> discoverServices() {
    return _enqueue(() async {
      logGatt.fine(() => 'discoverServices conn $_token');
      final r = await _runOp((reqId) => _lib.discoverServices(reqId, _token));
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
          _lib.read(reqId, _token, sPtr.cast(), cPtr.cast());
        } finally {
          calloc.free(sPtr);
          calloc.free(cPtr);
        }
      });
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
      logData.finest(
        () => 'write ${characteristic.value} ${describeBytes(value)}',
      );
      final r = await _runOp((reqId) {
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
      });
      if (r.status != 0) throw BleGattException('write failed', code: r.status);
    });
  }

  @override
  Stream<Uint8List> subscribe(Uuid service, Uuid characteristic) {
    final key = '${service.value}|${characteristic.value}';
    // Shared broadcast controller per characteristic (enable-on-first /
    // disable-on-last across all subscribers; notifications fan out to all).
    final controller = _notifyControllers.putIfAbsent(key, () {
      late StreamController<Uint8List> c;
      c = StreamController<Uint8List>.broadcast(
        onListen: () {
          // Surface a failed enable on the stream — subscribers otherwise wait
          // forever on notifications that were never switched on.
          unawaited(
            _setNotify(service, characteristic, enable: true).catchError((
              Object e,
            ) {
              if (!c.isClosed) c.addError(e);
            }),
          );
          logGatt.fine(() => 'subscribe ${characteristic.value} conn $_token');
        },
        onCancel: () {
          // Disable is best-effort — the link may already be gone.
          unawaited(
            _setNotify(service, characteristic, enable: false).catchError(
              (Object e) => logGatt.fine(() => 'notify disable failed: $e'),
            ),
          );
          // Drop AND close the (now listener-less) controller so a later
          // subscribe starts a fresh one and a re-listen on the old stream gets
          // a terminal done instead of silently-lost events.
          _notifyControllers.remove(key);
          unawaited(c.close());
        },
      );
      return c;
    });
    return controller.stream;
  }

  Future<void> _setNotify(
    Uuid service,
    Uuid characteristic, {
    required bool enable,
  }) {
    // Route the CCCD write through the op chain AND await its completion
    // (onDescriptorWrite -> nativeOnOp): Android allows only one outstanding
    // GATT op, so the next chained op must not be issued while the descriptor
    // write is still in flight — it would fail with device-busy.
    return _enqueue(() async {
      final r = await _runOp((reqId) {
        final sPtr = service.value.toNativeUtf8();
        final cPtr = characteristic.value.toNativeUtf8();
        try {
          _lib.subscribe(
            reqId,
            _token,
            sPtr.cast(),
            cPtr.cast(),
            enable ? 1 : 0,
          );
        } finally {
          calloc.free(sPtr);
          calloc.free(cPtr);
        }
      });
      if (r.status != 0) {
        throw BleGattException(
          '${enable ? 'enable' : 'disable'} notify failed',
          code: r.status,
        );
      }
    });
  }

  @override
  Future<int> requestMtu(int mtu) {
    return _enqueue(() async {
      final r = await _runOp((reqId) => _lib.requestMtu(reqId, _token, mtu));
      // MTU exchange is best-effort; tolerate any malformed/absent payload and
      // fall back to the ATT default rather than throwing.
      try {
        final decoded = r.json != null ? jsonDecode(r.json!) : null;
        if (decoded is Map && decoded['mtu'] is num) {
          return (decoded['mtu'] as num).toInt();
        }
      } catch (_) {
        // fall through to default
      }
      return 23;
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
    if (_torn) return;
    _torn = true;
    AndroidBleCentral._connections.remove(_token);
    // Fail any in-flight GATT ops so their awaits (and the op chain) don't hang
    // forever when the link drops or close() races a pending op.
    for (final reqId in _pendingReqs.toList()) {
      AndroidBleCentral._ops
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
    4 => BluetoothAdapterState.turningOn,
    5 => BluetoothAdapterState.on,
    6 => BluetoothAdapterState.turningOff,
    _ => BluetoothAdapterState.unknown,
  };
}
