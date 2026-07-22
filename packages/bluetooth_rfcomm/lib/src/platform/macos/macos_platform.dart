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
import '../transport_stats.dart';
import 'macos_bindings.dart';

// Additive bindings for the transport-introspection C exports. Declared here
// (with an explicit assetId matching macos_bindings.dart's @DefaultAsset)
// rather than in the shared bindings file to keep that file's surface stable.
@ffi.Native<ffi.Int32 Function(ffi.Int64)>(
  symbol: 'btc_rfcomm_mtu',
  assetId: 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart',
)
external int _btcRfcommMtu(int handle);

@ffi.Native<ffi.Int64 Function(ffi.Int64)>(
  symbol: 'btc_rfcomm_pending',
  assetId: 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart',
)
external int _btcRfcommPending(int handle);

/// Per-channel delivery counters as a malloc'd JSON object (freed with
/// [btcFree]): txEnqueuedBytes, txSubmittedBytes, txCompletedBytes,
/// txRetriedChunks, txFailedChunks, txDroppedBytes, rxEvents, rxBytes,
/// rxDroppedEvents. Returns null for an unknown handle.
@ffi.Native<ffi.Pointer<ffi.Char> Function(ffi.Int64)>(
  symbol: 'btc_rfcomm_stats_json',
  assetId: 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart',
)
external ffi.Pointer<ffi.Char> _btcRfcommStatsJson(int handle);

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

  // Process-wide rx-drop counters for events that can no longer be attributed
  // to a live transport. Surfaced through every transport's [nativeStats] so
  // an app can see them without a platform-specific import.
  //
  // Unrouted = the token looked up nothing: the transport was closed/removed
  // while data events were still queued behind the NativeCallable port. Bytes
  // counted natively as rxBytes but never reaching Dart show up here.
  static int _rxUnroutedEvents = 0;
  static int _rxUnroutedBytes = 0;

  /// Events discarded because native reported a length above
  /// [_maxInboundChunk] (corruption guard). Should stay 0 forever.
  static int _rxOversizeEvents = 0;
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
        // An SDP miss is only meaningful if the radio could actually run the
        // query: with the adapter off (or the device unreachable) the same
        // handle==0 comes back, and mislabeling that as "service not found"
        // (isTransient=false) would stop a caller's legitimate retry loop.
        if (_AdapterStateCode.toEnum(btcAdapterState()) !=
            BluetoothAdapterState.on) {
          throw const BluetoothDisabledException(
            'Bluetooth adapter is off or unavailable',
          );
        }
        if (channel == null) {
          // No explicit channel and SDP resolved none for this service. Note
          // an out-of-range device with no CACHED SDP record surfaces here
          // too — the message says so, and retrying near the device (or with
          // an explicit channel) is the fix.
          throw ServiceNotFoundException(
            'No RFCOMM channel for $serviceUuid on ${device.address} '
            '(no SDP record — the device may also be out of range; retry in '
            'range or pass an explicit channel)',
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
      if (len <= 0) return; // no payload — nothing to lose
      if (transport == null) {
        // Token lookup miss: the transport was closed while this event was
        // still queued behind the NativeCallable port. The bytes are gone —
        // count them so native rxBytes vs Dart delivery can be reconciled.
        _rxUnroutedEvents++;
        _rxUnroutedBytes += len;
        logNative.fine(
          () => 'dropped ${len}B rx for unknown token $token (closed?)',
        );
      } else if (len > _maxInboundChunk) {
        _rxOversizeEvents++;
        logNative.warning(
          () => 'dropped implausible ${len}B rx chunk (corrupt length?)',
        );
      } else {
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
class _MacRfcommTransport implements RfcommTransport, TransportStats {
  _MacRfcommTransport(this._token);

  final int _token;
  int _handle = 0;

  // Dart-side hop counters (see [nativeStats]).
  int _rxDartEvents = 0;
  int _rxDartBytes = 0;
  int _rxDroppedClosedBytes = 0;

  /// Native counters captured just before [close] releases the handle, so
  /// post-mortem [nativeStats] still reflects the channel's full life.
  Map<String, int>? _finalNativeStats;

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
    if (_incoming.isClosed) {
      // Data raced the teardown: the channel closed after native queued this
      // event. Count it — native rxBytes minus rxDartBytes minus this must
      // be zero, or the port hop itself is losing events.
      _rxDroppedClosedBytes += bytes.length;
      logNative.fine(() => 'dropped ${bytes.length}B rx delivered after close');
      return;
    }
    _rxDartEvents++;
    _rxDartBytes += bytes.length;
    _incoming.add(bytes);
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

  /// The negotiated RFCOMM channel MTU — the OS-advertised largest single
  /// write payload — or null if it cannot be read (channel closed, or the
  /// native layer reported none).
  @override
  int? get maxPayloadSize {
    if (_closed || _handle == 0) return null;
    final mtu = _btcRfcommMtu(_handle);
    return mtu > 0 ? mtu : null;
  }

  /// Bytes accepted by [send] but not yet handed to the OS (sitting in the
  /// native write queue).
  @override
  int get pendingWriteBytes =>
      (_closed || _handle == 0) ? 0 : _btcRfcommPending(_handle);

  @override
  void send(Uint8List data) {
    if (_closed || _handle == 0) {
      throw const BluetoothWriteException('transport not open');
    }
    final ptr = calloc<ffi.Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      final rc = btcRfcommWrite(_handle, ptr, data.length);
      if (rc != 0) {
        // -1: channel already closed natively (a disconnect event is on its
        // way); -2: the bounded native backlog is full (peer stalled). Either
        // way the bytes were NOT queued — surface it, never drop silently.
        throw BluetoothWriteException(
          rc == -2
              ? 'write rejected: native write backlog full (peer stalled)'
              : 'write failed: channel is not open',
          code: rc,
        );
      }
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  Future<void> flush() async {
    // Drain the native write queue (bytes accepted by [send] but not yet
    // handed to the OS). Bounded: on disconnect the native teardown clears the
    // queue, so pending falls to 0 and the loop exits.
    while (!_closed && _handle != 0 && _btcRfcommPending(_handle) > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Dart-side hop counters merged with the native channel counters.
  ///
  /// Native keys (from `btc_rfcomm_stats_json`): txEnqueuedBytes,
  /// txSubmittedBytes, txCompletedBytes, txRetriedChunks, txFailedChunks,
  /// txDroppedBytes, rxEvents, rxBytes, rxDroppedEvents. Dart-side keys:
  /// rxDartEvents / rxDartBytes (events that made it across the
  /// NativeCallable port into the incoming stream), rxDroppedClosedBytes
  /// (arrived after this transport closed), and the process-wide
  /// rxUnroutedEvents / rxUnroutedBytes / rxOversizeEvents. Native keys are
  /// omitted (never faked) when the loaded dylib predates the stats export.
  @override
  Map<String, int> nativeStats() {
    final out = <String, int>{
      'rxDartEvents': _rxDartEvents,
      'rxDartBytes': _rxDartBytes,
      'rxDroppedClosedBytes': _rxDroppedClosedBytes,
      'rxUnroutedEvents': MacosBluetoothRfcomm._rxUnroutedEvents,
      'rxUnroutedBytes': MacosBluetoothRfcomm._rxUnroutedBytes,
      'rxOversizeEvents': MacosBluetoothRfcomm._rxOversizeEvents,
    };
    final native = _finalNativeStats ?? _readNativeStats();
    if (native != null) out.addAll(native);
    return out;
  }

  Map<String, int>? _readNativeStats() {
    if (_handle == 0) return null;
    final ffi.Pointer<ffi.Char> ptr;
    try {
      ptr = _btcRfcommStatsJson(_handle);
    } on Object catch (e) {
      // Symbol missing: an older native library. Diagnostics degrade to the
      // Dart-side counters; never let stats introspection throw.
      logNative.fine(() => 'native stats unavailable: $e');
      return null;
    }
    if (ptr == ffi.nullptr) return null;
    try {
      final map =
          jsonDecode(ptr.cast<Utf8>().toDartString()) as Map<String, dynamic>;
      return {
        for (final MapEntry(:key, :value) in map.entries)
          if (value is num) key: value.toInt(),
      };
    } catch (e) {
      logNative.warning(() => 'malformed native stats payload: $e');
      return null;
    } finally {
      btcFree(ptr.cast());
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final alreadyDisconnected = _current == ConnectionState.disconnected;
    _current = ConnectionState.disconnected;
    if (_handle != 0) {
      // Snapshot the channel's counters while the handle is still valid so
      // stats read AFTER a disconnect (the usual diagnostic moment) work.
      _finalNativeStats = _readNativeStats();
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
