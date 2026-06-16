import 'package:bluetooth_le/bluetooth_le.dart';
import 'package:test/test.dart';

final _svc = Uuid('1800');
final _chr = Uuid('2a00');

void main() {
  group('Uuid', () {
    test('short form expands to canonical', () {
      expect(Uuid('180d').value, '0000180d-0000-1000-8000-00805f9b34fb');
      expect(Uuid('0x180D'), Uuid('180d'));
    });

    test('Nordic UART UUIDs', () {
      expect(
        Uuid.nordicUartService.value,
        '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
      );
      expect(Uuid.nordicUartRx.value, '6e400002-b5a3-f393-e0a9-e50e24dcca9e');
      expect(Uuid.nordicUartTx.value, '6e400003-b5a3-f393-e0a9-e50e24dcca9e');
    });

    test('short getter and malformed rejection', () {
      expect(Uuid('180d').short, 0x180d);
      expect(Uuid.nordicUartService.short, isNull);
      expect(() => Uuid('zzzz'), throwsFormatException);
      expect(() => Uuid(''), throwsFormatException);
    });
  });

  group('DeviceId', () {
    test('normalises addresses; opaque rejects .address', () {
      expect(
        DeviceId.address('aa:bb:cc:dd:ee:ff').address,
        'AA:BB:CC:DD:EE:FF',
      );
      expect(DeviceId.address('aabbccddeeff').address, 'AA:BB:CC:DD:EE:FF');
      expect(const DeviceId.opaque('x').isAddress, isFalse);
      expect(() => const DeviceId.opaque('x').address, throwsStateError);
    });
  });

  group('BleCharacteristic', () {
    test('property helpers', () {
      final c = BleCharacteristic(
        serviceUuid: _svc,
        uuid: _chr,
        properties: const {
          CharacteristicProperty.write,
          CharacteristicProperty.notify,
        },
      );
      expect(c.canWrite, isTrue);
      expect(c.canNotify, isTrue);
      expect(c.canRead, isFalse);
      expect(c.canStream, isTrue);
    });

    test('value equality', () {
      final a = BleCharacteristic(
        serviceUuid: _svc,
        uuid: _chr,
        properties: const {CharacteristicProperty.read},
      );
      final b = BleCharacteristic(
        serviceUuid: _svc,
        uuid: _chr,
        properties: const {CharacteristicProperty.read},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('BleService', () {
    test('characteristic lookup and equality', () {
      final chr = BleCharacteristic(serviceUuid: _svc, uuid: _chr);
      final s = BleService(uuid: _svc, characteristics: [chr]);
      expect(s.characteristic(_chr), chr);
      expect(s.characteristic(_svc), isNull);
      expect(s, BleService(uuid: _svc, characteristics: [chr]));
    });
  });

  group('enums', () {
    test('helpers', () {
      expect(BluetoothAdapterState.on.isOn, isTrue);
      expect(BleConnectionState.connected.isConnected, isTrue);
      expect(BleConnectionState.disconnected.isConnected, isFalse);
    });
  });

  group('exceptions', () {
    test('isTransient classification', () {
      expect(const BleConnectionException('x').isTransient, isTrue);
      expect(const BleTimeoutException('x').isTransient, isTrue);
      expect(const DeviceNotFoundException('x').isTransient, isTrue);
      expect(const BleException('x').isTransient, isFalse);
      expect(const BleUnsupportedException('x').isTransient, isFalse);
      expect(const BleGattException('x').isTransient, isFalse);
      expect(const ServiceNotFoundException('x').isTransient, isFalse);
    });

    test('toString includes label/message/code', () {
      const e = BleGattException('nope', code: 7);
      expect(e.toString(), contains('BleGattException'));
      expect(e.toString(), contains('nope'));
      expect(e.toString(), contains('7'));
    });
  });
}
