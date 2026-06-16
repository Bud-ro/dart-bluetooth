# bluetooth_rfcomm

[![CI](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml/badge.svg)](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml)

Cross-platform **Bluetooth Classic (RFCOMM serial)** for Dart and Flutter.

One Dart API, usable from a **pure-Dart CLI** (`dart run`) and from **Flutter**
apps. Read and write `Uint8List`, list paired/discovered devices, pick the
RFCOMM channel, and get notified of connection-state changes.

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

## The two packages

| Package | Use it for |
| --- | --- |
| **`bluetooth_rfcomm`** (this one) | The full API + the Windows, Linux and macOS backends. Pure Dart — works in a CLI and in Flutter **desktop** apps with no extra dependency. |
| [**`bluetooth_rfcomm_flutter`**](../bluetooth_rfcomm_flutter) | Add this to a Flutter app that targets **Android or iOS**. It supplies the native builds those platforms need (Android JNI/Kotlin via Gradle; Apple via this package's native-assets hook) and re-exports the same API. |

Why two packages? pub.dev requires a `flutter:` SDK constraint for any package
that declares a Flutter plugin platform block, and that constraint would make the
package unusable from a pure-Dart `dart pub get`. Splitting the Flutter-plugin
parts into `bluetooth_rfcomm_flutter` keeps this package pure Dart, so **both are
publishable to pub.dev** and the CLI use case stays Flutter-free.

## Install

Pure-Dart / desktop:

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

## Platform support

| Platform | Backend | Native build? | Notes |
| --- | --- | --- | --- |
| **Windows** 10+ | Winsock `AF_BTH`/`BTHPROTO_RFCOMM` + `bthprops.cpl` via `dart:ffi` | none (system DLLs) | Primary target. |
| **Linux** | BlueZ over D-Bus (`package:dbus`) | none | Raspberry Pi may need `bluetoothd --compat` for SPP (see below). |
| **macOS** | IOBluetooth via an Obj-C C-ABI wrapper + `dart:ffi` | from source (native-assets hook) | Requires a non-zero RFCOMM channel — resolved from SDP. |
| **Android** | Kotlin + C JNI shim via `dart:ffi` | CMake + Gradle (via `bluetooth_rfcomm_flutter`) | Needs runtime BT permissions. |
| **iOS** | ExternalAccessory (`EASession`) | from source (native-assets hook) | **MFi accessories only** — see below. |

Nothing binary is committed; native code is compiled from source.

## Why no `objective_c`/`jni`

All native interop goes through a hand-written **C ABI** called via `dart:ffi` +
`NativeCallable` — `package:objective_c` and `package:jni` are deliberately
avoided because both pull in the Flutter SDK, which would break pure-Dart use.
The Apple sources are compiled by the native-assets `hook/build.dart` for both
`dart run` and `flutter build`; Android's JVM/Gradle build lives in the
`bluetooth_rfcomm_flutter` plugin.

## API

`BluetoothRfcomm` (use `.instance`, or construct with a `platform:` for tests):

- `isSupported()`, `adapterState()`, `adapterStateChanges` (stream),
  `requestEnable()`/`requestDisable()` (where the OS permits)
- `bondedDevices()` — paired devices
- `startDiscovery()` → `Stream<BluetoothDiscoveryResult>`, `stopDiscovery()`
- `bondedAndDiscovered()` — one-shot: paired **and** in range during a single
  inquiry
- `bondedAndDiscoveredStream()` → `Stream<List<BluetoothDevice>>` — keeps scanning
  and emits the cumulative set of paired devices seen nearby (stays listed once
  seen); cancel the subscription to stop
- `discoverServices(device)` — SDP lookup (RFCOMM channels)
- `connect(device, {channel, serviceUuid, timeout})` → `BluetoothConnection`
- `pair()`/`unpair()` — optional; implemented on Linux, throws
  `BluetoothUnsupportedException` elsewhere (pair via OS settings)

This package is an RFCOMM **client** (it initiates outbound connections); there's
no server/listen mode for accepting incoming connections. `connect` failures that
are worth retrying report `BluetoothException.isTransient == true`; a
`BluetoothConnection` is single-use, so reconnect by calling `connect` again.

`BluetoothConnection`:

- `input` — `Stream<Uint8List>`; **closes on disconnect** (clean EOF)
- `add(bytes)` — synchronous, never blocks (drained off the calling isolate)
- `write(bytes)` (= `add` + `flush`); `flush()` awaits the OS accepting queued
  bytes on Windows/Linux and is best-effort on macOS/iOS/Android (writes are
  handed off synchronously and in order, but there's no OS drain ack)
- `stateChanges`, `state`, `isConnected`
- `close()` (immediate) / `finish()` (flush then close)

### Channel selection

RFCOMM serial uses a specific channel. By default `connect` resolves it from the
device's SDP record for the SPP UUID (`00001101-…`). Pass an explicit `channel:`
to override — required when a device doesn't advertise SDP, and the reason
macOS works at all (it rejects channel 0):

```dart
final services = await bt.discoverServices(device);   // inspect SDP
final conn = await bt.connect(device, channel: 1);     // or force a channel
```

### Errors

Everything throws a subtype of `BluetoothException`:
`BluetoothUnsupportedException`, `BluetoothPermissionException`,
`BluetoothDisabledException`, `BluetoothConnectionException`,
`BluetoothTimeoutException`, `BluetoothWriteException`,
`BluetoothDiscoveryException`, `DeviceNotFoundException`,
`ServiceNotFoundException`.

## Platform setup

### macOS
- Add to the app's `Info.plist` (and to a CLI tool's embedded `Info.plist`):
  `NSBluetoothAlwaysUsageDescription` — without it, `bondedDevices()` returns
  empty and connections are denied (TCC).
- Sandboxed apps need the `com.apple.security.device.bluetooth` entitlement.
- For `dart run`, the first run triggers a TCC prompt; for headless/CI use, run
  from a signed `.app` bundle. The build hook ad-hoc signs the compiled dylib so
  the signed `dart` executable can load it under Library Validation.

### iOS — MFi only
ExternalAccessory only surfaces accessories that contain Apple's MFi
authentication coprocessor and whose protocol strings you declare in
`UISupportedExternalAccessoryProtocols` (`Info.plist`). **A non-MFi device will
never connect on iOS** via Bluetooth Classic — `connect` throws
`BluetoothUnsupportedException`. Use the planned `bluetooth_le` package (BLE) for
non-MFi devices on iOS.

On iOS a device's `DeviceId` is the accessory's `connectionID`, which is
**session-scoped** — it changes when the accessory reconnects and across app
launches. Don't persist it; always re-fetch devices from `bondedDevices()` each
session and connect using the fresh instance.

### Android
Add `bluetooth_rfcomm_flutter` (it builds and bundles the native library) and
request runtime permissions before scanning/connecting: `BLUETOOTH_CONNECT` and
`BLUETOOTH_SCAN` on Android 12+ (API 31+), or `BLUETOOTH`/`BLUETOOTH_ADMIN` plus
`ACCESS_FINE_LOCATION` on older versions. The plugin's manifest declares them;
prompt the user with a permissions plugin of your choice.

### Linux / Raspberry Pi
Needs BlueZ + D-Bus (preinstalled on Raspberry Pi OS and most desktops). No build
step — it's pure Dart over D-Bus. The calling user must be in the `bluetooth`
group (otherwise BlueZ returns access-denied, surfaced as
`BluetoothPermissionException`). For the Serial Port Profile you typically need:
- `bluetoothd` running with the compat profile: `ExecStart=… bluetoothd --compat`
  (or `-C`) — many distro defaults omit it, so SPP isn't registered out of the box.
- the device paired/bonded first (via `bluetoothctl`), and on older images
  `sudo sdptool add SP`.

## Examples

- [`example/`](example) — pure-Dart CLI (`dart run`): `list`, `scan`, `connect`.
- The Flutter demo lives with the plugin:
  [`bluetooth_rfcomm_flutter/example`](../bluetooth_rfcomm_flutter/example).

## Logging

The package logs through [`package:logging`](https://pub.dev/packages/logging)
and **never prints or installs a handler itself** — output is entirely your
choice. Nothing is emitted until you attach a listener and raise the level.

Loggers (all children of `bluetooth_rfcomm`, names available as
`BluetoothRfcommLoggers.*`):

| Logger | What it covers |
| --- | --- |
| `bluetooth_rfcomm.connection` | connect/disconnect, state changes, write failures, pair/unpair |
| `bluetooth_rfcomm.data` | raw bytes sent/received (with a short hex preview) |
| `bluetooth_rfcomm.discovery` | inquiry start/stop, each sighting, bonded-device counts |
| `bluetooth_rfcomm.adapter` | adapter power/authorization state |
| `bluetooth_rfcomm.native` | diagnostics from the native backends (malformed payloads, dropped sightings) |

Levels:

| Level | Used for |
| --- | --- |
| `FINEST` | raw byte payloads (rx/tx) |
| `FINER` | per-event detail (individual sightings, bonded counts) |
| `FINE` | lifecycle: connect/disconnect/state, discovery start/stop, adapter changes |
| `WARNING` | recoverable problems (a write failed, a malformed sighting skipped) |
| `SEVERE` | a `connect()` that failed (with the exception attached) |

### Turn it on

Globally — one handler, one level:

```dart
import 'package:logging/logging.dart';

Logger.root.level = Level.FINE;            // everything FINE and above
Logger.root.onRecord.listen((r) {
  print('${r.level.name} ${r.loggerName}: ${r.message}');
});
```

Per subsystem — see connection events but not the noisy raw bytes:

```dart
hierarchicalLoggingEnabled = true;         // enables per-logger levels
Logger(BluetoothRfcommLoggers.connection).level = Level.FINE;
Logger(BluetoothRfcommLoggers.data).level = Level.OFF;      // silence rx/tx bytes
// records still surface on Logger.root.onRecord (they propagate to ancestors)
```

Or scope a listener to just this package's subtree:

```dart
Logger(BluetoothRfcommLoggers.package).onRecord.listen(handle);
```

Raw-byte messages (`data`, FINEST) are built lazily, so leaving that logger off
(the default) costs nothing.

## Testing without hardware

`package:bluetooth_rfcomm/testing.dart` ships `FakeBluetoothRfcommPlatform`:

```dart
final fake = FakeBluetoothRfcommPlatform()
  ..bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
final bt = BluetoothRfcomm(platform: fake);
```

## Status

The Dart layer is implemented and unit-tested across all platforms. Every
backend — Windows (Winsock), Linux (BlueZ, including the `Profile1` RFCOMM
file-descriptor stream), macOS/iOS (IOBluetooth/ExternalAccessory), and Android
(Kotlin + JNI) — is implemented and pending validation against real hardware on
each OS.
