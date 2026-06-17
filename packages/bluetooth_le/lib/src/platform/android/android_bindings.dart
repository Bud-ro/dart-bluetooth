import 'dart:ffi' as ffi;

/// FFI bindings to the Android C ABI (native/android/bluetooth_le_jni.c in the
/// bluetooth_le_flutter plugin), which bridges to the Kotlin BluetoothGatt
/// backend via JNI.
///
/// Like the RFCOMM plugin, Android uses Flutter's `ffiPlugin` path: the CMake
/// build produces `libbluetooth_le_android.so`, Flutter bundles it into the
/// APK's jniLibs, and we load it by name. No `flutter` dependency, no method
/// channel. Callback shapes mirror the Apple C ABI so the Dart backend correlates
/// async GATT ops identically.
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

class AndroidBindings {
  AndroidBindings._(this._lib) {
    free = _lib
        .lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)
        >('ble_free');
    register = _lib
        .lookupFunction<
          ffi.Void Function(
            ffi.Pointer<ffi.NativeFunction<ScanCbNative>>,
            ffi.Pointer<ffi.NativeFunction<StateCbNative>>,
            ffi.Pointer<ffi.NativeFunction<OpCbNative>>,
            ffi.Pointer<ffi.NativeFunction<NotifyCbNative>>,
          ),
          void Function(
            ffi.Pointer<ffi.NativeFunction<ScanCbNative>>,
            ffi.Pointer<ffi.NativeFunction<StateCbNative>>,
            ffi.Pointer<ffi.NativeFunction<OpCbNative>>,
            ffi.Pointer<ffi.NativeFunction<NotifyCbNative>>,
          )
        >('ble_and_register');
    init = _lib.lookupFunction<ffi.Int32 Function(), int Function()>(
      'ble_and_init',
    );
    adapterState = _lib.lookupFunction<ffi.Int32 Function(), int Function()>(
      'ble_and_adapter_state',
    );
    startScan = _lib
        .lookupFunction<
          ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Char>),
          int Function(int, ffi.Pointer<ffi.Char>)
        >('ble_and_start_scan');
    stopScan = _lib.lookupFunction<ffi.Void Function(), void Function()>(
      'ble_and_stop_scan',
    );
    connect = _lib
        .lookupFunction<
          ffi.Int32 Function(ffi.Int64, ffi.Pointer<ffi.Char>),
          int Function(int, ffi.Pointer<ffi.Char>)
        >('ble_and_connect');
    disconnect = _lib
        .lookupFunction<ffi.Void Function(ffi.Int64), void Function(int)>(
          'ble_and_disconnect',
        );
    discoverServices = _lib
        .lookupFunction<
          ffi.Void Function(ffi.Int64, ffi.Int64),
          void Function(int, int)
        >('ble_and_discover_services');
    read = _lib
        .lookupFunction<
          ffi.Void Function(
            ffi.Int64,
            ffi.Int64,
            ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Char>,
          ),
          void Function(int, int, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>)
        >('ble_and_read');
    write = _lib
        .lookupFunction<
          ffi.Void Function(
            ffi.Int64,
            ffi.Int64,
            ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Int32,
            ffi.Int32,
          ),
          void Function(
            int,
            int,
            ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Uint8>,
            int,
            int,
          )
        >('ble_and_write');
    subscribe = _lib
        .lookupFunction<
          ffi.Void Function(
            ffi.Int64,
            ffi.Pointer<ffi.Char>,
            ffi.Pointer<ffi.Char>,
            ffi.Int32,
          ),
          void Function(int, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, int)
        >('ble_and_subscribe');
    requestMtu = _lib
        .lookupFunction<
          ffi.Void Function(ffi.Int64, ffi.Int64, ffi.Int32),
          void Function(int, int, int)
        >('ble_and_request_mtu');
  }

  factory AndroidBindings.open() =>
      AndroidBindings._(ffi.DynamicLibrary.open(_libName));

  static const String _libName = 'libbluetooth_le_android.so';

  final ffi.DynamicLibrary _lib;

  late final void Function(ffi.Pointer<ffi.Void>) free;
  late final void Function(
    ffi.Pointer<ffi.NativeFunction<ScanCbNative>>,
    ffi.Pointer<ffi.NativeFunction<StateCbNative>>,
    ffi.Pointer<ffi.NativeFunction<OpCbNative>>,
    ffi.Pointer<ffi.NativeFunction<NotifyCbNative>>,
  )
  register;
  late final int Function() init;
  late final int Function() adapterState;
  late final int Function(int, ffi.Pointer<ffi.Char>) startScan;
  late final void Function() stopScan;
  late final int Function(int, ffi.Pointer<ffi.Char>) connect;
  late final void Function(int) disconnect;
  late final void Function(int, int) discoverServices;
  late final void Function(
    int,
    int,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
  read;
  late final void Function(
    int,
    int,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
  )
  write;
  late final void Function(
    int,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    int,
  )
  subscribe;
  late final void Function(int, int, int) requestMtu;
}
