/// Base class for every error this package throws.
///
/// Platform layers translate native error codes into these domain types so
/// callers never branch on platform-specific values. The original detail is
/// preserved in [code] and [cause].
class BleException implements Exception {
  const BleException(this.message, {this.code, this.cause});

  /// Human-readable description of what went wrong.
  final String message;

  /// Platform-specific error code, when available (errno, HRESULT, NSError code,
  /// BlueZ error name, GATT status, …). Type is platform-defined.
  final Object? code;

  /// The underlying error/exception, when this wraps another failure.
  final Object? cause;

  /// Whether retrying the operation (e.g. a reconnect loop) might succeed.
  bool get isTransient => false;

  String get _label => runtimeType.toString();

  @override
  String toString() {
    final b = StringBuffer('$_label: $message');
    if (code != null) b.write(' (code: $code)');
    if (cause != null) b.write('\n  caused by: $cause');
    return b.toString();
  }
}

/// The requested operation, platform, or device capability is not supported.
class BleUnsupportedException extends BleException {
  const BleUnsupportedException(super.message, {super.code, super.cause});
}

/// The app lacks the runtime permission / entitlement needed (e.g. Android
/// `BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT`, macOS/iOS Bluetooth privacy/TCC).
class BlePermissionException extends BleException {
  const BlePermissionException(super.message, {super.code, super.cause});
}

/// The local Bluetooth adapter is powered off or otherwise unavailable.
class BleDisabledException extends BleException {
  const BleDisabledException(super.message, {super.code, super.cause});
}

/// Establishing or maintaining a GATT connection failed.
class BleConnectionException extends BleException {
  const BleConnectionException(super.message, {super.code, super.cause});

  @override
  bool get isTransient => true;
}

/// An operation exceeded its allotted [timeout].
class BleTimeoutException extends BleException {
  const BleTimeoutException(
    super.message, {
    this.timeout,
    super.code,
    super.cause,
  });

  final Duration? timeout;

  @override
  bool get isTransient => true;
}

/// The referenced device could not be found (out of range, gone).
class DeviceNotFoundException extends BleException {
  const DeviceNotFoundException(super.message, {super.code, super.cause});

  @override
  bool get isTransient => true;
}

/// Device discovery (scanning) failed to start or run.
class BleScanException extends BleException {
  const BleScanException(super.message, {super.code, super.cause});
}

/// A GATT read/write/subscribe operation failed.
class BleGattException extends BleException {
  const BleGattException(super.message, {super.code, super.cause});
}

/// The requested GATT service was not found on the connected device.
class ServiceNotFoundException extends BleException {
  const ServiceNotFoundException(super.message, {super.code, super.cause});
}

/// The requested GATT characteristic was not found in its service.
class CharacteristicNotFoundException extends BleException {
  const CharacteristicNotFoundException(
    super.message, {
    super.code,
    super.cause,
  });
}
