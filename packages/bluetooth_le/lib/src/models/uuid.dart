import 'package:meta/meta.dart';

/// A Bluetooth GATT UUID (service, characteristic, or descriptor).
///
/// Accepts either the 128-bit canonical form
/// (`6e400001-b5a3-f393-e0a9-e50e24dcca9e`) or a 16-/32-bit short form
/// (`180d`, `0x180d`), which is expanded against the Bluetooth Base UUID.
@immutable
class Uuid {
  factory Uuid(String value) {
    return Uuid._(_normalize(value));
  }

  const Uuid._(this.value);

  /// The full 128-bit lower-case canonical representation.
  final String value;

  /// Nordic UART Service (NUS) — the de-facto "BLE serial" service. The default
  /// for [BleConnection.asSerial].
  static final Uuid nordicUartService = Uuid(
    '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
  );

  /// NUS RX characteristic (write, no response): data the central sends TO the
  /// peripheral. Use this as the serial **write** characteristic.
  static final Uuid nordicUartRx = Uuid('6e400002-b5a3-f393-e0a9-e50e24dcca9e');

  /// NUS TX characteristic (notify): data the peripheral sends back to the
  /// central. Use this as the serial **notify** (input) characteristic.
  static final Uuid nordicUartTx = Uuid('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  /// 16-bit Bluetooth SIG base used to expand short UUIDs.
  static const String _baseSuffix = '-0000-1000-8000-00805f9b34fb';

  static final RegExp _canonical128 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  static String _normalize(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.startsWith('0x')) s = s.substring(2);
    if (s.contains('-')) {
      if (!_canonical128.hasMatch(s)) {
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
