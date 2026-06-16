# bluetooth_le — design

A sibling to `bluetooth_rfcomm` for Bluetooth **Low Energy** (GATT). In progress
(Phase 1). Shipped as two packages, exactly like RFCOMM:

- **`bluetooth_le`** — pure-Dart core (full API + Windows/Linux/macOS backends).
  Publishable, usable from a `dart run` CLI.
- **`bluetooth_le_flutter`** — Flutter plugin providing the Android native build
  (Apple uses the core's native-assets hook); re-exports the core API.

## vs. `universal_ble`

`universal_ble` is the capable cross-platform BLE plugin, but it is **exclusively
a Flutter plugin** (MethodChannel on every platform; no pure-Dart/CLI path). This
package's differentiators: (1) **pure-Dart CLI** support alongside Flutter, and
(2) a first-class **GATT-as-serial** channel — a duplex `Stream<Uint8List>` + sink
over an RX(notify)/TX(write) characteristic pair (defaulting to the Nordic UART
service), mirroring RFCOMM's `BluetoothConnection`. Raw GATT (read/write/notify)
is also exposed for general use.

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
| Windows | Win32 GATT C API (`BluetoothGATT*`, `bluetoothleapis.h`) | pure-Dart `dart:ffi` — chosen over WinRT to stay CLI-friendly (no C++/WinRT build). Covers connect/read/write/notify to paired devices; unpaired-device *scanning* (advertisement watcher) is WinRT-only and a documented follow-up |
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

`Uuid`, the adapter-state enum, and the exception-hierarchy *shape* are copied
from `bluetooth_rfcomm` (not a shared dependency) so BLE stays a self-contained
codebase. A `bluetooth_common` package can be factored out later if it earns it.

## Build sequence (one backend per iteration, CI-validated)

1. Pure-Dart core: models, exceptions, `Uuid`, platform interface, `BleCentral`
   facade, the GATT-as-serial abstraction, `FakeBleCentralPlatform`, unit tests.
2. macOS + iOS — one shared CoreBluetooth Obj-C C-ABI wrapper (native assets).
3. Linux — BlueZ GATT over D-Bus.
4. Android — `BluetoothGatt` via Kotlin + JNI shim.
5. Windows — Win32 GATT FFI.
6. CI (per-push build/launch) + manual real-backend integration workflow + the
   multi-axis `/loop` review until clean.

## Reference

`flutter_blue_plus` is the mature prior art for the API shape and stream
semantics (streams that don't error/close, per-device queuing). Learn from it;
we additionally keep the package Flutter-free for CLI use.
