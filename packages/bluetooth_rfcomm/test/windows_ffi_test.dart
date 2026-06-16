@TestOn('vm')
library;

import 'dart:ffi' as ffi;

import 'package:bluetooth_rfcomm/src/platform/windows/windows_ffi.dart';
import 'package:test/test.dart';

// These validate the FFI struct layouts against the documented Win32 sizes.
// `sizeOf` computes the x64 layout on any host, so this guards the offsets
// without a Windows machine. Pointer-sized fields assume a 64-bit host.
void main() {
  test(
    'struct sizes match the Win32 SDK (x64)',
    () {
      // SOCKADDR_BTH is byte-packed in ws2bth.h (pshpack1): 2 + 8 + 16 + 4 = 30.
      // (Natural alignment would give 40 — that mismatch made connect() fail.)
      expect(ffi.sizeOf<SockaddrBth>(), 30);
      expect(ffi.sizeOf<BluetoothDeviceInfo>(), 560);
      expect(ffi.sizeOf<BluetoothDeviceSearchParams>(), 40);
    },
    skip: ffi.sizeOf<ffi.IntPtr>() != 8 ? '64-bit host only' : false,
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
