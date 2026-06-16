import 'dart:io';

import '../exceptions.dart';
import 'android/android_platform.dart';
import 'ios/ios_platform.dart';
import 'linux/linux_platform.dart';
import 'macos/macos_platform.dart';
import 'platform_interface.dart';
import 'windows/windows_platform.dart';

/// Selects the backend for the current host OS.
///
/// Desktop targets are pure-Dart (FFI / D-Bus). macOS, Android and iOS load a
/// native C-ABI library via FFI; those backends are constructed lazily so that,
/// e.g., the Linux build never touches the macOS bindings.
BluetoothRfcommPlatform createDefaultPlatform() {
  if (Platform.isLinux) return LinuxBluetoothRfcomm();
  if (Platform.isWindows) return WindowsBluetoothRfcomm();
  if (Platform.isMacOS) return MacosBluetoothRfcomm();
  if (Platform.isIOS) return IosBluetoothRfcomm();
  if (Platform.isAndroid) return AndroidBluetoothRfcomm();
  throw BluetoothUnsupportedException(
    'Unsupported platform: ${Platform.operatingSystem}',
  );
}
