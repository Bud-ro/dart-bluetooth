// Real-backend behavior tests for Flutter targets (Android JNI, iOS
// ExternalAccessory) — and usable on Flutter desktop too. They drive the ACTUAL
// OS APIs with NO Bluetooth hardware or peer, asserting that calls don't crash
// or surface a native loading error, and fail with the package's domain
// exceptions. Run by the manually-triggered "Integration" workflow, not on every
// push (the lightweight app_launch_test.dart is the per-push smoke).
import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final bt = BluetoothRfcomm.instance;

  BluetoothDevice absentDevice() =>
      BluetoothDevice(id: DeviceId.address('00:11:22:33:44:55'));

  testWidgets('isSupported / adapterState return cleanly', (tester) async {
    expect(await bt.isSupported(), isA<bool>());
    expect(await bt.adapterState(), isA<BluetoothAdapterState>());
  });

  testWidgets('bondedDevices: a list or a BluetoothException', (tester) async {
    try {
      expect(await bt.bondedDevices(), isA<List<BluetoothDevice>>());
    } on BluetoothException {
      // Tolerated on a headless runner (permission / disabled / unavailable).
    }
  });

  testWidgets('discovery starts and cancels without crashing', (tester) async {
    try {
      final sub = bt.startDiscovery().listen((_) {}, onError: (_) {});
      await Future<void>.delayed(const Duration(seconds: 2));
      await sub.cancel();
      await bt.stopDiscovery();
    } on BluetoothException {
      // Tolerated.
    }
  });

  testWidgets('connect to an absent device throws a BluetoothException', (
    tester,
  ) async {
    await expectLater(
      bt.connect(absentDevice(), timeout: const Duration(seconds: 5)),
      throwsA(isA<BluetoothException>()),
    );
  });

  testWidgets('pair throws a BluetoothException', (tester) async {
    await expectLater(
      bt.pair(absentDevice()),
      throwsA(isA<BluetoothException>()),
    );
  });
}
