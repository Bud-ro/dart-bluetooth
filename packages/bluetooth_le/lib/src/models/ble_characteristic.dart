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

  bool get canRead => properties.contains(CharacteristicProperty.read);
  bool get canWrite => properties.contains(CharacteristicProperty.write);
  bool get canWriteWithoutResponse =>
      properties.contains(CharacteristicProperty.writeWithoutResponse);
  bool get canNotify => properties.contains(CharacteristicProperty.notify);
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
