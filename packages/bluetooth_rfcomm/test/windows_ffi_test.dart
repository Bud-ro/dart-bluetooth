@TestOn('vm')
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data' show Endian;

import 'package:bluetooth_rfcomm/src/platform/windows/windows_ffi.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

// These validate the FFI struct layouts against the documented Win32 ABI.
//
// The size checks alone are necessary but NOT sufficient: a struct can be the
// right total size with the wrong field offsets, and an expected size copied
// from Dart's own computation is tautological (that's how the SOCKADDR_BTH
// packing bug slipped through — the test asserted Dart's buggy 40). The
// "byte layout" tests below set sentinel values and read the raw bytes back, so
// they pin each field's *offset and endianness* against the documented Win32
// layout, independent of Dart's alignment computation. All targeted hosts
// (x64/arm64) are little-endian.
final _le = Endian.host == Endian.little;

void main() {
  test(
    'struct sizes match the Win32 SDK (x64)',
    () {
      // SOCKADDR_BTH is byte-packed in ws2bth.h (pshpack1): 2 + 8 + 16 + 4 = 30.
      // (Natural alignment would give 40 — that mismatch made connect() fail.)
      expect(ffi.sizeOf<SockaddrBth>(), 30);
    },
    skip: ffi.sizeOf<ffi.IntPtr>() != 8 ? '64-bit host only' : false,
  );

  test(
    'SOCKADDR_BTH byte layout matches packed Win32 (offsets + endianness)',
    () {
      final p = calloc<SockaddrBth>();
      try {
        p.ref.addressFamily = 0x0102;
        p.ref.btAddr = 0x1122334455667788;
        p.ref.svcData1 = 0x0A0B0C0D; // GUID Data1 (ULONG)
        p.ref.svcData2 = 0x1112; // Data2 (USHORT)
        p.ref.svcData3 = 0x2122; // Data3 (USHORT)
        for (var i = 0; i < 8; i++) {
          p.ref.svcData4[i] = 0xD0 + i; // Data4 (BYTE[8])
        }
        p.ref.port = 0xCCDDEEFF; // ULONG
        final b = p.cast<ffi.Uint8>().asTypedList(30);
        expect(b.sublist(0, 2), [0x02, 0x01], reason: 'addressFamily @0');
        expect(b.sublist(2, 10), [
          0x88,
          0x77,
          0x66,
          0x55,
          0x44,
          0x33,
          0x22,
          0x11,
        ], reason: 'btAddr @2 (NOT @8 — packed)');
        expect(b.sublist(10, 14), [
          0x0D,
          0x0C,
          0x0B,
          0x0A,
        ], reason: 'Data1 @10');
        expect(b.sublist(14, 16), [0x12, 0x11], reason: 'Data2 @14');
        expect(b.sublist(16, 18), [0x22, 0x21], reason: 'Data3 @16');
        expect(b.sublist(18, 26), [
          0xD0,
          0xD1,
          0xD2,
          0xD3,
          0xD4,
          0xD5,
          0xD6,
          0xD7,
        ], reason: 'Data4 @18');
        expect(b.sublist(26, 30), [0xFF, 0xEE, 0xDD, 0xCC], reason: 'port @26');
      } finally {
        calloc.free(p);
      }
    },
    skip: !_le ? 'little-endian host only' : false,
  );

  test('BTH_ADDR parse/format round-trips', () {
    expect(
      formatBthAddr(parseBthAddr('AA:BB:CC:DD:EE:FF')),
      'AA:BB:CC:DD:EE:FF',
    );
    expect(parseBthAddr('00:00:00:00:00:01'), 1);
    expect(formatBthAddr(1), '00:00:00:00:00:01');
  });
}
