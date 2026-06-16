# bluetooth_rfcomm v0.1.0

First release of **bluetooth_rfcomm** — cross-platform Bluetooth Classic
(RFCOMM serial) for Dart and Flutter.

## Highlights

- **One package, two runtimes.** The same package works from a **pure-Dart CLI**
  (`dart run`) and inside a **Flutter app**, with no `flutter` dependency in the
  core. `dart pub get` resolves on a Dart-only machine.
- **Five platforms.** Windows, macOS, Linux, Android, and iOS.
- **`Uint8List` serial I/O.** Read via a broadcast `Stream<Uint8List>` that
  closes cleanly on disconnect; send with a non-blocking `add()` or an
  awaitable `write()`/`flush()`.
- **Channel selection.** RFCOMM channels resolve from SDP by default, or you can
  pass an explicit channel (required on macOS, which rejects channel 0).
- **Typed errors.** A domain `BluetoothException` hierarchy — callers never see
  raw platform error codes or `DBus*`/`HRESULT`/`NSError` types.
- **Testable.** `package:bluetooth_rfcomm/testing.dart` ships an in-memory fake
  backend.

## Platform backends

| Platform | Backend | Native build |
| --- | --- | --- |
| Windows 10+ | Winsock `AF_BTH`/RFCOMM + `bthprops.cpl` via `dart:ffi` | none (system DLLs) |
| Linux / Raspberry Pi | BlueZ over D-Bus (`package:dbus`) | none |
| macOS | IOBluetooth (Obj-C C-ABI wrapper) via `dart:ffi` | from source (native-assets hook + SPM) |
| Android | Kotlin + C JNI shim via `dart:ffi` | CMake (`ffiPlugin`) |
| iOS | ExternalAccessory (`EASession`) via `dart:ffi` | from source (native-assets hook + SPM) |

Native code is hidden behind a hand-written **C ABI** (`dart:ffi` +
`NativeCallable`); `package:objective_c` and `package:jni` are deliberately
avoided because they pull in the Flutter SDK.

## Verified by CI

GitHub Actions (Flutter 3.44.0) on every push:

- `dart analyze` + unit tests on Ubuntu, macOS, and Windows.
- `flutter build` of the example app for Android, Linux, macOS, iOS, and Windows
  — so the IOBluetooth, ExternalAccessory, and Android JNI native code all
  compile and link per platform.
- **Launch smoke tests** that load the real native library without any Bluetooth
  hardware: the CLI `doctor` command on all three desktops, the Flutter app on
  Linux/macOS/Windows desktop, and on an **Android emulator** (exercising the
  JNI `.so` load path).

## Known limitations

- **iOS requires MFi.** Bluetooth Classic on iOS only works with MFi-certified
  accessories (ExternalAccessory is hardware-gated). For a non-MFi device, use
  BLE — the planned sibling `bluetooth_le` package is the path there.
- **Runtime hardware bring-up.** CI proves everything compiles and launches, but
  it has no Bluetooth radio. End-to-end discovery/connect/serial round-trips
  should be exercised against real hardware (start with Windows and macOS).
- Programmatic adapter on/off and pairing are best-effort and unsupported on
  some platforms.

## Install

Distributed via Git (not pub.dev) to keep the package Flutter-free for CLI use —
pub.dev would force a `flutter:` SDK constraint that breaks pure-Dart consumption.

```yaml
dependencies:
  bluetooth_rfcomm:
    git:
      url: https://github.com/Bud-ro/dart-bluetooth.git
      ref: v0.1.0
      path: packages/bluetooth_rfcomm
```

## Getting started

```dart
import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';

final bt = BluetoothRfcomm.instance;
final paired = await bt.bondedDevices();
final conn = await bt.connect(paired.first);   // SDP-resolved SPP channel
conn.input.listen((bytes) => print('rx ${bytes.length}'));
conn.add(Uint8List.fromList('AT\r\n'.codeUnits));
await conn.finish();
```

See the [package README](packages/bluetooth_rfcomm/README.md) for platform
setup (macOS TCC, Android permissions, Raspberry Pi) and the full API.
