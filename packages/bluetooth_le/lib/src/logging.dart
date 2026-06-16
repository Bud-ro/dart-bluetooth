import 'package:logging/logging.dart';

/// The names of the [Logger]s this package logs under. All are children of
/// [package] (`bluetooth_le`), so a client can configure the whole package via
/// the `bluetooth_le` logger, or tune each subsystem independently after setting
/// `hierarchicalLoggingEnabled = true`. The package installs no handler and
/// prints nothing itself — output is the app's choice.
abstract final class BleLoggers {
  /// Parent logger for the whole package: `bluetooth_le`.
  static const String package = 'bluetooth_le';

  /// Scanning / advertisement sightings: `bluetooth_le.scan`.
  static const String scan = 'bluetooth_le.scan';

  /// Connection lifecycle — connect/disconnect/state: `bluetooth_le.connection`.
  static const String connection = 'bluetooth_le.connection';

  /// GATT operations — discover/read/write/subscribe: `bluetooth_le.gatt`.
  static const String gatt = 'bluetooth_le.gatt';

  /// Raw byte I/O on the serial channel, logged at FINEST: `bluetooth_le.data`.
  static const String data = 'bluetooth_le.data';

  /// Adapter power/authorization state: `bluetooth_le.adapter`.
  static const String adapter = 'bluetooth_le.adapter';

  /// Diagnostics from the native backends: `bluetooth_le.native`.
  static const String native = 'bluetooth_le.native';
}

final Logger logScan = Logger(BleLoggers.scan);
final Logger logConnection = Logger(BleLoggers.connection);
final Logger logGatt = Logger(BleLoggers.gatt);
final Logger logData = Logger(BleLoggers.data);
final Logger logAdapter = Logger(BleLoggers.adapter);
final Logger logNative = Logger(BleLoggers.native);

/// A compact, length-bounded description of a byte payload for FINEST logs.
/// Build it lazily (pass a closure to the logger).
String describeBytes(List<int> bytes, {int max = 16}) {
  final hex = bytes
      .take(max)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(' ');
  final suffix = bytes.length > max ? ' …' : '';
  return '${bytes.length}B [$hex$suffix]';
}
