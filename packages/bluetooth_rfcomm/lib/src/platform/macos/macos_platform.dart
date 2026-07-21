import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
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
import 'macos_bindings.dart';

/// macOS backend over IOBluetooth.
///
/// Calls into the C ABI in `macos/bluetooth_rfcomm/Sources/bluetooth_rfcomm/`
/// via `dart:ffi`.
/// The native side runs IOBluetooth on a dedicated CFRunLoop thread and forwards
/// inbound data / state through C callbacks, which arrive here as
/// `NativeCallable.listener` events on this isolate — so nothing blocks and no
/// objective_c/Flutter dependency is needed.
///
/// macOS requires a real, non-zero RFCOMM channel for serial; [connect] resolves
/// it from SDP when one isn't supplied.
class MacosBluetoothRfcomm extends BluetoothRfcommPlatform {
  MacosBluetoothRfcomm() {
    // The callables must pin this isolate while native sources can dial them.
    _setCallablesKeepAlive(true);
    // Hot-restart recovery: a previous isolate's channels/inquiry hold C
    // callback pointers into destroyed trampolines. Quiesce them (the native
    // teardown nulls each channel's pointers before anything can fire) before
    // this isolate hands out fresh ones.
    btcReset();
  }

  static void _setCallablesKeepAlive(bool alive) {
    _dataCb.keepIsolateAlive = alive;
    _stateCb.keepIsolateAlive = alive;
    _foundCb.keepIsolateAlive = alive;
    _doneCb.keepIsolateAlive = alive;
  }

  /// Upper bound on a single inbound chunk; guards `asTypedList` against a
  /// corrupted length from native code (RFCOMM frames are far smaller).
  static const int _maxInboundChunk = 1 << 20;

  static int _nextToken = 1;
  static final Map<int, _MacRfcommTransport> _transports = {};
  static final Map<int, StreamController<BluetoothDiscoveryResult>>
  _discoveries = {};

  // One shared listener per callback kind, kept alive for the process.
  static final ffi.NativeCallable<DataCbNative> _dataCb =
      ffi.NativeCallable<DataCbNative>.listener(_onData);
  static final ffi.NativeCallable<StateCbNative> _stateCb =
      ffi.NativeCallable<StateCbNative>.listener(_onState);
  static final ffi.NativeCallable<FoundCbNative> _foundCb =
      ffi.NativeCallable<FoundCbNative>.listener(_onFound);
  static final ffi.NativeCallable<InquiryDoneCbNative> _doneCb =
      ffi.NativeCallable<InquiryDoneCbNative>.listener(_onInquiryDone);

  @override
  Future<bool> isSupported() async =>
      btcAdapterState() != _AdapterStateCode.unavailable;

  @override
  Future<BluetoothAdapterState> adapterState() async =>
      _AdapterStateCode.toEnum(btcAdapterState());

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() async* {
    // IOBluetooth power notifications aren't bridged yet; emit current state.
    yield await adapterState();
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async =>
      throw const BluetoothUnsupportedException(
        'macOS does not allow apps to toggle the Bluetooth radio.',
      );

  @override
  Future<List<BluetoothDevice>> bondedDevices() async {
    final ptr = btcPairedDevicesJson();
    if (ptr == ffi.nullptr) return const [];
    try {
      final json = ptr.cast<Utf8>().toDartString();
      final list = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
      return list.map(_deviceFromJson).toList();
    } catch (e) {
      logNative.warning(() => 'malformed paired-devices payload: $e');
      throw BluetoothException('malformed paired-devices payload', cause: e);
    } finally {
      btcFree(ptr.cast());
    }
  }

  /// Token of the native inquiry currently running on our behalf (null =
  /// none). IOBluetooth has ONE inquiry slot, so concurrent discovery streams
  /// SHARE it: only the first stream starts the radio, later streams piggyback
  /// on its sightings, and only the last stream cancelling stops it — one
  /// stream tearing down no longer kills another's inquiry. The token also
  /// lets [_onInquiryDone] ignore a STALE done (queued from an inquiry that
  /// was already stopped) so it can't tear down a freshly started one.
  static int? _nativeInquiryToken;

  @override
  Stream<BluetoothDiscoveryResult> startDiscovery() {
    final token = _nextToken++;
    late StreamController<BluetoothDiscoveryResult> controller;
    controller = StreamController<BluetoothDiscoveryResult>.broadcast(
      onListen: () {
        _discoveries[token] = controller;
        if (_nativeInquiryToken != null) return; // share the running inquiry
        final rc = btcStartDiscovery(
          token,
          _foundCb.nativeFunction,
          _doneCb.nativeFunction,
        );
        if (rc != 0) {
          controller.addError(
            const BluetoothDiscoveryException('Failed to start inquiry'),
          );
          _discoveries.remove(token);
          // A discovery that failed to start never produces results or a done
          // callback — close so listeners see a terminal event, not a hang.
          unawaited(controller.close());
          return;
        }
        _nativeInquiryToken = token;
      },
      onCancel: () async {
        _discoveries.remove(token);
        if (_discoveries.isEmpty && _nativeInquiryToken != null) {
          _nativeInquiryToken = null;
          btcStopDiscovery();
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopDiscovery() async {
    if (_nativeInquiryToken != null) {
      _nativeInquiryToken = null;
      btcStopDiscovery();
    }
    // [inquiry stop] does not deliver deviceInquiryComplete, so close the
    // discovery streams here or they (and their controllers) leak forever.
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
    if (!device.isAddress) return const [];
    final u = serviceUuid ?? Uuid.spp;
    final channel = _sdpChannel(device.address, u);
    if (channel <= 0) return const [];
    return [BluetoothService(uuid: u, rfcommChannelId: channel)];
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
        'macOS requires a MAC-address DeviceId for RFCOMM connect',
      );
    }
    final token = _nextToken++;
    final transport = _MacRfcommTransport(token);
    _transports[token] = transport;

    final addrPtr = device.address.toNativeUtf8();
    final uuidPtr = serviceUuid.value.toNativeUtf8();
    try {
      final handle = btcRfcommOpen(
        token,
        addrPtr.cast(),
        channel ?? 0,
        uuidPtr.cast(),
        _dataCb.nativeFunction,
        _stateCb.nativeFunction,
      );
      if (handle == 0) {
        _transports.remove(token);
        if (channel == null) {
          // No explicit channel and SDP resolved none for this service.
          throw ServiceNotFoundException(
            'No RFCOMM channel for $serviceUuid on ${device.address}',
          );
        }
        throw BluetoothConnectionException(
          'openRFCOMMChannel failed for ${device.address}',
        );
      }
      transport.bindHandle(handle);
    } finally {
      calloc.free(addrPtr);
      calloc.free(uuidPtr);
    }

    // Wait for the channel-open delegate callback (or timeout).
    await transport.waitConnected(timeout);
    return transport;
  }

  @override
  Future<void> pair(DeviceId device) async =>
      throw const BluetoothUnsupportedException(
        'Programmatic pairing on macOS is not yet wired; pair from System '
        'Settings.',
      );

  @override
  Future<void> unpair(DeviceId device) async =>
      throw const BluetoothUnsupportedException(
        'Programmatic unpairing on macOS is not yet wired.',
      );

  @override
  Future<void> dispose() async {
    await stopDiscovery();
    for (final t in _transports.values.toList()) {
      await t.close();
    }
    for (final c in _discoveries.values.toList()) {
      if (!c.isClosed) await c.close();
    }
    _discoveries.clear();
    // Quiesce anything still live natively, then release the isolate pin so a
    // pure-Dart CLI can exit without calling exit() explicitly.
    btcReset();
    _setCallablesKeepAlive(false);
  }

  // --- callback dispatch (static; correlate by token) ----------------------

  static void _onData(int token, ffi.Pointer<ffi.Uint8> data, int len) {
    final transport = _transports[token];
    try {
      if (transport != null && len > 0 && len <= _maxInboundChunk) {
        transport._deliver(Uint8List.fromList(data.asTypedList(len)));
      }
    } finally {
      btcFree(data.cast());
    }
  }

  static void _onState(int token, int state) {
    _transports[token]?._onState(_connStateFromCode(state));
  }

  static void _onFound(int token, ffi.Pointer<ffi.Char> json) {
    try {
      if (_discoveries.isNotEmpty) {
        final map =
            (jsonDecode(json.cast<Utf8>().toDartString())
                as Map<String, dynamic>);
        final device = _deviceFromJson(map);
        final result = BluetoothDiscoveryResult(
          device: device,
          rssi: device.rssi,
          timestamp: DateTime.now(),
        );
        // The single native inquiry is shared: deliver to EVERY live stream,
        // not just the one whose token started the radio.
        for (final controller in _discoveries.values.toList()) {
          if (!controller.isClosed) controller.add(result);
        }
      }
    } catch (e) {
      // Skip a malformed sighting (e.g. a device with a withheld address or a
      // non-UTF-8 name) rather than tearing down the discovery stream.
      logNative.fine(() => 'skipped malformed sighting: $e');
    } finally {
      btcFree(json.cast());
    }
  }

  static void _onInquiryDone(int token, int aborted) {
    // A done queued from an inquiry that was already stopped/replaced must not
    // tear down a freshly started one — only the CURRENT inquiry's done acts.
    if (token != _nativeInquiryToken) return;
    _nativeInquiryToken = null;
    // The shared inquiry is over: every piggybacked stream completes with it.
    for (final controller in _discoveries.values.toList()) {
      if (!controller.isClosed) unawaited(controller.close());
    }
    _discoveries.clear();
  }

  static int _sdpChannel(String address, Uuid uuid) {
    final addrPtr = address.toNativeUtf8();
    final uuidPtr = uuid.value.toNativeUtf8();
    try {
      return btcSdpChannel(addrPtr.cast(), uuidPtr.cast());
    } finally {
      calloc.free(addrPtr);
      calloc.free(uuidPtr);
    }
  }

  static ConnectionState _connStateFromCode(int code) => switch (code) {
    2 => ConnectionState.connected,
    1 => ConnectionState.connecting,
    3 => ConnectionState.disconnecting,
    _ => ConnectionState.disconnected,
  };

  static BluetoothDevice _deviceFromJson(Map<String, dynamic> j) {
    final connected = j['connected'] as bool? ?? false;
    final addr = j['address'] as String?;
    final name = j['name'] as String?;
    // The native layer reports IOBluetoothDevice.isPaired; sightings of
    // strangers must NOT claim to be bonded (that would poison the
    // paired∩scanned intersections). Missing field (older native lib) defaults
    // to unknown rather than a false claim either way.
    final paired = j['paired'] as bool?;
    return BluetoothDevice(
      // Recent macOS can withhold the address; fall back to an opaque id.
      id: (addr != null && addr.isNotEmpty)
          ? DeviceId.address(addr)
          : DeviceId.opaque(name ?? 'macos-device'),
      name: name,
      type: BluetoothDeviceType.classic,
      bondState: switch (paired) {
        true => BluetoothBondState.bonded,
        false => BluetoothBondState.none,
        null => BluetoothBondState.unknown,
      },
      isConnected: connected,
      deviceClass: (j['classOfDevice'] as num?)?.toInt(),
    );
  }
}

abstract final class _AdapterStateCode {
  static const int unavailable = 1;
  static BluetoothAdapterState toEnum(int code) => switch (code) {
    1 => BluetoothAdapterState.unavailable,
    2 => BluetoothAdapterState.unauthorized,
    3 => BluetoothAdapterState.off,
    5 => BluetoothAdapterState.on,
    _ => BluetoothAdapterState.unknown,
  };
}

/// RFCOMM transport backed by a native IOBluetoothRFCOMMChannel handle.
class _MacRfcommTransport implements RfcommTransport {
  _MacRfcommTransport(this._token);

  final int _token;
  int _handle = 0;

  final StreamController<Uint8List> _incoming = StreamController<Uint8List>(
    sync: false,
  );
  final StreamController<ConnectionState> _state =
      StreamController<ConnectionState>.broadcast();
  final Completer<void> _connected = Completer<void>();
  ConnectionState _current = ConnectionState.connecting;
  bool _closed = false;

  void bindHandle(int handle) => _handle = handle;

  Future<void> waitConnected(Duration? timeout) {
    if (timeout == null) return _connected.future;
    return _connected.future.timeout(
      timeout,
      onTimeout: () {
        unawaited(close());
        throw BluetoothTimeoutException(
          'RFCOMM channel open timed out',
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
    if (state == ConnectionState.connected && !_connected.isCompleted) {
      _connected.complete();
    }
    if (state == ConnectionState.disconnected) {
      if (!_connected.isCompleted) {
        _connected.completeError(
          const BluetoothConnectionException('RFCOMM channel failed to open'),
          StackTrace.current,
        );
      }
      unawaited(close());
    }
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
      final rc = btcRfcommWrite(_handle, ptr, data.length);
      if (rc != 0) throw BluetoothWriteException('write failed', code: rc);
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  Future<void> flush() async {
    // Writes are dispatched in order on the native worker thread; there is no
    // separate user-space buffer to drain.
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final alreadyDisconnected = _current == ConnectionState.disconnected;
    _current = ConnectionState.disconnected;
    if (_handle != 0) {
      btcRfcommClose(_handle);
      _handle = 0;
    }
    MacosBluetoothRfcomm._transports.remove(_token);
    if (!_state.isClosed) {
      if (!alreadyDisconnected) _state.add(ConnectionState.disconnected);
      await _state.close();
    }
    if (!_incoming.isClosed) await _incoming.close();
  }
}
