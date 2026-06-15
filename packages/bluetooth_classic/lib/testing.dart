/// In-memory fake backend for testing apps that use `bluetooth_classic`
/// without real hardware.
///
/// ```dart
/// final fake = FakeBluetoothClassicPlatform()
///   ..bonded.add(FakeBluetoothClassicPlatform.sampleDevice());
/// final bt = BluetoothClassic(platform: fake);
/// ```
library;

export 'src/testing/fake_platform.dart';
