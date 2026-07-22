import 'dart:typed_data';

import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
import 'package:bluetooth_rfcomm/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeBluetoothRfcommPlatform fake;
  late BluetoothRfcomm bt;

  setUp(() {
    fake = FakeBluetoothRfcommPlatform();
    bt = BluetoothRfcomm(platform: fake);
  });

  tearDown(() => fake.dispose());

  Future<(BluetoothConnection, FakeRfcommTransport)> open() async {
    final conn = await bt.connect(FakeBluetoothRfcommPlatform.sampleDevice());
    return (conn, fake.transports.single);
  }

  test('input delivers received bytes', () async {
    final (conn, transport) = await open();
    final received = <int>[];
    conn.input.listen(received.addAll);
    transport.deliver([1, 2, 3]);
    transport.deliver([4, 5]);
    await Future<void>.delayed(Duration.zero);
    expect(received, [1, 2, 3, 4, 5]);
  });

  test('add is synchronous and non-blocking; write flushes', () async {
    final (conn, transport) = await open();
    conn.add(Uint8List.fromList([9, 9]));
    expect(transport.sent.single, [9, 9]); // visible synchronously
    expect(transport.flushCount, 0);
    await conn.write(Uint8List.fromList([7]));
    expect(transport.sent.last, [7]);
    expect(transport.flushCount, 1);
  });

  test('input closes when peer drops', () async {
    final (conn, transport) = await open();
    var done = false;
    conn.input.listen((_) {}, onDone: () => done = true);
    transport.dropPeer();
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue);
  });

  test(
    'peer drop emits exactly one disconnected and closes both streams',
    () async {
      final (conn, transport) = await open();
      final states = <ConnectionState>[];
      var stateDone = false;
      var inputDone = false;
      conn.stateChanges.listen(states.add, onDone: () => stateDone = true);
      conn.input.listen((_) {}, onDone: () => inputDone = true);
      transport.dropPeer();
      await Future<void>.delayed(Duration.zero);
      expect(states, [ConnectionState.disconnected]); // exactly one
      expect(stateDone, isTrue);
      expect(inputDone, isTrue);
      expect(conn.isConnected, isFalse);
    },
  );

  test('finish flushes then closes and emits disconnected', () async {
    final (conn, transport) = await open();
    final states = <ConnectionState>[];
    conn.stateChanges.listen(states.add);
    conn.add(Uint8List.fromList([1]));
    await conn.finish();
    expect(transport.flushCount, greaterThanOrEqualTo(1));
    expect(conn.isConnected, isFalse);
    expect(states.last, ConnectionState.disconnected);
  });

  test('close does not flush', () async {
    final (conn, transport) = await open();
    await conn.close();
    expect(transport.flushCount, 0);
    expect(conn.state, ConnectionState.disconnected);
  });

  test('add after close throws BluetoothWriteException', () async {
    final (conn, _) = await open();
    await conn.close();
    expect(
      () => conn.add(Uint8List.fromList([1])),
      throwsA(isA<BluetoothWriteException>()),
    );
  });

  test('empty payload is ignored (no send)', () async {
    final (conn, transport) = await open();
    conn.add(Uint8List(0));
    expect(transport.sent, isEmpty);
  });

  test('double close is idempotent (one flush-free teardown)', () async {
    final (conn, transport) = await open();
    final states = <ConnectionState>[];
    conn.stateChanges.listen(states.add);
    await conn.close();
    await conn.close(); // must not throw, re-close, or re-emit
    await Future<void>.delayed(Duration.zero);
    expect(transport.flushCount, 0);
    expect(states, [ConnectionState.disconnected]); // exactly one
  });

  test('finish after close is idempotent', () async {
    final (conn, _) = await open();
    await conn.close();
    await conn.finish(); // no throw, no extra flush past the closed transport
    expect(conn.isConnected, isFalse);
  });

  test('disconnect flushes then closes and emits disconnected', () async {
    final (conn, transport) = await open();
    final states = <ConnectionState>[];
    conn.stateChanges.listen(states.add);
    conn.add(Uint8List.fromList([1]));
    await conn.disconnect();
    expect(transport.flushCount, greaterThanOrEqualTo(1));
    expect(conn.isConnected, isFalse);
    expect(states, [ConnectionState.disconnected]);
  });

  test(
    'teardown after peer drop is safe and keeps state disconnected',
    () async {
      final (conn, transport) = await open();
      transport.dropPeer();
      await Future<void>.delayed(Duration.zero);
      // None of these may throw, re-emit, or regress state to `disconnecting`.
      await conn.disconnect();
      expect(conn.state, ConnectionState.disconnected);
      await conn.close();
      expect(conn.state, ConnectionState.disconnected);
      await conn.finish();
      expect(conn.state, ConnectionState.disconnected);
    },
  );

  group('backpressure surface', () {
    test(
      'maxPayloadSize surfaces the transport value (null by default)',
      () async {
        final (conn, transport) = await open();
        expect(conn.maxPayloadSize, isNull); // Windows/Linux/iOS model
        transport.maxPayloadSize = 1011; // macOS RFCOMM MTU model
        expect(conn.maxPayloadSize, 1011);
      },
    );

    test('platform seeds maxPayloadSize onto new transports', () async {
      fake.transportMaxPayloadSize = 990;
      final conn = await bt.connect(FakeBluetoothRfcommPlatform.sampleDevice());
      expect(conn.maxPayloadSize, 990);
    });

    test('pendingWriteBytes tracks add and drains on flush', () async {
      final (conn, transport) = await open();
      expect(conn.pendingWriteBytes, 0);
      conn.add(Uint8List.fromList([1, 2, 3]));
      conn.add(Uint8List.fromList([4, 5]));
      expect(conn.pendingWriteBytes, 5);
      expect(transport.pendingWriteBytes, 5);
      await conn.flush();
      expect(conn.pendingWriteBytes, 0);
    });

    test('drain() with an empty queue completes immediately', () async {
      final (conn, transport) = await open();
      await conn.drain();
      expect(transport.flushCount, 0); // no work, no flush
    });

    test('drain() uses flush where flush is exact (poll-free)', () async {
      final (conn, transport) = await open();
      conn.add(Uint8List.fromList(List.filled(100, 0)));
      await conn.drain();
      expect(conn.pendingWriteBytes, 0);
      expect(transport.flushCount, 1);
    });

    test(
      'drain() polls where flush is best-effort (macOS/iOS model)',
      () async {
        final (conn, transport) = await open();
        transport.flushDrains = false; // flush resolves without draining
        conn.add(Uint8List.fromList(List.filled(10, 0)));
        final drained = conn.drain();
        // Simulate the OS draining the native queue a moment later.
        Future<void>.delayed(const Duration(milliseconds: 20), () {
          transport.pendingWriteBytes = 0;
        });
        await drained;
        expect(conn.pendingWriteBytes, 0);
      },
    );

    test(
      'drain(belowBytes:) completes once the queue dips below the cap',
      () async {
        final (conn, transport) = await open();
        transport.pendingWriteBytes = 1000;
        final drained = conn.drain(belowBytes: 256);
        Future<void>.delayed(const Duration(milliseconds: 15), () {
          transport.pendingWriteBytes = 600; // not enough yet
        });
        Future<void>.delayed(const Duration(milliseconds: 30), () {
          transport.pendingWriteBytes = 200; // below the cap
        });
        await drained;
        expect(transport.pendingWriteBytes, lessThanOrEqualTo(256));
        expect(transport.flushCount, 0); // belowBytes > 0 never flushes
      },
    );

    test('drain() rejects a negative belowBytes', () async {
      final (conn, _) = await open();
      expect(() => conn.drain(belowBytes: -1), throwsRangeError);
    });

    test(
      'drain() throws when the peer drops with bytes still queued',
      () async {
        final (conn, transport) = await open();
        transport.flushDrains = false;
        conn.add(Uint8List.fromList([1, 2, 3]));
        final drained = conn.drain();
        transport.dropPeer();
        await expectLater(drained, throwsA(isA<BluetoothWriteException>()));
      },
    );

    test('drain() throws when close() discards queued bytes', () async {
      final (conn, transport) = await open();
      transport.pendingWriteBytes = 42;
      final drained = conn.drain(belowBytes: 10);
      await conn.close(); // discards, does not flush
      await expectLater(drained, throwsA(isA<BluetoothWriteException>()));
    });

    test('drain() after disconnect completes if the condition holds', () async {
      final (conn, _) = await open();
      await conn.finish(); // flushes: queue empty
      await conn.drain(); // must not throw or hang
    });
  });

  test('bytes received before the first input listener are replayed', () async {
    final (conn, transport) = await open();
    // The peer greets immediately after connect, before the app listens.
    transport.deliver([1, 2, 3]);
    transport.deliver([4, 5]);
    await Future<void>.delayed(Duration.zero);
    final received = <int>[];
    conn.input.listen(received.addAll);
    await Future<void>.delayed(Duration.zero);
    expect(received, [1, 2, 3, 4, 5]); // in order, nothing dropped
    expect(conn.rxBytes, 5);
  });

  test(
    'bytes received in a listen gap are replayed to the re-listener',
    () async {
      final (conn, transport) = await open();
      final first = <int>[];
      final sub = conn.input.listen(first.addAll);
      transport.deliver([1]);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      // Data arriving while nobody listens must not vanish.
      transport.deliver([2, 3]);
      await Future<void>.delayed(Duration.zero);
      final second = <int>[];
      conn.input.listen(second.addAll);
      await Future<void>.delayed(Duration.zero);
      expect(first, [1]);
      expect(second, [2, 3]);
      expect(conn.rxBytes, 3);
    },
  );

  test('txBytes counts accepted bytes only', () async {
    final (conn, transport) = await open();
    conn.add(Uint8List.fromList([1, 2, 3]));
    expect(conn.txBytes, 3);
    transport.dropPeer();
    await Future<void>.delayed(Duration.zero);
    expect(
      () => conn.add(Uint8List.fromList([9])),
      throwsA(isA<BluetoothWriteException>()),
    );
    expect(conn.txBytes, 3); // the rejected write is not counted
  });

  test('every API is crash-free after the peer drops', () async {
    final (conn, transport) = await open();
    transport.dropPeer();
    await Future<void>.delayed(Duration.zero);
    // Writes fail with the documented domain exception, never anything else.
    expect(
      () => conn.add(Uint8List.fromList([1])),
      throwsA(isA<BluetoothWriteException>()),
    );
    expect(
      () => conn.write(Uint8List.fromList([1])),
      throwsA(isA<BluetoothWriteException>()),
    );
    await conn.flush(); // no throw
    // Streams have closed cleanly: a late listener just gets done.
    var inputDone = false;
    var stateDone = false;
    conn.input.listen((_) {}, onDone: () => inputDone = true);
    conn.stateChanges.listen((_) {}, onDone: () => stateDone = true);
    await Future<void>.delayed(Duration.zero);
    expect(inputDone, isTrue);
    expect(stateDone, isTrue);
  });
}
