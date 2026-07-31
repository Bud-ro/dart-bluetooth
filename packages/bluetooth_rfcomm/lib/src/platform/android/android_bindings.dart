import 'dart:ffi' as ffi;

/// FFI bindings to the Android C ABI (native/android/bluetooth_rfcomm_jni.c),
/// which bridges to the Kotlin implementation via JNI.
///
/// Unlike the Apple backends (native assets / `@Native`), Android uses the
/// Flutter `ffiPlugin` path: the CMake build produces
/// `libbluetooth_rfcomm_android.so`, Flutter bundles it into the APK's
/// jniLibs, and we load it by name. No `flutter` dependency, no method channel.
typedef FoundCbNative = ffi.Void Function(ffi.Int64, ffi.Pointer<ffi.Char>);
typedef InquiryDoneCbNative = ffi.Void Function(ffi.Int64, ffi.Int32);
typedef DataCbNative =
    ffi.Void Function(ffi.Int64, ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef StateCbNative = ffi.Void Function(ffi.Int64, ffi.Int32);

class AndroidBindings {
  AndroidBindings._(this._lib) {
    free = _lib
        .lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)
        >('btc_free');
    register = _lib
        .lookupFunction<
          ffi.Void Function(
            ffi.Pointer<ffi.NativeFunction<FoundCbNative>>,
            ffi.Pointer<ffi.NativeFunction<InquiryDoneCbNative>>,
            ffi.Pointer<ffi.NativeFunction<DataCbNative>>,
            ffi.Pointer<ffi.NativeFunction<StateCbNative>>,
          ),
          void Function(
            ffi.Pointer<ffi.NativeFunction<FoundCbNative>>,
            ffi.Pointer<ffi.NativeFunction<InquiryDoneCbNative>>,
            ffi.Pointer<ffi.NativeFunction<DataCbNative>>,
            ffi.Pointer<ffi.NativeFunction<StateCbNative>>,
          )
        >('btc_and_register');
    init = _lib.lookupFunction<ffi.Int32 Function(), int Function()>(
      'btc_and_init',
    );
    adapterState = _lib.lookupFunction<ffi.Int32 Function(), int Function()>(
      'btc_and_adapter_state',
    );
    bondedJson = _lib
        .lookupFunction<
          ffi.Pointer<ffi.Char> Function(),
          ffi.Pointer<ffi.Char> Function()
        >('btc_and_bonded_json');
    startDiscovery = _lib
        .lookupFunction<ffi.Int32 Function(ffi.Int64), int Function(int)>(
          'btc_and_start_discovery',
        );
    stopDiscovery = _lib.lookupFunction<ffi.Int32 Function(), int Function()>(
      'btc_and_stop_discovery',
    );
    open = _lib
        .lookupFunction<
          ffi.Int64 Function(
            ffi.Int64,
            ffi.Pointer<ffi.Char>,
            ffi.Int32,
            ffi.Pointer<ffi.Char>,
          ),
          int Function(int, ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Char>)
        >('btc_and_open');
    write = _lib
        .lookupFunction<
          ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Uint8>, ffi.Int32),
          int Function(int, ffi.Pointer<ffi.Uint8>, int)
        >('btc_and_write');
    flush = _lib
        .lookupFunction<ffi.Int32 Function(ffi.Int64), int Function(int)>(
          'btc_and_flush',
        );
    // Optional symbols (added in 0.2.0): tolerate an older .so — a version
    // skew between the Dart package and the bundled native library must not
    // take down the whole backend, only degrade these two getters.
    try {
      maxTx = _lib
          .lookupFunction<ffi.Int32 Function(ffi.Int64), int Function(int)>(
            'btc_and_max_tx',
          );
    } on ArgumentError {
      maxTx = (_) => -1;
    }
    try {
      pendingBytes = _lib
          .lookupFunction<ffi.Int64 Function(ffi.Int64), int Function(int)>(
            'btc_and_pending_bytes',
          );
    } on ArgumentError {
      pendingBytes = (_) => 0;
    }
    close = _lib
        .lookupFunction<ffi.Int32 Function(ffi.Int64), int Function(int)>(
          'btc_and_close',
        );
    reset = _lib.lookupFunction<ffi.Void Function(), void Function()>(
      'btc_and_reset',
    );
  }

  factory AndroidBindings.open() =>
      AndroidBindings._(ffi.DynamicLibrary.open(_libName));

  /// Per-isolate singleton. The underlying .so and its symbols are
  /// process-wide, so re-opening per call bought nothing — and the previous
  /// nullable `_activeLib` plumbing could silently skip `free` (a leak) when
  /// no backend happened to be constructed yet.
  static final AndroidBindings instance = AndroidBindings.open();

  static const String _libName = 'libbluetooth_rfcomm_android.so';

  final ffi.DynamicLibrary _lib;

  late final void Function(ffi.Pointer<ffi.Void>) free;
  late final void Function(
    ffi.Pointer<ffi.NativeFunction<FoundCbNative>>,
    ffi.Pointer<ffi.NativeFunction<InquiryDoneCbNative>>,
    ffi.Pointer<ffi.NativeFunction<DataCbNative>>,
    ffi.Pointer<ffi.NativeFunction<StateCbNative>>,
  )
  register;
  late final int Function() init;
  late final int Function() adapterState;
  late final ffi.Pointer<ffi.Char> Function() bondedJson;
  late final int Function(int) startDiscovery;
  late final int Function() stopDiscovery;
  late final int Function(
    int,
    ffi.Pointer<ffi.Char>,
    int,
    ffi.Pointer<ffi.Char>,
  )
  open;
  late final int Function(int, ffi.Pointer<ffi.Uint8>, int) write;

  /// Blocks until every write queued before the call has been handed to the
  /// socket (bounded at 10s natively). Returns 0 on success, -1 on
  /// timeout/closed/unknown handle, or when any earlier queued write failed
  /// (bytes were lost — the drain must not report success).
  late final int Function(int) flush;

  /// OS-advertised max single-write payload
  /// (`BluetoothSocket.getMaxTransmitPacketSize`, API 23+); <= 0 = unknown.
  late final int Function(int) maxTx;

  /// Bytes submitted to the handle's write executor and not yet handed to the
  /// socket (exact; 0 for unknown/closed handles).
  late final int Function(int) pendingBytes;
  late final int Function(int) close;

  /// Quiesces every native event source (read loops, discovery receiver) so
  /// nothing can invoke a callback afterwards. Called AFTER [register] at
  /// construction (so any dying read-loop's final events land in the NEW
  /// listeners, which token-drop them) and at dispose.
  late final void Function() reset;
}
