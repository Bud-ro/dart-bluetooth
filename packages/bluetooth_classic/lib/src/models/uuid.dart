import 'package:meta/meta.dart';

/// A Bluetooth service UUID.
///
/// Accepts either the 128-bit canonical form
/// (`00001101-0000-1000-8000-00805F9B34FB`) or a 16-/32-bit short form
/// (`1101`, `0x1101`), which is expanded against the Bluetooth Base UUID.
@immutable
class Uuid {
  factory Uuid(String value) {
    return Uuid._(_normalize(value));
  }

  const Uuid._(this.value);

  /// The full 128-bit lower-case canonical representation.
  final String value;

  /// The Serial Port Profile (SPP) UUID — the default for RFCOMM serial.
  static final Uuid spp = Uuid('00001101-0000-1000-8000-00805F9B34FB');

  /// 16-bit Bluetooth SIG base used to expand short UUIDs.
  static const String _baseSuffix = '-0000-1000-8000-00805f9b34fb';

  static String _normalize(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.startsWith('0x')) s = s.substring(2);
    if (s.contains('-')) {
      if (s.length != 36) {
        throw FormatException('Invalid 128-bit UUID: $raw');
      }
      return s;
    }
    // Short (16/32-bit) form: pad to 8 hex digits then append the base.
    if (s.length > 8 || s.isEmpty || int.tryParse(s, radix: 16) == null) {
      throw FormatException('Invalid short UUID: $raw');
    }
    final padded = s.padLeft(8, '0');
    return '$padded$_baseSuffix';
  }

  /// The 16-bit short id if this UUID lies in the SIG base range, else null.
  int? get short {
    if (!value.endsWith(_baseSuffix)) return null;
    final prefix = value.substring(0, 8);
    final n = int.parse(prefix, radix: 16);
    return n <= 0xFFFF ? n : null;
  }

  @override
  bool operator ==(Object other) => other is Uuid && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
