# Changelog

## 0.2.0

Reliability fixes from three deep review passes — no API changes beyond new
`BleLoggers.root` / `.loggers` / `.setLevel(...)` logging conveniences.

- Apple: write-without-response no longer reports success while CoreBluetooth
  silently drops chunks — writes are gated on `canSendWriteWithoutResponse`
  and queued until the peripheral is ready, so bulk `BleSerial` sends arrive
  intact. A failed notify enable now errors the subscribe stream instead of
  going silently dead; connecting with the adapter off throws
  `BleDisabledException` instead of hanging; cancelled pending connects no
  longer leak native wrappers; stopping a scan releases the peripherals a
  long scan accumulated.
- Apple: fixed a thread-safety race in the native connection bookkeeping that
  could crash on disconnect; hot restarts can no longer crash on stale native
  callbacks (new quiesce-on-construction/dispose).
- Android: enabling notifications no longer collides with the next GATT op
  (the CCCD write is now a tracked op) — the everyday "listen then write"
  serial flow works. `connect()` now throws `BleDisabledException` /
  `BlePermissionException` for adapter-off / missing-permission failures
  instead of a transient `DeviceNotFoundException` that invited endless
  retries. Needs `bluetooth_le_flutter` >= 0.1.1.
- Linux: concurrent scans no longer stop each other; streams can be
  re-listened after cancelling; a link drop during subscribe setup no longer
  kills the process. Scans now survive suspend/resume (a Powered/Discovering
  watch restarts discovery on power-on); BlueZ `NotReady` / `DoesNotExist`
  errors map to `BleDisabledException` / `DeviceNotFoundException`; one
  malformed manufacturer-data entry no longer hides a whole sighting; and
  `dispose()` no longer closes a caller-supplied `DBusClient`.
- Windows: `connect()` now runs its blocking Win32 calls on a worker isolate
  and honours the `timeout` parameter.
- `BleSerial.input`: bytes arriving while nobody listens are buffered (1 MiB
  bound, replayed in order to the next listener); notifications stay enabled
  until `close()` releases them; a backend whose subscribe throws (Windows)
  errors the stream instead of crashing the process.
- Lifecycle: `BleCentral.dispose()` disposes only a caller-injected platform
  (the process-shared backend survives the facade), and a backend's own
  `dispose()` vacates the shared platform slot so later use gets a fresh
  backend instead of a disposed, silent one.

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
