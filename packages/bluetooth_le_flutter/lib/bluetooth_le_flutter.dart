/// Flutter integration for `bluetooth_le`.
///
/// Adding this package to a Flutter app pulls in the native builds the
/// `bluetooth_le` backends need on mobile: the Android JNI/Kotlin library (built
/// here via Gradle + CMake) and the Apple CoreBluetooth code asset (built from
/// `bluetooth_le`'s own build hook). Windows, Linux and macOS desktop need no
/// extra native build.
///
/// There is no separate API: import `package:bluetooth_le/bluetooth_le.dart`
/// (re-exported below) and use [BleCentral] exactly as in a pure-Dart app.
library;

export 'package:bluetooth_le/bluetooth_le.dart';
