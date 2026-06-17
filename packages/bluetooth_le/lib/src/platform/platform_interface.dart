import 'dart:async';
import 'dart:typed_data';

import '../models/ble_service.dart';
import '../models/device_id.dart';
import '../models/enums.dart';
import '../models/scan_result.dart';
import '../models/uuid.dart';
import 'platform_dispatch.dart';

/// The backend contract a platform implements. App code uses [BleCentral], not
/// this directly — but it's exported so advanced users can supply a custom
/// backend or a test fake via `BleCentral(platform: ...)`.
abstract class BleCentralPlatform {
  BleCentralPlatform();

  static BleCentralPlatform? _instance;

  /// The host-appropriate backend, created lazily. Settable for tests.
  static BleCentralPlatform get instance => _instance ??= createBlePlatform();

  static set instance(BleCentralPlatform platform) => _instance = platform;

  Future<bool> isSupported();

  Future<BluetoothAdapterState> adapterState();

  /// Adapter-state stream. Always emits the current state on listen. Live
  /// transition events are emitted by the Linux (BlueZ) backend; macOS, iOS,
  /// Android and Windows currently emit the current state once (continuous
  /// change events on those platforms are a future enhancement). Use
  /// [adapterState] for a one-shot snapshot.
  Stream<BluetoothAdapterState> adapterStateChanges();

  Future<void> setAdapterEnabled(bool enabled);

  /// Streams advertisement sightings, optionally filtered to [withServices].
  /// Cancelling the subscription (or [stopScan]) stops the scan.
  Stream<BleScanResult> startScan({List<Uuid>? withServices});

  Future<void> stopScan();

  /// Opens a GATT connection to the device with [id].
  Future<GattConnection> connect(DeviceId id, {Duration? timeout});

  /// Releases global resources held by the backend.
  Future<void> dispose() async {}
}

/// A live GATT connection's transport contract (one per connected device).
abstract class GattConnection {
  /// Connection-state transitions; closes when the link drops.
  Stream<BleConnectionState> get stateChanges;

  BleConnectionState get state;

  /// Discovers services and their characteristics.
  Future<List<BleService>> discoverServices();

  /// Reads the value of [characteristic] under [service].
  Future<Uint8List> readCharacteristic(Uuid service, Uuid characteristic);

  /// Writes [value] to [characteristic] under [service]. With [withoutResponse]
  /// the write is unacknowledged (higher throughput, no error feedback).
  Future<void> writeCharacteristic(
    Uuid service,
    Uuid characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  });

  /// Enables notifications/indications on [characteristic] and streams the
  /// values the peripheral pushes. Cancelling the subscription disables them.
  Stream<Uint8List> subscribe(Uuid service, Uuid characteristic);

  /// Returns the usable ATT MTU. Most platforms negotiate the MTU automatically
  /// and ignore the requested [mtu] (reporting the auto-negotiated value);
  /// Android honours an explicit request. Windows reports the ATT default (23).
  Future<int> requestMtu(int mtu);

  /// Closes the connection. Idempotent.
  Future<void> close();
}
