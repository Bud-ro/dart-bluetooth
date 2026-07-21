# Changelog

## 0.1.1

Reliability fixes from two deep review passes — no API changes beyond new
`BleLoggers.root` / `.loggers` / `.setLevel(...)` logging conveniences.

- Android: enabling notifications no longer collides with the next GATT op
  (the CCCD write is now a tracked op) — the everyday "listen then write"
  serial flow works. Needs `bluetooth_le_flutter` >= 0.1.1.
- Apple: fixed a thread-safety race in the native connection bookkeeping that
  could crash on disconnect; hot restarts can no longer crash on stale native
  callbacks (new quiesce-on-construction/dispose).
- Linux: concurrent scans no longer stop each other; streams can be
  re-listened after cancelling; a link drop during subscribe setup no longer
  kills the process.
- `BleSerial.input`: the last listener cancelling now really disables
  notifications, and re-listening re-enables them.

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
