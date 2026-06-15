# dart-bluetooth

Cross-platform Bluetooth for Dart and Flutter. One codebase, usable from a pure
Dart CLI **and** from Flutter apps, with no Flutter dependency baked into the
core.

## Packages

| Package | Status | Description |
| --- | --- | --- |
| [`bluetooth_classic`](packages/bluetooth_classic) | in progress | Bluetooth Classic RFCOMM serial (read/write `Uint8List`). Windows, macOS, Linux, Android, iOS. |
| [`bluetooth_le`](packages/bluetooth_le) | planned | Bluetooth Low Energy (GATT). The path for non-MFi devices on iOS. |

## Design highlights

- **One package, two runtimes.** The core is Flutter-free (raw `dart:ffi` +
  `package:dbus`), so `dart run` works for CLI tools and the same package drops
  into a Flutter app unchanged. `package:objective_c` and `package:jni` are
  deliberately avoided because both pull in the Flutter SDK.
- **Native code behind a C ABI.** macOS/iOS/Android native wrappers expose a
  plain C ABI called via `dart:ffi` + `NativeCallable`; built from source by a
  native-assets `hook/build.dart` for CLI and by the plugin's per-platform build
  files for Flutter. Nothing binary is committed.
- **Honest about iOS.** Bluetooth Classic on iOS requires an MFi accessory
  (hardware auth chip). Non-MFi devices must use the BLE package.

See [`packages/bluetooth_classic`](packages/bluetooth_classic) for the API.
