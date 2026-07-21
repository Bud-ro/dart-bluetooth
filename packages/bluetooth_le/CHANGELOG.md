# Changelog

## 0.1.1

### Callback-lifetime hardening

- Apple: the connection/peripheral maps are now confined to the CoreBluetooth
  dispatch queue — they were previously mutated from Dart caller threads while
  CB delegate callbacks removed entries on the queue (NSMutableDictionary is
  not thread-safe; this was crash-capable). New `ble_reset` / `ble_and_reset`
  native entry points quiesce every event source at backend construction
  (Flutter hot-restart no longer risks native calls into the dead isolate's
  destroyed callback trampolines) and at `dispose()`, which now also releases
  the callables' isolate pin.
- Linux: a `subscribe` whose link drops mid-setup no longer `addError`s a
  closed controller (an unhandled-zone-error process killer); every D-Bus
  signal subscription now handles dispatcher errors (malformed BlueZ signals).

Reliability fixes from a deep code review (no API changes).

- Android: notification enable/disable (the CCCD descriptor write) now runs as
  a tracked GATT op that completes on `onDescriptorWrite`, so the next queued
  op no longer collides with the in-flight write and fails with device-busy
  (the mainline "listen then write" serial flow). Requires
  `bluetooth_le_flutter` >= 0.1.1 — the native `ble_and_subscribe` ABI gained a
  request id. A failed enable now surfaces on the subscribe stream.
- `BleSerial.input`: cancelling the last listener now really unsubscribes from
  the platform (disabling notifications on the peripheral, as documented), and
  listening again re-enables them.
- Linux: BlueZ StartDiscovery/StopDiscovery is now reference-counted and
  serialized across scan streams — cancelling one scan no longer kills a
  concurrent one, a second concurrent `startScan` no longer errors with
  `org.bluez.Error.InProgress`, and `stopScan()` closes live scan streams
  (matching Apple/Android). Cancelling a scan during startup can no longer
  leave the adapter discovering forever.
- Linux: `adapterStateChanges()` and `GattConnection.subscribe()` streams can
  be re-listened after all listeners cancelled (previously a one-way latch left
  them permanently silent).
- Apple/Android: a scan stream that fails to start now closes after the error,
  and notify controllers are closed (not just dropped) when their last listener
  cancels, so error-tolerant consumers and stale stream references see a
  terminal event instead of hanging.

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
