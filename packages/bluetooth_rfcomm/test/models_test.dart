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

  group('BluetoothService / BluetoothDiscoveryResult equality', () {
    test('BluetoothService is a value type', () {
      final a = BluetoothService(uuid: Uuid.spp, rfcommChannelId: 1);
      final b = BluetoothService(uuid: Uuid.spp, rfcommChannelId: 1);
      final c = BluetoothService(uuid: Uuid.spp, rfcommChannelId: 2);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect({a, b}, hasLength(1)); // dedups in a Set
    });

    test('BluetoothDiscoveryResult is a value type', () {
      final device = BluetoothDevice(id: DeviceId.address('AA:BB:CC:DD:EE:FF'));
      final ts = DateTime(2026);
      final a = BluetoothDiscoveryResult(
        device: device,
        rssi: -40,
        timestamp: ts,
      );
      final b = BluetoothDiscoveryResult(
        device: device,
        rssi: -40,
        timestamp: ts,
      );
      final c = BluetoothDiscoveryResult(
        device: device,
        rssi: -90,
        timestamp: ts,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('BluetoothDevice opaque id', () {
    test('hasAddress is false and address throws for an opaque id', () {
      const d = BluetoothDevice(id: DeviceId.opaque('tok'));
      expect(d.hasAddress, isFalse);
      expect(() => d.address, throwsStateError);
    });

    test('hasAddress is true for a MAC id', () {
      final d = BluetoothDevice(id: DeviceId.address('AA:BB:CC:DD:EE:FF'));
      expect(d.hasAddress, isTrue);
      expect(d.address, 'AA:BB:CC:DD:EE:FF');
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
