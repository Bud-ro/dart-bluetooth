import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'ble_device.dart';
import 'uuid.dart';

/// A single advertisement sighting emitted by [BleCentral.startScan].
///
/// The same device may be reported many times during a scan as its signal or
/// advertised data updates; [device] identity is stable so callers de-duplicate
/// by `device.id`. Equality covers [device], [rssi] and [timestamp]; the
/// advertisement payload fields are snapshot data and not part of equality.
@immutable
class BleScanResult {
  const BleScanResult({
    required this.device,
    required this.timestamp,
    this.rssi,
    this.serviceUuids = const [],
    this.manufacturerData = const {},
    this.serviceData = const {},
    this.connectable = true,
  });

  /// The device that was seen. Its `rssi` mirrors [rssi] when available.
  final BleDevice device;

  /// Signal strength in dBm at this sighting, if reported.
  final int? rssi;

  /// When this sighting was observed (local time).
  final DateTime timestamp;

  /// Service UUIDs advertised in this packet.
  final List<Uuid> serviceUuids;

  /// Manufacturer-specific data, keyed by 16-bit company identifier.
  final Map<int, Uint8List> manufacturerData;

  /// Service data, keyed by service UUID.
  final Map<Uuid, Uint8List> serviceData;

  /// Whether the advertisement indicates the device is connectable.
  final bool connectable;

  @override
  bool operator ==(Object other) =>
      other is BleScanResult &&
      other.device == device &&
      other.rssi == rssi &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(device, rssi, timestamp);

  @override
  String toString() =>
      'BleScanResult(${device.name ?? device.id}'
      '${rssi != null ? ', ${rssi}dBm' : ''})';
}
