// Raw FFI bindings for Windows Bluetooth: Winsock RFCOMM (`ws2_32.dll`) and the
// device-enumeration functions in `bthprops.cpl`. No native build — these are
// all system DLLs, so this works from a pure-Dart CLI and a Flutter Windows app
// alike.
//
// Most struct layouts mirror the Win32 SDK with default (natural) alignment,
// which Dart FFI also applies. The exception is SOCKADDR_BTH: ws2bth.h wraps it
// in `#include <pshpack1.h>` (i.e. `#pragma pack(1)`), so it is byte-packed with
// NO padding — see the @ffi.Packed(1) on SockaddrBth below.
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

// --- Winsock constants -------------------------------------------------------

const int afBth = 32; // AF_BTH
const int sockStream = 1; // SOCK_STREAM
const int bthprotoRfcomm = 3; // BTHPROTO_RFCOMM
const int socketError = -1; // SOCKET_ERROR
const int wsaeWouldBlock = 10035;
const int wsaeTimedOut = 10060; // WSAETIMEDOUT (a recv() SO_RCVTIMEO expiry)

// setsockopt(SOL_SOCKET, SO_RCVTIMEO) — bounds how long recv() blocks (DWORD ms).
const int solSocket = 0xffff; // SOL_SOCKET
const int soRcvTimeo = 0x1006; // SO_RCVTIMEO

/// `INVALID_SOCKET` is `(SOCKET)(~0)`; SOCKET is `UINT_PTR` (64-bit on x64).
final int invalidSocket = -1; // all-ones when read as a pointer-sized int

// --- Registry constants (advapi32.dll) ---------------------------------------
// The paired-device list lives under HKLM\...\BTHPORT\Parameters\Devices and can
// be read radio-silently and instantly. BluetoothFindFirstDevice, by contrast,
// can trigger a blocking per-device remote-name request (HCI RNR) when a name
// isn't cached — seconds per absent device — which is the root of the slow list.

/// `HKEY_LOCAL_MACHINE`. The predefined HKEYs are sign-extended pointer values
/// on 64-bit Windows: `(HKEY)(ULONG_PTR)(LONG)0x80000002` -> 0xFFFFFFFF80000002.
const int hkeyLocalMachine = 0xFFFFFFFF80000002;
const int keyRead = 0x20019; // KEY_READ
const int errorMoreData = 234; // ERROR_MORE_DATA
const int errorNoMoreItems = 259; // ERROR_NO_MORE_ITEMS
const int regSz = 1; // REG_SZ (null-terminated UTF-16 string)
const int regBinary = 3; // REG_BINARY (raw bytes)

// --- Structs -----------------------------------------------------------------

/// `SOCKADDR_BTH` from `ws2bth.h`. That header is byte-packed (`pshpack1.h`), so
/// this MUST be `@ffi.Packed(1)`: total size 30 bytes with `btAddr` at offset 2.
/// Without packing, Dart 8-aligns `btAddr` to offset 8 and `connect()` receives a
/// malformed address (wrong bytes, wrong channel, wrong `namelen`) and fails.
@ffi.Packed(1)
final class SockaddrBth extends ffi.Struct {
  @ffi.Uint16()
  external int addressFamily;

  @ffi.Uint64()
  external int btAddr;

  // GUID serviceClassId
  @ffi.Uint32()
  external int svcData1;
  @ffi.Uint16()
  external int svcData2;
  @ffi.Uint16()
  external int svcData3;
  @ffi.Array<ffi.Uint8>(8)
  external ffi.Array<ffi.Uint8> svcData4;

  @ffi.Uint32()
  external int port;
}

/// `BLUETOOTH_DEVICE_INFO` from `bluetoothapis.h` (`BLUETOOTH_MAX_NAME_SIZE`
/// = 248 WCHARs).
final class BluetoothDeviceInfo extends ffi.Struct {
  @ffi.Uint32()
  external int dwSize;

  @ffi.Uint64()
  external int address; // BLUETOOTH_ADDRESS union -> ULONGLONG

  @ffi.Uint32()
  external int ulClassofDevice;

  @ffi.Int32()
  external int fConnected; // BOOL

  @ffi.Int32()
  external int fRemembered; // BOOL

  @ffi.Int32()
  external int fAuthenticated; // BOOL

  // SYSTEMTIME stLastSeen (8 x WORD)
  @ffi.Array<ffi.Uint16>(8)
  external ffi.Array<ffi.Uint16> stLastSeen;

  // SYSTEMTIME stLastUsed
  @ffi.Array<ffi.Uint16>(8)
  external ffi.Array<ffi.Uint16> stLastUsed;

  @ffi.Array<ffi.Uint16>(248)
  external ffi.Array<ffi.Uint16> szName;
}

/// `BLUETOOTH_DEVICE_SEARCH_PARAMS` from `bluetoothapis.h`.
final class BluetoothDeviceSearchParams extends ffi.Struct {
  @ffi.Uint32()
  external int dwSize;

  @ffi.Int32()
  external int fReturnAuthenticated;
  @ffi.Int32()
  external int fReturnRemembered;
  @ffi.Int32()
  external int fReturnUnknown;
  @ffi.Int32()
  external int fReturnConnected;
  @ffi.Int32()
  external int fIssueInquiry;

  @ffi.Uint8()
  external int cTimeoutMultiplier;

  @ffi.IntPtr()
  external int hRadio; // HANDLE
}

/// `WSADATA` is opaque to us; we only need a scratch buffer of the right size
/// (~408 bytes on x64). We over-allocate to be safe.
const int wsaDataSize = 512;

// --- Function typedefs -------------------------------------------------------

typedef _WSAStartupC =
    ffi.Int32 Function(
      ffi.Uint16 wVersionRequested,
      ffi.Pointer<ffi.Uint8> lpWSAData,
    );
typedef WSAStartupDart =
    int Function(int wVersionRequested, ffi.Pointer<ffi.Uint8> lpWSAData);

typedef _WSACleanupC = ffi.Int32 Function();
typedef WSACleanupDart = int Function();

typedef _WSAGetLastErrorC = ffi.Int32 Function();
typedef WSAGetLastErrorDart = int Function();

typedef _SocketC =
    ffi.IntPtr Function(ffi.Int32 af, ffi.Int32 type, ffi.Int32 protocol);
typedef SocketDart = int Function(int af, int type, int protocol);

typedef _ConnectC =
    ffi.Int32 Function(
      ffi.IntPtr s,
      ffi.Pointer<SockaddrBth> name,
      ffi.Int32 namelen,
    );
typedef ConnectDart =
    int Function(int s, ffi.Pointer<SockaddrBth> name, int namelen);

typedef _SendC =
    ffi.Int32 Function(
      ffi.IntPtr s,
      ffi.Pointer<ffi.Uint8> buf,
      ffi.Int32 len,
      ffi.Int32 flags,
    );
typedef SendDart =
    int Function(int s, ffi.Pointer<ffi.Uint8> buf, int len, int flags);

typedef _RecvC =
    ffi.Int32 Function(
      ffi.IntPtr s,
      ffi.Pointer<ffi.Uint8> buf,
      ffi.Int32 len,
      ffi.Int32 flags,
    );
typedef RecvDart =
    int Function(int s, ffi.Pointer<ffi.Uint8> buf, int len, int flags);

typedef _CloseSocketC = ffi.Int32 Function(ffi.IntPtr s);
typedef CloseSocketDart = int Function(int s);

typedef _ShutdownC = ffi.Int32 Function(ffi.IntPtr s, ffi.Int32 how);
typedef ShutdownDart = int Function(int s, int how);

typedef _SetSockOptC =
    ffi.Int32 Function(
      ffi.IntPtr s,
      ffi.Int32 level,
      ffi.Int32 optname,
      ffi.Pointer<ffi.Uint8> optval,
      ffi.Int32 optlen,
    );
typedef SetSockOptDart =
    int Function(
      int s,
      int level,
      int optname,
      ffi.Pointer<ffi.Uint8> optval,
      int optlen,
    );

typedef _FindFirstDeviceC =
    ffi.IntPtr Function(
      ffi.Pointer<BluetoothDeviceSearchParams> params,
      ffi.Pointer<BluetoothDeviceInfo> info,
    );
typedef FindFirstDeviceDart =
    int Function(
      ffi.Pointer<BluetoothDeviceSearchParams> params,
      ffi.Pointer<BluetoothDeviceInfo> info,
    );

typedef _FindNextDeviceC =
    ffi.Int32 Function(ffi.IntPtr find, ffi.Pointer<BluetoothDeviceInfo> info);
typedef FindNextDeviceDart =
    int Function(int find, ffi.Pointer<BluetoothDeviceInfo> info);

typedef _FindDeviceCloseC = ffi.Int32 Function(ffi.IntPtr find);
typedef FindDeviceCloseDart = int Function(int find);

typedef _FindFirstRadioC =
    ffi.IntPtr Function(
      ffi.Pointer<ffi.Void> params,
      ffi.Pointer<ffi.IntPtr> radio,
    );
typedef FindFirstRadioDart =
    int Function(ffi.Pointer<ffi.Void> params, ffi.Pointer<ffi.IntPtr> radio);

typedef _FindRadioCloseC = ffi.Int32 Function(ffi.IntPtr find);
typedef FindRadioCloseDart = int Function(int find);

typedef _CloseHandleC = ffi.Int32 Function(ffi.IntPtr h);
typedef CloseHandleDart = int Function(int h);

/// Bundles resolved Winsock symbols. Construct one per isolate (DynamicLibrary
/// handles are not shareable across isolates, but SOCKET handles are).
class WinsockBindings {
  WinsockBindings()
    : _ws2 = ffi.DynamicLibrary.open('ws2_32.dll'),
      _bth = ffi.DynamicLibrary.open('bthprops.cpl'),
      _k32 = ffi.DynamicLibrary.open('kernel32.dll') {
    wsaStartup = _ws2.lookupFunction<_WSAStartupC, WSAStartupDart>(
      'WSAStartup',
    );
    wsaCleanup = _ws2.lookupFunction<_WSACleanupC, WSACleanupDart>(
      'WSACleanup',
    );
    wsaGetLastError = _ws2
        .lookupFunction<_WSAGetLastErrorC, WSAGetLastErrorDart>(
          'WSAGetLastError',
        );
    socket = _ws2.lookupFunction<_SocketC, SocketDart>('socket');
    connect = _ws2.lookupFunction<_ConnectC, ConnectDart>('connect');
    send = _ws2.lookupFunction<_SendC, SendDart>('send');
    recv = _ws2.lookupFunction<_RecvC, RecvDart>('recv');
    closesocket = _ws2.lookupFunction<_CloseSocketC, CloseSocketDart>(
      'closesocket',
    );
    shutdown = _ws2.lookupFunction<_ShutdownC, ShutdownDart>('shutdown');
    setsockopt = _ws2.lookupFunction<_SetSockOptC, SetSockOptDart>(
      'setsockopt',
    );

    findFirstDevice = _bth
        .lookupFunction<_FindFirstDeviceC, FindFirstDeviceDart>(
          'BluetoothFindFirstDevice',
        );
    findNextDevice = _bth.lookupFunction<_FindNextDeviceC, FindNextDeviceDart>(
      'BluetoothFindNextDevice',
    );
    findDeviceClose = _bth
        .lookupFunction<_FindDeviceCloseC, FindDeviceCloseDart>(
          'BluetoothFindDeviceClose',
        );
    findFirstRadio = _bth.lookupFunction<_FindFirstRadioC, FindFirstRadioDart>(
      'BluetoothFindFirstRadio',
    );
    findRadioClose = _bth.lookupFunction<_FindRadioCloseC, FindRadioCloseDart>(
      'BluetoothFindRadioClose',
    );
    closeHandle = _k32.lookupFunction<_CloseHandleC, CloseHandleDart>(
      'CloseHandle',
    );
  }

  final ffi.DynamicLibrary _ws2;
  final ffi.DynamicLibrary _bth;
  final ffi.DynamicLibrary _k32;

  late final WSAStartupDart wsaStartup;
  late final WSACleanupDart wsaCleanup;
  late final WSAGetLastErrorDart wsaGetLastError;
  late final SocketDart socket;
  late final ConnectDart connect;
  late final SendDart send;
  late final RecvDart recv;
  late final CloseSocketDart closesocket;
  late final ShutdownDart shutdown;
  late final SetSockOptDart setsockopt;
  late final FindFirstDeviceDart findFirstDevice;
  late final FindNextDeviceDart findNextDevice;
  late final FindDeviceCloseDart findDeviceClose;
  late final FindFirstRadioDart findFirstRadio;
  late final FindRadioCloseDart findRadioClose;
  late final CloseHandleDart closeHandle;

  /// Initialises Winsock 2.2 for the current isolate. Safe to call repeatedly.
  void startup() {
    final data = calloc<ffi.Uint8>(wsaDataSize);
    try {
      final r = wsaStartup(0x0202, data);
      if (r != 0) {
        throw StateError('WSAStartup failed: $r');
      }
    } finally {
      calloc.free(data);
    }
  }
}

// --- Registry function typedefs ----------------------------------------------

typedef _RegOpenKeyExC =
    ffi.Int32 Function(
      ffi.IntPtr hKey,
      ffi.Pointer<ffi.Uint16> lpSubKey,
      ffi.Uint32 ulOptions,
      ffi.Uint32 samDesired,
      ffi.Pointer<ffi.IntPtr> phkResult,
    );
typedef RegOpenKeyExDart =
    int Function(
      int hKey,
      ffi.Pointer<ffi.Uint16> lpSubKey,
      int ulOptions,
      int samDesired,
      ffi.Pointer<ffi.IntPtr> phkResult,
    );

typedef _RegEnumKeyExC =
    ffi.Int32 Function(
      ffi.IntPtr hKey,
      ffi.Uint32 dwIndex,
      ffi.Pointer<ffi.Uint16> lpName,
      ffi.Pointer<ffi.Uint32> lpcchName,
      ffi.Pointer<ffi.Uint32> lpReserved,
      ffi.Pointer<ffi.Uint16> lpClass,
      ffi.Pointer<ffi.Uint32> lpcchClass,
      ffi.Pointer<ffi.Void> lpftLastWriteTime,
    );
typedef RegEnumKeyExDart =
    int Function(
      int hKey,
      int dwIndex,
      ffi.Pointer<ffi.Uint16> lpName,
      ffi.Pointer<ffi.Uint32> lpcchName,
      ffi.Pointer<ffi.Uint32> lpReserved,
      ffi.Pointer<ffi.Uint16> lpClass,
      ffi.Pointer<ffi.Uint32> lpcchClass,
      ffi.Pointer<ffi.Void> lpftLastWriteTime,
    );

typedef _RegQueryValueExC =
    ffi.Int32 Function(
      ffi.IntPtr hKey,
      ffi.Pointer<ffi.Uint16> lpValueName,
      ffi.Pointer<ffi.Uint32> lpReserved,
      ffi.Pointer<ffi.Uint32> lpType,
      ffi.Pointer<ffi.Uint8> lpData,
      ffi.Pointer<ffi.Uint32> lpcbData,
    );
typedef RegQueryValueExDart =
    int Function(
      int hKey,
      ffi.Pointer<ffi.Uint16> lpValueName,
      ffi.Pointer<ffi.Uint32> lpReserved,
      ffi.Pointer<ffi.Uint32> lpType,
      ffi.Pointer<ffi.Uint8> lpData,
      ffi.Pointer<ffi.Uint32> lpcbData,
    );

typedef _RegCloseKeyC = ffi.Int32 Function(ffi.IntPtr hKey);
typedef RegCloseKeyDart = int Function(int hKey);

/// Resolved `advapi32.dll` registry symbols. Construct one per isolate (the
/// `DynamicLibrary` handle is not shareable across isolates).
class RegistryBindings {
  RegistryBindings() : _adv = ffi.DynamicLibrary.open('advapi32.dll') {
    regOpenKeyEx = _adv.lookupFunction<_RegOpenKeyExC, RegOpenKeyExDart>(
      'RegOpenKeyExW',
    );
    regEnumKeyEx = _adv.lookupFunction<_RegEnumKeyExC, RegEnumKeyExDart>(
      'RegEnumKeyExW',
    );
    regQueryValueEx = _adv
        .lookupFunction<_RegQueryValueExC, RegQueryValueExDart>(
          'RegQueryValueExW',
        );
    regCloseKey = _adv.lookupFunction<_RegCloseKeyC, RegCloseKeyDart>(
      'RegCloseKey',
    );
  }

  final ffi.DynamicLibrary _adv;

  late final RegOpenKeyExDart regOpenKeyEx;
  late final RegEnumKeyExDart regEnumKeyEx;
  late final RegQueryValueExDart regQueryValueEx;
  late final RegCloseKeyDart regCloseKey;
}

/// Parses a 48-bit Bluetooth address `AA:BB:CC:DD:EE:FF` into the `BTH_ADDR`
/// little-endian 64-bit value Winsock expects.
int parseBthAddr(String address) {
  final parts = address.split(':');
  if (parts.length != 6) {
    throw FormatException('Invalid Bluetooth address: $address');
  }
  var value = 0;
  for (final p in parts) {
    value = (value << 8) | int.parse(p, radix: 16);
  }
  return value;
}

/// Formats a `BTH_ADDR` value back to `AA:BB:CC:DD:EE:FF`.
String formatBthAddr(int addr) {
  final bytes = <String>[];
  for (var shift = 40; shift >= 0; shift -= 8) {
    bytes.add(((addr >> shift) & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return bytes.join(':').toUpperCase();
}

/// Writes the SPP/serial-class GUID derived from a 128-bit UUID string into a
/// [SockaddrBth]'s service-class fields.
void writeServiceClassGuid(SockaddrBth addr, String uuid128) {
  final hex = uuid128.replaceAll('-', '');
  addr.svcData1 = int.parse(hex.substring(0, 8), radix: 16);
  addr.svcData2 = int.parse(hex.substring(8, 12), radix: 16);
  addr.svcData3 = int.parse(hex.substring(12, 16), radix: 16);
  for (var i = 0; i < 8; i++) {
    addr.svcData4[i] = int.parse(
      hex.substring(16 + i * 2, 18 + i * 2),
      radix: 16,
    );
  }
}
