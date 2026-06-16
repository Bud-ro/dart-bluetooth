import 'package:meta/meta.dart';

import 'uuid.dart';

/// An RFCOMM service advertised by a device, as discovered via SDP.
///
/// The [rfcommChannelId] is the piece that matters for serial: it is the
/// non-zero channel a caller must open to talk to this service. On macOS in
/// particular you cannot use channel 0 — you must resolve and use the real
/// channel from the device's SDP record, which is exactly what this carries.
@immutable
class BluetoothService {
  const BluetoothService({
    required this.uuid,
    required this.rfcommChannelId,
    this.name,
  });

  /// Service class UUID (e.g. SPP `0x1101`).
  final Uuid uuid;

  /// RFCOMM server channel (1–30) to open for this service.
  final int rfcommChannelId;

  /// Human-readable service name from the SDP record, if present.
  final String? name;

  @override
  bool operator ==(Object other) =>
      other is BluetoothService &&
      other.uuid == uuid &&
      other.rfcommChannelId == rfcommChannelId &&
      other.name == name;

  @override
  int get hashCode => Object.hash(uuid, rfcommChannelId, name);

  @override
  String toString() =>
      'BluetoothService(${name ?? uuid}, channel $rfcommChannelId)';
}
