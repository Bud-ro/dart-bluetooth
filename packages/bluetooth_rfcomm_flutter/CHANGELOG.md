# Changelog

## 0.1.0

Initial release.

- Flutter plugin companion for [`bluetooth_rfcomm`](https://pub.dev/packages/bluetooth_rfcomm).
- Provides the Android native build (Kotlin + JNI C shim via Gradle/CMake) and
  bundles `libbluetooth_rfcomm_android.so` into the host app.
- iOS/macOS native code is built from `bluetooth_rfcomm`'s native-assets hook;
  Windows/Linux need no native build.
- Re-exports the `bluetooth_rfcomm` API; there is no separate Dart surface.
