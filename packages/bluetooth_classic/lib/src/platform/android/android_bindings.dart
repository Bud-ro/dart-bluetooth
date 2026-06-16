import 'dart:ffi' as ffi;

/// FFI bindings to the Android C ABI (native/android/bluetooth_classic_jni.c),
/// which bridges to the Kotlin implementation via JNI.
///
/// Unlike the Apple backends (native assets / `@Native`), Android uses the
/// Flutter `ffiPlugin` path: the CMake build produces
/// `libbluetooth_classic_android.so`, Flutter bundles it into the APK's
/// jniLibs, and we load it by name. No `flutter` dependency, no method channel.
typedef FoundCbNative = ffi.Void Function(ffi.Int64, ffi.Pointer<ffi.Char>);
typedef InquiryDoneCbNative = ffi.Void Function(ffi.Int64, ffi.Int32);
typedef DataCbNative = ffi.Void Function(
    ffi.Int64, ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef StateCbNative = ffi.Void Function(ffi.Int64, ffi.Int32);

class AndroidBindings {
  AndroidBindings._(this._lib) {
    free = _lib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)>('btc_free');
    register = _lib.lookupFunction<
        ffi.Void Function(
            ffi.Pointer<ffi.NativeFunction<FoundCbNative>>,
            ffi.Pointer<ffi.NativeFunction<InquiryDoneCbNative>>,
            ffi.Pointer<ffi.NativeFunction<DataCbNative>>,
            ffi.Pointer<ffi.NativeFunction<StateCbNative>>),
        void Function(
            ffi.Pointer<ffi.NativeFunction<FoundCbNative>>,
            ffi.Pointer<ffi.NativeFunction<InquiryDoneCbNative>>,
            ffi.Pointer<ffi.NativeFunction<DataCbNative>>,
            ffi.Pointer<ffi.NativeFunction<StateCbNative>>)>('btc_and_register');
    init = _lib.lookupFunction<ffi.Int32 Function(), int Function()>(
        'btc_and_init');
    adapterState = _lib.lookupFunction<ffi.Int32 Function(), int Function()>(
        'btc_and_adapter_state');
    bondedJson = _lib.lookupFunction<ffi.Pointer<ffi.Char> Function(),
        ffi.Pointer<ffi.Char> Function()>('btc_and_bonded_json');
    startDiscovery = _lib.lookupFunction<ffi.Int32 Function(ffi.Int64),
        int Function(int)>('btc_and_start_discovery');
    stopDiscovery = _lib.lookupFunction<ffi.Int32 Function(), int Function()>(
        'btc_and_stop_discovery');
    open = _lib.lookupFunction<
        ffi.Int64 Function(
            ffi.Int64, ffi.Pointer<ffi.Char>, ffi.Int32, ffi.Pointer<ffi.Char>),
        int Function(int, ffi.Pointer<ffi.Char>, int,
            ffi.Pointer<ffi.Char>)>('btc_and_open');
    write = _lib.lookupFunction<
        ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Uint8>, ffi.Int32),
        int Function(int, ffi.Pointer<ffi.Uint8>, int)>('btc_and_write');
    close = _lib.lookupFunction<ffi.Int32 Function(ffi.Int64),
        int Function(int)>('btc_and_close');
  }

  factory AndroidBindings.open() =>
      AndroidBindings._(ffi.DynamicLibrary.open(_libName));

  static const String _libName = 'libbluetooth_classic_android.so';

  final ffi.DynamicLibrary _lib;

  late final void Function(ffi.Pointer<ffi.Void>) free;
  late final void Function(
      ffi.Pointer<ffi.NativeFunction<FoundCbNative>>,
      ffi.Pointer<ffi.NativeFunction<InquiryDoneCbNative>>,
      ffi.Pointer<ffi.NativeFunction<DataCbNative>>,
      ffi.Pointer<ffi.NativeFunction<StateCbNative>>) register;
  late final int Function() init;
  late final int Function() adapterState;
  late final ffi.Pointer<ffi.Char> Function() bondedJson;
  late final int Function(int) startDiscovery;
  late final int Function() stopDiscovery;
  late final int Function(int, ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Char>)
      open;
  late final int Function(int, ffi.Pointer<ffi.Uint8>, int) write;
  late final int Function(int) close;
}
