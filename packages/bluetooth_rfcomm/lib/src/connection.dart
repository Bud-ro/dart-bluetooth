import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'exceptions.dart';
import 'logging.dart';
import 'models/bluetooth_device.dart';
import 'models/enums.dart';
import 'platform/platform_interface.dart';
import 'platform/transport_stats.dart';

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
    _inputController = StreamController<Uint8List>.broadcast(
      onListen: _drainRxBuffer,
    );
    _inputSub = _transport.incoming.listen(
      (bytes) {
        logData.finest(() => 'rx ${device.id} ${describeBytes(bytes)}');
        _rxBytes += bytes.length;
        if (_inputController.hasListener) {
          _inputController.add(bytes);
        } else {
          // A broadcast stream DROPS events with no listener — and inbound
          // bytes can legally arrive before the app's first input.listen()
          // (the peer greets right after connect) or between a cancel and a
          // re-listen. Losing them would be silent data loss on a reliable
          // protocol, so buffer (bounded) and replay on the next listen.
          _bufferRx(bytes);
        }
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
  late final StreamController<Uint8List> _inputController;
  final StreamController<ConnectionState> _stateController =
      StreamController<ConnectionState>.broadcast();
  late final StreamSubscription<Uint8List> _inputSub;
  late final StreamSubscription<ConnectionState> _stateSub;

  ConnectionState _state = ConnectionState.connected;
  Future<void>? _cleanupFuture;

  /// Bytes received while [input] had no listener, replayed (in order) to the
  /// next listener. Bounded by [_maxRxBufferBytes]; beyond that the OLDEST
  /// data is discarded with a WARNING (only reachable when the app never
  /// listens at all).
  final List<Uint8List> _rxBuffer = [];
  int _rxBufferBytes = 0;
  static const int _maxRxBufferBytes = 1 << 20; // 1 MiB

  int _rxBytes = 0;
  int _txBytes = 0;
  int _txRejectedBytes = 0;
  int _txDiscardedBytes = 0;
  int _rxBufferOverflowBytes = 0;
  bool _txDiscardChecked = false;

  /// Total bytes received from the peer over this connection's lifetime
  /// (including any still buffered awaiting the first [input] listener).
  /// With [txBytes], lets an app attribute apparent message loss to a side.
  int get rxBytes => _rxBytes;

  /// Total bytes accepted by [add]/[write] over this connection's lifetime.
  int get txBytes => _txBytes;

  /// Hop-by-hop delivery counters — a **diagnostic surface** for attributing
  /// message loss to a specific hop. Keys and availability are
  /// platform-dependent and NOT covered by semver; log the whole map rather
  /// than parsing individual keys in production logic.
  ///
  /// Always present (counted in Dart, on every platform):
  ///
  ///  * `txAcceptedBytes` — accepted by [add]/[write] (== [txBytes]).
  ///  * `txRejectedBytes` — refused by the transport with a
  ///    [BluetoothWriteException] (dead link / native backlog full). These
  ///    bytes were never queued; the throw said so, this counts it.
  ///  * `txDiscardedBytes` — queued but unsent when [close] (or a peer drop)
  ///    discarded the outbound queue.
  ///  * `rxDeliveredBytes` — received from the transport (== [rxBytes]);
  ///    includes bytes still awaiting the first [input] listener.
  ///  * `rxBufferedBytes` — currently held for replay because nothing is
  ///    listening to [input]. Nonzero AFTER disconnect means bytes arrived
  ///    that no listener ever received.
  ///  * `rxBufferOverflowBytes` — dropped from that replay buffer (only
  ///    reachable when the app never listens and >1 MiB accrues).
  ///
  /// Where the transport can introspect its native layer (currently macOS),
  /// the map additionally carries native counters — on macOS:
  /// `txEnqueuedBytes`, `txSubmittedBytes`, `txCompletedBytes`,
  /// `txRetriedChunks`, `txFailedChunks`, `txDroppedBytes`, `rxEvents`,
  /// `rxBytes`, `rxDroppedEvents` (native side) plus `rxDartEvents`,
  /// `rxDartBytes`, `rxDroppedClosedBytes`, `rxUnroutedEvents`,
  /// `rxUnroutedBytes`, `rxOversizeEvents` (FFI-boundary side).
  ///
  /// Attribution — read the differentials outermost-in; the first nonzero
  /// gap names the lossy hop:
  ///
  /// | Differential                              | Implicates                                     |
  /// |-------------------------------------------|------------------------------------------------|
  /// | app sends − `txAcceptedBytes`             | app-side (a swallowed [add] throw)             |
  /// | `txAcceptedBytes` − `txEnqueuedBytes`     | FFI write boundary (should be 0)               |
  /// | `txEnqueuedBytes` − `txSubmittedBytes`    | native queue backlog (stalled, not lost — yet) |
  /// | `txSubmittedBytes` − `txCompletedBytes`   | OS/controller in flight or unacknowledged      |
  /// | `txFailedChunks` / `txDroppedBytes`       | native write failures / teardown discards      |
  /// | `txRejectedBytes` / `txDiscardedBytes`    | Dart-side refusals / eaten queue on close      |
  /// | peer sends − `rxBytes` (native)           | radio / peer / OS (Dart never saw it)          |
  /// | `rxDroppedEvents` (native)                | native→Dart forwarding failure                 |
  /// | `rxBytes` − `rxDartBytes` − `rxUnroutedBytes` − `rxDroppedClosedBytes` | NativeCallable port hop (should be 0) |
  /// | `rxDartBytes` − `rxDeliveredBytes`        | transport→connection stream (should be 0)      |
  /// | `rxDeliveredBytes` − app receives         | `rxBufferOverflowBytes`, residual `rxBufferedBytes`, or app framing |
  ///
  /// The snapshot stays meaningful after disconnect (transports capture their
  /// native counters during teardown), so read it post-mortem when a session
  /// under-delivers.
  Map<String, int> get stats {
    final out = <String, int>{
      'txAcceptedBytes': _txBytes,
      'txRejectedBytes': _txRejectedBytes,
      'txDiscardedBytes': _txDiscardedBytes,
      'rxDeliveredBytes': _rxBytes,
      'rxBufferedBytes': _rxBufferBytes,
      'rxBufferOverflowBytes': _rxBufferOverflowBytes,
    };
    if (_transport case final TransportStats transport) {
      try {
        out.addAll(transport.nativeStats());
      } catch (e) {
        // Diagnostics must never break the thing they diagnose.
        logConnection.warning(() => 'native stats failed ${device.id}: $e');
      }
    }
    return out;
  }

  void _bufferRx(Uint8List bytes) {
    _rxBuffer.add(bytes);
    _rxBufferBytes += bytes.length;
    while (_rxBufferBytes > _maxRxBufferBytes && _rxBuffer.isNotEmpty) {
      final dropped = _rxBuffer.removeAt(0);
      _rxBufferBytes -= dropped.length;
      _rxBufferOverflowBytes += dropped.length;
      logConnection.warning(
        () =>
            'input buffer overflow: dropped ${dropped.length}B received '
            'while nothing was listening to input',
      );
    }
  }

  void _drainRxBuffer() {
    // A listener attaching after teardown must not trip an add-after-close
    // (whatever is still buffered then is undeliverable; `stats` reports it
    // as a residual rxBufferedBytes).
    if (_rxBuffer.isEmpty || _inputController.isClosed) return;
    logData.fine(
      () =>
          'replaying ${_rxBufferBytes}B received before/without an input '
          'listener',
    );
    for (final chunk in _rxBuffer) {
      _inputController.add(chunk);
    }
    _rxBuffer.clear();
    _rxBufferBytes = 0;
  }

  /// Inbound data. Broadcast: multiple listeners see the same bytes. Closes
  /// when the connection drops, so `await for` / `onDone` cleanly terminates.
  ///
  /// Bytes that arrive while NO listener is attached (before your first
  /// `listen`, or between a cancel and a re-listen) are buffered — bounded at
  /// 1 MiB — and replayed in order to the next listener, so a peer that
  /// responds faster than your `listen()` attaches loses nothing.
  ///
  /// This is a BYTE stream, not a message stream: one event may carry several
  /// of your protocol's messages (they bunch when the link stalls briefly,
  /// e.g. waking from sniff mode) or a partial one. Frame by content, never
  /// by event boundaries.
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
  /// exceeds the platform's 32-bit length limit, if the connection is already
  /// closed / has dropped (check [isConnected] if you need to avoid that), or
  /// if a platform-side safety cap rejects the write (macOS bounds its native
  /// backlog at 4 MiB — only reachable by ignoring the pacing guidance
  /// above). A throw always means ZERO bytes of this call were accepted.
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
      _txBytes += data.length;
    } on BluetoothWriteException catch (e) {
      // Rejected, never queued (dead link, or a bounded native backlog said
      // no). Counted so a sender that swallows the throw still sees the loss
      // in [stats].
      _txRejectedBytes += data.length;
      logConnection.warning(() => 'write failed ${device.id}: ${e.message}');
      rethrow;
    }
  }

  /// Waits until all previously [add]ed bytes have been handed to the OS, and
  /// throws [BluetoothWriteException] where the platform can tell that queued
  /// bytes were lost to a dead link (Windows, Linux, Android). On macOS and
  /// iOS this is best-effort: macOS waits for the native queue to empty but
  /// cannot distinguish "delivered" from "discarded by a disconnect" (check
  /// [stats]' `txDroppedBytes` for that), and iOS resolves immediately — use
  /// [drain] there when you need the queue verifiably empty
  /// ([pendingWriteBytes] is accurate on every platform).
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
  /// Precision varies by platform: live on Windows (small reporting
  /// granularity), macOS, iOS and Android; on Linux it is an UPPER BOUND that
  /// only [flush] resets (dart:io sockets hide their internal buffer).
  /// [drain] compensates automatically — it falls back to a flush when the
  /// gauge shows no progress — so pacing works everywhere; treat the raw
  /// value on Linux as "at most this much still queued".
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
  /// discards the queue) while bytes this call was waiting on were lost —
  /// detected via the discard accounting, so a teardown that zeroes the
  /// gauge cannot masquerade as a successful drain. Completes normally,
  /// without waiting, whenever the condition already holds and nothing was
  /// discarded since the call began — even after disconnect.
  Future<void> drain({int belowBytes = 0}) async {
    RangeError.checkNotNegative(belowBytes, 'belowBytes');
    final discardedAtStart = _txDiscardedBytes;
    var lastPending = -1;
    var stalePolls = 0;
    while (true) {
      // Discards are checked FIRST: transports zero their gauge on teardown,
      // so "pending dropped to 0" alone cannot be trusted as delivery.
      final lost = _txDiscardedBytes - discardedAtStart;
      if (lost > 0) {
        throw BluetoothWriteException(
          '$lost queued bytes were discarded before delivery',
        );
      }
      final pending = _transport.pendingWriteBytes;
      if (pending <= belowBytes) return;
      if (_state == ConnectionState.disconnected) {
        throw BluetoothWriteException(
          'connection closed with $pending bytes undelivered',
        );
      }
      if (belowBytes == 0) {
        // Poll-free where the platform acknowledges drains (Windows, Linux,
        // Android, and macOS via its native pending gauge). The delay guards
        // against a tight loop on any platform whose flush can resolve
        // without fully draining.
        await flush();
        if (_transport.pendingWriteBytes > 0) {
          await Future<void>.delayed(_drainPollInterval);
        }
        continue; // re-run the loss check before declaring success
      }
      // Windowed waits poll — but on platforms whose gauge only updates at
      // flush boundaries (Linux reports an upper bound), polling alone would
      // never observe progress. A short no-progress watchdog falls back to a
      // real flush so the wait always converges.
      if (pending == lastPending) {
        if (++stalePolls >= 8) {
          stalePolls = 0;
          await flush();
          continue;
        }
      } else {
        lastPending = pending;
        stalePolls = 0;
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
    // Capture the queue depth BEFORE the transport zeroes it, or the discard
    // is invisible (a reconnecting app that closes eagerly would silently eat
    // its own queued tx). close() documents the discard, so it logs FINE;
    // an unrequested loss (peer drop) logs WARNING via _doCleanup.
    _noteDiscardedTx(requested: true);
    await _transport.close();
    await _cleanup();
  }

  /// Records (once) any bytes still queued toward the OS as discarded, so
  /// [stats] — and, for unrequested losses, a warning log — make an eaten tx
  /// queue observable even when the caller never awaited [drain]/[flush].
  void _noteDiscardedTx({required bool requested}) {
    if (_txDiscardChecked) return;
    _txDiscardChecked = true;
    final int pending;
    try {
      pending = _transport.pendingWriteBytes;
    } catch (_) {
      return; // a transport that can't answer post-mortem has nothing to add
    }
    if (pending > 0) {
      _txDiscardedBytes += pending;
      String message() =>
          'discarding ${pending}B queued but unsent tx ${device.id}';
      if (requested) {
        logConnection.fine(message);
      } else {
        logConnection.warning(message);
      }
    }
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
    // Peer-initiated drops reach teardown without passing through close();
    // record any queued-but-unsent tx before it evaporates (no-op if close()
    // already checked, or if the transport zeroed its queue first — native
    // layers count that side themselves, e.g. macOS txDroppedBytes).
    _noteDiscardedTx(requested: false);
    // One post-mortem loss ledger per connection: hardware sessions rarely
    // think to read [stats] before the object is gone. FINE, not INFO — the
    // package contract is silence at the default level.
    logConnection.fine(() => 'session stats ${device.id}: $stats');
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
