# Changelog

## 0.1.0 (in progress)

Initial development.

- Pure-Dart core (Phase 1): `BleCentral` facade, `BleConnection` (GATT
  discover/read/write/subscribe + MTU), and a `BleSerial` GATT-as-serial channel
  (duplex `Stream<Uint8List>` + `add`/`write`, defaulting to the Nordic UART
  service). Models (`BleDevice`, `BleScanResult`, `BleService`,
  `BleCharacteristic`, `Uuid`, `DeviceId`), a domain exception hierarchy with
  `isTransient`, namespaced `package:logging` loggers, and
  `FakeBleCentralPlatform` for tests.
- Native backends (macOS/iOS CoreBluetooth, Linux BlueZ, Android, Windows Win32
  GATT) are landing one per iteration; see `DESIGN.md`.
