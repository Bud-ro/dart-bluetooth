import 'dart:typed_data';

import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeBluetoothClassicPlatform fake;
  late BluetoothClassic bt;

  setUp(() {
    fake = FakeBluetoothClassicPlatform();
    bt = BluetoothClassic(platform: fake);
  });

  tearDown(() => fake.dispose());

  Future<(BluetoothConnection, FakeRfcommTransport)> open() async {
    final conn = await bt.connect(FakeBluetoothClassicPlatform.sampleDevice());
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
}
