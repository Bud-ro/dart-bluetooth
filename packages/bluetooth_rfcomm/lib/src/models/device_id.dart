import 'package:meta/meta.dart';

/// A stable, platform-appropriate identifier for a remote device.
///
/// On Windows, Linux, Android and macOS this is the 48-bit Bluetooth address
/// formatted as upper-case `AA:BB:CC:DD:EE:FF`. On iOS — and on recent macOS
/// where the address can be withheld — it is an opaque platform identifier
/// (e.g. an `EAAccessory.connectionID`-derived string). Treat it as an opaque
/// token for equality and lookup; only read [address] when [isAddress] is true.
@immutable
class DeviceId {
  /// Creates an identifier that is a real Bluetooth MAC address.
  ///
  /// [value] is normalised to upper-case colon-separated form.
  factory DeviceId.address(String value) {
    return DeviceId._(_normalizeAddress(value), isAddress: true);
  }

  /// Creates an opaque, platform-specific identifier (e.g. iOS).
  const DeviceId.opaque(String value) : _value = value, isAddress = false;

  const DeviceId._(this._value, {required this.isAddress});

  final String _value;

  /// Whether this id is a real Bluetooth MAC address (see [address]).
  final bool isAddress;

  /// The underlying identifier string (MAC address or opaque token).
  String get value => _value;

  /// The Bluetooth MAC address.
  ///
  /// Throws [StateError] when [isAddress] is false; check first.
  String get address {
    if (!isAddress) {
      throw StateError('DeviceId "$_value" is not a MAC address');
    }
    return _value;
  }

  static String _normalizeAddress(String raw) {
    final cleaned = raw.replaceAll('-', ':').toUpperCase().trim();
    // Accept already-formatted addresses and bare 12-hex-digit strings.
    if (cleaned.contains(':')) return cleaned;
    if (cleaned.length == 12) {
      final pairs = <String>[];
      for (var i = 0; i < 12; i += 2) {
        pairs.add(cleaned.substring(i, i + 2));
      }
      return pairs.join(':');
    }
    return cleaned;
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceId &&
      other._value == _value &&
      other.isAddress == isAddress;

  @override
  int get hashCode => Object.hash(_value, isAddress);

  @override
  String toString() => _value;
}
