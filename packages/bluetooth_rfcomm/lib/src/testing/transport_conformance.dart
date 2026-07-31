import 'dart:async';
import 'dart:typed_data';

import '../exceptions.dart';
import '../models/enums.dart';
import '../platform/platform_interface.dart';
import '../platform/transport_stats.dart';

/// Contract-conformance checker for [RfcommTransport] implementations.
///
/// Every backend must satisfy the same observable contract, and historically
/// most cross-platform bugs in this package were *contract drift* — one
/// transport erroring where another closed cleanly, teardown emitting twice,
/// writes silently vanishing. Running one shared checker against every
/// implementation turns that whole bug class into a red test.
///
/// Framework-free by design (no `package:test` dependency): each check runs
/// the scenario and returns human-readable violations; an empty result is a
/// pass. Wire it into any test framework:
///
/// ```dart
/// test('transport conforms', () async {
///   final violations = await checkRfcommTransportConformance(
///     open: () async => FakeRfcommTransport(...),
///     simulatePeerDrop: (t) async => (t as FakeRfcommTransport).dropPeer(),
///   );
///   expect(violations, isEmpty);
/// });
/// ```
///
/// [open] must yield a freshly CONNECTED transport (a new one per call).
/// [simulatePeerDrop], when provided, must make the peer go away (fakes call
/// their drop hook; a hardware rig powers the device off) — the peer-loss
/// checks are skipped without it. [injectIncoming], when provided, must make
/// the PEER send exactly [bytes] (fakes call their deliver hook; a rig with
/// an echo device can implement it as an echo round-trip) — it unlocks the
/// data-delivery check, without which a transport that never moves a byte
/// could pass on lifecycle choreography alone. Real backends need a live
/// peer, so they run this from an integration/hardware rig, not unit CI.
Future<List<String>> checkRfcommTransportConformance({
  required Future<RfcommTransport> Function() open,
  Future<void> Function(RfcommTransport transport)? simulatePeerDrop,
  Future<void> Function(RfcommTransport transport, Uint8List bytes)?
  injectIncoming,
}) async {
  final violations = <String>[];
  void check(bool condition, String rule) {
    if (!condition) violations.add(rule);
  }

  // NOTE: `incoming` is single-subscription and the contract assumes the
  // owner subscribes promptly (BluetoothConnection does so in its
  // constructor); transports may legally block close() on delivering the
  // terminal done. Every scenario below mirrors that by draining incoming.

  // -- starts connected ------------------------------------------------------
  {
    final t = await open();
    t.incoming.listen((_) {}, onError: (Object _) {});
    check(
      t.state == ConnectionState.connected,
      'a freshly opened transport must report ConnectionState.connected',
    );
    await t.close();
  }

  // -- local close: exactly-once terminal, clean EOF -------------------------
  {
    final t = await open();
    final states = <ConnectionState>[];
    var stateDone = false, incomingDone = false, incomingErrored = false;
    t.stateChanges.listen(states.add, onDone: () => stateDone = true);
    t.incoming.listen(
      (_) {},
      onError: (Object _) => incomingErrored = true,
      onDone: () => incomingDone = true,
    );
    await t.close();
    await _settle();
    check(
      states.where((s) => s == ConnectionState.disconnected).length == 1,
      'close() must emit exactly one terminal disconnected (got $states)',
    );
    check(stateDone, 'close() must close stateChanges');
    check(incomingDone, 'close() must close incoming');
    check(
      !incomingErrored,
      'a local close is a clean EOF, never a stream error',
    );
    check(
      t.state == ConnectionState.disconnected,
      'state must read disconnected after close()',
    );
  }

  // -- close is idempotent ---------------------------------------------------
  {
    final t = await open();
    t.incoming.listen((_) {}, onError: (Object _) {});
    await t.close();
    try {
      await t.close();
      check(
        t.state == ConnectionState.disconnected,
        'state must remain disconnected after a second close()',
      );
    } catch (e) {
      violations.add('a second close() must not throw (threw $e)');
    }
  }

  // -- post-close write surface ----------------------------------------------
  {
    final t = await open();
    t.incoming.listen((_) {}, onError: (Object _) {});
    await t.close();
    try {
      t.send(Uint8List.fromList([1]));
      violations.add('send() after close must throw BluetoothWriteException');
    } on BluetoothWriteException {
      // contract satisfied
    } catch (e) {
      violations.add(
        'send() after close threw ${e.runtimeType}, not BluetoothWriteException',
      );
    }
    try {
      await t.flush();
    } catch (e) {
      violations.add('flush() after close must not throw (threw $e)');
    }
  }

  // -- backpressure gauges ---------------------------------------------------
  {
    final t = await open();
    t.incoming.listen((_) {}, onError: (Object _) {});
    final max = t.maxPayloadSize;
    check(
      max == null || max > 0,
      'maxPayloadSize must be null (unadvertised) or positive (got $max)',
    );
    check(t.pendingWriteBytes >= 0, 'pendingWriteBytes must never be negative');
    t.send(Uint8List.fromList(List.filled(256 * 1024, 0)));
    check(
      t.pendingWriteBytes > 0,
      'a 256 KiB send must be visible in pendingWriteBytes immediately '
      '(a gauge that never rises makes drain()/backpressure vacuous)',
    );
    await t.flush();
    await t.close();
    check(
      t.pendingWriteBytes == 0,
      'a closed transport must report pendingWriteBytes == 0',
    );
  }

  // -- data delivery ---------------------------------------------------------
  if (injectIncoming != null) {
    final t = await open();
    final received = <int>[];
    final gotBytes = Completer<void>();
    t.incoming.listen((chunk) {
      received.addAll(chunk);
      if (received.length >= 3 && !gotBytes.isCompleted) gotBytes.complete();
    }, onError: (Object _) {});
    await injectIncoming(t, Uint8List.fromList([0xA5, 0x5A, 0x42]));
    try {
      await gotBytes.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      // fall through; the checks below report it
    }
    check(
      received.length >= 3,
      'bytes sent by the peer must arrive on incoming '
      '(got ${received.length} of 3)',
    );
    check(
      received.length < 3 ||
          (received[0] == 0xA5 && received[1] == 0x5A && received[2] == 0x42),
      'incoming must deliver the peer\'s bytes unmodified and in order '
      '(got $received)',
    );
    await t.close();
  }

  // -- peer loss --------------------------------------------------------------
  if (simulatePeerDrop != null) {
    {
      final t = await open();
      final states = <ConnectionState>[];
      var incomingDone = false, incomingErrored = false;
      t.stateChanges.listen(states.add);
      t.incoming.listen(
        (_) {},
        onError: (Object _) => incomingErrored = true,
        onDone: () => incomingDone = true,
      );
      await simulatePeerDrop(t);
      await _settle();
      check(
        states.where((s) => s == ConnectionState.disconnected).length == 1,
        'peer loss must emit exactly one terminal disconnected (got $states)',
      );
      check(
        incomingDone,
        'incoming must END on peer loss so `await for` terminates',
      );
      check(!incomingErrored, 'peer loss is a clean EOF on every platform');
      check(
        t.state == ConnectionState.disconnected,
        'state must read disconnected after peer loss',
      );
    }
    {
      final t = await open();
      t.incoming.listen((_) {}, onError: (Object _) {});
      await simulatePeerDrop(t);
      await _settle();
      try {
        t.send(Uint8List.fromList([1]));
        violations.add(
          'send() after peer loss must throw BluetoothWriteException',
        );
      } on BluetoothWriteException {
        // contract satisfied
      } catch (e) {
        violations.add(
          'send() after peer loss threw ${e.runtimeType}, '
          'not BluetoothWriteException',
        );
      }
      try {
        await t.flush();
        await t.close();
      } catch (e) {
        violations.add(
          'flush()/close() after peer loss must not throw '
          '(threw $e)',
        );
      }
      check(
        t.pendingWriteBytes == 0,
        'a dropped transport must report pendingWriteBytes == 0',
      );
    }
    {
      // Bytes queued BEFORE the drop: zeroing the gauge is required (above),
      // but the loss itself must remain observable — via a throwing flush()
      // or a TransportStats teardown latch. A transport that zeroes and
      // forgets makes drain()/stats silently lie about the most common loss
      // event there is.
      final t = await open();
      t.incoming.listen((_) {}, onError: (Object _) {});
      t.send(Uint8List.fromList(List.filled(64 * 1024, 1)));
      final queuedAtDrop = t.pendingWriteBytes;
      await simulatePeerDrop(t);
      await _settle();
      var flushThrew = false;
      try {
        await t.flush();
      } on BluetoothWriteException {
        flushThrew = true;
      } catch (e) {
        violations.add(
          'flush() over dropped bytes threw ${e.runtimeType}, '
          'not BluetoothWriteException',
        );
      }
      var latched = 0;
      if (t is TransportStats) {
        try {
          latched = (t as TransportStats).nativeStats()['txDroppedBytes'] ?? 0;
        } catch (_) {}
      }
      check(
        queuedAtDrop == 0 || flushThrew || latched > 0,
        'bytes queued before a peer drop must be observable as lost: flush() '
        'must throw or nativeStats must latch txDroppedBytes '
        '(queued $queuedAtDrop, latched $latched) — silent discard',
      );
      await t.close();
    }
  }

  return violations;
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
