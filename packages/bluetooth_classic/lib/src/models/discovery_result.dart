import 'package:meta/meta.dart';

import 'bluetooth_device.dart';

/// A single device sighting emitted by [BluetoothClassic.startDiscovery].
///
/// The same device may be reported multiple times during one inquiry as the
/// name resolves or the signal strength updates; [device] identity is stable so
/// callers can de-duplicate by `device.id` and keep the latest [rssi].
@immutable
class BluetoothDiscoveryResult {
  const BluetoothDiscoveryResult({
    required this.device,
    this.rssi,
    required this.timestamp,
  });

  /// The device that was seen. Its `rssi` mirrors [rssi] when available.
  final BluetoothDevice device;

  /// Signal strength in dBm at the moment of this sighting, if reported.
  final int? rssi;

  /// When this sighting was observed (local time).
  final DateTime timestamp;

  @override
  bool operator ==(Object other) =>
      other is BluetoothDiscoveryResult &&
      other.device == device &&
      other.rssi == rssi &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(device, rssi, timestamp);

  @override
  String toString() =>
      'BluetoothDiscoveryResult(${device.name ?? device.id}'
      '${rssi != null ? ', ${rssi}dBm' : ''})';
}
