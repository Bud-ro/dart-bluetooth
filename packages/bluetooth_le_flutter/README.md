# bluetooth_le_flutter

[![CI](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml/badge.svg)](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml)

The Flutter plugin for **Bluetooth Low Energy (GATT)**. It adds the native build
that Android and iOS need and re-exports the
[`bluetooth_le`](https://pub.dev/packages/bluetooth_le) API, so there is no
separate Dart surface to learn.

[`bluetooth_le`](https://pub.dev/packages/bluetooth_le) is pure Dart and works on
its own for Linux, macOS and Windows (command-line and Flutter desktop). Android
needs a JVM + Gradle build for its Kotlin `BluetoothGatt` + JNI bridge, which
can't ship as a Dart-only package — this plugin provides it and bundles the
native library into your app. Add this plugin to any Flutter app that targets
**Android or iOS**; desktop-only Flutter apps can depend on `bluetooth_le`
directly.

## Support

| Platform | Scan | Connect + read/write | Notifications | Manually verified |
| --- | --- | --- | --- | --- |
| Android | ✅ | ✅ | ✅ | ❌ |
| iOS | ✅ | ✅ | ✅ | ❌ |

In the capability columns: ✅ supported · ⚠️ partial · ❌ not supported.

**Manually verified** — whether the author has exercised this backend on real
hardware: ❌ = **not yet hardware-verified**.

> ⚠️ **No `bluetooth_le` backend has been manually verified on real hardware
> yet** (neither these Flutter platforms nor the core's desktop backends). Every
> backend is implemented but unverified — treat it all as best-effort for now.
> The backends will be verified on hardware over time.

(Linux, macOS and Windows are handled by the `bluetooth_le` core directly.)

## Install

```yaml
dependencies:
  bluetooth_le: ^0.1.0
  bluetooth_le_flutter: ^0.1.0
```

## Usage

Import `bluetooth_le` and use it exactly as in a pure-Dart app:

```dart
import 'package:bluetooth_le/bluetooth_le.dart';

final ble = BleCentral.instance;
final hit = await ble.startScan(withServices: [Uuid.nordicUartService]).first;
final conn = await ble.connect(hit.device);
final serial = conn.asSerial();
```

The full API, the GATT-as-serial channel, platform setup (Android runtime
permissions, iOS `Info.plist` keys), logging control, and the test fake are
documented in the
[`bluetooth_le` README](https://pub.dev/packages/bluetooth_le). A runnable Flutter
demo is in [`example/`](https://github.com/Bud-ro/dart-bluetooth/tree/master/packages/bluetooth_le_flutter/example).

## License

BSD 3-Clause. See [LICENSE](LICENSE).
