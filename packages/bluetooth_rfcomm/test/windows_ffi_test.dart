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
      // WSAQUERYSETW / CSADDR_INFO / SOCKET_ADDRESS use NATURAL alignment
      // (winsock2.h / ws2def.h are not packed). x64 MSVC sizes:
      expect(ffi.sizeOf<SocketAddress>(), 16);
      expect(ffi.sizeOf<CsAddrInfo>(), 40);
      expect(ffi.sizeOf<WsaQuerySetW>(), 120);
    },
    skip: ffi.sizeOf<ffi.IntPtr>() != 8 ? '64-bit host only' : false,
  );

  test(
    'WSAQUERYSETW key field offsets match the Win32 x64 ABI',
    () {
      // WSALookupServiceNextW writes into a caller buffer that we reinterpret
      // as WsaQuerySetW, so the offsets of the fields we READ must match the
      // SDK exactly: lpszServiceInstanceName @8, dwNameSpace @40,
      // dwNumberOfCsAddrs @88, lpcsaBuffer @96.
      final p = calloc<ffi.Uint8>(ffi.sizeOf<WsaQuerySetW>());
      try {
        final qs = p.cast<WsaQuerySetW>();
        qs.ref.dwSize = 0x11223344;
        qs.ref.lpszServiceInstanceName = ffi.Pointer.fromAddress(0x1);
        qs.ref.dwNameSpace = 0x55667788;
        qs.ref.dwNumberOfCsAddrs = 0x0A0B0C0D;
        qs.ref.lpcsaBuffer = ffi.Pointer.fromAddress(0x2);
        final b = p.asTypedList(ffi.sizeOf<WsaQuerySetW>());
        expect(b.sublist(0, 4), [0x44, 0x33, 0x22, 0x11], reason: 'dwSize @0');
        expect(b[8], 1, reason: 'lpszServiceInstanceName @8');
        expect(b.sublist(40, 44), [
          0x88,
          0x77,
          0x66,
          0x55,
        ], reason: 'dwNameSpace @40');
        expect(b.sublist(88, 92), [
          0x0D,
          0x0C,
          0x0B,
          0x0A,
        ], reason: 'dwNumberOfCsAddrs @88');
        expect(b[96], 2, reason: 'lpcsaBuffer @96');
      } finally {
        calloc.free(p);
      }
    },
    skip: ffi.sizeOf<ffi.IntPtr>() != 8 || !_le
        ? '64-bit little-endian host only'
        : false,
  );

  test(
    'CSADDR_INFO remoteAddr offset matches the Win32 x64 ABI',
    () {
      // We read remoteAddr.lpSockaddr (@16) and cast it to SOCKADDR_BTH.
      final p = calloc<ffi.Uint8>(ffi.sizeOf<CsAddrInfo>());
      try {
        final info = p.cast<CsAddrInfo>();
        info.ref.remoteAddr.lpSockaddr = ffi.Pointer.fromAddress(0x7);
        info.ref.remoteAddr.iSockaddrLength = 30;
        final b = p.asTypedList(ffi.sizeOf<CsAddrInfo>());
        expect(b[16], 7, reason: 'remoteAddr.lpSockaddr @16');
        expect(b[24], 30, reason: 'remoteAddr.iSockaddrLength @24');
      } finally {
        calloc.free(p);
      }
    },
    skip: ffi.sizeOf<ffi.IntPtr>() != 8 || !_le
        ? '64-bit little-endian host only'
        : false,
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
