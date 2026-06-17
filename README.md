# dart-bluetooth

Cross-platform Bluetooth for Dart and Flutter. One Dart API per capability,
usable from a pure-Dart CLI (`dart run`) and from Flutter apps, with no Flutter
dependency baked into the core.

Two capabilities are covered, each as a pair of packages (a pure-Dart core plus a
Flutter plugin — see [Why the split](#why-the-split)):

- **Bluetooth Classic (RFCOMM serial)** — read/write `Uint8List` over a serial
  link: [`bluetooth_rfcomm`](packages/bluetooth_rfcomm) +
  [`bluetooth_rfcomm_flutter`](packages/bluetooth_rfcomm_flutter).
- **Bluetooth Low Energy (GATT)** — connect, read/write/subscribe, and a
  GATT-as-serial channel: [`bluetooth_le`](packages/bluetooth_le) +
  [`bluetooth_le_flutter`](packages/bluetooth_le_flutter).

## Support

| Platform | Classic (RFCOMM) | Low Energy (GATT) |
| --- | --- | --- |
| Linux | ✅ | ✅ |
| macOS | ✅ | ✅ |
| Windows | ✅ | ⚠️ |
| Android | ✅ | ✅ |
| iOS | ⚠️ | ✅ |

✅ supported · ⚠️ partial · ❌ not supported

Notes:

- **iOS, Classic** — Bluetooth Classic on iOS only reaches MFi accessories
  (devices with Apple's authentication coprocessor). For anything else on iOS,
  use BLE.
- **Windows, BLE** — the current Win32 GATT backend reaches already-paired
  devices (connect, read, write, service discovery). Unpaired-device scanning and
  notifications are the next step (planned via WinRT, keeping the pure-Dart/CLI
  goal). Until then, pair the device in Windows settings and connect by address.

## Packages

| Package | Description |
| --- | --- |
| [`bluetooth_rfcomm`](packages/bluetooth_rfcomm) | Bluetooth Classic RFCOMM serial — full API plus the Linux, macOS and Windows backends. Pure Dart: CLI and Flutter desktop. |
| [`bluetooth_rfcomm_flutter`](packages/bluetooth_rfcomm_flutter) | Flutter plugin that adds the Android (and iOS) native build for `bluetooth_rfcomm`. |
| [`bluetooth_le`](packages/bluetooth_le) | Bluetooth Low Energy (GATT) with a GATT-as-serial channel — full API plus the Linux, macOS and Windows backends. Pure Dart: CLI and Flutter desktop. |
| [`bluetooth_le_flutter`](packages/bluetooth_le_flutter) | Flutter plugin that adds the Android (and iOS) native build for `bluetooth_le`. |

## Why the split

pub.dev requires a `flutter:` SDK constraint for any package that declares a
Flutter plugin platform block, and that constraint makes the package unusable
from a pure-Dart `dart pub get`. So each capability is two packages: a pure-Dart
core (publishable, CLI-friendly, carrying everything that doesn't need the Flutter
plugin mechanism) and a thin Flutter plugin that supplies the mobile native
builds and re-exports the core. Both halves publish to pub.dev; a CLI or desktop
project depends on the core alone, and a Flutter app targeting Android/iOS adds
the plugin.

## Design

- **Flutter-free core.** The cores use raw `dart:ffi` and `package:dbus`, so the
  same package runs under `dart run` and drops into a Flutter app unchanged.
- **Native code behind a C ABI.** Apple and Android native code sits behind a
  hand-written C ABI called via `dart:ffi` + `NativeCallable`. Apple sources are
  compiled by a native-assets build hook (for both CLI and Flutter); the Android
  JVM/Gradle build lives in each Flutter plugin. Linux and Windows are pure Dart
  (D-Bus and Win32 system APIs).

## License

BSD 3-Clause. See [LICENSE](LICENSE).
