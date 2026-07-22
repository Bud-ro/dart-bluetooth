@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
import 'package:bluetooth_rfcomm/src/platform/windows/windows_platform.dart';
import 'package:test/test.dart';

/// Pure-Dart pieces of the Windows backend that run on any host:
///
/// - The inquiry activation/End-ownership protocol, driven through the
///   [WindowsBluetoothRfcomm.debugSpawnInquiry] hook (the real worker runs
///   `WSALookupService*` and only exists on Windows). Every `_endLookup` FFI
///   call fails off-Windows and is swallowed by its catch, so Ends are
///   observed via [WindowsBluetoothRfcomm.debugOnLookupEnd].
/// - [ConsumedReporter], the writer isolate's consumed-bytes report gate with
///   its trailing-edge timer.
void main() {
  group('inquiry activation identity', () {
    late WindowsBluetoothRfcomm platform;
    late List<SendPort> ports;
    late List<int> ends;

    setUp(() {
      platform = WindowsBluetoothRfcomm();
      ports = [];
      ends = [];
      platform.debugSpawnInquiry = (port) async => ports.add(port);
      platform.debugOnLookupEnd = ends.add;
    });

    test('stale terminal null does not kill a re-activated inquiry', () async {
      final stream = platform.startDiscovery();
      final sub1 = stream.listen((_) {});
      expect(ports, hasLength(1));
      await sub1.cancel();

      // Rapid re-listen: the old worker's terminal null is still in flight.
      final results = <BluetoothDiscoveryResult>[];
      var done = false;
      stream.listen(results.add, onDone: () => done = true);
      expect(ports, hasLength(2));

      ports[0].send(null); // stale worker's cleanup null arrives late
      await pumpEventQueue();
      expect(done, isFalse, reason: 'stale null must not close the stream');

      // The new activation is still live...
      ports[1].send(<String, Object?>{'handle': 7});
      await pumpEventQueue();
      ports[1].send(<String, Object?>{'addr': 0x112233445566, 'name': 'peer'});
      await pumpEventQueue();
      expect(results, hasLength(1));
      expect(results.single.device.id.value, '11:22:33:44:55:66');

      // ...and still registered, so stopDiscovery can abort it.
      await platform.stopDiscovery();
      expect(ends, [7]);
      await pumpEventQueue();
      expect(done, isTrue);

      ports[1].send(null); // let the fake worker's port close
      await pumpEventQueue();
    });

    test(
      'stale handle is ended, never registered to the new activation',
      () async {
        final stream = platform.startDiscovery();
        final sub1 = stream.listen((_) {});
        await sub1.cancel();
        stream.listen((_) {});
        expect(ports, hasLength(2));

        // The OLD worker's Begin completes only now: its handle belongs to a
        // cancelled activation and must be aborted, not stored.
        ports[0].send(<String, Object?>{'handle': 41});
        ports[1].send(<String, Object?>{'handle': 42});
        await pumpEventQueue();
        expect(ends, [41]);

        // The new activation's slot holds 42 (not clobbered by 41).
        await platform.stopDiscovery();
        expect(ends, [41, 42]);

        ports[0].send(null);
        ports[1].send(null);
        await pumpEventQueue();
      },
    );

    test('cancel before the handle arrives aborts on arrival, once', () async {
      final stream = platform.startDiscovery();
      final sub = stream.listen((_) {});
      await sub.cancel();

      ports.single.send(<String, Object?>{'handle': 9});
      await pumpEventQueue();
      expect(ends, [9]);

      // The worker's terminal null must not End the handle a second time.
      ports.single.send(null);
      await pumpEventQueue();
      expect(ends, [9]);
    });

    test('natural completion is ended from the main isolate, once', () async {
      final stream = platform.startDiscovery();
      var done = false;
      stream.listen((_) {}, onDone: () => done = true);

      ports.single.send(<String, Object?>{'handle': 5});
      await pumpEventQueue();
      expect(ends, isEmpty);

      // Worker finished its scan (it never Ends the handle itself): the
      // terminal null makes the main isolate End the registered handle.
      ports.single.send(null);
      await pumpEventQueue();
      expect(ends, [5]);
      expect(done, isTrue);

      // Nothing left registered for stopDiscovery to End again.
      await platform.stopDiscovery();
      expect(ends, [5]);
    });
  });

  group('ConsumedReporter', () {
    test('sub-gate burst converges via the trailing-edge report', () async {
      final totals = <int>[];
      final r = ConsumedReporter(
        totals.add,
        reportInterval: const Duration(milliseconds: 20),
      );
      // Ten 1KB messages: under the 16KB byte gate and (normally) the time
      // gate, so nothing is reported at message time...
      for (var i = 0; i < 10; i++) {
        r.add(1024);
      }
      expect(r.total, 10 * 1024);
      // ...but with no further messages the trailing timer must still land
      // the tail, or pendingWriteBytes would stay stale forever.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(totals, isNotEmpty);
      expect(totals.last, 10 * 1024);
      r.dispose();
    });

    test('byte threshold reports immediately', () {
      final totals = <int>[];
      final r = ConsumedReporter(
        totals.add,
        reportBytes: 1000,
        reportInterval: const Duration(seconds: 10),
      );
      r.add(999);
      expect(totals, isEmpty);
      r.add(1);
      expect(totals, [1000]);
      r.dispose();
    });

    test('elapsed interval reports on the next message', () async {
      final totals = <int>[];
      final r = ConsumedReporter(
        totals.add,
        reportInterval: const Duration(milliseconds: 10),
      );
      r.add(10); // gated; arms the trailing timer
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(totals.last, 10); // trailing report fired meanwhile
      r.add(5); // gap was reset by that report -> gated again
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(totals.last, 15);
      r.dispose();
    });

    test('a forced report cancels the armed trailing timer', () async {
      final totals = <int>[];
      final r = ConsumedReporter(
        totals.add,
        reportInterval: const Duration(milliseconds: 10),
      );
      r.add(10); // gated; arms the trailing timer
      r.report(force: true);
      expect(totals, [10]);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(totals, [10], reason: 'no duplicate trailing report');
      r.dispose();
    });

    test('dispose flushes the unreported tail exactly once', () async {
      final totals = <int>[];
      final r = ConsumedReporter(
        totals.add,
        reportInterval: const Duration(milliseconds: 10),
      );
      r.add(10);
      r.dispose();
      expect(totals, [10]);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(totals, [10]);
      // A reporter with nothing unreported stays silent.
      r.dispose();
      expect(totals, [10]);
    });
  });
}
