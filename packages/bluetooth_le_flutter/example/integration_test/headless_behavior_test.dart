// Real-backend behavior tests for Flutter targets (Android BluetoothGatt/JNI,
// iOS CoreBluetooth) — usable on Flutter desktop too. They drive the ACTUAL OS
// APIs with NO Bluetooth hardware or peer, asserting that calls don't crash or
// surface a native loading error, and fail with the package's domain exceptions.
// Run by the manually-triggered "Integration" workflow, not on every push (the
// lightweight app_launch_test.dart is the per-push smoke).
import 'package:bluetooth_le/bluetooth_le.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final ble = BleCentral.instance;

  BleDevice absentDevice() =>
      BleDevice(id: DeviceId.address('00:11:22:33:44:55'));

  testWidgets('isSupported / adapterState return cleanly', (tester) async {
    expect(await ble.isSupported(), isA<bool>());
    expect(await ble.adapterState(), isA<BluetoothAdapterState>());
  });

  testWidgets('scan starts and cancels without crashing', (tester) async {
    try {
      final sub = ble.startScan().listen((_) {}, onError: (_) {});
      await Future<void>.delayed(const Duration(seconds: 2));
      await sub.cancel();
      await ble.stopScan();
    } on BleException {
      // Tolerated on a headless runner (permission / disabled / unavailable).
    }
  });

  testWidgets('connect to an absent device throws a BleException', (
    tester,
  ) async {
    await expectLater(
      ble.connect(absentDevice(), timeout: const Duration(seconds: 5)),
      throwsA(isA<BleException>()),
    );
  });
}
