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
import 'ios_bindings.dart';

// Additive binding for the transport-introspection C export. Declared here
// (with an explicit assetId matching ios_bindings.dart's @DefaultAsset) rather
// than in the shared bindings file to keep that file's surface stable.
@ffi.Native<ffi.Int64 Function(ffi.Int64)>(
  symbol: 'btc_ea_pending',
  assetId: 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart',
)
external int _btcEaPending(int handle);

/// iOS backend over ExternalAccessory (EASession).
///
/// Only MFi accessories appear here — see the note in the C header. For a
/// non-MFi device (the common case), [connect] throws
/// [BluetoothUnsupportedException] pointing at the BLE package, which is the only
/// App-Store-shippable path for non-MFi devices on iOS.
///
/// The "address" of an iOS device is the opaque `EAAccessory.connectionID`, not
/// a MAC. RFCOMM channel / service UUID don't apply; the accessory's first
/// declared protocol string is used.
class IosBluetoothRfcomm extends BluetoothRfcommPlatform {
  IosBluetoothRfcomm() {
    // The callables must pin this isolate while native sources can dial them.
    _setCallablesKeepAlive(true);
    // Hot-restart recovery: close any EA sessions a previous isolate left
    // open before this isolate hands out fresh callback pointers.
    btcEaReset();
  }

  static void _setCallablesKeepAlive(bool alive) {
    _dataCb.keepIsolateAlive = alive;
    _stateCb.keepIsolateAlive = alive;
  }

  static const int _maxInboundChunk = 1 << 20;
  static int _nextToken = 1;
  static final Map<int, _IosEaTransport> _transports = {};

  static final ffi.NativeCallable<DataCbNative> _dataCb =
      ffi.NativeCallable<DataCbNative>.listener(_onData);
  static final ffi.NativeCallable<StateCbNative> _stateCb =
      ffi.NativeCallable<StateCbNative>.listener(_onState);

  // ExternalAccessory exposes NO radio-state API (that would need
  // CoreBluetooth, which triggers the Bluetooth permission prompt just for a
  // status read). These therefore report a FIXED optimistic `on` — unlike
  // every other platform, they say nothing about the actual radio. Callers
  // find out the truth from connect() failing.
  @override
  Future<bool> isSupported() async => true;

  @override
  Future<BluetoothAdapterState> adapterState() async =>
      BluetoothAdapterState.on;

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() =>
      Stream<BluetoothAdapterState>.value(BluetoothAdapterState.on);

  @override
  Future<void> setAdapterEnabled(bool enabled) async =>
      throw const BluetoothUnsupportedException(
        'iOS does not allow apps to toggle the Bluetooth radio.',
      );

  @override
  Future<List<BluetoothDevice>> bondedDevices() async => _accessories();

  @override
  Stream<BluetoothDiscoveryResult> startDiscovery() {
    // EA has no inquiry; surface the currently-connected MFi accessories.
    // Broadcast, matching every other backend — the facade shares one platform
    // stream among its listeners and relies on that.
    late StreamController<BluetoothDiscoveryResult> controller;
    controller = StreamController<BluetoothDiscoveryResult>.broadcast(
      onListen: () async {
        try {
          final now = DateTime.now();
          for (final d in await _accessories()) {
            if (controller.isClosed) return;
            controller.add(
              BluetoothDiscoveryResult(device: d, rssi: null, timestamp: now),
            );
          }
        } catch (e) {
          if (!controller.isClosed) controller.addError(e);
        } finally {
          if (!controller.isClosed) unawaited(controller.close());
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<List<BluetoothService>> discoverServices(
    DeviceId device, {
    Uuid? serviceUuid,
  }) async => const []; // EA exposes protocol strings, not RFCOMM/SDP UUIDs.

  @override
  Future<RfcommTransport> openRfcomm(
    DeviceId device, {
    int? channel,
    required Uuid serviceUuid,
    Duration? timeout,
  }) async {
    final token = _nextToken++;
    final transport = _IosEaTransport(token);
    _transports[token] = transport;

    final idPtr = device.value.toNativeUtf8();
    final protoPtr = ''.toNativeUtf8(); // empty -> first protocol
    try {
      final handle = btcEaOpen(
        token,
        idPtr.cast(),
        protoPtr.cast(),
        _dataCb.nativeFunction,
        _stateCb.nativeFunction,
      );
      if (handle == 0) {
        _transports.remove(token);
        throw const BluetoothUnsupportedException(
          'No MFi ExternalAccessory session could be opened. iOS only supports '
          'Bluetooth Classic with MFi-certified accessories; for a non-MFi '
          'device use the BLE package instead.',
        );
      }
      transport.bindHandle(handle);
    } finally {
      calloc.free(idPtr);
      calloc.free(protoPtr);
    }

    await transport.waitConnected(timeout);
    return transport;
  }

  @override
  Future<void> pair(DeviceId device) async =>
      throw const BluetoothUnsupportedException(
        'iOS handles MFi pairing in Settings; apps cannot initiate it.',
      );

  @override
  Future<void> unpair(DeviceId device) async =>
      throw const BluetoothUnsupportedException(
        'iOS handles MFi unpairing in Settings.',
      );

  @override
  Future<void> dispose() async {
    for (final t in _transports.values.toList()) {
      await t.close();
    }
    // Quiesce anything still live natively, then release the isolate pin.
    btcEaReset();
    _setCallablesKeepAlive(false);
  }

  // --- helpers -------------------------------------------------------------

  Future<List<BluetoothDevice>> _accessories() async {
    final ptr = btcEaAccessoriesJson();
    if (ptr == ffi.nullptr) return const [];
    try {
      final list = (jsonDecode(ptr.cast<Utf8>().toDartString()) as List)
          .cast<Map<String, dynamic>>();
      return list
          .map(
            (j) => BluetoothDevice(
              id: DeviceId.opaque((j['id'] as String?) ?? 'ios-accessory'),
              name: j['name'] as String?,
              type: BluetoothDeviceType.classic,
              bondState: BluetoothBondState.bonded,
              isConnected: true,
            ),
          )
          .toList();
    } catch (e) {
      logNative.warning(() => 'malformed accessories payload: $e');
      throw BluetoothException('malformed accessories payload', cause: e);
    } finally {
      btcFree(ptr.cast());
    }
  }

  static void _onData(int token, ffi.Pointer<ffi.Uint8> data, int len) {
    final t = _transports[token];
    try {
      if (t != null && len > 0 && len <= _maxInboundChunk) {
        t._deliver(Uint8List.fromList(data.asTypedList(len)));
      }
    } finally {
      btcFree(data.cast());
    }
  }

  static void _onState(int token, int state) {
    _transports[token]?._onState(
      state == 2 ? ConnectionState.connected : ConnectionState.disconnected,
    );
  }
}

class _IosEaTransport implements RfcommTransport {
  _IosEaTransport(this._token);

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
          'EASession open timed out',
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
          const BluetoothConnectionException('EASession failed to open'),
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

  /// ExternalAccessory streams advertise no per-write payload limit.
  @override
  int? get maxPayloadSize => null;

  /// Bytes accepted by [send] but not yet written to the accessory's output
  /// stream (the native outBuffer backlog).
  @override
  int get pendingWriteBytes =>
      (_closed || _handle == 0) ? 0 : _btcEaPending(_handle);

  @override
  void send(Uint8List data) {
    if (_closed || _handle == 0) {
      throw const BluetoothWriteException('transport not open');
    }
    final ptr = calloc<ffi.Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      final rc = btcEaWrite(_handle, ptr, data.length);
      if (rc != 0) throw BluetoothWriteException('write failed', code: rc);
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  Future<void> flush() async {
    // Drain the native outBuffer. Bounded: closing the session clears it.
    while (!_closed && _handle != 0 && _btcEaPending(_handle) > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final alreadyDisconnected = _current == ConnectionState.disconnected;
    _current = ConnectionState.disconnected;
    if (_handle != 0) {
      btcEaClose(_handle);
      _handle = 0;
    }
    IosBluetoothRfcomm._transports.remove(_token);
    if (!_state.isClosed) {
      if (!alreadyDisconnected) _state.add(ConnectionState.disconnected);
      await _state.close();
    }
    if (!_incoming.isClosed) await _incoming.close();
  }
}
