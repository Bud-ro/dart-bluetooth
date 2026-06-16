import 'package:meta/meta.dart';

import 'device_id.dart';
import 'enums.dart';

/// An immutable snapshot of a remote Bluetooth device.
///
/// Identity is the [id] alone (a device keeps its identity as its name, RSSI or
/// bond state change), matching the convention used by `flutter_bluetooth_serial`.
/// Instances are snapshots: prefer re-querying over caching mutable fields like
/// [rssi] or [isConnected].
@immutable
class BluetoothDevice {
  const BluetoothDevice({
    required this.id,
    this.name,
    this.type = BluetoothDeviceType.unknown,
    this.bondState = BluetoothBondState.unknown,
    this.rssi,
    this.isConnected = false,
    this.deviceClass,
  });

  /// Stable platform identifier (MAC address or opaque token).
  final DeviceId id;

  /// Friendly name, if known. May be null before SDP/name resolution completes.
  final String? name;

  /// Radio class (classic / le / dual).
  final BluetoothDeviceType type;

  /// Pairing state.
  final BluetoothBondState bondState;

  /// Signal strength in dBm from the most recent inquiry, if available.
  /// Only meaningful on a [BluetoothDiscoveryResult]; null for bonded lists.
  final int? rssi;

  /// Whether the OS currently reports an active connection to this device.
  final bool isConnected;

  /// Raw Bluetooth Class-of-Device value, if the platform exposes it.
  final int? deviceClass;

  /// Convenience for the common MAC-address case.
  String get address => id.address;

  BluetoothDevice copyWith({
    String? name,
    BluetoothDeviceType? type,
    BluetoothBondState? bondState,
    int? rssi,
    bool? isConnected,
    int? deviceClass,
  }) {
    return BluetoothDevice(
      id: id,
      name: name ?? this.name,
      type: type ?? this.type,
      bondState: bondState ?? this.bondState,
      rssi: rssi ?? this.rssi,
      isConnected: isConnected ?? this.isConnected,
      deviceClass: deviceClass ?? this.deviceClass,
    );
  }

  @override
  bool operator ==(Object other) => other is BluetoothDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'BluetoothDevice(${name ?? '?'} [$id] '
      '${type.name}, ${bondState.name}'
      '${rssi != null ? ', ${rssi}dBm' : ''})';
}
