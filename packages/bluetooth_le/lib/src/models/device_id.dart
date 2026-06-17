import 'package:meta/meta.dart';

/// A platform-appropriate identifier for a remote BLE device.
///
/// On Windows, Linux and Android this is the 48-bit Bluetooth address formatted
/// as upper-case `AA:BB:CC:DD:EE:FF` — stable, safe to persist. On macOS and iOS
/// it is an opaque `CBPeripheral.identifier` (a per-host UUID) that is **not** a
/// MAC and is host-scoped; persisting it is fine on the same device but it won't
/// match across machines. Use [isPersistent] / [isAddress] to tell them apart;
/// treat the value as an opaque token for equality and lookup.
@immutable
class DeviceId {
  /// Creates an identifier that is a real Bluetooth MAC address.
  ///
  /// [value] is normalised to upper-case colon-separated form.
  factory DeviceId.address(String value) {
    return DeviceId._(_normalizeAddress(value), isAddress: true);
  }

  /// Creates an opaque, platform-specific identifier (e.g. a CoreBluetooth UUID).
  const DeviceId.opaque(String value) : _value = value, isAddress = false;

  const DeviceId._(this._value, {required this.isAddress});

  final String _value;

  /// Whether this id is a real Bluetooth MAC address (see [address]).
  final bool isAddress;

  /// Whether this id is safe to persist and reuse across sessions on this host.
  bool get isPersistent => true;

  /// The underlying identifier string (MAC address or opaque token).
  String get value => _value;

  /// The Bluetooth MAC address. Throws [StateError] when [isAddress] is false.
  String get address {
    if (!isAddress) {
      throw StateError('DeviceId "$_value" is not a MAC address');
    }
    return _value;
  }

  static String _normalizeAddress(String raw) {
    final cleaned = raw.trim().replaceAll('-', ':').toUpperCase();
    final String colonForm;
    if (cleaned.contains(':')) {
      colonForm = cleaned;
    } else if (cleaned.length == 12) {
      final pairs = <String>[];
      for (var i = 0; i < 12; i += 2) {
        pairs.add(cleaned.substring(i, i + 2));
      }
      colonForm = pairs.join(':');
    } else {
      throw FormatException('Invalid Bluetooth address: $raw');
    }
    final parts = colonForm.split(':');
    final valid =
        parts.length == 6 &&
        parts.every((p) => p.length == 2 && int.tryParse(p, radix: 16) != null);
    if (!valid) {
      throw FormatException('Invalid Bluetooth address: $raw');
    }
    return colonForm;
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
