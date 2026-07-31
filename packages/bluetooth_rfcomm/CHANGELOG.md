# Changelog

## 0.2.0

The device-listing release: scanning is now a first-class, always-available
primitive on every platform, and listings never conflate "paired" with
"actually nearby".

New:

- Background scan: `startScan()` / `stopScan()` accumulate every sighted
  device into `scannedDevices` / `scannedDevicesStream`; clear with
  `forgetScannedDevices()`. Start it in `main()` and listings are instant.
- Three dedicated list APIs — `listScannedDevices()`, `listPairedDevices()`,
  and `listPairedAndScannedDevices()` (paired AND sighted: the connectable
  set a picker wants). Pass `scanDuration:` to scan for a window first.
- `BluetoothConnection.disconnect()` — flush then close; idempotent and safe
  even after the link already dropped.
- Logging conveniences: `BluetoothRfcommLoggers.root` / `.loggers` /
  `.setLevel(...)` for one-call control of the package's logger hierarchy.
- Backpressure surface: `maxPayloadSize` (the OS-advertised max single-write
  payload — the most any OS reports; Bluetooth Classic has no baud rate to
  advertise), `pendingWriteBytes`, and `drain({belowBytes})` for windowed
  bulk pacing. See the README's "Backpressure and throughput" section.

Changed:

- Windows `startDiscovery` is now a real (and abortable) radio inquiry — it
  finds nearby unpaired devices and no longer returns the paired list
  instantly; use `bondedDevices()` for that.
- `bondedAndDiscoveredStream` now emits only devices that are paired AND have
  been sighted, identically on every platform. It previously streamed the
  full paired list, so paired-but-out-of-range devices looked connectable.

Fixed — two adversarial review passes over the whole stack; highlights:

- Disconnects always bubble up, and every API is safe to call after one:
  writes fail with `BluetoothWriteException`, teardown is idempotent, and
  `flush()` reports lost bytes honestly (Windows previously acked success on
  a dead link; Android could report a clean flush after a failed write).
- New test infrastructure that prevents bug classes rather than instances: a
  reusable transport contract-conformance checker (exported from
  `testing.dart`, runs against the fake in CI and against real backends on
  hardware rigs), a seeded random-schedule fuzzer for the facade state
  machines, and clang static analysis of the native sources in CI. See
  `doc/testing.md`.
- New diagnostics: `BluetoothConnection.stats` — hop-by-hop TX/RX counters
  (Dart + native on macOS) that attribute any loss to an exact hop, logged
  automatically once per connection at teardown (FINE).
- `input` no longer loses bytes that arrive while nothing is listening:
  a peer that responds before your first `listen()` attaches (or during a
  cancel/re-listen gap) is buffered and replayed in order. New `rxBytes` /
  `txBytes` counters make loss attributable to a side.
- Sending no longer loses bytes silently: Windows retries transient send
  errors (WSAENOBUFS) for the message remainder — a hole mid-stream is now
  impossible — and Android can no longer report a clean flush after a failed
  write. The macOS send path is deliberately unchanged from 0.1.x in this
  release (the only path with hardware mileage); its async-queue rework ships
  separately, and every macOS discard is now counted in `stats` instead of
  vanishing.
- macOS: a stopped inquiry now completes its stream (the "list devices twice"
  bug); sightings report real paired state; SDP queries the device when
  nothing is cached.
- Windows: ordered socket teardown (no more stale isolate touching a recycled
  handle), connect timeouts honored, inquiry cancellation races closed.
- Linux: connect timeouts bound BlueZ's own page timeout, BlueZ errors map to
  the right exception types, and discovery start/stop is refcounted so
  concurrent streams can't kill each other's inquiry.
- Long-tail sweep fixes: concurrent same-UUID connects on Linux can no longer
  cross-wire two devices' links (one shared BlueZ profile with per-device fd
  routing); scanning recovers after system suspend/resume on Linux; drain()
  converges on every platform and reports discarded bytes instead of lying;
  a facade's dispose() no longer breaks the process-shared backend for other
  facades; Windows inquiry restart races and the stuck pending-bytes gauge
  fixed; macOS no longer mislabels adapter-off as "service not found"; iOS
  reports teardown-discarded bytes; Android builds align for 16 KB pages
  (Android 15+); malformed addresses and hostile peer data are rejected with
  domain errors instead of raw throws.
- Hot-restart safety: new native reset entry points quiesce every native
  event source at construction and dispose, so a restarted app can't crash on
  callbacks into the dead isolate — and CLIs now exit without `exit()`.
- Android 13+: discovery sightings actually arrive again — the discovery
  receiver must be registered RECEIVER_EXPORTED because ACTION_FOUND is
  broadcast by the modularized Bluetooth stack's own process (a
  NOT_EXPORTED receiver silently receives nothing from another UID; the
  actions are protected broadcasts, so exporting is spoof-safe).
- Android/Apple hardening pass — infrastructure failures now surface instead
  of masquerading as empty results: the Kotlin backends survive R8/ProGuard
  (consumer keep rules) and load correctly from Dart-attached threads (app
  classloader); a broken JNI bridge, a denied macOS Bluetooth permission
  (TCC), or a missing iOS `UISupportedExternalAccessoryProtocols` key each
  throw a descriptive exception instead of returning "no devices"; missing
  `BLUETOOTH_CONNECT` degrades to unnamed sightings rather than crashing the
  discovery receiver; macOS `flush()` fails honestly when a disconnect
  discarded queued bytes; and constructing a second Android backend can no
  longer silently close the first one's sockets.

- Pre-release adversarial review (6 agents over the full diff) closed a last
  round: discard accounting now survives peer drops and `finish()` (transports
  latch teardown losses; `drain()`/`stats` consult the latch), concurrent
  `close()` callers on Windows share one completion, mid-scan radio loss on
  Windows errors the stream instead of finishing cleanly, Linux discovery
  restarts after suspend/resume for already-live streams and all BlueZ calls
  are bounded, a crashed scan loop retries instead of wedging `isScanning`,
  and Android/Apple lifecycle seams (keep-alive set, disposed-singleton
  reuse, callback-slot handoff) were closed.

Native changes build on CI for all platforms; runtime behavior still pending
a hardware pass.

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
