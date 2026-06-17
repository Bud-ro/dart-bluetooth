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

  test('isSupported / adapter state pass through', () async {
    expect(await bt.isSupported(), isTrue);
    expect(await bt.adapterState(), BluetoothAdapterState.on);
  });

  test('adapterState stream emits current then changes', () async {
    final events = <BluetoothAdapterState>[];
    final sub = bt.adapterStateChanges.listen(events.add);
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
    fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
    final list = await bt.bondedDevices();
    expect(list, hasLength(1));
    expect(list.first.name, 'Test Device');
  });

  test('bondedAndDiscovered returns intersection with latest rssi', () async {
    final inRange = FakeBluetoothRfcommPlatform.sampleDevice(
      address: 'AA:AA:AA:AA:AA:AA',
      name: 'InRange',
    );
    final outOfRange = FakeBluetoothRfcommPlatform.sampleDevice(
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

  test('bondedAndDiscovered short-circuits when nothing is bonded', () async {
    final result = await bt.bondedAndDiscovered(
      timeout: const Duration(milliseconds: 20),
    );
    expect(result, isEmpty);
    // No bonded devices => discovery should never start.
    expect(fake.discoveryStarted, isFalse);
    expect(fake.discoveryStopped, isFalse);
  });

  test(
    'bondedAndDiscovered rethrows discovery error when nothing seen',
    () async {
      fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
      fake.discoveryError = const BluetoothDiscoveryException('inquiry failed');
      expect(
        () => bt.bondedAndDiscovered(timeout: const Duration(milliseconds: 20)),
        throwsA(isA<BluetoothDiscoveryException>()),
      );
    },
  );

  test('bondedAndDiscovered wraps a non-Bluetooth discovery error', () async {
    fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
    fake.discoveryError = StateError('boom');
    await expectLater(
      () => bt.bondedAndDiscovered(timeout: const Duration(milliseconds: 20)),
      throwsA(
        isA<BluetoothDiscoveryException>().having(
          (e) => e.cause,
          'cause',
          isA<StateError>(),
        ),
      ),
    );
  });

  test(
    'bondedAndDiscoveredStream paints paired instantly then refines',
    () async {
      final inRange = FakeBluetoothRfcommPlatform.sampleDevice(
        address: 'AA:AA:AA:AA:AA:AA',
        name: 'InRange',
      );
      final notBonded = FakeBluetoothRfcommPlatform.sampleDevice(
        address: 'CC:CC:CC:CC:CC:CC',
        name: 'Stranger',
      );
      fake.bonded.add(inRange);
      fake.discoveryResults.addAll([
        BluetoothDiscoveryResult(
          device: notBonded, // not paired -> excluded
          timestamp: DateTime(2026),
        ),
        BluetoothDiscoveryResult(
          device: inRange.copyWith(rssi: -42),
          rssi: -42,
          timestamp: DateTime(2026),
        ),
      ]);

      final emissions = <List<BluetoothDevice>>[];
      // Opt into the active inquiry so RSSI is refined (the default streams the
      // paired list only, with no radio inquiry).
      final sub = bt
          .bondedAndDiscoveredStream(scanInterval: const Duration(seconds: 1))
          .listen(emissions.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(emissions, isNotEmpty);
      // First paint: the paired device surfaces immediately, before any inquiry.
      expect(emissions.first, hasLength(1));
      expect(emissions.first.first.id, inRange.id);
      // After the inquiry: refined with RSSI; the non-paired stranger excluded.
      final last = emissions.last;
      expect(last, hasLength(1));
      expect(last.first.id, inRange.id);
      expect(last.first.rssi, -42);
      expect(fake.discoveryStopped, isTrue);
    },
  );

  test('bondedAndDiscoveredStream defaults to no radio inquiry', () async {
    fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
    final first = await bt.bondedAndDiscoveredStream().first;
    expect(first, hasLength(1));
    // No scanInterval => the inquiry must never start (keeps the radio free).
    expect(fake.discoveryStarted, isFalse);
  });

  test('connect with explicit channel', () async {
    final device = FakeBluetoothRfcommPlatform.sampleDevice();
    final conn = await bt.connect(device, channel: 3);
    expect(conn.isConnected, isTrue);
    expect(fake.transports.single.channel, 3);
    expect(fake.transports.single.serviceUuid, Uuid.spp);
  });

  test('connect surfaces backend errors', () async {
    fake.connectError = const BluetoothConnectionException('refused');
    final device = FakeBluetoothRfcommPlatform.sampleDevice();
    expect(
      () => bt.connect(device),
      throwsA(isA<BluetoothConnectionException>()),
    );
  });

  test('pair / unpair pass through', () async {
    final device = FakeBluetoothRfcommPlatform.sampleDevice();
    await bt.pair(device);
    await bt.unpair(device);
    expect(fake.paired.single, device.id);
    expect(fake.unpaired.single, device.id);
  });
}
