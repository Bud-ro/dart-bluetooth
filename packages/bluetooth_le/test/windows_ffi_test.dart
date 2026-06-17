@TestOn('vm')
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data' show Endian;

import 'package:bluetooth_le/src/platform/windows/windows_ble_ffi.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

// Validate the Win32 GATT FFI struct layouts against the documented bthledef.h
// ABI. As with the RFCOMM SOCKADDR_BTH bug, size checks alone are necessary but
// NOT sufficient — a struct can be the right size with wrong field offsets. The
// byte-layout tests set sentinels and read raw bytes, pinning each field's
// offset and endianness independent of Dart's alignment computation. These run
// on every CI host (x64 layout is identical across the targeted OSes).
final _le = Endian.host == Endian.little;
final _is64 = ffi.sizeOf<ffi.IntPtr>() == 8;

void main() {
  test(
    'struct sizes match the Win32 SDK (x64)',
    () {
      expect(ffi.sizeOf<BthLeUuid>(), 20);
      expect(ffi.sizeOf<BthLeGattService>(), 24);
      expect(ffi.sizeOf<BthLeGattCharacteristic>(), 36);
      expect(ffi.sizeOf<BthLeGattDescriptor>(), 32);
      expect(ffi.sizeOf<SpDeviceInterfaceData>(), 32);
    },
    skip: !_is64 ? '64-bit host only' : false,
  );

  test(
    'BTH_LE_UUID byte layout (BOOLEAN + 3 pad + 4-aligned union)',
    () {
      final p = calloc<BthLeUuid>();
      try {
        p.ref.isShortUuid = 1;
        p.ref.value.shortUuid = 0xABCD;
        final b = p.cast<ffi.Uint8>().asTypedList(20);
        expect(b[0], 1, reason: 'isShortUuid @0');
        expect(b.sublist(4, 6), [
          0xCD,
          0xAB,
        ], reason: 'shortUuid @4 (after pad)');
      } finally {
        calloc.free(p);
      }
    },
    skip: !_le ? 'little-endian host only' : false,
  );

  test(
    'BTH_LE_GATT_CHARACTERISTIC field offsets',
    () {
      final p = calloc<BthLeGattCharacteristic>();
      try {
        p.ref.serviceHandle = 0x1122;
        p.ref.characteristicUuid.isShortUuid = 1; // @4
        p.ref.attributeHandle = 0x3344; // @24
        p.ref.characteristicValueHandle = 0x5566; // @26
        p.ref.isReadable = 1; // @29
        p.ref.isNotifiable = 1; // @33
        final b = p.cast<ffi.Uint8>().asTypedList(36);
        expect(b.sublist(0, 2), [0x22, 0x11], reason: 'serviceHandle @0');
        expect(b[4], 1, reason: 'characteristicUuid @4 (after 2 pad)');
        expect(b.sublist(24, 26), [0x44, 0x33], reason: 'attributeHandle @24');
        expect(b.sublist(26, 28), [
          0x66,
          0x55,
        ], reason: 'characteristicValueHandle @26');
        expect(b[29], 1, reason: 'isReadable @29');
        expect(b[33], 1, reason: 'isNotifiable @33');
      } finally {
        calloc.free(p);
      }
    },
    skip: !_le ? 'little-endian host only' : false,
  );

  test(
    'BTH_LE_GATT_DESCRIPTOR field offsets',
    () {
      final p = calloc<BthLeGattDescriptor>();
      try {
        p.ref.serviceHandle = 0x1122; // @0
        p.ref.characteristicHandle = 0x3344; // @2
        p.ref.descriptorType = 0x0A0B0C0D; // @4
        p.ref.descriptorUuid.isShortUuid = 1; // @8
        p.ref.attributeHandle = 0x1234; // @28
        final b = p.cast<ffi.Uint8>().asTypedList(32);
        expect(b.sublist(0, 2), [0x22, 0x11], reason: 'serviceHandle @0');
        expect(b.sublist(2, 4), [
          0x44,
          0x33,
        ], reason: 'characteristicHandle @2');
        expect(b.sublist(4, 8), [
          0x0D,
          0x0C,
          0x0B,
          0x0A,
        ], reason: 'descriptorType @4');
        expect(b[8], 1, reason: 'descriptorUuid @8');
        expect(b.sublist(28, 30), [0x34, 0x12], reason: 'attributeHandle @28');
      } finally {
        calloc.free(p);
      }
    },
    skip: !_le ? 'little-endian host only' : false,
  );

  test(
    'SP_DEVICE_INTERFACE_DATA field offsets',
    () {
      final p = calloc<SpDeviceInterfaceData>();
      try {
        p.ref.cbSize = 0x01020304; // @0
        p.ref.flags = 0x0A0B0C0D; // @20
        p.ref.reserved = 0x1122334455667788; // @24 (8-aligned)
        final b = p.cast<ffi.Uint8>().asTypedList(32);
        expect(b.sublist(0, 4), [0x04, 0x03, 0x02, 0x01], reason: 'cbSize @0');
        expect(b.sublist(20, 24), [
          0x0D,
          0x0C,
          0x0B,
          0x0A,
        ], reason: 'flags @20');
        expect(b.sublist(24, 32), [
          0x88,
          0x77,
          0x66,
          0x55,
          0x44,
          0x33,
          0x22,
          0x11,
        ], reason: 'reserved @24');
      } finally {
        calloc.free(p);
      }
    },
    skip: !_le ? 'little-endian host only' : false,
  );

  test('BTH_LE_UUID read/write round-trips a 128-bit UUID', () {
    final p = calloc<BthLeUuid>();
    try {
      const uuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
      writeBthLeUuid(p.ref, uuid);
      expect(p.ref.isShortUuid, 0);
      expect(readBthLeUuid(p.ref), uuid);
    } finally {
      calloc.free(p);
    }
  });

  test('BTH_LE_UUID short form expands against the base UUID', () {
    final p = calloc<BthLeUuid>();
    try {
      p.ref.isShortUuid = 1;
      p.ref.value.shortUuid = 0x180d; // Heart Rate service
      expect(readBthLeUuid(p.ref), '0000180d-0000-1000-8000-00805f9b34fb');
    } finally {
      calloc.free(p);
    }
  });
}
