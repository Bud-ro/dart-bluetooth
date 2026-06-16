@TestOn('linux')
library;

import 'package:bluetooth_le/src/models/enums.dart';
import 'package:bluetooth_le/src/platform/linux/linux_central.dart';
import 'package:test/test.dart';

void main() {
  group('parseCharacteristicProperties', () {
    test('maps known BlueZ flags', () {
      final props = LinuxGattConnection.parseCharacteristicProperties([
        'read',
        'write',
        'write-without-response',
        'notify',
        'indicate',
      ]);
      expect(props, {
        CharacteristicProperty.read,
        CharacteristicProperty.write,
        CharacteristicProperty.writeWithoutResponse,
        CharacteristicProperty.notify,
        CharacteristicProperty.indicate,
      });
    });

    test('ignores flags without a public-property analogue', () {
      final props = LinuxGattConnection.parseCharacteristicProperties([
        'read',
        'authenticated-signed-writes',
        'reliable-write',
        'encrypt-read',
      ]);
      expect(props, {CharacteristicProperty.read});
    });

    test('empty flags yield no properties', () {
      expect(
        LinuxGattConnection.parseCharacteristicProperties(const []),
        isEmpty,
      );
    });
  });
}
