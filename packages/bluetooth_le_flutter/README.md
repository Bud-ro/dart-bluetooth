# bluetooth_le_flutter

Flutter plugin companion for [`bluetooth_le`](../bluetooth_le). It provides the
native builds `bluetooth_le` needs on mobile and re-exports the same API — there
is no separate Dart surface.

## What it does

- **Android**: builds the Kotlin `BluetoothGatt` backend + its JNI C shim
  (Gradle/CMake) into `libbluetooth_le_android.so` and bundles it into your APK.
- **iOS / macOS**: the CoreBluetooth code asset is built from `bluetooth_le`'s
  own native-assets hook (not declared here).
- **Windows / Linux desktop**: no native build — pure Dart (Win32 GATT FFI /
  BlueZ over D-Bus).

## Usage

```yaml
dependencies:
  bluetooth_le: ^0.1.0
  bluetooth_le_flutter: ^0.1.0
```

```dart
import 'package:bluetooth_le/bluetooth_le.dart';
// or: import 'package:bluetooth_le_flutter/bluetooth_le_flutter.dart';

final ble = BleCentral.instance;
```

Use [`BleCentral`] exactly as in a pure-Dart app.

## Android permissions

The host app must request the runtime BLE permissions before scanning or
connecting: `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` on Android 12+ (API 31+),
or location on older versions. The plugin declares them in its manifest, but the
runtime grant is the app's responsibility.
