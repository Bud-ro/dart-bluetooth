import 'package:meta/meta.dart';

import 'ble_characteristic.dart';
import 'uuid.dart';

/// A GATT service discovered on a connected device, with its characteristics.
@immutable
class BleService {
  const BleService({required this.uuid, this.characteristics = const []});

  /// This service's UUID.
  final Uuid uuid;

  /// The characteristics discovered under this service.
  final List<BleCharacteristic> characteristics;

  /// The characteristic with [uuid] in this service, or null if absent.
  BleCharacteristic? characteristic(Uuid uuid) {
    for (final c in characteristics) {
      if (c.uuid == uuid) return c;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is BleService &&
      other.uuid == uuid &&
      _listEquals(other.characteristics, characteristics);

  @override
  int get hashCode => Object.hash(uuid, Object.hashAll(characteristics));

  @override
  String toString() =>
      'BleService($uuid, ${characteristics.length} characteristics)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
