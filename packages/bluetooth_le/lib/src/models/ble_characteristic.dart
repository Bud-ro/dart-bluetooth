import 'package:meta/meta.dart';

import 'enums.dart';
import 'uuid.dart';

/// A GATT characteristic discovered on a connected device.
@immutable
class BleCharacteristic {
  const BleCharacteristic({
    required this.serviceUuid,
    required this.uuid,
    this.properties = const {},
  });

  /// UUID of the service this characteristic belongs to.
  final Uuid serviceUuid;

  /// This characteristic's UUID.
  final Uuid uuid;

  /// The operations this characteristic supports.
  final Set<CharacteristicProperty> properties;

  /// Whether this characteristic supports reads.
  bool get canRead => properties.contains(CharacteristicProperty.read);

  /// Whether this characteristic supports acknowledged writes.
  bool get canWrite => properties.contains(CharacteristicProperty.write);

  /// Whether this characteristic supports unacknowledged writes.
  bool get canWriteWithoutResponse =>
      properties.contains(CharacteristicProperty.writeWithoutResponse);

  /// Whether the peripheral can push values via notifications.
  bool get canNotify => properties.contains(CharacteristicProperty.notify);

  /// Whether the peripheral can push values via indications.
  bool get canIndicate => properties.contains(CharacteristicProperty.indicate);

  /// Whether the peripheral can push values on this characteristic (notify or
  /// indicate) — i.e. it can act as a serial *input*.
  bool get canStream => canNotify || canIndicate;

  @override
  bool operator ==(Object other) =>
      other is BleCharacteristic &&
      other.serviceUuid == serviceUuid &&
      other.uuid == uuid &&
      _setEquals(other.properties, properties);

  @override
  int get hashCode =>
      Object.hash(serviceUuid, uuid, Object.hashAllUnordered(properties));

  @override
  String toString() =>
      'BleCharacteristic($uuid ${properties.map((p) => p.name).join('|')})';
}

bool _setEquals<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.containsAll(b);
