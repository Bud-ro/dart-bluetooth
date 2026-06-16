/// Base class for every error this package throws.
///
/// Platform layers translate native error codes into these domain types so
/// callers never have to branch on platform-specific errno/HRESULT/NSError
/// values. The original platform detail is preserved in [code] and [cause].
class BluetoothException implements Exception {
  const BluetoothException(this.message, {this.code, this.cause});

  /// Human-readable description of what went wrong.
  final String message;

  /// Platform-specific error code, when one is available (errno, HRESULT,
  /// NSError code, BlueZ error name, …). Type is platform-defined.
  final Object? code;

  /// The underlying error/exception, when this wraps another failure.
  final Object? cause;

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
///
/// Notably thrown on iOS when targeting a non-MFi device: Apple's
/// ExternalAccessory framework only surfaces accessories containing the MFi
/// authentication coprocessor. Use the BLE package for non-MFi devices on iOS.
class BluetoothUnsupportedException extends BluetoothException {
  const BluetoothUnsupportedException(super.message, {super.code, super.cause});
}

/// The app lacks the runtime permission / entitlement needed (e.g. Android
/// `BLUETOOTH_CONNECT`/`BLUETOOTH_SCAN`, macOS/iOS Bluetooth privacy/TCC).
class BluetoothPermissionException extends BluetoothException {
  const BluetoothPermissionException(super.message, {super.code, super.cause});
}

/// The local Bluetooth adapter is powered off or otherwise unavailable.
class BluetoothDisabledException extends BluetoothException {
  const BluetoothDisabledException(super.message, {super.code, super.cause});
}

/// Establishing or maintaining a connection failed.
class BluetoothConnectionException extends BluetoothException {
  const BluetoothConnectionException(super.message, {super.code, super.cause});
}

/// An operation exceeded its allotted [timeout].
class BluetoothTimeoutException extends BluetoothException {
  const BluetoothTimeoutException(
    super.message, {
    this.timeout,
    super.code,
    super.cause,
  });

  final Duration? timeout;
}

/// Writing to a connection failed (peer closed, buffer error, …).
class BluetoothWriteException extends BluetoothException {
  const BluetoothWriteException(super.message, {super.code, super.cause});
}

/// Device discovery (inquiry) failed to start or run.
class BluetoothDiscoveryException extends BluetoothException {
  const BluetoothDiscoveryException(super.message, {super.code, super.cause});
}

/// The referenced device could not be found (not bonded, out of range, gone).
class DeviceNotFoundException extends BluetoothException {
  const DeviceNotFoundException(super.message, {super.code, super.cause});
}

/// No RFCOMM channel was found for the requested service UUID via SDP.
///
/// Either the device does not advertise that service, or you should pass an
/// explicit `channel` to `connect`.
class ServiceNotFoundException extends BluetoothException {
  const ServiceNotFoundException(super.message, {super.code, super.cause});
}
