import 'package:logging/logging.dart';

/// The names of the [Logger]s this package logs under.
///
/// Every logger is a child of [package] (`bluetooth_rfcomm`), so clients can:
///
/// * configure the whole package at once via the `bluetooth_rfcomm` logger, or
/// * tune each subsystem independently after setting
///   `hierarchicalLoggingEnabled = true` (e.g. silence the very chatty raw-byte
///   [data] logs while keeping [connection] events).
///
/// This package never installs a log handler or prints anything itself — output
/// is entirely the app's choice (see the "Logging" section of the README).
///
/// Level usage:
/// * [Level.FINEST] — raw byte payloads (rx/tx), with a short hex preview.
/// * [Level.FINER]  — per-event detail: individual discovery sightings, flushes.
/// * [Level.FINE]   — lifecycle: connect/disconnect/state, discovery start/stop,
///   adapter-state changes.
/// * [Level.CONFIG] — one-time setup (backend selection, capability checks).
/// * [Level.INFO]   — notable milestones (a connection established).
/// * [Level.WARNING]— recoverable problems (a write failed, a malformed native
///   sighting was skipped, a timeout).
/// * [Level.SEVERE] — operations that failed (connect failed, a native callback
///   threw).
abstract final class BluetoothRfcommLoggers {
  /// Parent logger for the whole package: `bluetooth_rfcomm`.
  static const String package = 'bluetooth_rfcomm';

  /// Connection lifecycle — connect/disconnect/state: `bluetooth_rfcomm.connection`.
  static const String connection = 'bluetooth_rfcomm.connection';

  /// Raw byte I/O, logged at FINEST: `bluetooth_rfcomm.data`.
  static const String data = 'bluetooth_rfcomm.data';

  /// Device discovery / inquiry: `bluetooth_rfcomm.discovery`.
  static const String discovery = 'bluetooth_rfcomm.discovery';

  /// Adapter power/authorization state: `bluetooth_rfcomm.adapter`.
  static const String adapter = 'bluetooth_rfcomm.adapter';

  /// Diagnostics originating from the native backends (errors and dropped data
  /// at the FFI boundary): `bluetooth_rfcomm.native`.
  static const String native = 'bluetooth_rfcomm.native';

  /// All of the above, for convenience (e.g. to print the set in docs/tooling).
  static const List<String> all = [
    package,
    connection,
    data,
    discovery,
    adapter,
    native,
  ];
}

// --- Internal logger instances (not exported; clients use the names above with
// package:logging). ---------------------------------------------------------

/// Connection lifecycle events.
final Logger logConnection = Logger(BluetoothRfcommLoggers.connection);

/// Raw byte I/O (FINEST).
final Logger logData = Logger(BluetoothRfcommLoggers.data);

/// Discovery / inquiry events.
final Logger logDiscovery = Logger(BluetoothRfcommLoggers.discovery);

/// Adapter-state events.
final Logger logAdapter = Logger(BluetoothRfcommLoggers.adapter);

/// Native-backend diagnostics.
final Logger logNative = Logger(BluetoothRfcommLoggers.native);

/// A compact, length-bounded description of a byte payload for FINEST logs.
///
/// Build it lazily (pass a closure to the logger) so the hex string is only
/// constructed when the FINEST level is actually enabled.
String describeBytes(List<int> bytes, {int max = 16}) {
  final hex = bytes
      .take(max)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(' ');
  final suffix = bytes.length > max ? ' …' : '';
  return '${bytes.length}B [$hex$suffix]';
}
