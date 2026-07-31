@TestOn('vm')
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
import 'package:bluetooth_rfcomm/testing.dart';
import 'package:test/test.dart';

/// Seeded random-schedule fuzzing of the facade's public API.
///
/// Most bugs this package has shipped were async-interleaving races — legal
/// call sequences whose awaits interleaved in an order nobody hand-wrote a
/// test for. This harness generates random operation schedules against the
/// fake platform and checks global invariants continuously:
///
///  * no unhandled async error ever escapes (runZonedGuarded trap),
///  * the engine's internal counters never go negative,
///  * after dispose + quiescence, everything reads idle.
///
/// Failures print the SEED — rerun with `FUZZ_SEED=1234 dart test
/// test/facade_fuzz_test.dart` to reproduce deterministically. Crank
/// `FUZZ_RUNS` in a soak (default keeps CI fast).
void main() {
  final env = Platform.environment;
  final fixedSeed = env['FUZZ_SEED'] != null
      ? int.tryParse(env['FUZZ_SEED']!)
      : null;
  final runs = fixedSeed != null
      ? 1
      : int.tryParse(env['FUZZ_RUNS'] ?? '') ?? 12;
  final opsPerRun = int.tryParse(env['FUZZ_OPS'] ?? '') ?? 60;

  for (var run = 0; run < runs; run++) {
    final seed = fixedSeed ?? (0xC0DE + run * 7919);
    test('random schedule survives (seed $seed)', () async {
      final unhandled = <Object>[];
      // NOTE: errors cannot cross an error-zone boundary — awaiting the
      // zoned future directly would hang forever on any failure (masking the
      // real message as a 30s timeout). Values can cross; complete a parent-
      // zone completer instead and collect failures explicitly.
      final done = Completer<void>();
      unawaited(
        runZonedGuarded(
          () async {
            try {
              await _fuzzOnce(seed, opsPerRun);
            } catch (e) {
              unhandled.add(e);
            } finally {
              if (!done.isCompleted) done.complete();
            }
          },
          (e, st) {
            unhandled.add(e);
          },
        ),
      );
      await done.future;
      expect(
        unhandled,
        isEmpty,
        reason:
            'unhandled async error(s) escaped with seed $seed: $unhandled\n'
            'Reproduce: FUZZ_SEED=$seed dart test test/facade_fuzz_test.dart',
      );
    });
  }
}

Future<void> _fuzzOnce(int seed, int ops) async {
  final rand = Random(seed);
  final fake = FakeBluetoothRfcommPlatform();
  final bt = BluetoothRfcomm(platform: fake)
    ..bondedPollInterval = const Duration(milliseconds: 20);
  fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
  fake.discoveryResults.add(
    BluetoothDiscoveryResult(
      device: FakeBluetoothRfcommPlatform.sampleDevice(),
      rssi: -40,
      timestamp: DateTime(2026),
    ),
  );
  // Mix of stream-open (Linux-style) and stream-completing platforms.
  fake.discoveryCompletes = rand.nextBool();
  // Fault injection: a slice of runs fuzz the error path (the scan loop must
  // survive per-cycle stream errors) and slow connects (exercising the
  // connect-pause poll slice in the engine).
  if (rand.nextInt(4) == 0) {
    fake.discoveryError = const BluetoothDiscoveryException('fuzz-injected');
  }
  if (rand.nextInt(3) == 0) {
    fake.connectDelay = Duration(milliseconds: rand.nextInt(60));
  }

  final subs = <StreamSubscription<Object?>>[];
  final conns = <BluetoothConnection>[];
  var disposed = false;

  void checkInvariants(String afterOp) {
    final counters = bt.debugEngineCounters;
    for (final e in counters.entries) {
      if (e.value < 0) {
        fail(
          'invariant violated after "$afterOp" (seed $seed): '
          '${e.key} == ${e.value} (must be >= 0). Counters: $counters',
        );
      }
    }
    // UPWARD-leak guards — the clamped counters cannot go negative by
    // construction, so >= 0 alone is unfalsifiable. What a real scan-engine
    // bug looks like is a hold that never releases or an inquiry per
    // listener:
    // Loose upper bounds — every hold/platform inquiry is owned by a live
    // subscription, the background cycle, or a transient scanDuration window
    // (the fire-and-forget list ops can stack a handful). The slack absorbs
    // legitimate stacking; a genuine leak grows past any constant.
    const slack = 8;
    final holds = counters['scanHolds'] ?? 0;
    if (holds > subs.length + slack) {
      fail(
        'scanHolds leak after "$afterOp" (seed $seed): $holds holds for '
        '${subs.length} live subscriptions. Counters: $counters',
      );
    }
    final netInquiries = fake.startDiscoveryCount - fake.stopDiscoveryCount;
    if (netInquiries > subs.length + slack) {
      fail(
        'inquiry leak after "$afterOp" (seed $seed): '
        '${fake.startDiscoveryCount} starts vs ${fake.stopDiscoveryCount} '
        'stops with ${subs.length} live subscriptions. Counters: $counters',
      );
    }
  }

  final opsTable = <Future<void> Function()>[
    () async => bt.startScan(
      rescanDelay: Duration(milliseconds: 10 + rand.nextInt(40)),
    ),
    () async => bt.stopScan(),
    () async => bt.forgetScannedDevices(),
    () async {
      subs.add(bt.scannedDevicesStream.listen((_) {}, onError: (Object _) {}));
    },
    () async {
      subs.add(
        bt
            .bondedAndDiscoveredStream(
              scanInterval: rand.nextBool()
                  ? Duration(milliseconds: 10 + rand.nextInt(40))
                  : null,
            )
            .listen((_) {}, onError: (Object _) {}),
      );
    },
    () async {
      final s = bt.startDiscovery().listen((_) {}, onError: (Object _) {});
      subs.add(s);
    },
    () async {
      if (subs.isEmpty) return;
      await subs.removeAt(rand.nextInt(subs.length)).cancel();
    },
    () async {
      // Fire-and-forget listing (errors handled).
      unawaited(
        bt
            .listScannedDevices(
              scanDuration: rand.nextBool()
                  ? Duration(milliseconds: rand.nextInt(30))
                  : null,
            )
            .catchError((Object _) => const <BluetoothDevice>[]),
      );
    },
    () async {
      unawaited(
        bt.listPairedAndScannedDevices().catchError(
          (Object _) => const <BluetoothDevice>[],
        ),
      );
    },
    () async {
      try {
        final c = await bt.connect(FakeBluetoothRfcommPlatform.sampleDevice());
        conns.add(c);
      } on BluetoothException {
        // acceptable under fuzz
      }
    },
    () async {
      if (conns.isEmpty) return;
      final c = conns.removeAt(rand.nextInt(conns.length));
      try {
        c.add(Uint8List.fromList([1, 2, 3]));
      } on BluetoothWriteException {
        // fine post-drop
      }
      await c.disconnect();
    },
    () async {
      if (fake.transports.isEmpty) return;
      // Peer drops a random live transport out from under the facade.
      fake.transports[rand.nextInt(fake.transports.length)].dropPeer();
    },
  ];

  for (var i = 0; i < ops && !disposed; i++) {
    final op = opsTable[rand.nextInt(opsTable.length)];
    await op();
    checkInvariants('op#$i');
    if (rand.nextInt(4) == 0) {
      await Future<void>.delayed(Duration(milliseconds: rand.nextInt(3)));
    }
  }

  // Teardown: everything must quiesce cleanly regardless of live subs/conns.
  for (final c in conns) {
    await c.disconnect();
  }
  await bt.dispose();
  disposed = true;
  for (final s in subs) {
    await s.cancel();
  }
  await Future<void>.delayed(const Duration(milliseconds: 60));
  checkInvariants('post-dispose');
  expect(
    bt.isScanning,
    isFalse,
    reason: 'seed $seed: engine idle after dispose',
  );
  // dispose() force-zeroes the facade counters, so asserting on them alone is
  // a tautology. The platform's ledger is the falsifiable part: every started
  // inquiry must have been stopped by quiescence.
  final startsAtDispose = fake.startDiscoveryCount;
  await Future<void>.delayed(const Duration(milliseconds: 80));
  expect(
    fake.startDiscoveryCount,
    startsAtDispose,
    reason: 'seed $seed: no new platform inquiries may start after dispose',
  );
}
