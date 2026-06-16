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

  test('isSupported / adapter state pass through', () async {
    expect(await bt.isSupported(), isTrue);
    expect(await bt.adapterStateNow(), BluetoothAdapterState.on);
  });

  test('adapterState stream emits current then changes', () async {
    final events = <BluetoothAdapterState>[];
    final sub = bt.adapterState.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    fake.emitAdapterState(BluetoothAdapterState.turningOff);
    fake.emitAdapterState(BluetoothAdapterState.off);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(events, [
      BluetoothAdapterState.on,
      BluetoothAdapterState.turningOff,
      BluetoothAdapterState.off,
    ]);
  });

  test('bondedDevices', () async {
    fake.bonded.add(FakeBluetoothClassicPlatform.sampleDevice());
    final list = await bt.bondedDevices();
    expect(list, hasLength(1));
    expect(list.first.name, 'Test Device');
  });

  test('bondedAndDiscovered returns intersection with latest rssi', () async {
    final inRange = FakeBluetoothClassicPlatform.sampleDevice(
      address: 'AA:AA:AA:AA:AA:AA',
      name: 'InRange',
    );
    final outOfRange = FakeBluetoothClassicPlatform.sampleDevice(
      address: 'BB:BB:BB:BB:BB:BB',
      name: 'OutOfRange',
    );
    fake.bonded.addAll([inRange, outOfRange]);
    fake.discoveryResults.add(
      BluetoothDiscoveryResult(
        device: inRange.copyWith(rssi: -42),
        rssi: -42,
        timestamp: DateTime(2026),
      ),
    );

    final result = await bt.bondedAndDiscovered(
      timeout: const Duration(milliseconds: 20),
    );
    expect(result, hasLength(1));
    expect(result.first.id, inRange.id);
    expect(result.first.rssi, -42);
    expect(fake.discoveryStopped, isTrue);
  });

  test('connect with explicit channel', () async {
    final device = FakeBluetoothClassicPlatform.sampleDevice();
    final conn = await bt.connect(device, channel: 3);
    expect(conn.isConnected, isTrue);
    expect(fake.transports.single.channel, 3);
    expect(fake.transports.single.serviceUuid, Uuid.spp);
  });

  test('connect surfaces backend errors', () async {
    fake.connectError = const BluetoothConnectionException('refused');
    final device = FakeBluetoothClassicPlatform.sampleDevice();
    expect(
      () => bt.connect(device),
      throwsA(isA<BluetoothConnectionException>()),
    );
  });

  test('pair / unpair pass through', () async {
    final device = FakeBluetoothClassicPlatform.sampleDevice();
    await bt.pair(device);
    await bt.unpair(device);
    expect(fake.paired.single, device.id);
    expect(fake.unpaired.single, device.id);
  });
}
