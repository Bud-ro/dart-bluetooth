/// In-memory fake backend for testing apps that use `bluetooth_le` without real
/// hardware.
///
/// ```dart
/// final fake = FakeBleCentralPlatform();
/// final ble = BleCentral(platform: fake);
/// ```
library;

export 'src/testing/fake_platform.dart'
    show FakeBleCentralPlatform, FakeGattConnection;
