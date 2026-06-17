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
