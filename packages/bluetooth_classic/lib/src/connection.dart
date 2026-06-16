import 'dart:async';
import 'dart:typed_data';

import 'exceptions.dart';
import 'models/bluetooth_device.dart';
import 'models/enums.dart';
import 'platform/platform_interface.dart';

/// An open RFCOMM serial connection to a device.
///
/// Obtain one from [BluetoothClassic.connect]. Read with [input] and write with
/// [add] (fire-and-forget, never blocks) or [write] (awaits the OS accepting the
/// bytes). [input] closes cleanly when the peer disconnects.
///
/// ```dart
/// final conn = await bt.connect(device, channel: 1);
/// conn.input.listen((bytes) => print('rx: ${bytes.length}'));
/// conn.add(Uint8List.fromList('AT\r\n'.codeUnits));
/// // ...later
/// await conn.finish();
/// ```
class BluetoothConnection {
  BluetoothConnection._(this.device, this._transport) {
    _inputSub = _transport.incoming.listen(
      _inputController.add,
      onError: _inputController.addError,
      onDone: () {
        unawaited(_inputController.close());
      },
    );
    _stateSub = _transport.stateChanges.listen((s) {
      _state = s;
      if (!_stateController.isClosed) _stateController.add(s);
    });
  }

  /// Internal: wrap a platform transport. Not part of the public API.
  static BluetoothConnection wrap(
    BluetoothDevice device,
    RfcommTransport transport,
  ) => BluetoothConnection._(device, transport);

  /// The device this connection talks to.
  final BluetoothDevice device;

  final RfcommTransport _transport;
  final StreamController<Uint8List> _inputController =
      StreamController<Uint8List>.broadcast();
  final StreamController<ConnectionState> _stateController =
      StreamController<ConnectionState>.broadcast();
  late final StreamSubscription<Uint8List> _inputSub;
  late final StreamSubscription<ConnectionState> _stateSub;

  ConnectionState _state = ConnectionState.connected;

  /// Inbound data. Broadcast: multiple listeners see the same bytes. Closes
  /// when the connection drops, so `await for` / `onDone` cleanly terminates.
  Stream<Uint8List> get input => _inputController.stream;

  /// Connection-state transitions for this connection.
  Stream<ConnectionState> get stateChanges => _stateController.stream;

  /// Current connection state.
  ConnectionState get state => _state;

  /// Whether the connection is currently open.
  bool get isConnected => _state == ConnectionState.connected;

  /// Queues [data] for transmission and returns immediately. Bytes are drained
  /// off the calling isolate, so this never blocks even under backpressure.
  /// Empty payloads are ignored. Throws [BluetoothWriteException] if [data]
  /// exceeds the platform's 32-bit length limit.
  void add(Uint8List data) {
    if (data.isEmpty) return;
    if (data.length > 0x7fffffff) {
      throw const BluetoothWriteException('payload exceeds 2GiB limit');
    }
    _transport.send(data);
  }

  /// Waits until all previously [add]ed bytes have been handed to the OS.
  /// Note: on macOS, iOS and Android this is best-effort — writes are handed to
  /// the OS synchronously at [add] time, but there is no OS-level drain ack.
  Future<void> flush() => _transport.flush();

  /// Convenience: [add] then [flush].
  Future<void> write(Uint8List data) {
    add(data);
    return flush();
  }

  /// Closes immediately, discarding anything not yet flushed.
  Future<void> close() async {
    _state = ConnectionState.disconnecting;
    await _transport.close();
    await _cleanup();
  }

  /// Flushes pending writes, then closes. Prefer this for graceful shutdown.
  Future<void> finish() async {
    _state = ConnectionState.disconnecting;
    try {
      await _transport.flush();
    } finally {
      await _transport.close();
      await _cleanup();
    }
  }

  Future<void> _cleanup() async {
    _state = ConnectionState.disconnected;
    await _inputSub.cancel();
    await _stateSub.cancel();
    if (!_stateController.isClosed) {
      _stateController.add(ConnectionState.disconnected);
      await _stateController.close();
    }
    if (!_inputController.isClosed) await _inputController.close();
  }
}
