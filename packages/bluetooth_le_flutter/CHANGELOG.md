# Changelog

## 0.1.0

Initial release.

- Flutter plugin companion for [`bluetooth_le`](https://pub.dev/packages/bluetooth_le).
- Provides the Android native build (Kotlin `BluetoothGatt` + JNI C shim via
  Gradle/CMake) and bundles `libbluetooth_le_android.so` into the host app.
- iOS/macOS native code is built from `bluetooth_le`'s native-assets hook;
  Windows/Linux need no native build.
- Re-exports the `bluetooth_le` API; there is no separate Dart surface.
