import 'dart:io';

import '../exceptions.dart';
import 'platform_interface.dart';

/// Selects the host-appropriate backend.
///
/// Backends are wired in per platform as they land (macOS/iOS CoreBluetooth,
/// Linux BlueZ, Android, Windows Win32 GATT). Until a platform's backend exists,
/// this throws — tests and early adopters inject a backend via
/// `BleCentral(platform: ...)` / `BleCentralPlatform.instance = ...`.
BleCentralPlatform createBlePlatform() {
  throw BleUnsupportedException(
    'No bluetooth_le backend for ${Platform.operatingSystem} yet',
  );
}
