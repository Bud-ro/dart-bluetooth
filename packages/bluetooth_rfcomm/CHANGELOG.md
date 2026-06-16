# Changelog

## 0.1.0

Initial release.

- Cross-platform Bluetooth Classic RFCOMM serial: Windows, Linux, macOS,
  Android, iOS.
- Pure-Dart, Flutter-free, pub.dev-publishable — works from a CLI and a Flutter
  app via `dart:ffi` (+ `package:dbus` on Linux); native code behind a C ABI. The
  Flutter-plugin native builds (Android Gradle/JNI; Apple via native-assets) ship
  in the companion `bluetooth_rfcomm_flutter` package.
- `BluetoothRfcomm` facade: adapter state, bonded devices, discovery,
  `bondedAndDiscovered`, SDP service discovery, RFCOMM connect with channel
  selection, pair/unpair.
- `BluetoothConnection`: `Stream<Uint8List>` input (closes on disconnect),
  non-blocking `add`, `write`/`flush`, state stream, `close`/`finish`.
- Domain exception hierarchy; `FakeBluetoothRfcommPlatform` for tests.
- All five backends implemented (incl. Linux RFCOMM `Profile1` fd stream);
  native code pending on-device validation per OS.
- Removed `connectionState(device)` — it was only implementable on Linux and
  was a silent no-op elsewhere. Use `BluetoothConnection.stateChanges` (all
  platforms) or `bondedDevices().isConnected`.
- Hardened after multi-axis code review: fixed a macOS write use-after-free,
  Android JNI exception-safety / thread-detach / receiver-export / write
  ordering, duplicate disconnect events, Linux profile/socket leaks and error
  mapping, a Windows `flush()` hang, an iOS O(n²) send path, a Windows non-ASCII
  device-name crash, macOS/Android discovery-stream leaks, and a blocking Android
  connect (now off the calling isolate); added send/receive length guards.
