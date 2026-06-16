@TestOn('vm')
library;

import 'dart:ffi' as ffi;

import 'package:bluetooth_classic/src/platform/windows/windows_ffi.dart';
import 'package:test/test.dart';

// These validate the FFI struct layouts against the documented Win32 sizes.
// `sizeOf` computes the x64 layout on any host (all fields are fixed-width or
// pointer-sized, with natural alignment), so this guards the offsets without a
// Windows machine. Pointer-sized fields assume a 64-bit host.
void main() {
  test(
    'struct sizes match the Win32 SDK (x64)',
    () {
      expect(ffi.sizeOf<SockaddrBth>(), 40);
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
