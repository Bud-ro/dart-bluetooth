import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceId', () {
    test('normalises addresses (case, dashes, bare hex)', () {
      expect(
        DeviceId.address('aa:bb:cc:dd:ee:ff').address,
        'AA:BB:CC:DD:EE:FF',
      );
      expect(
        DeviceId.address('aa-bb-cc-dd-ee-ff').address,
        'AA:BB:CC:DD:EE:FF',
      );
      expect(DeviceId.address('aabbccddeeff').address, 'AA:BB:CC:DD:EE:FF');
    });

    test('equality by value + kind', () {
      expect(
        DeviceId.address('AA:BB:CC:DD:EE:FF'),
        DeviceId.address('aa:bb:cc:dd:ee:ff'),
      );
      expect(const DeviceId.opaque('x'), const DeviceId.opaque('x'));
      expect(
        const DeviceId.opaque('AA:BB:CC:DD:EE:FF') ==
            DeviceId.address('AA:BB:CC:DD:EE:FF'),
        isFalse,
      );
    });

    test('opaque id rejects .address', () {
      expect(() => const DeviceId.opaque('tok').address, throwsStateError);
    });
  });

  group('Uuid', () {
    test('SPP short form expands to canonical', () {
      expect(Uuid('1101'), Uuid.spp);
      expect(Uuid('0x1101'), Uuid.spp);
      expect(Uuid.spp.value, '00001101-0000-1000-8000-00805f9b34fb');
    });

    test('short id round-trips', () {
      expect(Uuid('1101').short, 0x1101);
    });

    test('rejects malformed input', () {
      expect(() => Uuid('zzzz'), throwsFormatException); // non-hex
      expect(
        () => Uuid('123456789'),
        throwsFormatException,
      ); // >8 hex, no dashes
      expect(
        () => Uuid('0000-1000-8000'),
        throwsFormatException,
      ); // dashed != 36
      // 36 chars but non-hex / wrong structure must be rejected.
      expect(
        () => Uuid('zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz'),
        throwsFormatException,
      );
      expect(
        () => Uuid('00001101_0000_1000_8000_00805f9b34fb'),
        throwsFormatException,
      );
      expect(Uuid('123').short, 0x123); // 3 hex digits IS a valid short form
    });
  });

  group('BluetoothDevice', () {
    test('identity is id only', () {
      final a = BluetoothDevice(
        id: DeviceId.address('AA:BB:CC:DD:EE:FF'),
        name: 'A',
        rssi: -40,
      );
      final b = BluetoothDevice(
        id: DeviceId.address('AA:BB:CC:DD:EE:FF'),
        name: 'B',
        rssi: -90,
        isConnected: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('copyWith preserves id, overrides fields', () {
      final d = BluetoothDevice(id: DeviceId.address('AA:BB:CC:DD:EE:FF'));
      final u = d.copyWith(name: 'New', rssi: -55);
      expect(u.id, d.id);
      expect(u.name, 'New');
      expect(u.rssi, -55);
    });
  });

  group('enums', () {
    test('helpers', () {
      expect(BluetoothBondState.bonded.isBonded, isTrue);
      expect(BluetoothBondState.none.isBonded, isFalse);
      expect(BluetoothAdapterState.on.isOn, isTrue);
      expect(BluetoothAdapterState.unauthorized.isOn, isFalse);
      expect(ConnectionState.connected.isConnected, isTrue);
    });
  });

  group('exceptions', () {
    test('hierarchy + toString', () {
      const e = BluetoothUnsupportedException('nope', code: 42);
      expect(e, isA<BluetoothException>());
      expect(e.toString(), contains('BluetoothUnsupportedException'));
      expect(e.toString(), contains('nope'));
      expect(e.toString(), contains('42'));
    });
  });
}
