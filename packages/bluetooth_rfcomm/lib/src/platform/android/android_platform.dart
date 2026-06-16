import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';
import '../../logging.dart';
import '../../models/bluetooth_device.dart';
import '../../models/bluetooth_service.dart';
import '../../models/device_id.dart';
import '../../models/discovery_result.dart';
import '../../models/enums.dart';
import '../../models/uuid.dart';
import '../platform_interface.dart';
import 'android_bindings.dart';

/// Android backend.
///
/// The heavy lifting (BluetoothAdapter, discovery via BroadcastReceiver, the
/// BluetoothSocket RFCOMM I/O) is in Kotlin; a C JNI shim exposes a plain C ABI
/// that Dart calls via FFI, and the Kotlin side calls back through the same shim
/// into Dart `NativeCallable.listener`s. This keeps the package Flutter-free
/// (no MethodChannel, no `flutter` dependency) while still working inside a
/// Flutter Android app, which provides the ambient JVM.
///
/// Requires the app to hold the runtime Bluetooth permissions
/// (`BLUETOOTH_CONNECT`/`BLUETOOTH_SCAN` on API 31+, location on older).
class AndroidBluetoothRfcomm extends BluetoothRfcommPlatform {
  AndroidBluetoothRfcomm() : _lib = AndroidBindings.open() {
    // Set before any native callback can fire so the static free-routing in
    // _onData/_onFound never sees a null binding.
    _activeLib = _lib;
    _lib.register(
      _foundCb.nativeFunction,
      _doneCb.nativeFunction,
      _dataCb.nativeFunction,
      _stateCb.nativeFunction,
    );
    _lib.init();
  }

  final AndroidBindings _lib;

  static const int _maxInboundChunk = 1 << 20;
  static int _nextToken = 1;
  static final Map<int, _AndroidTransport> _transports = {};
  static final Map<int, StreamController<BluetoothDiscoveryResult>>
  _discoveries = {};
  // Late-bound so the static callbacks can reach the active backend's bindings.
  static AndroidBindings? _activeLib;

  static final ffi.NativeCallable<FoundCbNative> _foundCb =
      ffi.NativeCallable<FoundCbNative>.listener(_onFound);
  static final ffi.NativeCallable<InquiryDoneCbNative> _doneCb =
      ffi.NativeCallable<InquiryDoneCbNative>.listener(_onInquiryDone);
  static final ffi.NativeCallable<DataCbNative> _dataCb =
      ffi.NativeCallable<DataCbNative>.listener(_onData);
  static final ffi.NativeCallable<StateCbNative> _stateCb =
      ffi.NativeCallable<StateCbNative>.listener(_onState);

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
    // Adapter ACTION_STATE_CHANGED bridging is a later refinement; emit current.
    yield await adapterState();
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async =>
      throw const BluetoothUnsupportedException(
        'Programmatic radio toggling is restricted on modern Android; prompt '
        'the user via system UI instead.',
      );

  @override
  Future<List<BluetoothDevice>> bondedDevices() async {
    _activeLib = _lib;
    final ptr = _lib.bondedJson();
    if (ptr == ffi.nullptr) return const [];
    try {
      final list = (jsonDecode(ptr.cast<Utf8>().toDartString()) as List)
          .cast<Map<String, dynamic>>();
      return list.map(_deviceFromJson).toList();
    } catch (e) {
      logNative.warning(() => 'malformed bonded-devices payload: $e');
      throw BluetoothException('malformed bonded-devices payload', cause: e);
    } finally {
      _lib.free(ptr.cast());
    }
  }

  @override
  Stream<BluetoothDiscoveryResult> startDiscovery() {
    _activeLib = _lib;
    final token = _nextToken++;
    late StreamController<BluetoothDiscoveryResult> controller;
    controller = StreamController<BluetoothDiscoveryResult>.broadcast(
      onListen: () {
        _discoveries[token] = controller;
        if (_lib.startDiscovery(token) != 0) {
          controller.addError(
            const BluetoothDiscoveryException('startDiscovery failed'),
          );
          _discoveries.remove(token);
        }
      },
      onCancel: () async {
        _discoveries.remove(token);
        _lib.stopDiscovery();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopDiscovery() async {
    _lib.stopDiscovery();
    // Close any discovery streams whose subscribers used stopDiscovery() rather
    // than cancelling, so the controllers don't leak. (The ACTION_DISCOVERY_-
    // FINISHED callback also closes them, but only if it actually fires.)
    for (final controller in _discoveries.values.toList()) {
      if (!controller.isClosed) unawaited(controller.close());
    }
    _discoveries.clear();
  }

  @override
  Future<List<BluetoothService>> discoverServices(
    DeviceId device, {
    Uuid? serviceUuid,
  }) async {
    // Android resolves the channel from SDP inside createRfcommSocketTo-
    // ServiceRecord(uuid); we report the requested service with a sentinel
    // channel of 0 ("resolve at connect").
    final u = serviceUuid ?? Uuid.spp;
    return [BluetoothService(uuid: u, rfcommChannelId: 0)];
  }

  @override
  Future<RfcommTransport> openRfcomm(
    DeviceId device, {
    int? channel,
    required Uuid serviceUuid,
    Duration? timeout,
  }) async {
    if (!device.isAddress) {
      throw const BluetoothConnectionException(
        'Android requires a MAC-address DeviceId for RFCOMM connect',
      );
    }
    _activeLib = _lib;
    final token = _nextToken++;
    final transport = _AndroidTransport(token, _lib);
    _transports[token] = transport;

    // The native BluetoothSocket.connect() blocks until the link is up, so run
    // the open on a helper isolate to keep the caller's isolate responsive (the
    // package's "never hang the main thread" guarantee). The token's data/state
    // callbacks are process-global C function pointers that still deliver to this
    // isolate's NativeCallable listeners, regardless of where open() is invoked.
    final address = device.address;
    final uuidValue = serviceUuid.value;
    final ch = channel ?? 0;
    // Run the blocking open via a top-level function (NOT an inline closure):
    // the computation sent to Isolate.run must be sendable, and an inline closure
    // in this method can capture non-sendable context. Mirrors the Windows path.
    final openFuture = Isolate.run(
      () => _androidOpen(token, address, ch, uuidValue),
    );

    final int handle;
    try {
      handle = timeout == null
          ? await openFuture
          : await openFuture.timeout(timeout);
    } on TimeoutException {
      unawaited(transport.close());
      // Close a socket that finishes connecting after we've given up on it.
      unawaited(
        openFuture
            .then((h) {
              if (h != 0) _lib.close(h);
            })
            .catchError((_) {}),
      );
      throw BluetoothTimeoutException(
        'RFCOMM connect timed out',
        timeout: timeout,
      );
    } on BluetoothException {
      unawaited(transport.close());
      rethrow;
    } catch (e) {
      // Any other worker-isolate failure (FFI load, isolate error, …) maps to a
      // domain exception rather than leaking a raw ArgumentError/etc.
      unawaited(transport.close());
      throw BluetoothConnectionException(
        'RFCOMM connect to ${device.address} failed',
        cause: e,
      );
    }
    if (handle == 0) {
      _transports.remove(token);
      throw BluetoothConnectionException(
        'RFCOMM connect to ${device.address} failed',
      );
    }
    if (!transport.bindHandle(handle)) {
      throw BluetoothConnectionException(
        'RFCOMM connection to ${device.address} dropped during connect',
      );
    }
    return transport;
  }

  @override
  Future<void> pair(DeviceId device) async =>
      throw const BluetoothUnsupportedException(
        'Programmatic pairing is not yet wired on Android; bond via system UI.',
      );

  @override
  Future<void> unpair(DeviceId device) async =>
      throw const BluetoothUnsupportedException(
        'Programmatic unpairing is not yet wired on Android.',
      );

  @override
  Future<void> dispose() async {
    for (final t in _transports.values.toList()) {
      await t.close();
    }
    for (final c in _discoveries.values.toList()) {
      if (!c.isClosed) await c.close();
    }
    _discoveries.clear();
  }

  // --- static callback dispatch --------------------------------------------

  static void _onFound(int token, ffi.Pointer<ffi.Char> json) {
    final controller = _discoveries[token];
    try {
      if (controller != null && !controller.isClosed) {
        final map =
            jsonDecode(json.cast<Utf8>().toDartString())
                as Map<String, dynamic>;
        final device = _deviceFromJson(map);
        controller.add(
          BluetoothDiscoveryResult(
            device: device,
            rssi: device.rssi,
            timestamp: DateTime.now(),
          ),
        );
      }
    } catch (e) {
      // Skip a malformed sighting rather than tearing down discovery.
      logNative.fine(() => 'skipped malformed sighting: $e');
    } finally {
      _activeLib?.free(json.cast());
    }
  }

  static void _onInquiryDone(int token, int aborted) {
    final controller = _discoveries.remove(token);
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  static void _onData(int token, ffi.Pointer<ffi.Uint8> data, int len) {
    final t = _transports[token];
    try {
      if (t != null && len > 0 && len <= _maxInboundChunk) {
        t._deliver(Uint8List.fromList(data.asTypedList(len)));
      }
    } finally {
      _activeLib?.free(data.cast());
    }
  }

  static void _onState(int token, int state) {
    _transports[token]?._onState(
      state == 2 ? ConnectionState.connected : ConnectionState.disconnected,
    );
  }

  static BluetoothDevice _deviceFromJson(Map<String, dynamic> j) {
    final bonded = (j['bonded'] as bool?) ?? false;
    final addr = j['address'] as String?;
    final name = j['name'] as String?;
    return BluetoothDevice(
      id: (addr != null && addr.isNotEmpty)
          ? DeviceId.address(addr)
          : DeviceId.opaque(name ?? 'android-device'),
      name: name,
      type: BluetoothDeviceType.classic,
      bondState: bonded ? BluetoothBondState.bonded : BluetoothBondState.none,
      rssi: (j['rssi'] as num?)?.toInt(),
      isConnected: (j['connected'] as bool?) ?? false,
      deviceClass: (j['classOfDevice'] as num?)?.toInt(),
    );
  }
}

/// Runs the blocking native `open` on a helper isolate. Top-level (not a method
/// closure) so the computation sent to [Isolate.run] captures only its sendable
/// args. Opens its own bindings (lookups only — the global JNI callbacks were
/// registered once on the main isolate and still deliver there).
int _androidOpen(int token, String address, int channel, String uuid) {
  final lib = AndroidBindings.open();
  final addrPtr = address.toNativeUtf8();
  final uuidPtr = uuid.toNativeUtf8();
  try {
    return lib.open(token, addrPtr.cast(), channel, uuidPtr.cast());
  } finally {
    calloc.free(addrPtr);
    calloc.free(uuidPtr);
  }
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

class _AndroidTransport implements RfcommTransport {
  _AndroidTransport(this._token, this._lib);

  final int _token;
  final AndroidBindings _lib;
  int _handle = 0;

  final StreamController<Uint8List> _incoming = StreamController<Uint8List>(
    sync: false,
  );
  final StreamController<ConnectionState> _state =
      StreamController<ConnectionState>.broadcast();
  ConnectionState _current = ConnectionState.connecting;
  bool _closed = false;

  /// Binds the native handle once [openRfcomm] has it. Returns false if the link
  /// already dropped during connect (the read thread can fire disconnect ->
  /// close() before open() returns on the main isolate); the caller then treats
  /// the connect as failed and we close the now-orphaned native handle.
  bool bindHandle(int handle) {
    if (_closed) {
      _lib.close(handle);
      return false;
    }
    _handle = handle;
    _current = ConnectionState.connected;
    if (!_state.isClosed) _state.add(ConnectionState.connected);
    return true;
  }

  void _deliver(Uint8List bytes) {
    if (!_incoming.isClosed) _incoming.add(bytes);
  }

  void _onState(ConnectionState state) {
    _current = state;
    if (!_state.isClosed) _state.add(state);
    if (state == ConnectionState.disconnected) unawaited(close());
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<ConnectionState> get stateChanges => _state.stream;

  @override
  ConnectionState get state => _current;

  @override
  void send(Uint8List data) {
    if (_closed || _handle == 0) {
      throw const BluetoothWriteException('transport not open');
    }
    final ptr = calloc<ffi.Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      final rc = _lib.write(_handle, ptr, data.length);
      if (rc != 0) throw BluetoothWriteException('write failed', code: rc);
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final alreadyDisconnected = _current == ConnectionState.disconnected;
    _current = ConnectionState.disconnected;
    if (_handle != 0) {
      _lib.close(_handle);
      _handle = 0;
    }
    AndroidBluetoothRfcomm._transports.remove(_token);
    if (!_state.isClosed) {
      if (!alreadyDisconnected) _state.add(ConnectionState.disconnected);
      await _state.close();
    }
    if (!_incoming.isClosed) await _incoming.close();
  }
}
