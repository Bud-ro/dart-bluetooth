# bluetooth_le

[![CI](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml/badge.svg)](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml)

Cross-platform **Bluetooth Low Energy (GATT)** for Dart and Flutter. Scan,
connect, discover services, read/write/subscribe to characteristics — and use a
write+notify characteristic pair as a **serial channel** (the BLE analogue of an
RFCOMM port, defaulting to the Nordic UART Service).

This is a pure-Dart package: it runs from a command-line tool (`dart run`) and in
Flutter desktop apps with no extra dependency. Linux, macOS and Windows are
supported here directly. For **Android and iOS**, add the companion Flutter plugin
[`bluetooth_le_flutter`](https://pub.dev/packages/bluetooth_le_flutter), which
supplies the native build those platforms need and re-exports this same API.

```dart
import 'dart:typed_data';
import 'package:bluetooth_le/bluetooth_le.dart';

final ble = BleCentral.instance;
final hit = await ble.startScan(withServices: [Uuid.nordicUartService]).first;
final conn = await ble.connect(hit.device);
await conn.discoverServices();

final serial = conn.asSerial();             // Nordic UART by default
serial.input.listen((bytes) => print('rx: ${bytes.length}'));
await serial.write(Uint8List.fromList('AT\r\n'.codeUnits));
```

## Support

| Platform | Scan | Connect + read/write | Notifications | Manually verified |
| --- | --- | --- | --- | --- |
| Linux | ✅ | ✅ | ✅ | ❌ |
| macOS | ✅ | ✅ | ✅ | ❌ |
| Android | ✅ | ✅ | ✅ | ❌ |
| iOS | ✅ | ✅ | ✅ | ❌ |
| Windows | ❌ | ✅ | ❌ | ❌ |

In the capability columns: ✅ supported · ⚠️ partial · ❌ not supported.

**Manually verified** — whether the author has actually exercised this backend on
real hardware: ❌ = **not yet hardware-verified** (the capabilities shown are
implemented, but their effectiveness has not been confirmed by the author).

> ⚠️ **No `bluetooth_le` backend has been manually verified on real hardware
> yet.** Every platform is implemented but unverified — treat it all as
> best-effort for now. The backends will be verified on hardware over time.

Notes:

- **iOS / macOS** use a per-host opaque device identifier rather than a MAC
  address (a CoreBluetooth peculiarity); treat `DeviceId` as an opaque token.
- **Windows** currently uses the Win32 GATT API, which reaches already-paired
  devices: connect, read, write and service discovery work, but it has no
  unpaired-device scan and no notifications — so `asSerial().input` (the serial
  receive path) is unavailable there. Pair the device in Windows settings, then
  connect by address. Lifting these is the next step, planned via WinRT while
  keeping the pure-Dart/CLI goal.

How each platform is reached: Linux via BlueZ over D-Bus (`package:dbus`); macOS
and iOS via a CoreBluetooth wrapper; Windows via the Win32 GATT API; Android via a
Kotlin `BluetoothGatt` + JNI bridge. Linux and Windows talk to system APIs
directly (no build step); the Apple and Android native code builds automatically
(a native-assets hook and the Flutter plugin's Gradle build, respectively).

## Install

Command-line or Flutter desktop:

```yaml
dependencies:
  bluetooth_le: ^0.1.0
```

Flutter app targeting Android/iOS — add the companion plugin too:

```yaml
dependencies:
  bluetooth_le: ^0.1.0
  bluetooth_le_flutter: ^0.1.0
```

## API

`BleCentral` (use `.instance`, or construct with a `platform:` for tests):

- `isSupported()`, `adapterState()`, `adapterStateChanges` (stream),
  `setAdapterEnabled()` (where the OS permits)
- `startScan({withServices})` → `Stream<BleScanResult>`, `stopScan()`
- `connect(device, {timeout})` → `BleConnection`

`BleConnection`:

- `discoverServices()` → `List<BleService>`
- `readCharacteristic(service, char)`, `writeCharacteristic(service, char, value,
  {withoutResponse})`
- `subscribe(service, char)` → `Stream<Uint8List>` (enables notifications while
  listened)
- `requestMtu(mtu)`, `stateChanges`, `state`, `close()`
- `asSerial({service, writeCharacteristic, notifyCharacteristic})` → `BleSerial`

### GATT-as-serial

`asSerial()` returns a `BleSerial`: `input` (a `Stream<Uint8List>` of
notifications) plus `add`/`write`/`flush` (writes chunked to the ATT payload and
serialised to preserve order). It defaults to the Nordic UART Service.
`negotiateMtu()` updates the chunk size from the connection's usable MTU — note
the OS negotiates the MTU automatically on most platforms (only Android honours
an explicit request; Windows is fixed at the 23-byte default).

### Errors

Every failure throws a subtype of `BleException`: `BleUnsupportedException`,
`BlePermissionException`, `BleDisabledException`, `BleConnectionException`,
`BleTimeoutException`, `DeviceNotFoundException`, `BleScanException`,
`BleGattException`, `ServiceNotFoundException`, `CharacteristicNotFoundException`.
`isTransient == true` marks failures worth retrying (connection, timeout,
device-not-found).

## Platform setup

- **macOS / iOS** — add `NSBluetoothAlwaysUsageDescription` to the app's
  `Info.plist`; sandboxed macOS apps need the
  `com.apple.security.device.bluetooth` entitlement. Under `dart run`, the first
  run triggers a TCC prompt.
- **Android** — add `bluetooth_le_flutter` and request the runtime permissions
  before scanning/connecting: `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` on Android
  12+ (API 31+), or location on older versions.
- **Linux** — needs BlueZ + D-Bus (preinstalled on most desktops and Raspberry
  Pi OS); the user must be in the `bluetooth` group.
- **Windows** — pair the device in Windows settings first, then connect by
  address (see the support note above).

## Logging

Logging goes through [`package:logging`](https://pub.dev/packages/logging). No
handler is installed by default — nothing is emitted until you attach a listener
and raise the level.

Loggers (children of `bluetooth_le`, names in `BleLoggers`):

| Logger | Covers |
| --- | --- |
| `bluetooth_le.scan` | scan start/stop and sightings |
| `bluetooth_le.connection` | connect/disconnect and state changes |
| `bluetooth_le.gatt` | service discovery, reads, writes, subscriptions |
| `bluetooth_le.data` | raw bytes read/written (short hex preview) |
| `bluetooth_le.adapter` | adapter power/authorization state |
| `bluetooth_le.native` | diagnostics from the native backends |

Raw bytes log at `FINEST`, lifecycle at `FINE`, and recoverable problems at
`WARNING`/`SEVERE`.

```dart
import 'package:logging/logging.dart';

Logger.root.level = Level.FINE;
Logger.root.onRecord.listen((r) {
  print('${r.level.name} ${r.loggerName}: ${r.message}');
});
```

For per-subsystem levels, set `hierarchicalLoggingEnabled = true` and configure
individual loggers (e.g. silence `BleLoggers.data` to drop raw bytes). Raw-byte
messages are built lazily, so leaving that logger off costs nothing.

## Example

A pure-Dart CLI demo (`doctor` / `scan` / `connect`) lives in
[`example/`](https://github.com/Bud-ro/dart-bluetooth/tree/master/packages/bluetooth_le/example):

```sh
cd example
dart run bin/ble.dart scan
dart run bin/ble.dart connect <DEVICE-ID>   # opens a Nordic-UART serial link
```

A Flutter demo app ships with the companion plugin
[`bluetooth_le_flutter`](https://pub.dev/packages/bluetooth_le_flutter).

## Testing without hardware

`package:bluetooth_le/testing.dart` ships `FakeBleCentralPlatform`:

```dart
final fake = FakeBleCentralPlatform();
final ble = BleCentral(platform: fake);
```

Real-backend integration tests drive the actual OS APIs with no hardware
present, asserting that calls return cleanly or throw domain exceptions rather
than crashing — `integration/headless_test.dart` here (desktop), and a mobile
counterpart in the `bluetooth_le_flutter` example. They run live system
services, so they are triggered manually (the **Integration** workflow), or
locally with `dart test integration`.

## Status

The Dart layer is implemented and unit-tested, and every backend compiles in CI.
The native paths are pending broader validation against real hardware on each OS.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
