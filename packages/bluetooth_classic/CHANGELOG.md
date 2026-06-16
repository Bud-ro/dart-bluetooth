# Changelog

## 0.1.0 (unreleased)

Initial release.

- Cross-platform Bluetooth Classic RFCOMM serial: Windows, Linux, macOS,
  Android, iOS.
- Flutter-free single package — works from a pure-Dart CLI and a Flutter app via
  `dart:ffi` (+ `package:dbus` on Linux); native code behind a C ABI.
- `BluetoothClassic` facade: adapter state, bonded devices, discovery,
  `bondedAndDiscovered`, SDP service discovery, RFCOMM connect with channel
  selection, pair/unpair.
- `BluetoothConnection`: `Stream<Uint8List>` input (closes on disconnect),
  non-blocking `add`, `write`/`flush`, state stream, `close`/`finish`.
- Domain exception hierarchy; `FakeBluetoothClassicPlatform` for tests.
- All five backends implemented (incl. Linux RFCOMM `Profile1` fd stream);
  native code pending on-device validation per OS.
