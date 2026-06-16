import 'connection.dart';
import 'exceptions.dart';
import 'logging.dart';
import 'models/ble_device.dart';
import 'models/enums.dart';
import 'models/scan_result.dart';
import 'models/uuid.dart';
import 'platform/platform_interface.dart';

/// Entry point for Bluetooth Low Energy (GATT) as a central.
///
/// Use the shared [instance], or construct one with an explicit [platform] for
/// tests. Scan for devices, [connect], then use the [BleConnection] (raw GATT or
/// a serial channel via [BleConnection.asSerial]).
///
/// ```dart
/// final ble = BleCentral.instance;
/// final result = await ble.startScan().firstWhere((r) => r.device.name == 'My Board');
/// final conn = await ble.connect(result.device);
/// await conn.discoverServices();
/// final serial = conn.asSerial();
/// serial.input.listen(handleBytes);
/// await serial.write(payload);
/// ```
class BleCentral {
  /// Creates a facade over [platform], or the auto-selected host backend.
  BleCentral({BleCentralPlatform? platform})
    : _platform = platform ?? BleCentralPlatform.instance;

  /// Shared instance backed by the host's default platform.
  static final BleCentral instance = BleCentral();

  final BleCentralPlatform _platform;

  /// Whether this host can do BLE at all.
  Future<bool> isSupported() => _platform.isSupported();

  /// The current adapter power/authorization state (one-shot snapshot).
  Future<BluetoothAdapterState> adapterState() async {
    final state = await _platform.adapterState();
    logAdapter.fine(() => 'adapter state: ${state.name}');
    return state;
  }

  /// Adapter-state changes. Broadcast; emits the current state on listen.
  Stream<BluetoothAdapterState> get adapterStateChanges =>
      _platform.adapterStateChanges().map((s) {
        logAdapter.fine(() => 'adapter -> ${s.name}');
        return s;
      });

  /// Asks the OS to power the radio on (where the OS permits; else throws).
  Future<void> requestEnable() {
    logAdapter.fine('requestEnable');
    return _platform.setAdapterEnabled(true);
  }

  /// Asks the OS to power the radio off (where allowed).
  Future<void> requestDisable() {
    logAdapter.fine('requestDisable');
    return _platform.setAdapterEnabled(false);
  }

  /// Streams advertisement sightings, optionally filtered to [withServices].
  /// Stop by cancelling the subscription or calling [stopScan].
  Stream<BleScanResult> startScan({List<Uuid>? withServices}) {
    logScan.fine(
      () =>
          'scan requested'
          '${withServices != null ? ' (services: ${withServices.length})' : ''}',
    );
    return _platform.startScan(withServices: withServices).map((r) {
      logScan.finer(
        () => 'found ${r.device.id}${r.rssi != null ? ' rssi=${r.rssi}' : ''}',
      );
      return r;
    });
  }

  /// Stops any in-progress scan.
  Future<void> stopScan() {
    logScan.fine('scan stopped');
    return _platform.stopScan();
  }

  /// Opens a GATT connection to [device]. Throws a [BleException] on failure.
  Future<BleConnection> connect(BleDevice device, {Duration? timeout}) async {
    logConnection.fine(() => 'connecting to ${device.id}');
    try {
      final gatt = await _platform.connect(device.id, timeout: timeout);
      return BleConnection.wrap(device, gatt);
    } on BleException catch (e, st) {
      logConnection.severe(() => 'connect to ${device.id} failed: $e', e, st);
      rethrow;
    }
  }

  /// Releases resources held by the backend.
  Future<void> dispose() => _platform.dispose();
}
