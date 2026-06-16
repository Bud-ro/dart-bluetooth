# Pre-release code review (10-agent, Opus 4.8)

Synthesis of a 10-axis review of `bluetooth_rfcomm`. Items marked **[fixed]**
are addressed in the release-hardening pass; **[tracked]** are deferred with a
rationale.

## Critical (correctness / memory safety / crashes)

- **[fixed]** macOS RFCOMM write use-after-free — `btc_rfcomm_write` freed the
  copied buffer immediately after the async `writeAsync:` (which doesn't copy).
  Switched to synchronous `writeSync:` on the worker thread so the free is safe;
  also chunked to the channel MTU and length-guarded.
- **[fixed]** Android JNI could abort the VM — `bondedJson()`/`startDiscovery()`
  weren't wrapped, so a `SecurityException` (missing `BLUETOOTH_CONNECT/SCAN`)
  propagated; and the C shim left pending JNI exceptions uncleared. Wrapped the
  Kotlin methods and added `ExceptionCheck`/`ExceptionClear` + `malloc` null
  checks in the shim.
- **[fixed]** Android `registerReceiver` on API 34 needs an export flag — added
  `RECEIVER_NOT_EXPORTED` (else `SecurityException` at runtime).
- **[fixed]** Android writes could interleave/corrupt — replaced the
  `newCachedThreadPool` with a single serial executor (ordered writes).
- **[fixed]** Android JNI thread attach was never detached — added a TLS
  destructor that calls `DetachCurrentThread`.
- **[fixed]** Fake backend used a broadcast `incoming` while the contract +
  all real backends are single-subscription — made the fake single-subscription
  so tests exercise real semantics.
- **[fixed]** `send()` int32 length truncation and unchecked inbound `len` —
  added length guards on send and validation of native callback lengths.

## Major

- **[fixed]** Duplicate terminal `disconnected` — `_onState(disconnected)` then
  `close()` emitted it twice; guarded `close()` to emit once (all backends).
- **[fixed]** No `BluetoothRfcomm.dispose()` — backend resources were
  unreachable; added `dispose()` forwarding to the platform.
- **[fixed]** Linux leaked BlueZ profile registrations — now calls
  `ProfileManager1.UnregisterProfile` on close and all error paths.
- **[fixed]** Linux dropped the orphaned RFCOMM socket on a late `NewConnection`
  after timeout — now destroys it.
- **[fixed]** Linux didn't map `DBusUnknownObjectException` → now
  `DeviceNotFoundException`; `send()` after close now throws (was silent).
- **[fixed]** Android discovery `BroadcastReceiver` leaked on natural
  `ACTION_DISCOVERY_FINISHED` — now unregistered.
- **[fixed]** Android `_activeLib` static could free via the wrong/null library
  — frees now route through the per-token transport's bindings.
- **[fixed]** Windows `flush()` could hang forever after peer close and
  `_sendAll` silently dropped failed writes — flush completes on close and write
  failures surface.
- **[fixed]** macOS could throw a raw `StateError`/`TypeError` when a device
  address is withheld or JSON is malformed — falls back to an opaque id and
  guards decode.

## Minor / docs / CI

- **[fixed]** CLI header used a non-runnable `dart run <pkg>` form → `dart run :btc`.
- **[fixed]** `Uuid` 128-bit parsing only checked length → added structural
  validation + test.
- **[fixed]** CI: added `dart format --set-exit-if-changed` check and pub caching.

## Previously-deferred items — now resolved

Nothing is left deferred; each was either fixed or deliberately dropped:

- **`connectionStateChanges` (was Linux-only)** — **removed** from the public API
  and the platform interface. It worked on only one of five platforms and was a
  silent no-op elsewhere; per-connection `BluetoothConnection.stateChanges`
  (all platforms) plus `bondedDevices().isConnected` cover the real need.
- **`flush()` best-effort on macOS/iOS/Android** — kept (writes are handed to the
  OS synchronously and in order; there's no OS drain ack on these platforms).
  The `flush()`/`write()` docs and README now state this precisely, so it is a
  documented, accurate characteristic rather than a false guarantee.
- **Inbound backpressure** — **accepted, no action.** RFCOMM serial is
  low-throughput and frames are small; an unbounded-growth scenario requires a
  pathologically fast peer the app never drains. Not worth a flow-control redesign.
- **iOS `connectionID` is session-scoped** — documented in the README (don't
  persist a `DeviceId` on iOS; re-fetch each session).
- **`close()` vs `finish()` semantics** — kept intentionally: it mirrors
  `flutter_bluetooth_serial` (`finish` = graceful flush+close, `close` =
  immediate), the reference this package's data model is based on. Documented.
- **Raspberry Pi SPP** — documented (`bluetoothd --compat`, `bluetooth` group).

## Review — Set B (second 10-axis pass, post-split)

A second review pass on 10 new axes (performance, dartdoc accuracy, test
coverage, build/packaging, cross-platform parity, resource lifecycle,
cancellation/timeout, error diagnosability, encoding/binary-safety, API
idiomaticity). Status of the genuinely-real findings:

- **[fixed]** iOS send path O(n²) — buffer drained per chunk via front-removal;
  now drains with an offset cursor and compacts once per pump.
- **[fixed]** Windows device-name decode crash — `writeCharCode` per UTF-16 unit
  rejects lone surrogates (emoji / names truncated at the 248-char cap); switched
  to `String.fromCharCodes`.
- **[fixed]** macOS/Android `stopDiscovery()` leaked the discovery controller
  (macOS `[inquiry stop]` never fires the completion callback) — now closes them.
- **[fixed]** Windows worker isolates didn't balance `WSAStartup`/`WSACleanup`.
- **[fixed]** `BluetoothService`/`BluetoothDiscoveryResult` lacked `==`/`hashCode`.
- **[fixed]** Dead `AlreadyConnectedException` removed.
- **[fixed]** Docs: Android connect blocking + timeout, `ConnectionState`
  semantics, Windows discovery batch/cancel, parity notes; CHANGELOG link.
- **[fixed]** Test coverage: add-after-close, empty payload, double close/finish
  idempotency, bondedAndDiscovered short-circuit + error surfacing, value-type
  equality, opaque-id behavior (25 → 36 tests).

Tracked — genuinely real but requiring real-hardware verification to change
safely (CI has no Bluetooth peer, so a connect-path change can't be validated
here); recorded so the next review round doesn't re-flag them as new:

- **[tracked]** Android `connect()` blocks the calling isolate — the native
  `socket.connect()` runs synchronously inside the FFI `open` call, so the Dart
  `timeout` can't interrupt it and the isolate is blocked for Android's internal
  connect timeout (~12s). Fix path: run `btc_and_open` on a helper isolate and
  surface completion via the existing state callback. Needs a device to verify
  the JNI thread-attach + callback delivery still work off-isolate.
- **[tracked]** Native open-failure diagnosability — macOS `IOReturn`, iOS
  `NSStream.streamError`, and Android Java exceptions (incl. `SecurityException`)
  are collapsed to a bare `0`/null at the C-ABI boundary, so the thrown
  `BluetoothException` lacks `code`/`cause` and a permission failure can look like
  "no devices". Fix path: thread the native error through the callbacks/out-params
  and map `SecurityException` → `BluetoothPermissionException`.
- **[tracked]** Android device-name encoding — `GetStringUTFChars` returns
  modified UTF-8, so a bonded device whose name contains a NUL or astral char
  makes `bondedDevices()` throw `FormatException` on decode. Fix path: marshal
  the name as standard UTF-8 (`String.getBytes("UTF-8")`) on the C side.

Accepted (low impact, not worth the churn/risk):

- macOS `g_inquiry` holds one completed inquiry object until the next discovery
  (bounded to one, not a growing leak).
- Linux `dispose()` closes the D-Bus client but not an outstanding
  `adapterStateChanges` controller (per-listener `onCancel` already releases the
  signal subscription; only matters if `dispose()` races a live listener).
