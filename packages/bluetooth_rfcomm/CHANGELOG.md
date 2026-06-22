# Changelog

## 0.1.1

- Windows: fix rare RFCOMM disconnects under fast send/receive bursts. A blocking
  `recv()` can return `SOCKET_ERROR` while `WSAGetLastError()` reads back 0 — the
  thread's last-error gets clobbered by the Dart VM's safepoint/GC between the two
  separate FFI calls (dart-lang/sdk#38832), not a real error. The reader now
  classifies fail-closed on `recv()`'s return value (graceful close `n==0` and
  real error codes still disconnect immediately; a clobbered `wsa==0` is tolerated
  but bounded), so a live link is no longer torn down by a benign timeout whose
  code was lost. A failed send is surfaced at the `WARNING` log level.
- Windows: added connection diagnostics under the `bluetooth_rfcomm.connection`
  logger (FINE = disconnect reason with the WSA code; FINER = per-message rx/tx
  idle gaps and send timing) to make link-level behaviour observable.

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
- Structured logging via `package:logging` under namespaced loggers
  (`bluetooth_rfcomm.{connection,data,discovery,adapter,native}`), with raw bytes
  at FINEST and lifecycle at FINE. No handler is installed by default; see the
  README "Logging" section for per-namespace level control.
- All five backends implemented (incl. Linux RFCOMM `Profile1` fd stream).
  **Only macOS and Windows have been manually verified against real hardware so
  far** (works well enough for the author, not guaranteed perfect); the other
  backends are implemented but unverified and will be verified on hardware over
  time. See the README support table.
- Does not expose `connectionState(device)` — it is only implementable on Linux
  and would be a silent no-op elsewhere. Use `BluetoothConnection.stateChanges`
  (all platforms) or `bondedDevices().isConnected`.
