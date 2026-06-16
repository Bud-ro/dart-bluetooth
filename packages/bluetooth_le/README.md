# bluetooth_le

[![CI](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml/badge.svg)](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml)

Cross-platform **Bluetooth Low Energy (GATT)** for Dart and Flutter — with a
**GATT-as-serial** channel. Usable from a **pure-Dart CLI** (`dart run`) and from
**Flutter** apps. A CLI-capable alternative to `universal_ble`, focused on using
a GATT characteristic pair like a serial port.

> Status: **in development.** Phase 1 (the pure-Dart core + serial abstraction +
> test fake) is done; native backends are landing one per iteration. See
> [`DESIGN.md`](DESIGN.md).

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

## The two packages

Same split as [`bluetooth_rfcomm`](../bluetooth_rfcomm): **`bluetooth_le`** is the
pure-Dart core (full API + Windows/Linux/macOS backends, CLI-friendly);
**`bluetooth_le_flutter`** (a Flutter plugin) supplies the Android native build
for Flutter apps and re-exports the API.

## Platform plan

| Platform | Backend | Distribution |
| --- | --- | --- |
| macOS / iOS | CoreBluetooth via an Obj-C C-ABI wrapper + `dart:ffi` | native-assets hook (iOS works for non-MFi devices) |
| Linux | BlueZ GATT over D-Bus (`package:dbus`) | pure Dart |
| Android | `BluetoothGatt` via Kotlin + C JNI shim | `bluetooth_le_flutter` |
| Windows | Win32 GATT C API via `dart:ffi` | pure Dart (paired devices; unpaired scan is a WinRT follow-up) |

## GATT-as-serial

`BleConnection.asSerial({service, writeCharacteristic, notifyCharacteristic})`
returns a `BleSerial`: `input` (a `Stream<Uint8List>` of notifications) plus
`add`/`write`/`flush` (writes chunked to the ATT payload, serialised to preserve
order). Defaults to the Nordic UART Service. Call `negotiateMtu()` to raise
throughput.

## Testing without hardware

`package:bluetooth_le/testing.dart` ships `FakeBleCentralPlatform`:

```dart
final fake = FakeBleCentralPlatform();
final ble = BleCentral(platform: fake);
```

## Logging

Via `package:logging` under `bluetooth_le.{scan,connection,gatt,data,adapter,native}`
(names in `BleLoggers`). No handler installed by default; see the
`bluetooth_rfcomm` README's Logging section for the same setup.
