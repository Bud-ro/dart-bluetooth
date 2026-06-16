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

  test('isSupported / adapterState pass through', () async {
    expect(await ble.isSupported(), isTrue);
    expect(await ble.adapterState(), BluetoothAdapterState.on);
  });

  test('adapterStateChanges emits current then changes', () async {
    final events = <BluetoothAdapterState>[];
    final sub = ble.adapterStateChanges.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    fake.emitAdapterState(BluetoothAdapterState.off);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(events, [BluetoothAdapterState.on, BluetoothAdapterState.off]);
  });

  test('startScan emits results and filters by service', () async {
    fake.scanResults.addAll([
      BleScanResult(
        device: FakeBleCentralPlatform.sampleDevice(
          address: 'AA:AA:AA:AA:AA:AA',
        ),
        timestamp: DateTime(2026),
        serviceUuids: [Uuid('180d')],
      ),
      BleScanResult(
        device: FakeBleCentralPlatform.sampleDevice(
          address: 'BB:BB:BB:BB:BB:BB',
        ),
        timestamp: DateTime(2026),
        serviceUuids: [Uuid('180f')],
      ),
    ]);
    final all = await ble.startScan().take(2).toList();
    expect(all, hasLength(2));

    final filtered = await ble.startScan(withServices: [Uuid('180d')]).first;
    expect(filtered.serviceUuids, contains(Uuid('180d')));
  });

  test('startScan surfaces errors', () async {
    fake.scanError = const BleScanException('radio off');
    await expectLater(
      ble.startScan().toList(),
      throwsA(isA<BleScanException>()),
    );
  });

  test('connect returns a BleConnection', () async {
    final conn = await ble.connect(FakeBleCentralPlatform.sampleDevice());
    expect(conn.isConnected, isTrue);
    expect(fake.connections, hasLength(1));
  });

  test('connect surfaces backend errors', () async {
    fake.connectError = const BleConnectionException('refused');
    await expectLater(
      ble.connect(FakeBleCentralPlatform.sampleDevice()),
      throwsA(isA<BleConnectionException>()),
    );
  });
}
