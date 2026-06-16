/// Flutter integration for `bluetooth_rfcomm`.
///
/// Adding this package to a Flutter app pulls in the native builds the
/// `bluetooth_rfcomm` backends need on mobile: the Android JNI/Kotlin library
/// (built here via Gradle + CMake) and the Apple IOBluetooth/ExternalAccessory
/// code assets (built from `bluetooth_rfcomm`'s own build hook). Windows, Linux
/// and macOS desktop need no native build.
///
/// There is no separate API: import `package:bluetooth_rfcomm/bluetooth_rfcomm.dart`
/// (re-exported below) and use [BluetoothRfcomm] exactly as in a pure-Dart app.
library;

export 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
