import 'package:meta/meta.dart';

import 'device_id.dart';

/// A remote BLE device. Identity is [id] only, so a copy with updated [name] or
/// [rssi] compares equal to the original.
@immutable
class BleDevice {
  const BleDevice({required this.id, this.name, this.rssi});

  /// Stable, platform-appropriate identifier (see [DeviceId]).
  final DeviceId id;

  /// Advertised/GAP name, if known.
  final String? name;

  /// Most recent signal strength in dBm, if known.
  final int? rssi;

  /// Whether [id] is a real MAC address (vs an opaque CoreBluetooth id).
  bool get hasAddress => id.isAddress;

  BleDevice copyWith({String? name, int? rssi}) =>
      BleDevice(id: id, name: name ?? this.name, rssi: rssi ?? this.rssi);

  @override
  bool operator ==(Object other) => other is BleDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'BleDevice(${name ?? '?'} $id${rssi != null ? ' ${rssi}dBm' : ''})';
}
