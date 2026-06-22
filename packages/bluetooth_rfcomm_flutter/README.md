# bluetooth_rfcomm_flutter

[![CI](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml/badge.svg)](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml)

The Flutter plugin for **Bluetooth Classic (RFCOMM serial)**. It adds the
**Android** native build and re-exports the
[`bluetooth_rfcomm`](https://pub.dev/packages/bluetooth_rfcomm) API, so there is
no separate Dart surface to learn.

Android needs a JVM + Gradle build for its Kotlin/JNI bridge, which can't ship as
a Dart-only package — this plugin provides it and bundles the native library into
your app. Everything else is handled by the
[`bluetooth_rfcomm`](https://pub.dev/packages/bluetooth_rfcomm) core directly:
Linux and Windows are pure Dart, and **iOS and macOS** are compiled by the core's
native-assets build hook (for both CLI and Flutter — there is no separate iOS
plugin here). Add this plugin to a Flutter app that targets **Android**; an
iOS-only or desktop-only Flutter app can depend on `bluetooth_rfcomm` directly.

## Support

| Platform | RFCOMM serial | Manually verified |
| --- | --- | --- |
| Android | ✅ | ❌ |
| iOS | ⚠️ | ❌ |

In the capability column: ✅ supported · ⚠️ partial · ❌ not supported.

**Manually verified** — whether the author has exercised this backend on real
hardware: ⚠️ = yes (works well enough for the author, but **not guaranteed to be
perfect**); ❌ = **not yet hardware-verified** (implemented, but its effectiveness
has not been confirmed by the author).

> ⚠️ Neither the Android nor the iOS backend has been manually verified on a
> device yet — treat both as best-effort for now. Of the `bluetooth_rfcomm`
> backends, only **macOS** and **Windows** (provided by the pure-Dart core, used
> on desktop) currently carry any manual verification. Every backend will be
> verified on hardware over time.

This plugin builds only the Android native library. The iOS backend (and the
macOS, Linux and Windows backends) all come from the `bluetooth_rfcomm` core —
iOS and macOS via its native-assets build hook, Linux and Windows as pure Dart.

iOS reaches only MFi accessories; a non-MFi device throws
`BluetoothUnsupportedException`.

## Install

```yaml
dependencies:
  bluetooth_rfcomm: ^0.1.1
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
Flutter demo is in [`example/`](https://github.com/Bud-ro/dart-bluetooth/tree/master/packages/bluetooth_rfcomm_flutter/example).

## License

BSD 3-Clause. See [LICENSE](LICENSE).
