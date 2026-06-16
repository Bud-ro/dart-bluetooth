import 'dart:io';

import '../exceptions.dart';
import 'linux/linux_platform.dart';
import 'macos/macos_platform.dart';
import 'platform_interface.dart';
import 'windows/windows_platform.dart';

/// Selects the backend for the current host OS.
///
/// Desktop targets are pure-Dart (FFI / D-Bus). macOS, Android and iOS load a
/// native C-ABI library via FFI; those backends are constructed lazily so that,
/// e.g., the Linux build never touches the macOS bindings.
BluetoothClassicPlatform createDefaultPlatform() {
  if (Platform.isLinux) return LinuxBluetoothClassic();
  if (Platform.isWindows) return WindowsBluetoothClassic();
  if (Platform.isMacOS) return MacosBluetoothClassic();
  if (Platform.isIOS || Platform.isAndroid) {
    // iOS (ExternalAccessory) and Android (Kotlin + JNI shim) backends land
    // with the mobile native sources.
    throw BluetoothUnsupportedException(
      'The ${Platform.operatingSystem} backend is not wired into this build '
      'yet.',
    );
  }
  throw BluetoothUnsupportedException(
    'Unsupported platform: ${Platform.operatingSystem}',
  );
}
