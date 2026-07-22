import 'dart:typed_data';

import 'package:bluetooth_le/bluetooth_le.dart';
import 'package:bluetooth_le/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeBleCentralPlatform fake;
  late BleCentral ble;

  setUp(() {
    fake = FakeBleCentralPlatform();
    ble = BleCentral(platform: fake);
  });

  tearDown(() => fake.dispose());

  Future<(BleConnection, FakeGattConnection, BleSerial)> openSerial() async {
    final conn = await ble.connect(FakeBleCentralPlatform.sampleDevice());
    return (conn, fake.connections.single, conn.asSerial());
  }

  test('asSerial defaults to the Nordic UART characteristics', () async {
    final (_, _, serial) = await openSerial();
    expect(serial.service, Uuid.nordicUartService);
    expect(serial.writeCharacteristic, Uuid.nordicUartRx);
    expect(serial.notifyCharacteristic, Uuid.nordicUartTx);
  });

  test('input streams notifications from the TX characteristic', () async {
    final (_, gatt, serial) = await openSerial();
    final received = <int>[];
    serial.input.listen(received.addAll);
    await Future<void>.delayed(Duration.zero);
    gatt.deliver(Uuid.nordicUartTx, [1, 2, 3]);
    gatt.deliver(Uuid.nordicUartTx, [4, 5]);
    await Future<void>.delayed(Duration.zero);
    expect(received, [1, 2, 3, 4, 5]);
  });

  test('notifications stay enabled across a listener gap; close() releases '
      'them', () async {
    final (_, gatt, serial) = await openSerial();
    final sub = serial.input.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(gatt.notifyEnabled[Uuid.nordicUartTx], isTrue);
    await sub.cancel();
    await Future<void>.delayed(Duration.zero);
    // Still enabled: data in the gap is buffered, not lost at the peripheral.
    expect(gatt.notifyEnabled[Uuid.nordicUartTx], isTrue);
    await serial.close();
    expect(gatt.notifyEnabled[Uuid.nordicUartTx], isFalse);
  });

  test('bytes received in a listen gap are buffered and replayed to the '
      're-listener', () async {
    final (_, gatt, serial) = await openSerial();
    final first = serial.input.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await first.cancel();
    // Data arriving while nobody listens must not vanish.
    gatt.deliver(Uuid.nordicUartTx, [7]);
    await Future<void>.delayed(Duration.zero);

    final received = <int>[];
    serial.input.listen(received.addAll);
    await Future<void>.delayed(Duration.zero);
    gatt.deliver(Uuid.nordicUartTx, [9, 8]);
    await Future<void>.delayed(Duration.zero);
    expect(received, [7, 9, 8]); // gap bytes first, in order
  });

  test('gap buffer is bounded at 1 MiB, dropping oldest first', () async {
    final (_, gatt, serial) = await openSerial();
    final sub = serial.input.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    gatt.deliver(Uuid.nordicUartTx, List.filled(1 << 20, 0xaa));
    gatt.deliver(Uuid.nordicUartTx, [1, 2, 3]);
    await Future<void>.delayed(Duration.zero);

    final received = <List<int>>[];
    serial.input.listen(received.add);
    await Future<void>.delayed(Duration.zero);
    expect(received.single, [1, 2, 3]); // the oldest (1 MiB) chunk was dropped
  });

  test(
    'a synchronous subscribe throw surfaces on the stream, not the zone',
    () async {
      final (_, gatt, serial) = await openSerial();
      gatt.subscribeError = const BleUnsupportedException(
        'notifications unavailable',
      );
      final errors = <Object>[];
      serial.input.listen((_) {}, onError: errors.add);
      await Future<void>.delayed(Duration.zero);
      expect(errors.single, isA<BleUnsupportedException>());
    },
  );

  test('write targets the RX characteristic, without response', () async {
    final (_, gatt, serial) = await openSerial();
    await serial.write(Uint8List.fromList([10, 11, 12]));
    expect(gatt.writes.single.characteristic, Uuid.nordicUartRx);
    expect(gatt.writes.single.withoutResponse, isTrue);
    expect(gatt.writes.single.value, [10, 11, 12]);
  });

  test('write chunks to chunkSize and preserves order', () async {
    final (_, gatt, serial) = await openSerial();
    serial.chunkSize = 2;
    await serial.write(Uint8List.fromList([1, 2, 3, 4, 5]));
    expect(gatt.writes.map((w) => w.value.toList()).toList(), [
      [1, 2],
      [3, 4],
      [5],
    ]);
  });

  test('add is fire-and-forget; flush awaits the queue', () async {
    final (_, gatt, serial) = await openSerial();
    serial.add(Uint8List.fromList([7]));
    serial.add(Uint8List.fromList([8]));
    await serial.flush();
    expect(gatt.writes.expand((w) => w.value).toList(), [7, 8]);
  });

  test('negotiateMtu raises chunkSize (MTU - 3)', () async {
    final (_, _, serial) = await openSerial();
    expect(await serial.negotiateMtu(100), 100);
    expect(serial.chunkSize, 97);
  });

  test('write after close returns an errored future (no sync throw)', () async {
    final (_, _, serial) = await openSerial();
    await serial.close();
    // Returns an errored future rather than throwing synchronously...
    await expectLater(
      serial.write(Uint8List.fromList([1])),
      throwsA(isA<BleGattException>()),
    );
    // ...so add() stays truly fire-and-forget on a closed serial.
    expect(() => serial.add(Uint8List.fromList([1])), returnsNormally);
  });

  test('negotiateMtu clamps chunkSize back down for a small MTU', () async {
    final (_, _, serial) = await openSerial();
    await serial.negotiateMtu(100);
    expect(serial.chunkSize, 97);
    // The fake clamps MTU to >=23, so a tiny request yields 23 -> chunkSize 20.
    await serial.negotiateMtu(10);
    expect(serial.chunkSize, 20);
  });
}
