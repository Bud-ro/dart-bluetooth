import 'dart:io';

import '../exceptions.dart';
import 'android/android_central.dart';
import 'apple/apple_central.dart';
import 'linux/linux_central.dart';
import 'platform_interface.dart';

/// Selects the host-appropriate backend.
///
/// Backends are wired in per platform as they land. Until a platform's backend
/// exists, this throws — tests and early adopters inject a backend via
/// `BleCentral(platform: ...)` / `BleCentralPlatform.instance = ...`.
BleCentralPlatform createBlePlatform() {
  if (Platform.isMacOS || Platform.isIOS) return AppleBleCentral();
  if (Platform.isLinux) return LinuxBleCentral();
  if (Platform.isAndroid) return AndroidBleCentral();
  throw BleUnsupportedException(
    'No bluetooth_le backend for ${Platform.operatingSystem} yet',
  );
}
