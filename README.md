# dart-bluetooth

Cross-platform Bluetooth for Dart and Flutter. One Dart API, usable from a pure
Dart CLI **and** from Flutter apps, with no Flutter dependency baked into the
core.

## Packages

| Package | Status | Description |
| --- | --- | --- |
| [`bluetooth_rfcomm`](packages/bluetooth_rfcomm) | implemented | Bluetooth Classic RFCOMM serial (read/write `Uint8List`). The full API + Windows, Linux and macOS backends. Pure Dart — CLI and Flutter desktop. |
| [`bluetooth_rfcomm_flutter`](packages/bluetooth_rfcomm_flutter) | implemented | Flutter plugin that adds the Android (and Apple) native builds for `bluetooth_rfcomm`. Add it to a Flutter app targeting Android/iOS. |
| [`bluetooth_le`](packages/bluetooth_le) | planned | Bluetooth Low Energy (GATT). The path for non-MFi devices on iOS. |
| `bluetooth_le_flutter` | planned | Flutter plugin companion for `bluetooth_le` (same split as above). |

## Why the split

pub.dev requires a `flutter:` SDK constraint for any package that declares a
Flutter plugin platform block — and that constraint makes a package unusable from
a pure-Dart `dart pub get`. So each capability is two packages: a pure-Dart core
(publishable, CLI-friendly, carries everything that doesn't need the Flutter
plugin mechanism) and a thin Flutter plugin that supplies the
mobile/Gradle/SPM-bound native builds and re-exports the core. Both halves
publish to pub.dev.

## Design highlights

- **Flutter-free core.** The core is raw `dart:ffi` + `package:dbus`, so
  `dart run` works for CLI tools and the same package drops into a Flutter app
  unchanged. `package:objective_c` and `package:jni` are deliberately avoided
  because both pull in the Flutter SDK.
- **Native code behind a C ABI.** macOS/iOS/Android native wrappers expose a
  plain C ABI called via `dart:ffi` + `NativeCallable`. Apple code is compiled
  from source by a native-assets `hook/build.dart` (for both CLI and Flutter);
  Android's JVM/Gradle build lives in the Flutter plugin. Nothing binary is
  committed.
- **Honest about iOS.** Bluetooth Classic on iOS requires an MFi accessory
  (hardware auth chip). Non-MFi devices must use the BLE package.

See [`packages/bluetooth_rfcomm`](packages/bluetooth_rfcomm) for the API.
