# Testing methodology

Bluetooth is a physical medium, but almost every bug this package has shipped
was *software*: async-interleaving races, cross-platform contract drift, and
silent-discard paths. Each of those is a **class**, and each class has a
software-pure prevention. This document is the map: what's in place, what it
prevents, and what to opt into next.

## Layers in place

### 1. Transport contract conformance (`checkRfcommTransportConformance`)

*Prevents: cross-platform semantic drift.*

One checker (`package:bluetooth_rfcomm/testing.dart`) encodes the observable
`RfcommTransport` contract — exactly-once terminal `disconnected`, clean-EOF
`incoming` on both local close and peer loss, post-close write surface,
backpressure-gauge rules. It runs against `FakeRfcommTransport` in unit CI
(`test/transport_conformance_test.dart`), which keeps every test written
against the fake honest; the *same* checker runs against real backends from a
hardware rig (it's framework-free and exported), so "Linux errors where macOS
closes cleanly" becomes a red test instead of a review finding. Any new
backend must pass it before it ships.

### 2. Seeded schedule fuzzing (`test/facade_fuzz_test.dart`)

*Prevents: async-interleaving races in the facade state machines.*

Random legal call schedules (scan start/stop, stream listen/cancel, connect/
disconnect, peer drops, dispose) run against the fake under `runZonedGuarded`,
with the engine's internal counters checked for invariant violations after
every operation and full quiescence asserted after dispose. Deterministic:
failures print a seed; `FUZZ_SEED=<seed>` reproduces exactly. CI runs 12
seeds (~2s); soak with `FUZZ_RUNS=500 FUZZ_OPS=200` before releases. New
facade operations MUST be added to the fuzzer's op table.

### 3. Silent-discard prohibition + counters

*Prevents: invisible data loss.*

The contract is "never silently drop accepted bytes" — and it's enforced by
accounting, not by review: every discard path (teardown purges, RX drops,
rejected writes, buffer overflows) increments a counter surfaced via
`BluetoothConnection.stats` (Dart + native hops on macOS). A loss report that
all counters read zero against is a *localizable* loss. `btc bench` (example
CLI) is the reference load harness: CRC-framed, sequence-numbered, separating
lost / late / corrupted / never-sent.

### 4. Native static analysis (CI `native-analyze` job)

*Prevents: memory/lifetime bug classes in ObjC/C that Dart tests can't reach.*

`clang --analyze` (with `-Wall -Wextra -Werror`) over the macOS/iOS ObjC and
strict-warning syntax passes over the JNI C, on every push. The Dart side
already runs under `strict-casts`/`strict-inference`/`strict-raw-types` +
`unawaited_futures` + `avoid_print`.

### 5. Headless integration (`integration/headless_test.dart`)

Drives the REAL backend of the host OS with no hardware: FFI loading, ABI
marshaling, error taxonomy, no-crash guarantees. Runs on the manual
`integration.yml` workflow and locally.

## Worth opting into next (roughly in leverage order)

1. **Emulated end-to-end on Linux CI (`btvirt`)** — BlueZ ships a virtual
   controller (`btvirt` from bluez/tools, or the `vhci` kernel driver). Two
   virtual controllers on one bus can pair and open a REAL RFCOMM link —
   which would let CI run `btc bench` end-to-end, conformance-check the real
   Linux transport, and regression-test actual byte transport with zero
   hardware. Needs: bluez tools in the runner image, root for vhci, and a
   small peer script exposing an SPP echo profile. This is the single biggest
   remaining robustness unlock.
2. **Sanitizer builds** — compile the Apple natives with
   `-fsanitize=address,undefined` in a CI variant of the native-assets hook
   and run the headless integration under them; TSan for the worker-thread
   code. Catches the use-after-free class at runtime rather than by review.
3. **Hardware-in-the-loop rig** — a Pi (Linux backend) + the real device,
   running `btc bench` + the transport conformance checker on a schedule.
   Physical-layer truths (sniff-mode latency, UART overrun) only show here;
   `doc/backpressure.md` and the bench verdicts tell you what to measure.
4. **Parser property tests** — fuzz the pure parsers (native JSON payloads,
   registry name decoding, `WSAQUERYSET` field handling, the bench
   reassembler already has one) with random/mutated inputs; they're pure
   functions, so this is cheap and total.
5. **Port the whole stack of layers 1–3 to `bluetooth_le`** — the LE package
   has the same architecture and has historically received rfcomm's fixes
   late. Its serial surface (`BleSerial`) needs the same conformance +
   counters treatment.

## The one rule

Every bug fixed here must leave behind the *test that would have caught it* —
in the layer that prevents its class, not just a regression test for its
instance. That's the difference between a hardened codebase and a hacked-
together one that happens to pass review.
