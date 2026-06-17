# bluetooth_rfcomm_flutter

[![CI](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml/badge.svg)](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml)

The Flutter plugin for **Bluetooth Classic (RFCOMM serial)**. It adds the native
build that Android and iOS need and re-exports the
[`bluetooth_rfcomm`](https://pub.dev/packages/bluetooth_rfcomm) API, so there is
no separate Dart surface to learn.

[`bluetooth_rfcomm`](https://pub.dev/packages/bluetooth_rfcomm) is pure Dart and
works on its own for Linux, macOS and Windows (command-line and Flutter desktop).
Android needs a JVM + Gradle build for its Kotlin/JNI bridge, which can't ship as
a Dart-only package — this plugin provides it and bundles the native library into
your app. Add this plugin to any Flutter app that targets **Android or iOS**;
desktop-only Flutter apps can depend on `bluetooth_rfcomm` directly.

## Support

| Platform | RFCOMM serial |
| --- | --- |
| Android | ✅ |
| iOS | ⚠️ |

✅ supported · ⚠️ partial · ❌ not supported

iOS reaches only MFi accessories; a non-MFi device throws
`BluetoothUnsupportedException`. (Linux, macOS and Windows are handled by the
`bluetooth_rfcomm` core directly.)

## Install

```yaml
dependencies:
  bluetooth_rfcomm: ^0.1.0
  bluetooth_rfcomm_flutter: ^0.1.0
```

## Usage

Import `bluetooth_rfcomm` and use it exactly as in a pure-Dart app:

```dart
import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';

final bt = BluetoothRfcomm.instance;
final paired = await bt.bondedDevices();
final conn = await bt.connect(paired.first);
```

The full API, the connection model, platform setup (Android runtime permissions,
iOS `Info.plist` keys and the MFi caveat), logging control, and the test fake are
documented in the
[`bluetooth_rfcomm` README](https://pub.dev/packages/bluetooth_rfcomm). A runnable
Flutter demo is in [`example/`](example).

## License

BSD 3-Clause. See [LICENSE](LICENSE).
