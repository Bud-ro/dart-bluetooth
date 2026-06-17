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

final paired = await bt.bondedDevices();
final conn = await bt.connect(paired.first);     // SDP-resolves the SPP channel
conn.input.listen((bytes) => print('rx ${bytes.length} bytes'));
conn.add(Uint8List.fromList('AT\r\n'.codeUnits)); // non-blocking send
await conn.finish();                              // flush, then close
```

## Support

| Platform | Discover | Connect + serial I/O | Pairing |
| --- | --- | --- | --- |
| Linux | ✅ | ✅ | ✅ |
| macOS | ✅ | ✅ | ⚠️ |
| Windows | ✅ | ✅ | ⚠️ |
| Android | ✅ | ✅ | ⚠️ |
| iOS | ⚠️ | ⚠️ | ⚠️ |

✅ supported · ⚠️ partial · ❌ not supported

Notes:

- **Pairing** is programmatic on Linux; elsewhere pair through the OS settings
  (the API throws `BluetoothUnsupportedException` for `pair`/`unpair`).
- **iOS** reaches only MFi accessories (devices with Apple's authentication
  coprocessor); a non-MFi device throws `BluetoothUnsupportedException` — use BLE
  ([`bluetooth_le`](https://pub.dev/packages/bluetooth_le)) instead.

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
  bluetooth_rfcomm: ^0.1.0
```

Flutter app targeting Android/iOS — add the companion plugin too:

```yaml
dependencies:
  bluetooth_rfcomm: ^0.1.0
  bluetooth_rfcomm_flutter: ^0.1.0
```

## API

`BluetoothRfcomm` (use `.instance`, or construct with a `platform:` for tests):

- `isSupported()`, `adapterState()`, `adapterStateChanges` (stream),
  `requestEnable()`/`requestDisable()` (where the OS permits)
- `bondedDevices()` — paired devices
- `startDiscovery()` → `Stream<BluetoothDiscoveryResult>`, `stopDiscovery()`
- `bondedAndDiscovered()` — one-shot: paired **and** in range during a single
  inquiry
- `bondedAndDiscoveredStream()` → `Stream<List<BluetoothDevice>>` — keeps scanning
  and emits the cumulative set of paired devices seen nearby; cancel to stop
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
- `add(bytes)` — synchronous, never blocks (drained off the calling isolate)
- `write(bytes)` (= `add` + `flush`); `flush()` awaits the OS accepting queued
  bytes on Windows/Linux and is best-effort on macOS/iOS/Android
- `stateChanges`, `state`, `isConnected`
- `close()` (immediate) / `finish()` (flush then close)

### Channel selection

RFCOMM uses a specific channel. By default `connect` resolves it from the
device's SDP record for the SPP UUID (`00001101-…`). Pass an explicit `channel:`
to override — needed when a device doesn't advertise SDP, and the reason macOS
works at all (it rejects channel 0):

```dart
final services = await bt.discoverServices(device);   // inspect SDP
final conn = await bt.connect(device, channel: 1);     // or force a channel
```

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

Logger.root.level = Level.FINE;
Logger.root.onRecord.listen((r) {
  print('${r.level.name} ${r.loggerName}: ${r.message}');
});
```

For per-subsystem levels, set `hierarchicalLoggingEnabled = true` and configure
individual loggers (e.g. silence `BluetoothRfcommLoggers.data` to drop raw
bytes). Raw-byte messages are built lazily, so leaving that logger off costs
nothing.

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

- [`example/`](example) — pure-Dart CLI: `list`, `scan`, `connect`.
- A Flutter demo ships with the companion plugin.

## Status

The Dart layer is implemented and unit-tested, and every backend compiles in CI.
The native paths are pending broader validation against real hardware on each OS.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
