# Backpressure and data-rate design

Design note for the continuous-send story: what happens when a client writes
faster than the link drains, and what "data rate" can honestly mean for
Bluetooth Classic. The user-facing summary lives in the README's
[Backpressure and throughput](../README.md#backpressure-and-throughput)
section; this note records the rationale.

## The two questions this answers

1. *"If the pipe fills up too much, data is eventually dropped. What's the
   right way to handle it?"*
2. *"How do we present data rates to clients? Not by measurement but by
   whatever is advertised by the OS."*

## 1. No silent drops — pacing, not dropping

Some serial stacks respond to a full pipe by discarding bytes. This package
does not, ever. The contract, enforced at the transport seam
(`RfcommTransport.send`):

> The queue between `add()` and the OS is **unbounded and lossless**. Every
> byte accepted by `add` is either handed to the OS or reported lost — via a
> `BluetoothWriteException` from `flush()`/`drain()` when the link dies with
> bytes queued, or via `close()` which documents that it discards. There is no
> path where accepted bytes vanish quietly.

An unbounded queue moves the problem rather than solving it: a client that
`add`s in a tight loop against a slow link just grows memory. The remedy is
client-side pacing, and the API makes each pattern one primitive:

| Traffic shape | Pattern | Primitive |
| --- | --- | --- |
| Small, occasional frames | fire-and-forget | `add(frame)` |
| Request/response | one frame in flight | `await write(frame)` |
| Bulk transfer | windowed queue depth | `add` + `pendingWriteBytes` + `await drain(belowBytes: …)` |

### Why `drain({int belowBytes = 0})` and not `flush()` alone

`flush()` was considered as the sole backpressure primitive ("write a window,
flush, repeat"). Rejected as the *only* surface for three reasons:

- **`flush` is all-or-nothing.** Waiting for a completely empty queue between
  windows leaves the link idle for one round-trip per window (stop-and-wait).
  `drain(belowBytes: window ~/ 2)` refills while bytes are still in flight —
  the queue never runs dry, so the radio never starves.
- **Gauge precision varies by platform, and `drain` compensates.** The
  pending gauge is live on Windows/macOS/iOS/Android; on Linux it is an
  UPPER BOUND that only `flush` resets (dart:io sockets hide their internal
  buffer), and `flush` is exact on Windows/Linux/Android and drains the
  native queue on macOS while iOS remains best-effort. `drain` therefore
  watches for progress and falls back to a real `flush` when the gauge
  stalls — so pacing converges on every platform regardless of which
  primitive is precise there.
- **Visibility is useful by itself.** `pendingWriteBytes` also answers "is it
  safe to power the peer down?" and drives progress UI, with no waiting
  involved.

`flush()` stays, unchanged, as the *delivery-confirmation* primitive (and the
engine of `write` and `finish`). `drain` is the *pacing* primitive layered on
`pendingWriteBytes`.

### `drain` semantics (precision and failure)

- Completes when `pendingWriteBytes <= belowBytes`.
- `belowBytes == 0` first awaits `flush()` — poll-free and exact on
  Windows/Linux/Android, where flush really acknowledges the drain.
- Otherwise (and on the best-effort-flush platforms) it polls
  `pendingWriteBytes` every 5 ms, so completion may lag the condition by one
  poll interval. At realistic RFCOMM throughput (~tens to a few hundred
  KB/s) a 5 ms poll resolves the queue to a few hundred bytes — ample for
  pacing, deliberately not pitched as real-time.
- If the connection drops (or `close()` discards) while more than
  `belowBytes` remain queued, `drain` throws `BluetoothWriteException` naming
  the undelivered byte count — the no-silent-drop contract applied to the one
  unavoidable loss case, a dead link.
- If the condition already holds, it completes immediately — even after
  disconnect — so shutdown code can always `await drain()` safely.

## 2. Data rate: expose what the OS advertises — which is a size, not a rate

Research result, per platform, of everything the OS *advertises* (as opposed
to what one could measure) for an RFCOMM link:

| Platform | Advertised | API | Exposed as |
| --- | --- | --- | --- |
| macOS | negotiated RFCOMM frame payload size (typically ≤ 1011 B) | `-[IOBluetoothRFCOMMChannel getMTU]` | `maxPayloadSize` |
| Android | max size of one outgoing packet | `BluetoothSocket.getMaxTransmitPacketSize()` (API 23+) | `maxPayloadSize` |
| Windows | nothing per link — Winsock `AF_BTH` stream socket; `SO_SNDBUF` is send-buffer *capacity*, not a rate | — | `null` |
| Linux | nothing — BlueZ hands the profile a plain stream fd | — | `null` |
| iOS | nothing — ExternalAccessory `NSStream`s | — | `null` |

The key truth, stated plainly in the docs: **unlike a UART baud rate,
Bluetooth Classic advertises no throughput number anywhere.** The best any OS
offers is a maximum frame/packet size. Actual throughput is emergent:

- the baseband renegotiates ACL packet types (DM1…3-DH5) with link quality;
- sniff/power-save mode multiplies latency without any API-visible signal;
- RFCOMM credit-based flow control lets the **peer** throttle the sender;
- adapter bandwidth is shared across A2DP/other ACL links and (often) Wi-Fi
  coexistence.

A `bitsPerSecond` getter would therefore be either a fabrication or a
measurement — and the requirement was explicitly *advertised, not measured*.
So the API surface is exactly:

- `maxPayloadSize` (`int?`) — the OS-advertised max single native write
  payload, verbatim; `null` where the OS advertises nothing. Informational
  (e.g. size protocol frames to fit one RFCOMM packet); `add` accepts any
  size and transports split as needed.
- `pendingWriteBytes` (`int`) — queue-depth visibility.
- `drain` — the awaitable form of the queue-depth check.

Clients that want a rate can compute one from observation — sample
`pendingWriteBytes` over time — with full knowledge that it describes the
current link, not a capability.

## Transport implementor notes

Every `RfcommTransport` must implement:

```dart
int? get maxPayloadSize;   // OS-advertised, verbatim; null if none
int get pendingWriteBytes; // accepted by send() but not yet handed to the OS
```

`pendingWriteBytes` must be maintained on the main isolate (the facade reads
it synchronously): increment by `data.length` in `send`, decrement when the
worker/native layer confirms bytes were handed to the OS. "Handed to the OS"
means the platform write call accepted them (Winsock `send`, fd `write`,
`OutputStream.write`, `writeAsync` completion) — not delivered to the peer;
RFCOMM has no end-to-end delivery signal.

`FakeRfcommTransport` mirrors this: `send` accrues `pendingWriteBytes`,
`flush` zeroes it (set `flushDrains = false` to model macOS/iOS best-effort
flush), and the count is directly settable so tests can script drain
timelines; `maxPayloadSize` is a mutable field, seedable per platform via
`FakeBluetoothRfcommPlatform.transportMaxPayloadSize`.
