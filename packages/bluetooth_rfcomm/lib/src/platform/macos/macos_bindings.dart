// FFI bindings to the macOS C ABI in
// macos/bluetooth_rfcomm/Sources/bluetooth_rfcomm/bluetooth_rfcomm.{h,m}.
//
// Resolved via native assets: the build hook compiles the Objective-C sources
// and registers a code asset whose id matches the @DefaultAsset below, so these
// `@Native` functions link both from a pure-Dart CLI (`dart run`) and a Flutter
// macOS build. No DynamicLibrary.open / committed binary needed.
@ffi.DefaultAsset('package:bluetooth_rfcomm/bluetooth_rfcomm.dart')
library;

import 'dart:ffi' as ffi;

// Native callback signatures (see the C typedefs).
typedef FoundCbNative = ffi.Void Function(ffi.Int64, ffi.Pointer<ffi.Char>);
typedef InquiryDoneCbNative = ffi.Void Function(ffi.Int64, ffi.Int32);
typedef DataCbNative =
    ffi.Void Function(ffi.Int64, ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef StateCbNative = ffi.Void Function(ffi.Int64, ffi.Int32);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(symbol: 'btc_free')
external void btcFree(ffi.Pointer<ffi.Void> ptr);

@ffi.Native<ffi.Int32 Function()>(symbol: 'btc_adapter_state')
external int btcAdapterState();

@ffi.Native<ffi.Pointer<ffi.Char> Function()>(symbol: 'btc_paired_devices_json')
external ffi.Pointer<ffi.Char> btcPairedDevicesJson();

@ffi.Native<ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>)>(
  symbol: 'btc_sdp_channel',
)
external int btcSdpChannel(
  ffi.Pointer<ffi.Char> address,
  ffi.Pointer<ffi.Char> uuid,
);

@ffi.Native<
  ffi.Int32 Function(
    ffi.Int64,
    ffi.Pointer<ffi.NativeFunction<FoundCbNative>>,
    ffi.Pointer<ffi.NativeFunction<InquiryDoneCbNative>>,
  )
>(symbol: 'btc_start_discovery')
external int btcStartDiscovery(
  int token,
  ffi.Pointer<ffi.NativeFunction<FoundCbNative>> found,
  ffi.Pointer<ffi.NativeFunction<InquiryDoneCbNative>> done,
);

@ffi.Native<ffi.Int32 Function()>(symbol: 'btc_stop_discovery')
external int btcStopDiscovery();

@ffi.Native<
  ffi.Int64 Function(
    ffi.Int64,
    ffi.Pointer<ffi.Char>,
    ffi.Int32,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.NativeFunction<DataCbNative>>,
    ffi.Pointer<ffi.NativeFunction<StateCbNative>>,
  )
>(symbol: 'btc_rfcomm_open')
external int btcRfcommOpen(
  int token,
  ffi.Pointer<ffi.Char> address,
  int channel,
  ffi.Pointer<ffi.Char> uuid,
  ffi.Pointer<ffi.NativeFunction<DataCbNative>> data,
  ffi.Pointer<ffi.NativeFunction<StateCbNative>> state,
);

@ffi.Native<ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Uint8>, ffi.Int32)>(
  symbol: 'btc_rfcomm_write',
)
external int btcRfcommWrite(int handle, ffi.Pointer<ffi.Uint8> data, int len);

@ffi.Native<ffi.Int32 Function(ffi.Int64)>(symbol: 'btc_rfcomm_close')
external int btcRfcommClose(int handle);
