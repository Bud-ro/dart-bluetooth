// Raw FFI bindings for the Windows Win32 GATT client API (`BluetoothApis.dll`)
// plus device enumeration (`setupapi.dll`) and handle management
// (`kernel32.dll`). No native build — all system DLLs, so this works from a
// pure-Dart CLI and a Flutter Windows app alike.
//
// The GATT structs (bthledef.h) use natural (default) alignment, which Dart FFI
// also applies. BTH_LE_UUID embeds a union aligned to 4 (its GUID member), which
// pushes several field offsets — exactly the kind of layout the byte-layout
// tests in test/windows_ffi_test.dart pin against the documented Win32 ABI.
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

// --- Constants ---------------------------------------------------------------

const int digcfPresent = 0x00000002;
const int digcfDeviceInterface = 0x00000010;

const int genericRead = 0x80000000;
const int genericWrite = 0x40000000;
const int fileShareRead = 0x00000001;
const int fileShareWrite = 0x00000002;
const int openExisting = 3;

/// `INVALID_HANDLE_VALUE` is `(HANDLE)-1`.
const int invalidHandleValue = -1;

const int bluetoothGattFlagNone = 0x00000000;
const int bluetoothGattFlagWriteWithoutResponse = 0x00000004;

/// `S_OK`.
const int sOk = 0;

/// `GUID_BLUETOOTHLE_DEVICE_INTERFACE` = {781aee18-7733-4ce4-add0-91f41c67b592}.
const int _bleIfaceData1 = 0x781aee18;
const int _bleIfaceData2 = 0x7733;
const int _bleIfaceData3 = 0x4ce4;
const List<int> _bleIfaceData4 = [
  0xad,
  0xd0,
  0x91,
  0xf4,
  0x1c,
  0x67,
  0xb5,
  0x92,
];

// --- Structs -----------------------------------------------------------------

/// `GUID`. 16 bytes, 4-aligned.
final class Guid extends ffi.Struct {
  @ffi.Uint32()
  external int data1;
  @ffi.Uint16()
  external int data2;
  @ffi.Uint16()
  external int data3;
  @ffi.Array<ffi.Uint8>(8)
  external ffi.Array<ffi.Uint8> data4;
}

/// The `Value` union of `BTH_LE_UUID` (short USHORT vs long GUID). Union
/// alignment is 4 (the GUID), size 16.
final class BthLeUuidValue extends ffi.Union {
  @ffi.Uint16()
  external int shortUuid;
  external Guid longUuid;
}

/// `BTH_LE_UUID` from bthledef.h: BOOLEAN + (3 pad) + union. 20 bytes, 4-aligned.
final class BthLeUuid extends ffi.Struct {
  @ffi.Uint8()
  external int isShortUuid; // BOOLEAN
  external BthLeUuidValue value; // 4-aligned -> offset 4
}

/// `BTH_LE_GATT_SERVICE`: BTH_LE_UUID + USHORT. 24 bytes (padded), 4-aligned.
final class BthLeGattService extends ffi.Struct {
  external BthLeUuid serviceUuid; // @0, 20
  @ffi.Uint16()
  external int attributeHandle; // @20
}

/// `BTH_LE_GATT_CHARACTERISTIC`. 36 bytes, 4-aligned.
final class BthLeGattCharacteristic extends ffi.Struct {
  @ffi.Uint16()
  external int serviceHandle; // @0
  external BthLeUuid characteristicUuid; // @4 (2 pad), 20 -> ends @24
  @ffi.Uint16()
  external int attributeHandle; // @24
  @ffi.Uint16()
  external int characteristicValueHandle; // @26
  @ffi.Uint8()
  external int isBroadcastable; // @28
  @ffi.Uint8()
  external int isReadable; // @29
  @ffi.Uint8()
  external int isWritable; // @30
  @ffi.Uint8()
  external int isWritableWithoutResponse; // @31
  @ffi.Uint8()
  external int isSignedWritable; // @32
  @ffi.Uint8()
  external int isNotifiable; // @33
  @ffi.Uint8()
  external int isIndicatable; // @34
  @ffi.Uint8()
  external int hasExtendedProperties; // @35
}

/// `BTH_LE_GATT_DESCRIPTOR`. 32 bytes (padded), 4-aligned.
final class BthLeGattDescriptor extends ffi.Struct {
  @ffi.Uint16()
  external int serviceHandle; // @0
  @ffi.Uint16()
  external int characteristicHandle; // @2
  @ffi.Int32()
  external int descriptorType; // @4 (enum)
  external BthLeUuid descriptorUuid; // @8, 20 -> ends @28
  @ffi.Uint16()
  external int attributeHandle; // @28
}

/// Header of `BTH_LE_GATT_CHARACTERISTIC_VALUE` (`{ULONG DataSize; UCHAR Data[];}`).
/// The variable-length `Data` follows immediately after the 4-byte `dataSize`.
final class BthLeGattCharacteristicValueHeader extends ffi.Struct {
  @ffi.Uint32()
  external int dataSize;
}

/// `SP_DEVICE_INTERFACE_DATA`. 32 bytes on x64; `cbSize` must be set to that.
final class SpDeviceInterfaceData extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize; // @0
  external Guid interfaceClassGuid; // @4, 16
  @ffi.Uint32()
  external int flags; // @20
  @ffi.IntPtr()
  external int reserved; // @24 (8-aligned)
}

/// Offset of `DevicePath` within `SP_DEVICE_INTERFACE_DETAIL_DATA_W` (after the
/// 4-byte `cbSize`). The `cbSize` *value* to set differs from this (see below).
const int spDeviceInterfaceDetailPathOffset = 4;

/// `cbSize` to write into `SP_DEVICE_INTERFACE_DETAIL_DATA_W` on 64-bit Windows
/// (the struct is 8-aligned, so its reported size is 8 even though the path
/// starts at offset 4). A wrong value makes SetupDiGetDeviceInterfaceDetail fail.
const int spDeviceInterfaceDetailCbSize64 = 8;

// --- Function typedefs -------------------------------------------------------

typedef _GetClassDevsC =
    ffi.IntPtr Function(
      ffi.Pointer<Guid> classGuid,
      ffi.Pointer<Utf16> enumerator,
      ffi.IntPtr hwndParent,
      ffi.Uint32 flags,
    );
typedef GetClassDevsDart =
    int Function(
      ffi.Pointer<Guid> classGuid,
      ffi.Pointer<Utf16> enumerator,
      int hwndParent,
      int flags,
    );

typedef _EnumDeviceInterfacesC =
    ffi.Int32 Function(
      ffi.IntPtr devInfo,
      ffi.Pointer<ffi.Void> devInfoData,
      ffi.Pointer<Guid> interfaceClassGuid,
      ffi.Uint32 memberIndex,
      ffi.Pointer<SpDeviceInterfaceData> ifaceData,
    );
typedef EnumDeviceInterfacesDart =
    int Function(
      int devInfo,
      ffi.Pointer<ffi.Void> devInfoData,
      ffi.Pointer<Guid> interfaceClassGuid,
      int memberIndex,
      ffi.Pointer<SpDeviceInterfaceData> ifaceData,
    );

typedef _GetDeviceInterfaceDetailC =
    ffi.Int32 Function(
      ffi.IntPtr devInfo,
      ffi.Pointer<SpDeviceInterfaceData> ifaceData,
      ffi.Pointer<ffi.Uint8> detail,
      ffi.Uint32 detailSize,
      ffi.Pointer<ffi.Uint32> requiredSize,
      ffi.Pointer<ffi.Void> devInfoData,
    );
typedef GetDeviceInterfaceDetailDart =
    int Function(
      int devInfo,
      ffi.Pointer<SpDeviceInterfaceData> ifaceData,
      ffi.Pointer<ffi.Uint8> detail,
      int detailSize,
      ffi.Pointer<ffi.Uint32> requiredSize,
      ffi.Pointer<ffi.Void> devInfoData,
    );

typedef _DestroyDeviceInfoListC = ffi.Int32 Function(ffi.IntPtr devInfo);
typedef DestroyDeviceInfoListDart = int Function(int devInfo);

typedef _CreateFileC =
    ffi.IntPtr Function(
      ffi.Pointer<Utf16> name,
      ffi.Uint32 access,
      ffi.Uint32 shareMode,
      ffi.Pointer<ffi.Void> security,
      ffi.Uint32 disposition,
      ffi.Uint32 flags,
      ffi.IntPtr template,
    );
typedef CreateFileDart =
    int Function(
      ffi.Pointer<Utf16> name,
      int access,
      int shareMode,
      ffi.Pointer<ffi.Void> security,
      int disposition,
      int flags,
      int template,
    );

typedef _CloseHandleC = ffi.Int32 Function(ffi.IntPtr handle);
typedef CloseHandleDart = int Function(int handle);

typedef _GetLastErrorC = ffi.Uint32 Function();
typedef GetLastErrorDart = int Function();

typedef _GattGetServicesC =
    ffi.Int32 Function(
      ffi.IntPtr device,
      ffi.Uint16 count,
      ffi.Pointer<BthLeGattService> buffer,
      ffi.Pointer<ffi.Uint16> actual,
      ffi.Uint32 flags,
    );
typedef GattGetServicesDart =
    int Function(
      int device,
      int count,
      ffi.Pointer<BthLeGattService> buffer,
      ffi.Pointer<ffi.Uint16> actual,
      int flags,
    );

typedef _GattGetCharacteristicsC =
    ffi.Int32 Function(
      ffi.IntPtr device,
      ffi.Pointer<BthLeGattService> service,
      ffi.Uint16 count,
      ffi.Pointer<BthLeGattCharacteristic> buffer,
      ffi.Pointer<ffi.Uint16> actual,
      ffi.Uint32 flags,
    );
typedef GattGetCharacteristicsDart =
    int Function(
      int device,
      ffi.Pointer<BthLeGattService> service,
      int count,
      ffi.Pointer<BthLeGattCharacteristic> buffer,
      ffi.Pointer<ffi.Uint16> actual,
      int flags,
    );

typedef _GattGetCharacteristicValueC =
    ffi.Int32 Function(
      ffi.IntPtr device,
      ffi.Pointer<BthLeGattCharacteristic> characteristic,
      ffi.Uint32 valueDataSize,
      ffi.Pointer<ffi.Uint8> value,
      ffi.Pointer<ffi.Uint16> sizeRequired,
      ffi.Uint32 flags,
    );
typedef GattGetCharacteristicValueDart =
    int Function(
      int device,
      ffi.Pointer<BthLeGattCharacteristic> characteristic,
      int valueDataSize,
      ffi.Pointer<ffi.Uint8> value,
      ffi.Pointer<ffi.Uint16> sizeRequired,
      int flags,
    );

typedef _GattSetCharacteristicValueC =
    ffi.Int32 Function(
      ffi.IntPtr device,
      ffi.Pointer<BthLeGattCharacteristic> characteristic,
      ffi.Pointer<ffi.Uint8> value,
      ffi.Uint64 reliableWriteContext,
      ffi.Uint32 flags,
    );
typedef GattSetCharacteristicValueDart =
    int Function(
      int device,
      ffi.Pointer<BthLeGattCharacteristic> characteristic,
      ffi.Pointer<ffi.Uint8> value,
      int reliableWriteContext,
      int flags,
    );

typedef _FindFirstRadioC =
    ffi.IntPtr Function(
      ffi.Pointer<ffi.Uint32> params,
      ffi.Pointer<ffi.IntPtr> radio,
    );
typedef FindFirstRadioDart =
    int Function(ffi.Pointer<ffi.Uint32> params, ffi.Pointer<ffi.IntPtr> radio);

typedef _FindRadioCloseC = ffi.Int32 Function(ffi.IntPtr find);
typedef FindRadioCloseDart = int Function(int find);

/// Resolved Win32 symbols for the GATT client + device enumeration.
class WindowsBleBindings {
  WindowsBleBindings()
    : _bt = ffi.DynamicLibrary.open('BluetoothApis.dll'),
      _setup = ffi.DynamicLibrary.open('setupapi.dll'),
      _bthprops = ffi.DynamicLibrary.open('bthprops.cpl'),
      _k32 = ffi.DynamicLibrary.open('kernel32.dll') {
    getClassDevs = _setup.lookupFunction<_GetClassDevsC, GetClassDevsDart>(
      'SetupDiGetClassDevsW',
    );
    enumDeviceInterfaces = _setup
        .lookupFunction<_EnumDeviceInterfacesC, EnumDeviceInterfacesDart>(
          'SetupDiEnumDeviceInterfaces',
        );
    getDeviceInterfaceDetail = _setup
        .lookupFunction<
          _GetDeviceInterfaceDetailC,
          GetDeviceInterfaceDetailDart
        >('SetupDiGetDeviceInterfaceDetailW');
    destroyDeviceInfoList = _setup
        .lookupFunction<_DestroyDeviceInfoListC, DestroyDeviceInfoListDart>(
          'SetupDiDestroyDeviceInfoList',
        );
    createFile = _k32.lookupFunction<_CreateFileC, CreateFileDart>(
      'CreateFileW',
    );
    closeHandle = _k32.lookupFunction<_CloseHandleC, CloseHandleDart>(
      'CloseHandle',
    );
    getLastError = _k32.lookupFunction<_GetLastErrorC, GetLastErrorDart>(
      'GetLastError',
    );
    gattGetServices = _bt
        .lookupFunction<_GattGetServicesC, GattGetServicesDart>(
          'BluetoothGATTGetServices',
        );
    gattGetCharacteristics = _bt
        .lookupFunction<_GattGetCharacteristicsC, GattGetCharacteristicsDart>(
          'BluetoothGATTGetCharacteristics',
        );
    gattGetCharacteristicValue = _bt
        .lookupFunction<
          _GattGetCharacteristicValueC,
          GattGetCharacteristicValueDart
        >('BluetoothGATTGetCharacteristicValue');
    gattSetCharacteristicValue = _bt
        .lookupFunction<
          _GattSetCharacteristicValueC,
          GattSetCharacteristicValueDart
        >('BluetoothGATTSetCharacteristicValue');
    findFirstRadio = _bthprops
        .lookupFunction<_FindFirstRadioC, FindFirstRadioDart>(
          'BluetoothFindFirstRadio',
        );
    findRadioClose = _bthprops
        .lookupFunction<_FindRadioCloseC, FindRadioCloseDart>(
          'BluetoothFindRadioClose',
        );
  }

  final ffi.DynamicLibrary _bt;
  final ffi.DynamicLibrary _setup;
  final ffi.DynamicLibrary _bthprops;
  final ffi.DynamicLibrary _k32;

  late final GetClassDevsDart getClassDevs;
  late final EnumDeviceInterfacesDart enumDeviceInterfaces;
  late final GetDeviceInterfaceDetailDart getDeviceInterfaceDetail;
  late final DestroyDeviceInfoListDart destroyDeviceInfoList;
  late final CreateFileDart createFile;
  late final CloseHandleDart closeHandle;
  late final GetLastErrorDart getLastError;
  late final GattGetServicesDart gattGetServices;
  late final GattGetCharacteristicsDart gattGetCharacteristics;
  late final GattGetCharacteristicValueDart gattGetCharacteristicValue;
  late final GattSetCharacteristicValueDart gattSetCharacteristicValue;
  late final FindFirstRadioDart findFirstRadio;
  late final FindRadioCloseDart findRadioClose;

  /// Fills [out] with `GUID_BLUETOOTHLE_DEVICE_INTERFACE`.
  static void writeBleInterfaceGuid(Guid out) {
    out.data1 = _bleIfaceData1;
    out.data2 = _bleIfaceData2;
    out.data3 = _bleIfaceData3;
    for (var i = 0; i < 8; i++) {
      out.data4[i] = _bleIfaceData4[i];
    }
  }
}

// --- UUID helpers ------------------------------------------------------------

/// Writes a 128-bit UUID string into [out] as a long-form `BTH_LE_UUID`.
void writeBthLeUuid(BthLeUuid out, String uuid128) {
  out.isShortUuid = 0;
  final g = out.value.longUuid;
  final hex = uuid128.replaceAll('-', '');
  g.data1 = int.parse(hex.substring(0, 8), radix: 16);
  g.data2 = int.parse(hex.substring(8, 12), radix: 16);
  g.data3 = int.parse(hex.substring(12, 16), radix: 16);
  for (var i = 0; i < 8; i++) {
    g.data4[i] = int.parse(hex.substring(16 + i * 2, 18 + i * 2), radix: 16);
  }
}

/// Reads a `BTH_LE_UUID` as a canonical lowercase 128-bit UUID string (matching
/// `Uuid.value`). Short UUIDs are expanded against the Bluetooth base UUID.
String readBthLeUuid(BthLeUuid u) {
  if (u.isShortUuid != 0) {
    final short = u.value.shortUuid & 0xFFFF;
    return '0000${short.toRadixString(16).padLeft(4, '0')}'
        '-0000-1000-8000-00805f9b34fb';
  }
  final g = u.value.longUuid;
  final b = StringBuffer();
  b.write(g.data1.toRadixString(16).padLeft(8, '0'));
  b.write('-');
  b.write(g.data2.toRadixString(16).padLeft(4, '0'));
  b.write('-');
  b.write(g.data3.toRadixString(16).padLeft(4, '0'));
  b.write('-');
  for (var i = 0; i < 8; i++) {
    if (i == 2) b.write('-');
    b.write(g.data4[i].toRadixString(16).padLeft(2, '0'));
  }
  return b.toString().toLowerCase();
}
