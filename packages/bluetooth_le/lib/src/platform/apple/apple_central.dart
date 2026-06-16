import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';
import '../../logging.dart';
import '../../models/ble_device.dart';
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
/// Built incrementally: adapter state and scanning are wired; connect/GATT next.
class AppleBleCentral extends BleCentralPlatform {
  AppleBleCentral() {
    bleRegister(
      _scanCb.nativeFunction,
      _stateCb.nativeFunction,
      _opCb.nativeFunction,
      _notifyCb.nativeFunction,
    );
  }

  static int _nextScanToken = 1;
  static StreamController<BleScanResult>? _scanController;
  static int _scanToken = 0;

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
    // CoreBluetooth live state-change bridging lands later; emit current.
    yield await adapterState();
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async =>
      throw const BleUnsupportedException(
        'Apps cannot toggle the Bluetooth radio on macOS/iOS.',
      );

  @override
  Stream<BleScanResult> startScan({List<Uuid>? withServices}) {
    final token = _nextScanToken++;
    late StreamController<BleScanResult> controller;
    controller = StreamController<BleScanResult>.broadcast(
      onListen: () {
        _scanController = controller;
        _scanToken = token;
        final csv = (withServices == null || withServices.isEmpty)
            ? ''
            : withServices.map((u) => u.value).join(',');
        final ptr = csv.toNativeUtf8();
        try {
          bleStartScan(token, ptr.cast());
          logScan.fine('scan started');
        } finally {
          calloc.free(ptr);
        }
      },
      onCancel: () {
        if (_scanToken == token) {
          bleStopScan();
          _scanController = null;
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    bleStopScan();
    if (_scanController != null && !_scanController!.isClosed) {
      await _scanController!.close();
    }
    _scanController = null;
  }

  @override
  Future<GattConnection> connect(DeviceId id, {Duration? timeout}) async =>
      throw const BleUnsupportedException(
        'CoreBluetooth connect is not wired yet',
      );

  // --- native callback dispatch --------------------------------------------

  static void _onScan(int token, ffi.Pointer<ffi.Char> json) {
    try {
      final controller = _scanController;
      if (controller == null ||
          controller.isClosed ||
          _scanToken != token ||
          json == ffi.nullptr) {
        return;
      }
      final map =
          jsonDecode(json.cast<Utf8>().toDartString()) as Map<String, dynamic>;
      controller.add(_scanResultFromJson(map));
    } catch (e) {
      logNative.fine(() => 'skipped malformed scan result: $e');
    } finally {
      if (json != ffi.nullptr) bleFree(json.cast());
    }
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

  static BleScanResult _scanResultFromJson(Map<String, dynamic> j) {
    final rssi = (j['rssi'] as num?)?.toInt();
    final device = BleDevice(
      // Apple uses an opaque CBPeripheral identifier (a UUID), not a MAC.
      id: DeviceId.opaque(j['id'] as String),
      name: j['name'] as String?,
      rssi: rssi,
    );
    final serviceUuids =
        (j['serviceUuids'] as List?)
            ?.map((s) => Uuid(s as String))
            .toList(growable: false) ??
        const <Uuid>[];
    final manufacturerData = <int, Uint8List>{};
    (j['manufacturerData'] as Map?)?.forEach((k, v) {
      manufacturerData[int.parse(k as String)] = _hexToBytes(v as String);
    });
    final serviceData = <Uuid, Uint8List>{};
    (j['serviceData'] as Map?)?.forEach((k, v) {
      serviceData[Uuid(k as String)] = _hexToBytes(v as String);
    });
    return BleScanResult(
      device: device,
      timestamp: DateTime.now(),
      rssi: rssi,
      serviceUuids: serviceUuids,
      manufacturerData: manufacturerData,
      serviceData: serviceData,
      connectable: (j['connectable'] as bool?) ?? true,
    );
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
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
