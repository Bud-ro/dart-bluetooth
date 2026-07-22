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
/// bytes). [input] closes cleanly when the peer disconnects. For bulk sending,
/// pace against the outbound queue with [pendingWriteBytes]/[drain] — the
/// queue is unbounded and never silently drops accepted bytes.
///
/// A connection is **single-use**: once it drops or you [disconnect]/[close]/
/// [finish] it, it can't be reopened — call [BluetoothRfcomm.connect] again for
/// a fresh one. Every method is safe to call after the link has dropped: writes
/// fail with a [BluetoothWriteException], teardown methods are idempotent
/// no-ops, and the streams have already closed cleanly. To
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
  /// the caller (bytes drain on a background isolate/thread).
  ///
  /// The queue between [add] and the OS is **unbounded and lossless**: every
  /// byte accepted here is either delivered to the OS or reported as lost
  /// (via [flush]/[drain]/the terminal disconnect) — this package never
  /// silently drops accepted bytes. The flip side is that nothing stops *you*
  /// from queueing faster than the link drains, which only grows memory.
  /// Pick the pacing that fits the traffic:
  ///
  ///  * **Small, occasional frames** (commands, telemetry ticks): plain [add],
  ///    fire-and-forget.
  ///  * **Request/response**: `await write(frame)` per message, so each frame
  ///    reaches the OS before you send the next.
  ///  * **Bulk transfer**: window it — [add] chunks while
  ///    [pendingWriteBytes] is below a cap, then `await drain(belowBytes: …)`.
  ///
  /// Empty payloads are ignored. Throws [BluetoothWriteException] if [data]
  /// exceeds the platform's 32-bit length limit, or if the connection is already
  /// closed / has dropped (check [isConnected] if you need to avoid that).
  /// Payloads larger than [maxPayloadSize] are fine — transports split them
  /// into OS-sized writes; the limit is per *native write*, not per [add].
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

  /// Waits until all previously [add]ed bytes have been handed to the OS, and
  /// throws [BluetoothWriteException] where the platform can tell that queued
  /// bytes were lost to a dead link (Windows, Linux, Android). On macOS and
  /// iOS this is best-effort: bytes are queued to the native layer and there
  /// is no drain acknowledgement, so flush resolves immediately — use [drain]
  /// there when you need the queue verifiably empty ([pendingWriteBytes] is
  /// accurate on every platform).
  Future<void> flush() => _transport.flush();

  /// Convenience: [add] then [flush] — the natural request/response rhythm
  /// (`await conn.write(request)` then read the reply from [input]). Awaiting
  /// each write also self-paces a sender to the link's real speed on the
  /// platforms where [flush] is exact.
  Future<void> write(Uint8List data) {
    add(data);
    return flush();
  }

  /// OS-advertised largest single *native* write payload (RFCOMM MTU on
  /// macOS, max transmit packet size on Android); null where the OS exposes
  /// none (Windows/Linux stream sockets, iOS EA).
  ///
  /// This is a frame *size*, not a data *rate* — Bluetooth Classic advertises
  /// no throughput number anywhere (see the README's "Backpressure and
  /// throughput" section). You never have to chunk to it ([add] takes any
  /// size); it is informational, e.g. for sizing protocol frames so each fits
  /// one RFCOMM packet.
  int? get maxPayloadSize => _transport.maxPayloadSize;

  /// Bytes accepted by [add]/[write] but not yet handed to the OS — the
  /// current depth of the unbounded outbound queue. 0 means fully drained.
  ///
  /// Poll it to window bulk transfers (see [drain]) or to surface a
  /// "sending…" indicator; it is accurate on every platform.
  int get pendingWriteBytes => _transport.pendingWriteBytes;

  /// Completes once [pendingWriteBytes] is at or below [belowBytes] — the
  /// awaitable form of the queue-depth check, for windowed bulk sending:
  /// [add] chunks until the queue holds a window's worth, then
  /// `await drain(belowBytes: window ~/ 2)` before adding more.
  ///
  /// With the default `belowBytes: 0` this resolves when the queue is fully
  /// drained; where [flush] is exact (Windows, Linux, Android) that case is
  /// poll-free and precise. Otherwise the queue is polled every few
  /// milliseconds, so completion can lag the condition by one poll interval
  /// (~5 ms) — ample for pacing, not for hard real-time.
  ///
  /// Throws [BluetoothWriteException] if the connection drops (or [close]
  /// discards the queue) while more than [belowBytes] bytes remain — queued
  /// bytes were lost, and per this package's no-silent-drop contract that is
  /// always reported. Completes normally, without waiting, whenever the
  /// condition already holds — even after disconnect.
  Future<void> drain({int belowBytes = 0}) async {
    RangeError.checkNotNegative(belowBytes, 'belowBytes');
    while (true) {
      final pending = _transport.pendingWriteBytes;
      if (pending <= belowBytes) return;
      if (_state == ConnectionState.disconnected) {
        throw BluetoothWriteException(
          'connection closed with $pending bytes undelivered',
        );
      }
      if (belowBytes == 0) {
        // Poll-free where the platform acknowledges drains; on macOS/iOS
        // flush resolves immediately and we fall through to the poll.
        await flush();
        if (_transport.pendingWriteBytes == 0) return;
      }
      await Future<void>.delayed(_drainPollInterval);
    }
  }

  static const Duration _drainPollInterval = Duration(milliseconds: 5);

  /// Closes immediately, discarding anything not yet flushed.
  ///
  /// Safe to call at any time, including after the connection has already
  /// dropped or been closed — it then just awaits the (already-run) teardown.
  Future<void> close() async {
    // Already torn down (peer dropped, or a previous close/finish/disconnect):
    // don't regress state to `disconnecting`, just await the same teardown.
    final done = _cleanupFuture;
    if (done != null) return done;
    logConnection.fine(() => 'close ${device.id}');
    _state = ConnectionState.disconnecting;
    await _transport.close();
    await _cleanup();
  }

  /// Flushes pending writes, then closes. Prefer this for graceful shutdown.
  ///
  /// Safe to call at any time, including after the connection has already
  /// dropped or been closed.
  Future<void> finish() async {
    final done = _cleanupFuture;
    if (done != null) return done;
    logConnection.fine(() => 'finish ${device.id}');
    _state = ConnectionState.disconnecting;
    try {
      await _transport.flush();
    } catch (e) {
      // The link died with bytes still queued (e.g. peer powered off in the
      // race window before the drop was detected). The disconnect is already
      // in motion; graceful shutdown still completes — never throw out of a
      // teardown method. Callers that need delivery confirmation use
      // write()/flush() directly.
      logConnection.fine(() => 'flush during finish failed ${device.id}: $e');
    } finally {
      await _transport.close();
      await _cleanup();
    }
  }

  /// Disconnects from the device: flushes pending writes, then closes the link.
  ///
  /// Equivalent to [finish]. Idempotent and safe to call at any time — if the
  /// connection already dropped (e.g. the device was powered off) this simply
  /// completes once teardown has finished.
  Future<void> disconnect() => finish();

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
