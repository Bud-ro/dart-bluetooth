# Changelog

## 0.2.0

### Callback-lifetime hardening

A targeted delete-then-invoke audit (can a callback be unregistered/freed and
still be called later?) across the Dart, FFI and native layers:

- **New native `reset` entry points** (`btc_reset` on macOS, `btc_ea_reset` on
  iOS, `btc_and_reset` on Android) that quiesce every native event source
  (open channels/sockets/sessions, running inquiries). Called at backend
  construction — so a Flutter **hot restart** can no longer leave native read
  loops dialing the dead isolate's destroyed callback trampolines (a native
  crash) — and at `dispose()`, after which the callables release their isolate
  pin, so a pure-Dart CLI now exits without an explicit `exit()`.
- macOS: every channel-teardown path now defers `setDelegate:nil` + callback
  nulling (previously only the write-failure path did), fixing a per-connection
  retain cycle / potential use-after-free; a late `deviceInquiryComplete` can
  no longer double-fire the inquiry-done callback.
- macOS/Android: a stale inquiry-done (queued from an already-stopped inquiry)
  is now token-checked so it can't tear down a freshly started discovery;
  Android's discovery receiver swap is synchronized and identity-checked so an
  old FINISHED broadcast can't cancel a new scan.
- Facade: `scannedDevicesStream`/`bondedAndDiscoveredStream` now close when
  the facade is disposed (previously a consumer's `await for` hung forever);
  late stream cancels after `dispose()` can no longer corrupt the scan-engine
  hold counters; Linux D-Bus signal subscriptions all handle dispatcher errors
  (a malformed BlueZ signal was an unhandled-zone-error process killer).

### Deep-review hardening

A 13-lens adversarially-verified review of the whole stack; the surviving
findings are all fixed in this release:

- **Windows**: `flush()`/`write()` now fail with `BluetoothWriteException`
  when queued bytes were lost to a dead link (previously they acked success);
  `close()` waits for the reader/writer isolates to release the SOCKET before
  `closesocket`, so a recycled handle value can never be touched by a stale
  isolate; the inquiry worker no longer double-`WSALookupServiceEnd`s a handle
  the main isolate already ended (a recycled lookup handle could kill an
  unrelated inquiry); re-listening a discovery stream works; a malformed
  address no longer leaks a socket handle; reader/writer isolate spawn
  failures surface as disconnects instead of unhandled errors; the
  clobbered-recv classification is extracted and regression-tested.
- **Linux**: `connect(timeout:)` now bounds `ConnectProfile` itself (BlueZ's
  10–40s page timeout no longer overrides the caller's deadline); BlueZ
  connect/adapter errors map to the proper exception types (`NotReady` →
  `BluetoothDisabledException`, access-denied → permission, unknown device →
  not-found) instead of all masquerading as transient connection failures;
  hard read errors end `input` with a clean EOF like every other platform
  (no more Linux-only stream errors); a `NewConnection` that lands before a
  `ConnectProfile` error now returns the live transport instead of leaking
  its fd; discovery start/stop decisions are made against fresh serialized
  state (a restart racing a stop can no longer be starved); re-listening
  `adapterStateChanges` works; `dispose()` no longer closes a caller-injected
  `DBusClient`.
- **macOS/Android**: concurrent discovery streams now SHARE the single native
  inquiry (piggyback + refcount) — starting a second stream no longer clobbers
  the first, and cancelling one no longer kills the other. macOS reports real
  `isPaired` bond state in sightings (previously every sighting claimed
  bonded, poisoning paired∩scanned); macOS SDP resolution queries the device
  when no record is cached; macOS writes moved off the worker run loop
  (a stalled write no longer freezes every API call); Android gained a real
  `flush()` (drains the write executor, so `finish()` no longer loses tail
  bytes), a classloader-robust JNI init, and discovery-receiver leak fixes;
  iOS discovery is broadcast like every other platform, EA writes respect
  `hasSpaceAvailable` with a bounded backlog, and the fixed-optimistic
  `adapterState` is now documented as such.
- **Facade**: a `bondedAndDiscoveredStream(scanInterval:)` can no longer
  permanently clobber the `startScan` cadence (cadence requests are
  arbitrated, shortest wins, and are withdrawn on cancel); the
  paired∩scanned loop got the same restart-race-proof chaining as the scan
  engine; a crashed scan loop no longer leaves `isScanning` lying;
  `dispose()` joins the loops before tearing down the backend.
- **Docs**: every claim audited against the implementation — `requestEnable`
  platform support, `discoverServices` honesty (only macOS consults real
  SDP), `flush` guarantees per platform, `dispose` scope, connect-vs-inquiry
  radio interplay.

### Features

- **New: background scan API** — `startScan()` / `stopScan()` /
  `forgetScannedDevices()`, with results in `scannedDevices` and
  `scannedDevicesStream`. The scan accumulates every sighted device (paired or
  not) across inquiry cycles, so a device listing built from the cache is
  instant and complete — call `startScan()` early (e.g. in `main`) instead of
  waiting out a ~10s inquiry at listing time. The scan pauses automatically
  while a `connect` or a one-shot `startDiscovery` is in flight (a classic
  radio can't inquire and page at once) and resumes on its own.
- **New: three dedicated listing APIs** — `listScannedDevices({scanDuration})`
  (everything sighted, paired or not), `listPairedDevices()` (what the OS
  remembers, nearby or not), and `listPairedAndScannedDevices({scanDuration})`
  (paired AND actually sighted — the connectable set a picker wants).
  Deliberately never a union: a mixed list makes paired-but-out-of-range
  devices look connectable. All are instant and radio-silent by default; pass
  a `scanDuration` to scan for that window first, replacing the startScan →
  wait → list → stopScan dance (the scan is started and stopped for you
  unless one was already running).
- **`bondedAndDiscoveredStream` now means what it says** — it emits ONLY
  devices that are paired AND have been sighted by the radio, identically on
  every platform (Windows included). **Behavior change vs 0.1.x**: it
  previously streamed the full paired list (the inquiry, when enabled via
  `scanInterval`, only refreshed RSSI), so paired-but-out-of-range devices
  looked connectable. It now runs the shared background scan while listened
  (`scanInterval` tunes the rescan cadence); for the plain paired list use
  `listPairedDevices()`. Sightings persist until `forgetScannedDevices()`.
- **New: `BluetoothConnection.disconnect()`** — flushes then closes (same as
  `finish`), idempotent and safe to call even after the link already dropped.
- **Windows: `startDiscovery` is now a real radio inquiry**
  (`WSALookupServiceBegin/Next/End` with `LUP_FLUSHCACHE` on a worker isolate,
  aborted cross-isolate via `WSALookupServiceEnd`), so nearby *unpaired*
  devices are discoverable on Windows for the first time, and
  `bondedAndDiscovered()` genuinely reports "paired AND in range" there.
  **Behavior change vs 0.1.x**: Windows `startDiscovery` no longer returns the
  paired list instantly — it streams inquiry sightings for up to ~10s (cancel
  to abort); use `bondedDevices()` for the instant paired list. The
  radio-monopolization concern that motivated the old shim is addressed by
  abortability plus the facade pausing inquiries while a connect is in flight.
- macOS: fixed discovery streams hanging open when an inquiry was stopped or
  replaced — `-[IOBluetoothDeviceInquiry stop]` never delivers
  `deviceInquiryComplete`, so the native layer now fires the done callback
  itself. This is what forced users to list devices twice (the first listing
  sat on a dead inquiry until its timeout and returned only paired devices).
- Linux: BlueZ `StartDiscovery`/`StopDiscovery` calls are now reference-counted
  and serialized across this package's discovery streams, so tearing one
  stream down (e.g. the background scan pausing for a connect) no longer kills
  another stream's inquiry, and a start racing a still-in-flight stop no
  longer fails with `org.bluez.Error.InProgress`.
- Discovery streams whose native inquiry fails to start now close after the
  error instead of staying open forever (all platforms).
- `stopDiscovery()` on Linux now also closes live discovery streams, matching
  macOS/Android.
- Disconnect handling hardened across platforms so a peer powering off always
  bubbles up and never crashes the app:
  - Linux: write failures against a vanished peer (`socket.done` errors,
    `flush()`/`add()` on a dead socket) no longer surface as unhandled async
    errors or raw `SocketException`s — they fold into the normal disconnect
    path / throw `BluetoothWriteException`. Hard read errors now tear the
    connection down even if the socket never signals `onDone`.
  - Windows: a fatal writer-side `send` error (connection reset/aborted, …)
    now bubbles the disconnect up immediately instead of waiting ~20s for the
    reader's link-supervision timeout.
  - Core: `close()`/`finish()`/`disconnect()` after the link already dropped
    are idempotent no-ops that no longer regress `state` to `disconnecting`.

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
