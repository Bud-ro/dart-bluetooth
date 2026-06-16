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
