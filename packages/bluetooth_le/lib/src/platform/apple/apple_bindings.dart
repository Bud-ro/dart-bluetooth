// FFI bindings to the Apple CoreBluetooth C ABI in
// src/native/apple/bluetooth_le.{h,m}.
//
// Resolved via native assets: the build hook compiles the Objective-C source and
// registers a code asset whose id matches the @DefaultAsset below, so these
// `@Native` functions link from a pure-Dart CLI (`dart run`) and a Flutter
// build. No DynamicLibrary.open / committed binary needed.
@ffi.DefaultAsset('package:bluetooth_le/bluetooth_le.dart')
library;

import 'dart:ffi' as ffi;

// Native callback signatures (see the C typedefs in bluetooth_le.h).
typedef ScanCbNative = ffi.Void Function(ffi.Int64, ffi.Pointer<ffi.Char>);
typedef StateCbNative = ffi.Void Function(ffi.Int64, ffi.Int32);
typedef OpCbNative =
    ffi.Void Function(
      ffi.Int64,
      ffi.Int32,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
    );
typedef NotifyCbNative =
    ffi.Void Function(
      ffi.Int64,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
    );

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(symbol: 'ble_free')
external void bleFree(ffi.Pointer<ffi.Void> ptr);

@ffi.Native<ffi.Int32 Function()>(symbol: 'ble_adapter_state')
external int bleAdapterState();

@ffi.Native<ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Char>)>(
  symbol: 'ble_start_scan',
)
external int bleStartScan(int scanToken, ffi.Pointer<ffi.Char> serviceUuidsCsv);

@ffi.Native<ffi.Void Function()>(symbol: 'ble_stop_scan')
external void bleStopScan();

@ffi.Native<
  ffi.Void Function(
    ffi.Pointer<ffi.NativeFunction<ScanCbNative>>,
    ffi.Pointer<ffi.NativeFunction<StateCbNative>>,
    ffi.Pointer<ffi.NativeFunction<OpCbNative>>,
    ffi.Pointer<ffi.NativeFunction<NotifyCbNative>>,
  )
>(symbol: 'ble_register')
external void bleRegister(
  ffi.Pointer<ffi.NativeFunction<ScanCbNative>> scan,
  ffi.Pointer<ffi.NativeFunction<StateCbNative>> state,
  ffi.Pointer<ffi.NativeFunction<OpCbNative>> op,
  ffi.Pointer<ffi.NativeFunction<NotifyCbNative>> notify,
);
