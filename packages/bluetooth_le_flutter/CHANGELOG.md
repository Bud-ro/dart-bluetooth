# Changelog

## 0.1.1

- Android: descriptor (CCCD) writes issued by subscribe are now tracked per
  request and completed via a new `onDescriptorWrite` GATT callback, so Dart
  can serialize them with other GATT ops instead of colliding with Android's
  one-outstanding-op limit. The `ble_and_subscribe` JNI/C ABI gained a request
  id — use with `bluetooth_le` >= 0.1.1 (older versions call the old
  four-argument form).

## 0.1.0

Initial release.

- Flutter plugin companion for [`bluetooth_le`](https://pub.dev/packages/bluetooth_le).
- Provides the Android native build (Kotlin `BluetoothGatt` + JNI C shim via
  Gradle/CMake) and bundles `libbluetooth_le_android.so` into the host app.
- iOS/macOS native code is built from `bluetooth_le`'s native-assets hook;
  Windows/Linux need no native build.
- Re-exports the `bluetooth_le` API; there is no separate Dart surface.
