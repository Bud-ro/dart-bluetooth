# bluetooth_classic

Cross-platform **Bluetooth Classic (RFCOMM serial)** for Dart and Flutter.

One package, one Dart API, usable from a **pure-Dart CLI** (`dart run`) and from
**Flutter** apps — with no `flutter` dependency baked into the package. Read and
write `Uint8List`, list paired/discovered devices, pick the RFCOMM channel, and
get notified of connection-state changes.

```dart
import 'package:bluetooth_classic/bluetooth_classic.dart';

final bt = BluetoothClassic.instance;

final paired = await bt.bondedDevices();
final conn = await bt.connect(paired.first);     // SDP-resolves the SPP channel
conn.input.listen((bytes) => print('rx ${bytes.length} bytes'));
conn.add(Uint8List.fromList('AT\r\n'.codeUnits)); // non-blocking send
await conn.finish();                              // flush, then close
```

## Platform support

| Platform | Backend | Native build? | Notes |
| --- | --- | --- | --- |
| **Windows** 10+ | Winsock `AF_BTH`/`BTHPROTO_RFCOMM` + `bthprops.cpl` via `dart:ffi` | none (system DLLs) | Primary target. |
| **Linux** | BlueZ over D-Bus (`package:dbus`) | none | Works on Raspberry Pi OS out of the box. |
| **macOS** | IOBluetooth via an Obj-C C-ABI wrapper + `dart:ffi` | from source (native-assets hook / SPM) | Requires a non-zero RFCOMM channel — resolved from SDP. |
| **Android** | Kotlin + C JNI shim via `dart:ffi` | CMake (`ffiPlugin`) | Needs runtime BT permissions. |
| **iOS** | ExternalAccessory (`EASession`) | from source (native-assets hook / SPM) | **MFi accessories only** — see below. |

Nothing binary is committed; native code is compiled from source.

## Why one package (and no `objective_c`/`jni`)

The package stays Dart-only so `dart pub get` works without the Flutter SDK. All
native interop goes through a hand-written **C ABI** called via `dart:ffi` +
`NativeCallable` — `package:objective_c` and `package:jni` are deliberately
avoided because both pull in the Flutter SDK. The `flutter: plugin:` block in
`pubspec.yaml` only drives the per-platform native build for Flutter apps; it
adds no Dart dependency.

## API

`BluetoothClassic` (use `.instance`, or construct with a `platform:` for tests):

- `isSupported()`, `adapterStateNow()`, `adapterState` (stream),
  `requestEnable()`/`requestDisable()` (where the OS permits)
- `bondedDevices()` — paired devices
- `startDiscovery()` → `Stream<BluetoothDiscoveryResult>`, `stopDiscovery()`
- `bondedAndDiscovered()` — paired **and** currently in range
- `discoverServices(device)` — SDP lookup (RFCOMM channels)
- `connect(device, {channel, serviceUuid, timeout})` → `BluetoothConnection`
- `connectionState(device)`, `pair()`/`unpair()` (best-effort, optional)

`BluetoothConnection`:

- `input` — `Stream<Uint8List>`; **closes on disconnect** (clean EOF)
- `add(bytes)` — synchronous, never blocks (drained off the calling isolate)
- `write(bytes)` / `flush()` — backpressure-aware
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
`ServiceNotFoundException`, `AlreadyConnectedException`.

## Platform setup

### macOS
- Add to the app's `Info.plist` (and to a CLI tool's embedded `Info.plist`):
  `NSBluetoothAlwaysUsageDescription` — without it, `bondedDevices()` returns
  empty and connections are denied (TCC).
- Sandboxed apps need the `com.apple.security.device.bluetooth` entitlement.
- For `dart run`, the first run triggers a TCC prompt; for headless/CI use, run
  from a signed `.app` bundle. The build hook ad-hoc signs the compiled dylib so
  the signed `dart` executable can load it under Library Validation.
- Uses Swift Package Manager; builds are warning-free on Flutter 3.44.0.

### iOS — MFi only
ExternalAccessory only surfaces accessories that contain Apple's MFi
authentication coprocessor and whose protocol strings you declare in
`UISupportedExternalAccessoryProtocols` (`Info.plist`). **A non-MFi device will
never connect on iOS** via Bluetooth Classic — `connect` throws
`BluetoothUnsupportedException`. Use the planned
[`bluetooth_le`](../bluetooth_le) package (BLE) for non-MFi devices on iOS.

### Android
Request runtime permissions before scanning/connecting: `BLUETOOTH_CONNECT` and
`BLUETOOTH_SCAN` on Android 12+ (API 31+), or `BLUETOOTH`/`BLUETOOTH_ADMIN` plus
`ACCESS_FINE_LOCATION` on older versions. The plugin's manifest declares them;
prompt the user with a permissions plugin of your choice.

### Linux / Raspberry Pi
Needs BlueZ + D-Bus (preinstalled on Raspberry Pi OS and most desktops). For the
Serial Port Profile you may need to enable SPP once:
`sudo sdptool add SP` (older images) or ensure the device is paired via
`bluetoothctl`. No build step — it's pure Dart over D-Bus.

## Examples

- [`example_cli/`](example_cli) — pure-Dart CLI (`dart run`): `list`, `scan`,
  `connect`.
- [`example/`](example) — Flutter app (run `flutter create .` there once to
  generate the runner projects, then add the permission strings above).

## Testing without hardware

`package:bluetooth_classic/testing.dart` ships `FakeBluetoothClassicPlatform`:

```dart
final fake = FakeBluetoothClassicPlatform()
  ..bonded.add(FakeBluetoothClassicPlatform.sampleDevice());
final bt = BluetoothClassic(platform: fake);
```

## Status

Desktop (Windows, Linux, macOS) and the Dart layer are implemented and tested;
the mobile/Apple native code is complete but pending on-device validation. The
Linux RFCOMM file-descriptor stream (BlueZ `Profile1`) is the remaining gap;
adapter state, discovery, bonded enumeration and pairing work today.
