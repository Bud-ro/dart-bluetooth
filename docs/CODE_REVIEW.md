# Pre-release code review (10-agent, Opus 4.8)

Synthesis of a 10-axis review of `bluetooth_classic`. Items marked **[fixed]**
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
- **[fixed]** No `BluetoothClassic.dispose()` — backend resources were
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

## Tracked (deferred, with rationale)

- **`connectionStateChanges` is Linux-only** (others return an empty stream).
  Documented as Linux-only for now; Android ACL-intent + Apple notifications are
  a follow-up.
- **`flush()` is best-effort on macOS/iOS/Android** (writes are synchronous at
  the native call, so `finish()` is safe, but there's no OS-level drain ack).
  Documented; a native write-completion barrier is a follow-up.
- **No inbound backpressure / flow control** — a hostile peer can grow memory.
  Tracked; needs a pausable native source (a design change).
- **iOS `connectionID` is session-scoped** — `DeviceId`s on iOS are ephemeral;
  documented that callers must re-fetch each session.
- **`close()` vs `finish()` semantics** — kept (`finish` = graceful flush+close,
  `close` = immediate); documented prominently rather than renamed.
- **Raspberry Pi SPP** may need `bluetoothd --compat` and `bluetooth` group
  membership — documented.
