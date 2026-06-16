/// In-memory fake backend for testing apps that use `bluetooth_rfcomm`
/// without real hardware.
///
/// ```dart
/// final fake = FakeBluetoothRfcommPlatform()
///   ..bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
/// final bt = BluetoothRfcomm(platform: fake);
/// ```
library;

export 'src/testing/fake_platform.dart'
    show FakeBluetoothRfcommPlatform, FakeRfcommTransport;
