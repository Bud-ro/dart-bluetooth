# Changelog

## 0.2.0

- Tracks `bluetooth_rfcomm` 0.2.0 (background scan, list APIs, `disconnect()`,
  reliability fixes). Android native picks up the core's new flush/reset hooks
  and discovery-receiver fixes; no API changes here.

## 0.1.0

Initial release.

- Flutter plugin companion for [`bluetooth_rfcomm`](https://pub.dev/packages/bluetooth_rfcomm).
- Provides the Android native build (Kotlin + JNI C shim via Gradle/CMake) and
  bundles `libbluetooth_rfcomm_android.so` into the host app.
- iOS/macOS native code is built from `bluetooth_rfcomm`'s native-assets hook;
  Windows/Linux need no native build.
- Re-exports the `bluetooth_rfcomm` API; there is no separate Dart surface.
- Note: the Android and iOS backends have **not** been manually verified on a
  device yet — treat them as best-effort. Of the underlying `bluetooth_rfcomm`
  backends, only macOS and Windows currently carry manual verification. See the
  README support table.
