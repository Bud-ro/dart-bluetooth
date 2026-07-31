# bluetooth_rfcomm

[![CI](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml/badge.svg)](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml)

Cross-platform **Bluetooth Classic (RFCOMM serial)** for Dart and Flutter. Read
and write `Uint8List` over a serial link, list paired and discovered devices,
pick the RFCOMM channel, and track connection-state changes.

This is a pure-Dart package: it runs from a command-line tool (`dart run`) and in
Flutter desktop apps with no extra dependency. Linux, macOS and Windows are
supported here directly. For **Android and iOS**, add the companion Flutter
plugin [`bluetooth_rfcomm_flutter`](https://pub.dev/packages/bluetooth_rfcomm_flutter),
which supplies the native build those platforms need and re-exports this same
API.

```dart
import 'dart:typed_data';

import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';

final bt = BluetoothRfcomm.instance;

await bt.startScan(); // background scan: sightings accumulate while you work

// Paired AND actually nearby — the connectable set. (Or pass scanDuration
// instead of running startScan yourself.)
final connectable = await bt.listPairedAndScannedDevices();

final conn = await bt.connect(connectable.first); // SDP-resolves the SPP channel
conn.input.listen((bytes) => print('rx ${bytes.length} bytes'));
conn.add(Uint8List.fromList('AT\r\n'.codeUnits)); // non-blocking send
await conn.disconnect();                          // flush, then close
```

## Support

| Platform | Discover | Connect + serial I/O | Pairing | Manually verified |
| --- | --- | --- | --- | --- |
| Linux | ✅ | ✅ | ✅ | ❌ |
| macOS | ✅ | ✅ | ⚠️ | ⚠️ |
| Windows | ✅ | ✅ | ⚠️ | ⚠️ |
| Android | ✅ | ✅ | ⚠️ | ⚠️ |
| iOS | ⚠️ | ⚠️ | ⚠️ | ❌ |

In the capability columns (Discover / Connect / Pairing): ✅ supported · ⚠️ partial
· ❌ not supported.

**Manually verified** is a *separate* axis — whether the author has actually
exercised this backend against real hardware: ⚠️ = yes, it works well enough for
the author, but correctness is **not guaranteed to be perfect**; ❌ = **not yet
hardware-verified** (the capability shown in the other columns is implemented, but
its effectiveness has not been confirmed by the author).

> Note: ⚠️ means **"partial"** in the capability columns but **"author-verified"**
> in the Manually verified column — they are unrelated. (E.g. iOS is ⚠️ partial
> for Discover, while Windows is ⚠️ author-verified.)

> ⚠️ Only **macOS** and **Windows** have been manually verified against real
> devices so far. Every other backend is implemented but unverified — treat it as
> best-effort for now. The remaining platforms will be verified on hardware over
> time; until then, only the platforms marked ⚠️ above carry any manual
> verification of this package's effectiveness.

Notes:

- **Windows discovery is a real inquiry** (as of 0.2.0): `startDiscovery`,
  the background scan and `bondedAndDiscovered` all run a genuine
  `WSALookupService` inquiry on a worker isolate — nearby *unpaired* devices
  are found, and `bondedAndDiscovered` really means "paired AND in range".
  The inquiry occupies the radio for up to ~10s while it runs, but it is
  abortable (`WSALookupServiceEnd`) and is paused automatically while a
  connect is in flight. Note the new inquiry path has not yet been verified
  against real hardware.
- **Pairing** is programmatic on Linux; elsewhere pair through the OS settings
  (the API throws `BluetoothUnsupportedException` for `pair`/`unpair`).
- **iOS** reaches only MFi accessories (devices with Apple's authentication
  coprocessor); a non-MFi device throws `BluetoothUnsupportedException` — use BLE
  ([`bluetooth_le`](https://pub.dev/packages/bluetooth_le)) instead. iOS also
  cannot report the real radio state: `adapterState` is a fixed optimistic `on`
  (ExternalAccessory has no status API and CoreBluetooth would trigger the
  permission prompt).
- **`discoverServices` is only authoritative on macOS.** Windows/Linux/Android
  return the requested service with a sentinel channel 0 ("resolved at connect
  time by the OS") without consulting the device — a non-empty result there
  does not confirm the device advertises the service.

How each platform is reached: Linux via BlueZ over D-Bus (`package:dbus`); macOS
via an IOBluetooth wrapper; Windows via Winsock `AF_BTH`/`BTHPROTO_RFCOMM`;
Android via a Kotlin + JNI bridge; iOS via ExternalAccessory. Linux and Windows
talk to system APIs directly (no build step); the Apple and Android native code
builds automatically (a native-assets hook and the Flutter plugin's Gradle
build, respectively).

## Install

Command-line or Flutter desktop:

```yaml
dependencies:
  bluetooth_rfcomm: ^0.2.0
```

Flutter app targeting Android/iOS — add the companion plugin too:

```yaml
dependencies:
  bluetooth_rfcomm: ^0.2.0
  bluetooth_rfcomm_flutter: ^0.2.0
```

## API

`BluetoothRfcomm` (use `.instance`, or construct with a `platform:` for tests):

- `isSupported()`, `adapterState()`, `adapterStateChanges` (stream),
  `requestEnable()`/`requestDisable()` (where the OS permits)
- `bondedDevices()` — paired devices
- `startScan()`/`stopScan()` — opt-in **background scan** that accumulates every
  sighted device (paired or not) into `scannedDevices` /
  `scannedDevicesStream`; `forgetScannedDevices()` clears the cache. Start it
  early (e.g. in `main`) and device listings are instant and complete — no
  waiting out a ~10s inquiry at listing time. The scan pauses automatically
  while a `connect` or one-shot discovery is in flight and resumes after.
- The three dedicated listings (deliberately never a union — a mixed list
  makes paired-but-out-of-range devices look connectable):
  - `listScannedDevices({scanDuration})` — everything the scan has sighted,
    paired or not
  - `listPairedDevices()` — what the OS remembers, nearby or not (courtesy;
    don't build a connect picker from this alone)
  - `listPairedAndScannedDevices({scanDuration})` — **paired AND actually
    sighted: the connectable set a picker wants**
  All are instant and radio-silent by default; pass `scanDuration` to scan for
  that window first (starts and stops the scan for you if it wasn't already
  running)
- `startDiscovery()` → `Stream<BluetoothDiscoveryResult>`, `stopDiscovery()` —
  one-shot inquiry, real on every platform (see the Windows note above)
- `bondedAndDiscovered()` — one-shot: paired **and** in range during a single
  fresh inquiry, on every platform
- `bondedAndDiscoveredStream()` → `Stream<List<BluetoothDevice>>` — the live
  version of `listPairedAndScannedDevices`: emits **only** devices that are
  paired AND have actually been sighted (never the bare paired list).
  Listening holds the shared background scan running; cancel to stop
- `discoverServices(device)` — SDP lookup (RFCOMM channels)
- `connect(device, {channel, serviceUuid, timeout})` → `BluetoothConnection`
- `pair()`/`unpair()` — programmatic on Linux; elsewhere throws
  `BluetoothUnsupportedException`

This is an RFCOMM **client** (it makes outbound connections); there is no
server/listen mode. `connect` failures worth retrying report
`BluetoothException.isTransient == true`; a `BluetoothConnection` is single-use,
so reconnect by calling `connect` again.

`BluetoothConnection`:

- `input` — `Stream<Uint8List>`; closes on disconnect (clean EOF)
- `add(bytes)` — synchronous, never blocks (drained off the calling isolate);
  the outbound queue is unbounded and **never silently drops accepted bytes**
- `write(bytes)` (= `add` + `flush`); `flush()` awaits the OS accepting queued
  bytes on Windows/Linux/Android and is best-effort on macOS/iOS
- `pendingWriteBytes` — bytes accepted but not yet handed to the OS;
  `drain({belowBytes})` — awaits the queue dipping to that depth;
  `maxPayloadSize` — the OS-advertised max single-write payload, or null (see
  [Backpressure and throughput](#backpressure-and-throughput))
- `stateChanges`, `state`, `isConnected`
- `disconnect()` (= `finish()`: flush then close) / `close()` (immediate,
  discards unflushed bytes)

Disconnects always bubble up: when the peer drops (e.g. the device is powered
off), `input` closes, `stateChanges` emits a final `disconnected` and closes,
and `isConnected` flips to false. Every method stays safe afterwards — writes
throw `BluetoothWriteException`, and `disconnect`/`close`/`finish`/`flush` are
idempotent no-ops.

### Channel selection

RFCOMM uses a specific channel. By default `connect` resolves it from the
device's SDP record for the SPP UUID (`00001101-…`). Pass an explicit `channel:`
to override — needed when a device doesn't advertise SDP, and the reason macOS
works at all (it rejects channel 0):

```dart
final services = await bt.discoverServices(device);   // inspect SDP
final conn = await bt.connect(device, channel: 1);     // or force a channel
```

### Backpressure and throughput

**The contract: bytes you hand to `add` are never silently dropped.** The queue
between `add` and the OS is unbounded and lossless — every accepted byte is
either delivered to the OS or *loudly* reported lost (a
`BluetoothWriteException` from `flush`/`drain`, or the terminal disconnect).
The flip side of an unbounded queue is that nothing stops you from queueing
faster than the link drains; the fix is not a bigger buffer somewhere, it's
pacing with the async primitives:

- **Small, occasional frames** (commands, telemetry): `conn.add(frame)`,
  fire-and-forget.
- **Request/response**: `await conn.write(request)` per message — each frame
  reaches the OS before the next is sent.
- **Bulk transfer**: window it against `pendingWriteBytes` with `drain`:

```dart
// Send a large payload without ever holding more than ~64 KiB in the queue.
const window = 64 * 1024;
const chunkSize = 4 * 1024;
for (var off = 0; off < payload.length; off += chunkSize) {
  final end = (off + chunkSize < payload.length) ? off + chunkSize : payload.length;
  conn.add(Uint8List.sublistView(payload, off, end));
  if (conn.pendingWriteBytes >= window) {
    await conn.drain(belowBytes: window ~/ 2); // let the link catch up
  }
}
await conn.drain(); // fully handed to the OS (throws if the link died first)
```

`drain(belowBytes: 0)` rides `flush` (exact on Windows/Linux/Android, drains
the native queue on macOS); for `belowBytes > 0` the queue is polled every
~5 ms with an automatic `flush` fallback when the gauge shows no progress
(Linux reports an upper bound that only `flush` refreshes) — pacing converges
on every platform. `drain` throws if queued bytes were discarded (link death
or `close()`) rather than reporting a lie of success.

**Why is there no `bitsPerSecond`?** Unlike a UART, Bluetooth Classic
advertises **no throughput number anywhere** — no OS API reports a data rate
for an RFCOMM link. The radio renegotiates packet types with link quality, the
link may sit in sniff (power-save) mode, RFCOMM's own credit-based flow
control lets the *peer* throttle you, and the bandwidth is shared with every
other connection on the adapter. Any number this package invented would be a
measurement, not a capability — so it doesn't invent one. What the OS *does*
advertise is at most a maximum size for a single outgoing packet, exposed
verbatim as `maxPayloadSize`:

| Platform | `maxPayloadSize` | OS source |
| --- | --- | --- |
| macOS | RFCOMM frame payload size (typically ≤ 1011 B) | `IOBluetoothRFCOMMChannel getMTU` |
| Android | max outgoing packet size | `BluetoothSocket.getMaxTransmitPacketSize()` |
| Windows | `null` — stream socket, nothing advertised per link | (`SO_SNDBUF` is buffer capacity, not a rate) |
| Linux | `null` — BlueZ profile fd, nothing advertised | — |
| iOS | `null` — ExternalAccessory streams | — |

That's a frame *size*, not a rate — useful for sizing protocol frames so each
fits one RFCOMM packet, nothing more. You never have to chunk to it: `add`
accepts any size and transports split as needed. To observe actual throughput,
measure it yourself: watch `pendingWriteBytes` fall over time. Design details
in [doc/backpressure.md](doc/backpressure.md).

### Errors

Every failure throws a subtype of `BluetoothException`:
`BluetoothUnsupportedException`, `BluetoothPermissionException`,
`BluetoothDisabledException`, `BluetoothConnectionException`,
`BluetoothTimeoutException`, `BluetoothWriteException`,
`BluetoothDiscoveryException`, `DeviceNotFoundException`,
`ServiceNotFoundException`.

## Platform setup

### macOS
- Add `NSBluetoothAlwaysUsageDescription` to the app's `Info.plist` (and to a CLI
  tool's embedded `Info.plist`) — without it, `bondedDevices()` returns empty and
  connections are denied (TCC).
- Sandboxed apps need the `com.apple.security.device.bluetooth` entitlement.
- Under `dart run`, the first run triggers a TCC prompt; for headless/CI use, run
  from a signed `.app` bundle.

### iOS — MFi only
ExternalAccessory only surfaces accessories that contain Apple's MFi coprocessor
and whose protocol strings you declare in `UISupportedExternalAccessoryProtocols`
(`Info.plist`). A non-MFi device throws `BluetoothUnsupportedException`; use
[`bluetooth_le`](https://pub.dev/packages/bluetooth_le) for those. A device's
`DeviceId` on iOS is session-scoped — re-fetch from `bondedDevices()` each
session rather than persisting it.

### Android
Add `bluetooth_rfcomm_flutter` and request the runtime permissions before
scanning/connecting: `BLUETOOTH_CONNECT` and `BLUETOOTH_SCAN` on Android 12+ (API
31+), or `BLUETOOTH`/`BLUETOOTH_ADMIN` plus `ACCESS_FINE_LOCATION` on older
versions. The plugin's manifest declares them; prompt the user with a permissions
plugin of your choice.

### Linux / Raspberry Pi
Needs BlueZ + D-Bus (preinstalled on Raspberry Pi OS and most desktops). The
calling user must be in the `bluetooth` group. For the Serial Port Profile you
typically need `bluetoothd` running with the compat profile (`bluetoothd
--compat`) and the device paired first via `bluetoothctl`.

## Logging

Logging goes through [`package:logging`](https://pub.dev/packages/logging). No
handler is installed by default — nothing is emitted until you attach a listener
and raise the level.

Loggers (children of `bluetooth_rfcomm`, names in `BluetoothRfcommLoggers`):

| Logger | Covers |
| --- | --- |
| `bluetooth_rfcomm.connection` | connect/disconnect, state changes, write failures, pair/unpair |
| `bluetooth_rfcomm.data` | raw bytes sent/received (short hex preview) |
| `bluetooth_rfcomm.discovery` | inquiry start/stop, sightings, bonded counts |
| `bluetooth_rfcomm.adapter` | adapter power/authorization state |
| `bluetooth_rfcomm.native` | diagnostics from the native backends |

Raw bytes log at `FINEST`, per-event detail at `FINER`, lifecycle at `FINE`,
recoverable problems at `WARNING`, and a failed `connect()` at `SEVERE`.

```dart
import 'package:logging/logging.dart';

// One call: this package's loggers at FINE, everything else untouched.
BluetoothRfcommLoggers.setLevel(Level.FINE);
Logger.root.onRecord.listen((r) {
  print('${r.level.name} ${r.loggerName}: ${r.message}');
});
```

For per-subsystem levels, configure individual loggers (all reachable via
`BluetoothRfcommLoggers.loggers` / `.root`, or by name) — e.g. silence
`BluetoothRfcommLoggers.data` to drop raw bytes. Raw-byte messages are built
lazily, so leaving that logger off costs nothing.

The package itself never prints. The one exception outside `package:logging`'s
reach: the Android native layer logs RFCOMM connect failures to logcat under
the tag `BluetoothRfcomm` (the JNI ABI can't carry the throwable across).

## Testing without hardware

`package:bluetooth_rfcomm/testing.dart` ships `FakeBluetoothRfcommPlatform`:

```dart
final fake = FakeBluetoothRfcommPlatform()
  ..bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
final bt = BluetoothRfcomm(platform: fake);
```

Real-backend integration tests (`integration/headless_test.dart` for desktop and
the example's `integration_test/headless_behavior_test.dart` for mobile) drive
the actual OS APIs with no hardware present, asserting that calls fail with domain
exceptions rather than crashing. They run live system services, so they are
triggered manually (the **Integration** workflow), or locally with
`dart test integration`.

## Examples

- [`example/`](https://github.com/Bud-ro/dart-bluetooth/tree/master/packages/bluetooth_rfcomm/example) — pure-Dart CLI: `list`, `scan`, `connect`.
- A Flutter demo ships with the companion plugin.

## Status

The Dart layer is implemented and unit-tested, and every backend compiles in CI.
The native paths are pending broader validation against real hardware on each OS.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
