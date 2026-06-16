import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';
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
class AndroidBluetoothClassic extends BluetoothClassicPlatform {
  AndroidBluetoothClassic() : _lib = AndroidBindings.open() {
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

    final addrPtr = device.address.toNativeUtf8();
    final uuidPtr = serviceUuid.value.toNativeUtf8();
    try {
      final handle = _lib.open(
        token,
        addrPtr.cast(),
        channel ?? 0,
        uuidPtr.cast(),
      );
      if (handle == 0) {
        _transports.remove(token);
        throw BluetoothConnectionException(
          'RFCOMM connect to ${device.address} failed',
        );
      }
      transport.bindHandle(handle);
    } finally {
      calloc.free(addrPtr);
      calloc.free(uuidPtr);
    }

    await transport.waitConnected(timeout);
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
    } catch (_) {
      // Skip a malformed sighting rather than tearing down discovery.
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

abstract final class _AdapterCode {
  static const int unavailable = 1;
  static BluetoothAdapterState toEnum(int code) => switch (code) {
    1 => BluetoothAdapterState.unavailable,
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
  final Completer<void> _connected = Completer<void>();
  ConnectionState _current = ConnectionState.connecting;
  bool _closed = false;

  void bindHandle(int handle) {
    _handle = handle;
    // The Kotlin connect() blocks until connected, so a non-zero handle means
    // the socket is already up.
    _current = ConnectionState.connected;
    if (!_connected.isCompleted) _connected.complete();
    if (!_state.isClosed) _state.add(ConnectionState.connected);
  }

  Future<void> waitConnected(Duration? timeout) {
    if (timeout == null) return _connected.future;
    return _connected.future.timeout(
      timeout,
      onTimeout: () {
        unawaited(close());
        throw BluetoothTimeoutException(
          'RFCOMM connect timed out',
          timeout: timeout,
        );
      },
    );
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
    AndroidBluetoothClassic._transports.remove(_token);
    if (!_state.isClosed) {
      if (!alreadyDisconnected) _state.add(ConnectionState.disconnected);
      await _state.close();
    }
    if (!_incoming.isClosed) await _incoming.close();
  }
}
