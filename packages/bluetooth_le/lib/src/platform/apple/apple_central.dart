import 'dart:async';
import 'dart:ffi' as ffi;

import '../../exceptions.dart';
import '../../models/device_id.dart';
import '../../models/enums.dart';
import '../../models/scan_result.dart';
import '../../models/uuid.dart';
import '../platform_interface.dart';
import 'apple_bindings.dart';

/// macOS + iOS backend over CoreBluetooth (one source for both — CoreBluetooth
/// is identical). Calls into the C ABI in `src/native/apple/` via `dart:ffi`;
/// native events arrive as `NativeCallable.listener` events on this isolate.
///
/// Built incrementally: adapter state is wired; scan/connect/GATT land next.
class AppleBleCentral extends BleCentralPlatform {
  AppleBleCentral() {
    bleRegister(
      _scanCb.nativeFunction,
      _stateCb.nativeFunction,
      _opCb.nativeFunction,
      _notifyCb.nativeFunction,
    );
  }

  // One shared listener per callback kind, kept alive for the process.
  static final ffi.NativeCallable<ScanCbNative> _scanCb =
      ffi.NativeCallable<ScanCbNative>.listener(_onScan);
  static final ffi.NativeCallable<StateCbNative> _stateCb =
      ffi.NativeCallable<StateCbNative>.listener(_onState);
  static final ffi.NativeCallable<OpCbNative> _opCb =
      ffi.NativeCallable<OpCbNative>.listener(_onOp);
  static final ffi.NativeCallable<NotifyCbNative> _notifyCb =
      ffi.NativeCallable<NotifyCbNative>.listener(_onNotify);

  @override
  Future<bool> isSupported() async =>
      bleAdapterState() != _AdapterCode.unavailable;

  @override
  Future<BluetoothAdapterState> adapterState() async =>
      _AdapterCode.toEnum(bleAdapterState());

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() async* {
    // CoreBluetooth state-change bridging lands with the scan revision.
    yield await adapterState();
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async =>
      throw const BleUnsupportedException(
        'Apps cannot toggle the Bluetooth radio on macOS/iOS.',
      );

  @override
  Stream<BleScanResult> startScan({List<Uuid>? withServices}) =>
      throw const BleUnsupportedException(
        'CoreBluetooth scan is not wired yet',
      );

  @override
  Future<void> stopScan() async {}

  @override
  Future<GattConnection> connect(DeviceId id, {Duration? timeout}) async =>
      throw const BleUnsupportedException(
        'CoreBluetooth connect is not wired yet',
      );

  // --- native callback dispatch (free the malloc'd payloads) ---------------

  static void _onScan(int token, ffi.Pointer<ffi.Char> json) {
    if (json != ffi.nullptr) bleFree(json.cast());
  }

  static void _onState(int token, int state) {}

  static void _onOp(
    int reqId,
    int status,
    ffi.Pointer<ffi.Char> json,
    ffi.Pointer<ffi.Uint8> data,
    int len,
  ) {
    if (json != ffi.nullptr) bleFree(json.cast());
    if (data != ffi.nullptr) bleFree(data.cast());
  }

  static void _onNotify(
    int token,
    ffi.Pointer<ffi.Char> characteristic,
    ffi.Pointer<ffi.Uint8> data,
    int len,
  ) {
    if (characteristic != ffi.nullptr) bleFree(characteristic.cast());
    if (data != ffi.nullptr) bleFree(data.cast());
  }
}

abstract final class _AdapterCode {
  static const int unavailable = 1;
  static BluetoothAdapterState toEnum(int code) => switch (code) {
    1 => BluetoothAdapterState.unavailable,
    2 => BluetoothAdapterState.unauthorized,
    3 => BluetoothAdapterState.off,
    5 => BluetoothAdapterState.on,
    _ => BluetoothAdapterState.unknown,
  };
}
