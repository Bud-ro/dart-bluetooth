# bluetooth_le — design (planned)

A sibling to `bluetooth_rfcomm` for Bluetooth **Low Energy** (GATT). Deferred;
this document records the intended shape so the two packages stay coherent.

## Why a separate package

BLE is largely orthogonal to Classic RFCOMM: it's GATT (services →
characteristics → notify/read/write) rather than a serial byte stream, and it
uses different native APIs. Keeping it separate avoids forcing a serial
abstraction onto GATT and lets apps depend on only what they use. The two
packages use distinct OS APIs and can run side by side; the **only** shared
resource is adapter power state — apps should not toggle the radio from both.

## Why BLE matters for this project

It is the **only** App-Store-shippable path to a non-MFi device on **iOS**
(Classic SPP there requires MFi hardware — see the `bluetooth_rfcomm` README).
For a custom non-MFi board, expose a GATT "serial" service (e.g. the Nordic UART
service, or `CBL2CAPChannel` for a true stream) and talk to it via this package.

## Native APIs (same Flutter-free strategy as bluetooth_rfcomm)

| Platform | API | Dart binding |
| --- | --- | --- |
| macOS / iOS | Core Bluetooth (`CBCentralManager`, `CBPeripheral`, `CBL2CAPChannel`) | Obj-C C-ABI wrapper + `dart:ffi` + `NativeCallable`, built by the native-assets hook / SPM |
| Windows | WinRT `Windows.Devices.Bluetooth.GenericAttributeProfile` | `dart:ffi` (WinRT projection) — heavier than Classic's Winsock; evaluate `win32`/`windows_foundation` |
| Linux | BlueZ GATT over D-Bus (`org.bluez.GattService1` / `GattCharacteristic1`) | pure Dart `package:dbus` |
| Android | `BluetoothLeScanner` / `BluetoothGatt` (Kotlin) | Kotlin + C JNI shim, same pattern as Classic |

## Proposed API sketch

```dart
final ble = BluetoothLe.instance;
final scan = ble.scan(withServices: [Uuid('180d')]);          // Stream<LeScanResult>
final device = await scan.firstWhere((r) => r.name == 'My Board');
final peripheral = await ble.connect(device.id);
final services = await peripheral.discoverServices();
final tx = services.characteristic(svc, txUuid);
await tx.write(bytes, withResponse: false);
peripheral.characteristic(svc, rxUuid).notifications.listen(onData); // Stream<Uint8List>
```

## Shared types

When BLE lands, factor `DeviceId`, `Uuid`, `BluetoothAdapterState`, and the
exception hierarchy into a `bluetooth_common` package that both depend on, rather
than duplicating. Until then `bluetooth_rfcomm` owns them.

## Reference

`flutter_blue_plus` is the mature prior art for the API shape and stream
semantics (streams that don't error/close, per-device queuing). Learn from it;
we additionally keep the package Flutter-free for CLI use.
