// FFI bindings to the iOS C ABI in
// ios/bluetooth_classic/Sources/bluetooth_classic/bluetooth_classic.{h,m}.
//
// Same native-assets code asset as the other Apple bindings; only the iOS .m is
// compiled when targeting iOS, so these `btc_ea_*` symbols resolve there.
@ffi.DefaultAsset('package:bluetooth_classic/bluetooth_classic.dart')
library;

import 'dart:ffi' as ffi;

typedef DataCbNative = ffi.Void Function(
    ffi.Int64, ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef StateCbNative = ffi.Void Function(ffi.Int64, ffi.Int32);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(symbol: 'btc_free')
external void btcFree(ffi.Pointer<ffi.Void> ptr);

@ffi.Native<ffi.Pointer<ffi.Char> Function()>(
    symbol: 'btc_ea_accessories_json')
external ffi.Pointer<ffi.Char> btcEaAccessoriesJson();

@ffi.Native<
    ffi.Int64 Function(
        ffi.Int64,
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<ffi.NativeFunction<DataCbNative>>,
        ffi.Pointer<ffi.NativeFunction<StateCbNative>>)>(symbol: 'btc_ea_open')
external int btcEaOpen(
    int token,
    ffi.Pointer<ffi.Char> accessoryId,
    ffi.Pointer<ffi.Char> protocol,
    ffi.Pointer<ffi.NativeFunction<DataCbNative>> data,
    ffi.Pointer<ffi.NativeFunction<StateCbNative>> state);

@ffi.Native<ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Uint8>, ffi.Int32)>(
    symbol: 'btc_ea_write')
external int btcEaWrite(int handle, ffi.Pointer<ffi.Uint8> data, int len);

@ffi.Native<ffi.Int32 Function(ffi.Int64)>(symbol: 'btc_ea_close')
external int btcEaClose(int handle);
