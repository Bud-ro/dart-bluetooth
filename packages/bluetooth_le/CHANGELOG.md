# Changelog

## 0.1.0

Initial release.

- Pure-Dart core: `BleCentral` facade, `BleConnection` (GATT
  discover/read/write/subscribe + MTU), and a `BleSerial` GATT-as-serial channel
  (duplex `Stream<Uint8List>` + `add`/`write`, defaulting to the Nordic UART
  service). Models (`BleDevice`, `BleScanResult`, `BleService`,
  `BleCharacteristic`, `Uuid`, `DeviceId`), a domain exception hierarchy with
  `isTransient`, namespaced `package:logging` loggers, and
  `FakeBleCentralPlatform` for tests.
- Native backends: macOS/iOS (CoreBluetooth), Linux (BlueZ over D-Bus), Android
  (Kotlin `BluetoothGatt` + JNI, via `bluetooth_le_flutter`), and Windows (Win32
  GATT). Windows is paired-devices-only (no unpaired scan or notifications). The
  native paths are pending broader on-device validation.
