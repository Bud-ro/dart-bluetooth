import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';
import '../../logging.dart';
import '../../models/ble_characteristic.dart';
import '../../models/ble_service.dart';
import '../../models/device_id.dart';
import '../../models/enums.dart';
import '../../models/scan_result.dart';
import '../../models/uuid.dart';
import '../platform_interface.dart';
import 'windows_ble_ffi.dart';

/// Windows BLE central over the Win32 GATT client API (`BluetoothApis.dll`).
///
/// Pure Dart — no native build. **Scope (honest limits of the Win32 path):**
///
/// * **Connect/read/write/discover work only for already-paired devices.** Win32
///   GATT has no advertisement-scan API, so [startScan] throws
///   [BleUnsupportedException]; discovering/​pairing new devices needs the WinRT
///   `BluetoothLEAdvertisementWatcher` (out of scope for the pure-FFI backend).
/// * **Notifications are unavailable on this backend.** `BluetoothGATTRegisterEvent`
///   delivers value-changed data in a pointer valid only during a synchronous
///   callback on a Windows threadpool thread; Dart's `NativeCallable.listener`
///   runs asynchronously (reading it later is a use-after-free) and
///   `isolateLocal` can't be invoked from a foreign thread. A correct
///   implementation needs a small native shim (a future enhancement), so
///   [GattConnection.subscribe] throws here.
///
/// Implemented but pending on-device validation.
class WindowsBleCentral extends BleCentralPlatform {
  WindowsBleCentral() : _lib = WindowsBleBindings();

  final WindowsBleBindings _lib;

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<BluetoothAdapterState> adapterState() async {
    final params = calloc<ffi.Uint32>();
    final radio = calloc<ffi.IntPtr>();
    try {
      params.value = 4; // sizeof(BLUETOOTH_FIND_RADIO_PARAMS)
      final find = _lib.findFirstRadio(params, radio);
      if (find == 0) return BluetoothAdapterState.off;
      if (radio.value != 0) _lib.closeHandle(radio.value);
      _lib.findRadioClose(find);
      return BluetoothAdapterState.on;
    } catch (_) {
      return BluetoothAdapterState.unavailable;
    } finally {
      calloc.free(params);
      calloc.free(radio);
    }
  }

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() async* {
    yield await adapterState();
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async =>
      throw const BleUnsupportedException(
        'Toggling the radio is not supported via the Win32 GATT backend.',
      );

  @override
  Stream<BleScanResult> startScan({List<Uuid>? withServices}) =>
      throw const BleUnsupportedException(
        'Win32 GATT has no advertisement-scan API; scanning for unpaired '
        'devices requires the WinRT advertisement watcher (not supported by '
        'the pure-FFI Windows backend). Pair the device in Windows settings, '
        'then connect by its address.',
      );

  @override
  Future<void> stopScan() async {}

  @override
  Future<GattConnection> connect(DeviceId id, {Duration? timeout}) async {
    if (!id.isAddress) {
      throw const BleConnectionException(
        'Windows requires a MAC-address DeviceId to connect',
      );
    }
    logConnection.fine(() => 'connecting to ${id.value}');
    final path = _findDevicePath(id.address);
    if (path == null) {
      throw DeviceNotFoundException(
        'No paired BLE device for ${id.value}; pair it in Windows settings '
        'first',
      );
    }
    final pathPtr = path.toNativeUtf16();
    final int handle;
    try {
      handle = _lib.createFile(
        pathPtr,
        genericRead | genericWrite,
        fileShareRead | fileShareWrite,
        ffi.nullptr,
        openExisting,
        0,
        0,
      );
    } finally {
      calloc.free(pathPtr);
    }
    if (handle == invalidHandleValue || handle == 0) {
      throw BleConnectionException(
        'CreateFile failed for ${id.value}',
        code: _lib.getLastError(),
      );
    }
    return WindowsGattConnection(handle, _lib);
  }

  /// Enumerates `GUID_BLUETOOTHLE_DEVICE_INTERFACE` and returns the device
  /// interface path whose embedded address matches [address], or null.
  String? _findDevicePath(String address) {
    final target = 'dev_${address.replaceAll(':', '').toLowerCase()}';
    final guid = calloc<Guid>();
    final ifaceData = calloc<SpDeviceInterfaceData>();
    final reqSize = calloc<ffi.Uint32>();
    WindowsBleBindings.writeBleInterfaceGuid(guid.ref);
    final devInfo = _lib.getClassDevs(
      guid,
      ffi.nullptr,
      0,
      digcfPresent | digcfDeviceInterface,
    );
    if (devInfo == invalidHandleValue || devInfo == 0) {
      calloc
        ..free(guid)
        ..free(ifaceData)
        ..free(reqSize);
      return null;
    }
    try {
      ifaceData.ref.cbSize = ffi.sizeOf<SpDeviceInterfaceData>();
      var index = 0;
      while (_lib.enumDeviceInterfaces(
            devInfo,
            ffi.nullptr,
            guid,
            index,
            ifaceData,
          ) !=
          0) {
        index++;
        // First call sizes the detail buffer; second reads the path.
        _lib.getDeviceInterfaceDetail(
          devInfo,
          ifaceData,
          ffi.nullptr,
          0,
          reqSize,
          ffi.nullptr,
        );
        final size = reqSize.value;
        if (size == 0) continue;
        final detail = calloc<ffi.Uint8>(size);
        try {
          detail.cast<ffi.Uint32>().value = spDeviceInterfaceDetailCbSize64;
          if (_lib.getDeviceInterfaceDetail(
                devInfo,
                ifaceData,
                detail,
                size,
                ffi.nullptr,
                ffi.nullptr,
              ) ==
              0) {
            continue;
          }
          final path = ffi.Pointer<Utf16>.fromAddress(
            detail.address + spDeviceInterfaceDetailPathOffset,
          ).toDartString();
          if (path.toLowerCase().contains(target)) return path;
        } finally {
          calloc.free(detail);
        }
      }
      return null;
    } finally {
      _lib.destroyDeviceInfoList(devInfo);
      calloc
        ..free(guid)
        ..free(ifaceData)
        ..free(reqSize);
    }
  }
}

/// A live Win32 GATT connection backed by a device `HANDLE`.
class WindowsGattConnection implements GattConnection {
  WindowsGattConnection(this._handle, this._lib) {
    _stateController.add(BleConnectionState.connected);
  }

  int _handle;
  final WindowsBleBindings _lib;
  final StreamController<BleConnectionState> _stateController =
      StreamController<BleConnectionState>.broadcast();
  // Malloc'd characteristic structs kept for the connection's lifetime so
  // read/write can pass them back to the Win32 API. Keyed "service|char".
  final Map<String, ffi.Pointer<BthLeGattCharacteristic>> _chars = {};
  Future<void> _opChain = Future<void>.value();
  BleConnectionState _current = BleConnectionState.connected;
  bool _closed = false;

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _opChain.then((_) => op());
    _opChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Stream<BleConnectionState> get stateChanges => _stateController.stream;

  @override
  BleConnectionState get state => _current;

  @override
  Future<List<BleService>> discoverServices() {
    return _enqueue(() async {
      logGatt.fine('discoverServices');
      _freeChars();
      final services = <BleService>[];
      final actual = calloc<ffi.Uint16>();
      try {
        var hr = _lib.gattGetServices(
          _handle,
          0,
          ffi.nullptr.cast(),
          actual,
          bluetoothGattFlagNone,
        );
        final count = actual.value;
        if (count == 0) return services;
        final buf = calloc<BthLeGattService>(count);
        try {
          hr = _lib.gattGetServices(
            _handle,
            count,
            buf,
            actual,
            bluetoothGattFlagNone,
          );
          if (hr != sOk) throw BleGattException('GetServices failed', code: hr);
          for (var i = 0; i < actual.value; i++) {
            final svcPtr = ffi.Pointer<BthLeGattService>.fromAddress(
              buf.address + i * ffi.sizeOf<BthLeGattService>(),
            );
            services.add(_discoverCharacteristics(svcPtr));
          }
        } finally {
          calloc.free(buf);
        }
        return services;
      } finally {
        calloc.free(actual);
      }
    });
  }

  BleService _discoverCharacteristics(ffi.Pointer<BthLeGattService> svcPtr) {
    final serviceUuid = Uuid(readBthLeUuid(svcPtr.ref.serviceUuid));
    final chars = <BleCharacteristic>[];
    final actual = calloc<ffi.Uint16>();
    try {
      _lib.gattGetCharacteristics(
        _handle,
        svcPtr,
        0,
        ffi.nullptr.cast(),
        actual,
        bluetoothGattFlagNone,
      );
      final count = actual.value;
      if (count == 0) return BleService(uuid: serviceUuid, characteristics: []);
      final buf = calloc<BthLeGattCharacteristic>(count);
      final hr = _lib.gattGetCharacteristics(
        _handle,
        svcPtr,
        count,
        buf,
        actual,
        bluetoothGattFlagNone,
      );
      if (hr != sOk) {
        calloc.free(buf);
        throw BleGattException('GetCharacteristics failed', code: hr);
      }
      for (var i = 0; i < actual.value; i++) {
        final src = ffi.Pointer<BthLeGattCharacteristic>.fromAddress(
          buf.address + i * ffi.sizeOf<BthLeGattCharacteristic>(),
        );
        final charUuid = Uuid(readBthLeUuid(src.ref.characteristicUuid));
        // Persist a copy so read/write can reference it after this returns.
        final keep = calloc<BthLeGattCharacteristic>();
        _copyCharacteristic(src.ref, keep.ref);
        _chars['${serviceUuid.value}|${charUuid.value}'] = keep;
        chars.add(
          BleCharacteristic(
            serviceUuid: serviceUuid,
            uuid: charUuid,
            properties: _propertiesOf(src.ref),
          ),
        );
      }
      calloc.free(buf);
      return BleService(uuid: serviceUuid, characteristics: chars);
    } finally {
      calloc.free(actual);
    }
  }

  @override
  Future<Uint8List> readCharacteristic(Uuid service, Uuid characteristic) {
    return _enqueue(() async {
      final charPtr = await _charPtr(service, characteristic);
      logGatt.fine(() => 'read ${characteristic.value}');
      final sizeReq = calloc<ffi.Uint16>();
      try {
        _lib.gattGetCharacteristicValue(
          _handle,
          charPtr,
          0,
          ffi.nullptr,
          sizeReq,
          bluetoothGattFlagNone,
        );
        final size = sizeReq.value;
        if (size == 0) return Uint8List(0);
        final buf = calloc<ffi.Uint8>(size);
        try {
          final hr = _lib.gattGetCharacteristicValue(
            _handle,
            charPtr,
            size,
            buf,
            ffi.nullptr,
            bluetoothGattFlagNone,
          );
          if (hr != sOk) throw BleGattException('read failed', code: hr);
          final dataSize = buf.cast<ffi.Uint32>().value;
          final dataPtr = ffi.Pointer<ffi.Uint8>.fromAddress(buf.address + 4);
          return Uint8List.fromList(dataPtr.asTypedList(dataSize));
        } finally {
          calloc.free(buf);
        }
      } finally {
        calloc.free(sizeReq);
      }
    });
  }

  @override
  Future<void> writeCharacteristic(
    Uuid service,
    Uuid characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  }) {
    return _enqueue(() async {
      final charPtr = await _charPtr(service, characteristic);
      logData.finest(
        () => 'write ${characteristic.value} ${describeBytes(value)}',
      );
      final total = 4 + value.length;
      final vbuf = calloc<ffi.Uint8>(total);
      try {
        vbuf.cast<ffi.Uint32>().value = value.length;
        if (value.isNotEmpty) {
          final dataPtr = ffi.Pointer<ffi.Uint8>.fromAddress(vbuf.address + 4);
          dataPtr.asTypedList(value.length).setAll(0, value);
        }
        final flags = withoutResponse
            ? bluetoothGattFlagWriteWithoutResponse
            : bluetoothGattFlagNone;
        final hr = _lib.gattSetCharacteristicValue(
          _handle,
          charPtr,
          vbuf,
          0,
          flags,
        );
        if (hr != sOk) throw BleGattException('write failed', code: hr);
      } finally {
        calloc.free(vbuf);
      }
    });
  }

  @override
  Stream<Uint8List> subscribe(Uuid service, Uuid characteristic) =>
      throw const BleUnsupportedException(
        'GATT notifications are not supported by the pure-FFI Windows backend '
        '(Win32 value-changed events need a native callback shim). Use read/'
        'write, or poll readCharacteristic.',
      );

  @override
  Future<int> requestMtu(int mtu) async {
    // Win32 GATT negotiates the ATT MTU internally and does not expose a request
    // API or the negotiated value; report the ATT default.
    return 23;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_handle != 0 && _handle != invalidHandleValue) {
      _lib.closeHandle(_handle);
      _handle = 0;
    }
    _freeChars();
    if (_current != BleConnectionState.disconnected) {
      _current = BleConnectionState.disconnected;
      if (!_stateController.isClosed) {
        _stateController.add(BleConnectionState.disconnected);
      }
    }
    if (!_stateController.isClosed) await _stateController.close();
  }

  Future<ffi.Pointer<BthLeGattCharacteristic>> _charPtr(
    Uuid service,
    Uuid characteristic,
  ) async {
    final key = '${service.value}|${characteristic.value}';
    final cached = _chars[key];
    if (cached != null) return cached;
    await discoverServices();
    final p = _chars[key];
    if (p == null) {
      throw CharacteristicNotFoundException(
        'No characteristic ${characteristic.value} in service ${service.value}',
      );
    }
    return p;
  }

  void _freeChars() {
    for (final p in _chars.values) {
      calloc.free(p);
    }
    _chars.clear();
  }

  static Set<CharacteristicProperty> _propertiesOf(BthLeGattCharacteristic c) {
    final out = <CharacteristicProperty>{};
    if (c.isReadable != 0) out.add(CharacteristicProperty.read);
    if (c.isWritable != 0) out.add(CharacteristicProperty.write);
    if (c.isWritableWithoutResponse != 0) {
      out.add(CharacteristicProperty.writeWithoutResponse);
    }
    if (c.isNotifiable != 0) out.add(CharacteristicProperty.notify);
    if (c.isIndicatable != 0) out.add(CharacteristicProperty.indicate);
    return out;
  }

  static void _copyCharacteristic(
    BthLeGattCharacteristic src,
    BthLeGattCharacteristic dst,
  ) {
    dst.serviceHandle = src.serviceHandle;
    dst.attributeHandle = src.attributeHandle;
    dst.characteristicValueHandle = src.characteristicValueHandle;
    dst.isBroadcastable = src.isBroadcastable;
    dst.isReadable = src.isReadable;
    dst.isWritable = src.isWritable;
    dst.isWritableWithoutResponse = src.isWritableWithoutResponse;
    dst.isSignedWritable = src.isSignedWritable;
    dst.isNotifiable = src.isNotifiable;
    dst.isIndicatable = src.isIndicatable;
    dst.hasExtendedProperties = src.hasExtendedProperties;
    dst.characteristicUuid.isShortUuid = src.characteristicUuid.isShortUuid;
    final s = src.characteristicUuid.value.longUuid;
    final d = dst.characteristicUuid.value.longUuid;
    dst.characteristicUuid.value.shortUuid =
        src.characteristicUuid.value.shortUuid;
    d.data1 = s.data1;
    d.data2 = s.data2;
    d.data3 = s.data3;
    for (var i = 0; i < 8; i++) {
      d.data4[i] = s.data4[i];
    }
  }
}
