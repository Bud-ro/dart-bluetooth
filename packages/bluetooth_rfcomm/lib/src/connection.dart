import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'exceptions.dart';
import 'logging.dart';
import 'models/bluetooth_device.dart';
import 'models/enums.dart';
import 'platform/platform_interface.dart';

/// An open RFCOMM serial connection to a device.
///
/// Obtain one from [BluetoothRfcomm.connect]. Read with [input] and write with
/// [add] (fire-and-forget, never blocks) or [write] (awaits the OS accepting the
/// bytes). [input] closes cleanly when the peer disconnects.
///
/// A connection is **single-use**: once it drops or you [close]/[finish] it, it
/// can't be reopened — call [BluetoothRfcomm.connect] again for a fresh one. To
/// reconnect, re-fetch the device (the [DeviceId] may be session-scoped on iOS)
/// and retry while [BluetoothException.isTransient] is true.
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
    logConnection.fine(() => 'opened ${device.id}');
    _inputSub = _transport.incoming.listen(
      (bytes) {
        logData.finest(() => 'rx ${device.id} ${describeBytes(bytes)}');
        _inputController.add(bytes);
      },
      onError: _inputController.addError,
      // Peer-initiated disconnect: the transport closes its incoming stream.
      onDone: () => unawaited(_cleanup()),
    );
    _stateSub = _transport.stateChanges.listen((s) {
      _state = s;
      logConnection.fine(() => 'state ${device.id} -> ${s.name}');
      // Funnel the terminal state through _cleanup so it's emitted exactly
      // once (and the input/state controllers + subscriptions are released).
      if (s == ConnectionState.disconnected) {
        unawaited(_cleanup());
      } else if (!_stateController.isClosed) {
        _stateController.add(s);
      }
    }, onDone: () => unawaited(_cleanup()));
  }

  /// Internal: wrap a platform transport. Not part of the public API.
  @internal
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
  Future<void>? _cleanupFuture;

  /// Inbound data. Broadcast: multiple listeners see the same bytes. Closes
  /// when the connection drops, so `await for` / `onDone` cleanly terminates.
  Stream<Uint8List> get input => _inputController.stream;

  /// Connection-state transitions for this connection. A [BluetoothConnection]
  /// only exists once [BluetoothRfcomm.connect] has resolved, so the stream starts at
  /// [ConnectionState.connected]; in practice the only transition it emits is
  /// the terminal [ConnectionState.disconnected] (followed by close).
  Stream<ConnectionState> get stateChanges => _stateController.stream;

  /// Current connection state.
  ConnectionState get state => _state;

  /// Whether the connection is currently open.
  bool get isConnected => _state == ConnectionState.connected;

  /// Queues [data] for transmission and returns immediately — it never blocks
  /// the caller (bytes drain on a background isolate/thread). The queue is
  /// unbounded, so for sustained bulk writes against a slow link pace yourself
  /// with [write]/[flush] rather than calling [add] in a tight loop. Fine for
  /// the small, low-rate frames typical of RFCOMM serial.
  /// Empty payloads are ignored. Throws [BluetoothWriteException] if [data]
  /// exceeds the platform's 32-bit length limit, or if the connection is already
  /// closed / has dropped (check [isConnected] if you need to avoid that).
  void add(Uint8List data) {
    if (data.isEmpty) return;
    if (data.length > 0x7fffffff) {
      throw const BluetoothWriteException('payload exceeds 2GiB limit');
    }
    logData.finest(() => 'tx ${device.id} ${describeBytes(data)}');
    try {
      _transport.send(data);
    } on BluetoothWriteException catch (e) {
      logConnection.warning(() => 'write failed ${device.id}: ${e.message}');
      rethrow;
    }
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
    logConnection.fine(() => 'close ${device.id}');
    _state = ConnectionState.disconnecting;
    await _transport.close();
    await _cleanup();
  }

  /// Flushes pending writes, then closes. Prefer this for graceful shutdown.
  Future<void> finish() async {
    logConnection.fine(() => 'finish ${device.id}');
    _state = ConnectionState.disconnecting;
    try {
      await _transport.flush();
    } finally {
      await _transport.close();
      await _cleanup();
    }
  }

  /// Idempotent teardown — runs once whether triggered by [close]/[finish] or a
  /// peer-initiated disconnect. Emits a single terminal `disconnected`, cancels
  /// both subscriptions, and closes both controllers. Memoized so every caller
  /// awaits the *same* completion (incl. the terminal-event delivery turn).
  Future<void> _cleanup() => _cleanupFuture ??= _doCleanup();

  Future<void> _doCleanup() async {
    logConnection.fine(() => 'disconnected ${device.id}');
    _state = ConnectionState.disconnected;
    await _inputSub.cancel();
    await _stateSub.cancel();
    if (!_stateController.isClosed) {
      _stateController.add(ConnectionState.disconnected);
      await _stateController.close();
    }
    if (!_inputController.isClosed) await _inputController.close();
    // Let the terminal `disconnected` reach broadcast listeners before a caller
    // awaiting close()/finish() observes the result.
    await Future<void>.delayed(Duration.zero);
  }
}
