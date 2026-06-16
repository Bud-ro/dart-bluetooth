# bluetooth_rfcomm_flutter

[![CI](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml/badge.svg)](https://github.com/Bud-ro/dart-bluetooth/actions/workflows/ci.yml)

Flutter plugin for [`bluetooth_rfcomm`](../bluetooth_rfcomm) — Bluetooth Classic
(RFCOMM serial) for Flutter apps.

`bluetooth_rfcomm` is a pure-Dart package and already works on its own for
Windows, Linux and macOS (CLI and Flutter desktop). **Android** needs a JVM +
Gradle build for its Kotlin/JNI bridge, which can't be a Dart native asset — this
plugin provides it, and bundles the native library into your APK. iOS/macOS
native code is built from `bluetooth_rfcomm`'s own native-assets hook, so this
plugin covers the gap that hook can't.

Add it to any Flutter app that targets **Android or iOS**; desktop-only Flutter
apps can depend on `bluetooth_rfcomm` directly.

## Install

```yaml
dependencies:
  bluetooth_rfcomm: ^0.1.0
  bluetooth_rfcomm_flutter: ^0.1.0
```

## Usage

There is no separate API — this package re-exports `bluetooth_rfcomm`:

```dart
import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';

final bt = BluetoothRfcomm.instance;
final paired = await bt.bondedDevices();
final conn = await bt.connect(paired.first);
```

See the [`bluetooth_rfcomm` README](../bluetooth_rfcomm/README.md) for the full
API, platform setup (permissions, `Info.plist` keys), and the iOS MFi caveat.

A runnable Flutter demo is in [`example/`](example).
