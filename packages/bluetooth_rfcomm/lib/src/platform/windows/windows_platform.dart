import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';
import '../../logging.dart';
import '../../models/bluetooth_device.dart';
import '../../models/bluetooth_service.dart';
import '../../models/device_id.dart';
import '../../models/discovery_result.dart';
import '../../models/enums.dart';
import '../../models/uuid.dart';
import '../platform_interface.dart';
import 'windows_ffi.dart';

/// Windows backend over Winsock Bluetooth (`AF_BTH` / `BTHPROTO_RFCOMM`) plus
/// the `BluetoothAPIs` device-enumeration functions.
///
/// Pure Dart via `dart:ffi` to system DLLs (`ws2_32.dll`, `bthprops.cpl`) — no
/// native component to build, so this is identical from `dart run` and a Flutter
/// Windows app. Blocking socket I/O and inquiries run on worker isolates so the
/// calling isolate never stalls.
class WindowsBluetoothRfcomm extends BluetoothRfcommPlatform {
  WindowsBluetoothRfcomm();

  WinsockBindings? _bindings;
  WinsockBindings get _ws => _bindings ??= WinsockBindings()..startup();

  @override
  Future<bool> isSupported() async {
    try {
      return await Isolate.run(_hasRadio);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<BluetoothAdapterState> adapterState() async {
    try {
      final present = await Isolate.run(_hasRadio);
      return present
          ? BluetoothAdapterState.on
          : BluetoothAdapterState.unavailable;
    } catch (_) {
      return BluetoothAdapterState.unavailable;
    }
  }

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() async* {
    // Windows exposes radio power changes via WMI/PnP notifications, which are
    // heavyweight to bind through FFI. We emit the current state; callers that
    // need live toggling can poll adapterState(). (Tracked for a later pass.)
    yield await adapterState();
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async {
    throw const BluetoothUnsupportedException(
      'Toggling the Windows Bluetooth radio programmatically is not supported; '
      'use Windows Settings.',
    );
  }

  @override
  Future<List<BluetoothDevice>> bondedDevices() async {
    try {
      // Read the paired list straight from the registry: this is radio-silent
      // and instant. BluetoothFindFirstDevice can block on a per-device remote-
      // name request (HCI RNR) when a name isn't cached — seconds per absent
      // device — which is why the old path felt slow. Fall back to it only if the
      // registry yields nothing (unexpected layout / locked-down machine).
      final raw = await Isolate.run(_enumeratePairedFromRegistry);
      if (raw.isNotEmpty) {
        logDiscovery.fine(
          () => 'bondedDevices: ${raw.length} paired device(s) from registry',
        );
        return raw.map(_toDevice).toList();
      }
      logDiscovery.fine(
        'bondedDevices: registry empty, falling back to BluetoothFindFirstDevice',
      );
      final fallback = await Isolate.run(
        () => _enumerateDevices(remembered: true),
      );
      return fallback.map(_toDevice).toList();
    } on BluetoothException {
      rethrow;
    } catch (e) {
      // e.g. DynamicLibrary.open failing (no Bluetooth stack) -> ArgumentError.
      throw BluetoothDisabledException(
        'Enumerating bonded devices failed',
        cause: e,
      );
    }
  }

  @override
  Stream<BluetoothDiscoveryResult> startDiscovery() async* {
    // Prefer the Winsock NS_BTH inquiry (LUP_FLUSHCACHE): it returns ONLY devices
    // that actually answered the inquiry — i.e. genuinely nearby — so a paired but
    // absent device does NOT show up. BluetoothFindFirstDevice, by contrast, always
    // unions in every remembered device, and Windows offers no reliable per-device
    // "seen now" flag (stLastSeen is frozen at the pairing date on real hardware),
    // so it cannot tell nearby from absent. We fall back to it only if the Winsock
    // inquiry can't be started, and log which path produced the results so the two
    // backends can be told apart during verification.
    logDiscovery.fine('inquiry starting (~10s window)');
    final start = DateTime.now();
    List<_RawDevice> raw;
    var via = 'WSALookupService';
    try {
      raw = await Isolate.run(_inquireViaWsaLookup);
    } on _WsaLookupUnavailable catch (e) {
      logDiscovery.warning(
        () =>
            'WSALookupService inquiry unavailable ($e); '
            'falling back to BluetoothFindFirstDevice',
      );
      via = 'BluetoothFindFirstDevice';
      try {
        raw = await Isolate.run(
          () =>
              _enumerateDevices(remembered: true, unknown: true, inquiry: true),
        );
      } on BluetoothException {
        rethrow;
      } catch (e) {
        throw BluetoothDiscoveryException('inquiry failed', cause: e);
      }
    } on BluetoothException {
      rethrow;
    } catch (e) {
      throw BluetoothDiscoveryException('inquiry failed', cause: e);
    }
    final now = DateTime.now();
    logDiscovery.fine(
      () =>
          'inquiry ($via) returned ${raw.length} device(s) in '
          '${now.difference(start).inMilliseconds}ms',
    );
    for (final r in raw) {
      final device = _toDevice(r);
      logDiscovery.finer(
        () =>
            'device "${device.name ?? '(unnamed)'}" ${device.id.address} '
            'remembered=${r.remembered} connected=${r.connected}',
      );
      yield BluetoothDiscoveryResult(
        device: device,
        rssi: device.rssi,
        timestamp: now,
      );
    }
  }

  @override
  Future<void> stopDiscovery() async {
    // The inquiry runs to completion on its worker isolate; nothing to cancel.
  }

  @override
  Future<List<BluetoothService>> discoverServices(
    DeviceId device, {
    Uuid? serviceUuid,
  }) async {
    // Winsock resolves the RFCOMM channel from SDP automatically when you set
    // the service-class GUID on connect, so we report the requested service with
    // a sentinel channel of 0 ("resolve at connect"). openRfcomm honours it.
    final u = serviceUuid ?? Uuid.spp;
    return [BluetoothService(uuid: u, rfcommChannelId: 0)];
  }

  @override
  Future<RfcommTransport> openRfcomm(
    DeviceId device, {
    int? channel,
    required Uuid serviceUuid,
    Duration? timeout,
  }) async {
    if (!device.isAddress) {
      throw const BluetoothConnectionException(
        'Windows requires a MAC-address DeviceId for RFCOMM connect',
      );
    }
    final address = device.address;
    final uuid = serviceUuid.value;
    // (socket, errorCode): separate fields so a SOCKET (an unsigned UINT_PTR)
    // can never be misread as an error code, whatever its high bit.
    final (int, int) connectResult;
    try {
      // Spawn the connect via a STATIC helper, never an inline closure here.
      // The `.then(...)` callback below references `_ws`, so it captures `this`;
      // an inline `Isolate.run(() => _connectSocket(...))` in this same method
      // would share that closure context and get `this` serialized into the
      // isolate message. Once `_bindings` is lazily created (a non-sendable
      // DynamicLibrary), that serialization throws "object is a DynamicLibrary"
      // — which is exactly why the FIRST connect worked (bindings still null →
      // sendable) but every later one failed. The static helper has no `this`
      // in scope, so its closure captures only the sendable args.
      final connectFuture = _spawnConnect(address, channel, uuid);
      var timedOut = false;
      // Isolate.run can't be cancelled: if connect succeeds AFTER we time out,
      // the returned SOCKET would be dropped without closesocket — leaking the
      // handle and leaving a half-open RFCOMM link. Close any late socket.
      unawaited(
        connectFuture.then((r) {
          final (sock, err) = r;
          if (timedOut && err == 0 && sock != 0) {
            try {
              _ws.closesocket(sock);
            } catch (_) {}
          }
        }, onError: (_) {}),
      );
      connectResult = await (timeout == null
          ? connectFuture
          : connectFuture.timeout(
              timeout,
              onTimeout: () {
                timedOut = true;
                throw BluetoothTimeoutException(
                  'RFCOMM connect to $address timed out',
                  timeout: timeout,
                );
              },
            ));
    } on BluetoothException {
      rethrow;
    } catch (e) {
      // Map worker-isolate errors (bad address FormatException, WSAStartup
      // StateError, …) into the domain hierarchy.
      throw BluetoothConnectionException(
        'RFCOMM connect to $address failed',
        cause: e,
      );
    }
    final (socket, error) = connectResult;
    if (error != 0) {
      throw BluetoothConnectionException(
        'RFCOMM connect to $address failed',
        code: error,
      );
    }
    return _WindowsRfcommTransport(socket: socket, ws: _ws);
  }

  @override
  Future<void> pair(
    DeviceId device,
  ) async => throw const BluetoothUnsupportedException(
    'Programmatic pairing on Windows (BluetoothAuthenticateDeviceEx) is not '
    'yet wired; pair from Windows Settings.',
  );

  @override
  Future<void> unpair(DeviceId device) async =>
      throw const BluetoothUnsupportedException(
        'Programmatic unpairing on Windows is not yet wired.',
      );

  // --- main-isolate helpers ------------------------------------------------

  // Static (no `this` in scope) so the Isolate.run closure captures only the
  // sendable args — see the note in openRfcomm.
  static Future<(int, int)> _spawnConnect(
    String address,
    int? channel,
    String uuid,
  ) => Isolate.run(() => _connectSocket(address, channel, uuid));

  BluetoothDevice _toDevice(_RawDevice r) => BluetoothDevice(
    id: DeviceId.address(formatBthAddr(r.addr)),
    name: r.name.isEmpty ? null : r.name,
    type: BluetoothDeviceType.classic,
    bondState: r.authenticated
        ? BluetoothBondState.bonded
        : BluetoothBondState.none,
    isConnected: r.connected,
    deviceClass: r.classOfDevice,
  );
}

// --- isolate entrypoints (top-level, run in worker isolates) -----------------

bool _hasRadio() {
  final ws = WinsockBindings();
  final radio = calloc<ffi.IntPtr>();
  try {
    // BLUETOOTH_FIND_RADIO_PARAMS is { DWORD dwSize; }; pass an 8-byte buffer
    // with dwSize=4.
    final params = calloc<ffi.Uint8>(8);
    params.cast<ffi.Uint32>().value = 4;
    final find = ws.findFirstRadio(params.cast(), radio);
    calloc.free(params);
    if (find == 0 || find == invalidSocket) return false;
    ws.closeHandle(radio.value);
    ws.findRadioClose(find);
    return true;
  } finally {
    calloc.free(radio);
  }
}

/// Plain, sendable device record produced inside worker isolates.
class _RawDevice {
  _RawDevice(
    this.addr,
    this.name,
    this.classOfDevice,
    this.connected,
    this.remembered,
    this.authenticated,
  );
  final int addr;
  final String name;
  final int classOfDevice;
  final bool connected;
  final bool remembered;
  final bool authenticated;
}

/// Registry subkey holding the paired devices: subkey name is the 12-hex MAC
/// (no separators), and each holds a `Name` value with the friendly name.
const String _pairedDevicesKey =
    r'SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices';

/// Lists paired devices by reading the registry directly — no radio I/O, so it
/// returns instantly even when a paired device is powered off or out of range
/// (unlike BluetoothFindFirstDevice, which can block on a remote-name request
/// per device). Returns an empty list on any failure so the caller can fall back
/// to the FindFirstDevice path. classOfDevice/connected aren't in this registry
/// view, so they default (a paired device is authenticated/remembered by
/// definition; live connection state comes from the connection's own stream).
List<_RawDevice> _enumeratePairedFromRegistry() {
  final reg = RegistryBindings();
  final out = <_RawDevice>[];
  final subPath = _pairedDevicesKey.toNativeUtf16();
  final hDevices = calloc<ffi.IntPtr>();
  // Subkey names are 12 hex chars; 64 WCHARs is ample headroom.
  final nameBuf = calloc<ffi.Uint16>(64);
  final nameLen = calloc<ffi.Uint32>();
  try {
    if (reg.regOpenKeyEx(
          hkeyLocalMachine,
          subPath.cast(),
          0,
          keyRead,
          hDevices,
        ) !=
        0) {
      return out;
    }
    final devicesKey = hDevices.value;
    try {
      for (var i = 0; ; i++) {
        nameLen.value = 64;
        final rc = reg.regEnumKeyEx(
          devicesKey,
          i,
          nameBuf,
          nameLen,
          ffi.nullptr,
          ffi.nullptr,
          ffi.nullptr,
          ffi.nullptr,
        );
        if (rc != 0) break; // ERROR_NO_MORE_ITEMS or any error -> done
        final mac = _utf16ToString(nameBuf, nameLen.value);
        final addr = _parseRegistryMac(mac);
        if (addr == null) continue; // not a MAC subkey -> skip
        final name = _readRegistryName(reg, devicesKey, nameBuf);
        out.add(
          _RawDevice(
            addr,
            name ?? '',
            0, // classOfDevice unknown from this view
            false, // connected unknown; live state via the connection stream
            true, // listed here => remembered
            true, // and authenticated/paired
          ),
        );
      }
    } finally {
      reg.regCloseKey(devicesKey);
    }
  } catch (_) {
    return out; // any FFI mishap -> empty so the caller falls back
  } finally {
    calloc.free(subPath);
    calloc.free(hDevices);
    calloc.free(nameBuf);
    calloc.free(nameLen);
  }
  return out;
}

/// Reads the `Name` value of the paired-device subkey named by [macNameBuf]
/// (a null-terminated WSTR already holding the MAC, reused from the enumeration).
String? _readRegistryName(
  RegistryBindings reg,
  int devicesKey,
  ffi.Pointer<ffi.Uint16> macNameBuf,
) {
  final hSub = calloc<ffi.IntPtr>();
  final valueName = 'Name'.toNativeUtf16();
  final type = calloc<ffi.Uint32>();
  final size = calloc<ffi.Uint32>();
  try {
    if (reg.regOpenKeyEx(devicesKey, macNameBuf, 0, keyRead, hSub) != 0) {
      return null;
    }
    final subKey = hSub.value;
    try {
      // Size probe first (lpData null) to learn the byte length.
      final probe = reg.regQueryValueEx(
        subKey,
        valueName.cast(),
        ffi.nullptr,
        type,
        ffi.nullptr,
        size,
      );
      if ((probe != 0 && probe != errorMoreData) || size.value == 0) {
        return null;
      }
      final data = calloc<ffi.Uint8>(size.value + 2); // +2 NUL slack
      try {
        if (reg.regQueryValueEx(
              subKey,
              valueName.cast(),
              ffi.nullptr,
              type,
              data,
              size,
            ) !=
            0) {
          return null;
        }
        return _decodeRegistryName(type.value, data, size.value);
      } finally {
        calloc.free(data);
      }
    } finally {
      reg.regCloseKey(subKey);
    }
  } finally {
    calloc.free(hSub);
    calloc.free(valueName);
    calloc.free(type);
    calloc.free(size);
  }
}

/// Decodes a registry `Name` value. Windows stores it inconsistently across
/// stacks/versions: usually REG_BINARY (raw name bytes, sometimes NUL-padded),
/// occasionally REG_SZ (UTF-16). Handle both, then UTF-16 vs UTF-8 heuristically.
String? _decodeRegistryName(int type, ffi.Pointer<ffi.Uint8> data, int size) {
  final bytes = data.asTypedList(size);
  if (type == regSz || (size >= 2 && size.isEven && _looksUtf16(bytes))) {
    final units = <int>[];
    for (var i = 0; i + 1 < size; i += 2) {
      final c = bytes[i] | (bytes[i + 1] << 8);
      if (c == 0) break;
      units.add(c);
    }
    final s = String.fromCharCodes(units).trim();
    return s.isEmpty ? null : s;
  }
  // REG_BINARY as a single-byte encoding: strip trailing NULs, decode UTF-8
  // (covers ASCII), falling back to Latin-1 for any non-UTF-8 bytes.
  var end = size;
  while (end > 0 && bytes[end - 1] == 0) {
    end--;
  }
  if (end == 0) return null;
  final slice = bytes.sublist(0, end);
  String s;
  try {
    s = utf8.decode(slice);
  } catch (_) {
    s = String.fromCharCodes(slice);
  }
  s = s.trim();
  return s.isEmpty ? null : s;
}

/// Heuristic: REG_BINARY name bytes are UTF-16LE if the high byte of each WCHAR
/// is mostly zero (ASCII text encoded as UTF-16 has every other byte == 0).
bool _looksUtf16(Uint8List bytes) {
  var oddZeros = 0;
  var pairs = 0;
  for (var i = 1; i < bytes.length; i += 2) {
    pairs++;
    if (bytes[i] == 0) oddZeros++;
  }
  return pairs > 0 && oddZeros >= (pairs * 3) ~/ 4;
}

/// Reads [len] UTF-16 code units from [buf] into a Dart string.
String _utf16ToString(ffi.Pointer<ffi.Uint16> buf, int len) {
  final units = <int>[];
  for (var i = 0; i < len; i++) {
    final c = buf[i];
    if (c == 0) break;
    units.add(c);
  }
  return String.fromCharCodes(units);
}

/// Parses a registry paired-device subkey name (12 hex digits, no separators)
/// into a `BTH_ADDR`, or null if it isn't a MAC subkey.
int? _parseRegistryMac(String name) {
  if (name.length != 12) return null;
  final v = int.tryParse(name, radix: 16);
  if (v == null) return null;
  return v;
}

/// Thrown by [_inquireViaWsaLookup] when the Winsock inquiry can't even be
/// started (`WSALookupServiceBegin` failed). Carries the WSA error so the caller
/// can log it and fall back to `BluetoothFindFirstDevice`. Sendable across the
/// `Isolate.run` boundary (plain fields only).
class _WsaLookupUnavailable implements Exception {
  _WsaLookupUnavailable(this.code);
  final int code;
  @override
  String toString() => 'WSALookupServiceBegin failed (WSA $code)';
}

/// Discovers devices via the Winsock NS_BTH inquiry. With `LUP_FLUSHCACHE` this
/// performs a live inquiry and returns ONLY devices that actually responded —
/// i.e. genuinely nearby — unlike [_enumerateDevices] (BluetoothFindFirstDevice),
/// which always unions in every remembered/paired device. Runs in a worker
/// isolate (blocks for the inquiry window). Throws [_WsaLookupUnavailable] if the
/// inquiry can't be started so the caller can fall back.
List<_RawDevice> _inquireViaWsaLookup() {
  final ws = WinsockBindings();
  ws.startup();
  final out = <_RawDevice>[];
  final restrictions = calloc<WsaQuerySet>();
  final hLookup = calloc<ffi.IntPtr>();
  try {
    restrictions.ref
      ..dwSize = ffi.sizeOf<WsaQuerySet>()
      ..dwNameSpace = nsBth;
    final begin = ws.wsaLookupServiceBegin(
      restrictions,
      lupContainers | lupFlushCache,
      hLookup,
    );
    if (begin != 0) {
      throw _WsaLookupUnavailable(ws.wsaGetLastError());
    }
    final handle = hLookup.value;
    const bufSize = 4096; // one device per Next; ample for the set + its strings
    final buf = calloc<ffi.Uint8>(bufSize);
    final lenPtr = calloc<ffi.Uint32>();
    final results = buf.cast<WsaQuerySet>();
    try {
      while (true) {
        lenPtr.value = bufSize;
        final rc = ws.wsaLookupServiceNext(
          handle,
          lupReturnName | lupReturnAddr | lupReturnType,
          lenPtr,
          results,
        );
        if (rc != 0) break; // WSA_E_NO_MORE / WSAEFAULT / any error -> stop
        final qs = results.ref;
        if (qs.dwNumberOfCsAddrs == 0 || qs.lpcsaBuffer == ffi.nullptr) {
          continue; // no address -> can't identify the device, skip
        }
        final remote = qs.lpcsaBuffer.ref.remoteAddr;
        if (remote.lpSockaddr == ffi.nullptr) continue;
        final addr = remote.lpSockaddr.cast<SockaddrBth>().ref.btAddr;
        final name = qs.lpszServiceInstanceName == ffi.nullptr
            ? ''
            : qs.lpszServiceInstanceName.cast<Utf16>().toDartString();
        out.add(
          _RawDevice(
            addr,
            name,
            0, // class-of-device not requested here
            false, // connection state isn't reported by the inquiry
            false, // remembered/authenticated unknown from an inquiry result;
            false, // the stream intersects with the bonded set for those flags
          ),
        );
      }
    } finally {
      ws.wsaLookupServiceEnd(handle);
      calloc.free(buf);
      calloc.free(lenPtr);
    }
    return out;
  } finally {
    calloc.free(restrictions);
    calloc.free(hLookup);
    ws.wsaCleanup();
  }
}

List<_RawDevice> _enumerateDevices({
  bool remembered = false,
  bool unknown = false,
  bool inquiry = false,
}) {
  final ws = WinsockBindings();
  final params = calloc<BluetoothDeviceSearchParams>();
  final info = calloc<BluetoothDeviceInfo>();
  final out = <_RawDevice>[];
  try {
    params.ref
      ..dwSize = ffi.sizeOf<BluetoothDeviceSearchParams>()
      ..fReturnAuthenticated = 1
      ..fReturnRemembered = remembered ? 1 : 0
      ..fReturnUnknown = unknown ? 1 : 0
      ..fReturnConnected = 1
      ..fIssueInquiry = inquiry ? 1 : 0
      ..cTimeoutMultiplier = inquiry
          ? 8
          : 0 // ~10.24s when inquiring
      ..hRadio = 0;
    info.ref.dwSize = ffi.sizeOf<BluetoothDeviceInfo>();

    final find = ws.findFirstDevice(params, info);
    if (find == 0 || find == invalidSocket) return out;
    try {
      do {
        out.add(_readDevice(info.ref));
        info.ref.dwSize = ffi.sizeOf<BluetoothDeviceInfo>();
      } while (ws.findNextDevice(find, info) != 0);
    } finally {
      ws.findDeviceClose(find);
    }
    // No nearby/stale filtering here: BluetoothFindFirstDevice returns ALL
    // remembered (paired) devices even after a real inquiry, so the caller
    // (startDiscovery, on the main isolate) decides which count as nearby using
    // each device's stLastSeen — that way every keep/drop decision can be logged.
    return out;
  } finally {
    calloc.free(params);
    calloc.free(info);
    // No WSACleanup: BluetoothFindFirstDevice is a BluetoothAPIs call and never
    // needed WSAStartup, so there is nothing to balance here. (Calling cleanup
    // without a matching startup corrupts the process-global Winsock refcount.)
  }
}

_RawDevice _readDevice(BluetoothDeviceInfo info) {
  // szName is a null-terminated UTF-16 array. Collect the raw code units and let
  // String.fromCharCodes assemble surrogate pairs — writeCharCode would reject a
  // lone surrogate and mangle astral (emoji) names truncated at the 248 limit.
  final units = <int>[];
  for (var i = 0; i < 248; i++) {
    final c = info.szName[i];
    if (c == 0) break;
    units.add(c);
  }
  return _RawDevice(
    info.address,
    String.fromCharCodes(units),
    info.ulClassofDevice,
    info.fConnected != 0,
    info.fRemembered != 0,
    info.fAuthenticated != 0,
  );
}

/// A WSA error code, or -1 when the call failed but `WSAGetLastError()` was 0.
int _wsaError(int err) => err == 0 ? -1 : err;

/// Opens and connects an RFCOMM socket. Returns `(socket, 0)` on success or
/// `(0, errorCode)` on failure. The handle and error are separate fields so a
/// SOCKET (an unsigned `UINT_PTR`) can never be mistaken for an error code.
(int, int) _connectSocket(String address, int? channel, String serviceUuid) {
  // Each isolate that calls Winsock functions must run its own WSAStartup (the
  // initialisation does not carry across Dart isolates). No matching WSACleanup
  // here: it would tear down this isolate's Winsock and could invalidate the
  // SOCKET we're about to hand back; the socket itself is a process-global handle
  // that the reader/writer/main isolates go on to use.
  final ws = WinsockBindings();
  ws.startup();
  final sock = ws.socket(afBth, sockStream, bthprotoRfcomm);
  if (sock == invalidSocket) return (0, _wsaError(ws.wsaGetLastError()));

  final addr = calloc<SockaddrBth>();
  try {
    addr.ref.addressFamily = afBth;
    addr.ref.btAddr = parseBthAddr(address);
    if (channel != null && channel > 0) {
      addr.ref.port = channel;
    } else {
      // Let Winsock resolve the channel from SDP via the service-class GUID.
      writeServiceClassGuid(addr.ref, serviceUuid);
      addr.ref.port = 0;
    }
    final rc = ws.connect(sock, addr, ffi.sizeOf<SockaddrBth>());
    if (rc == socketError) {
      final err = ws.wsaGetLastError();
      ws.closesocket(sock);
      return (0, _wsaError(err));
    }
    return (sock, 0);
  } finally {
    calloc.free(addr);
  }
}

const int _recvBufSize = 8192;
const int _sendChunkFlags = 0;

void _recvEntry(List<Object?> args) {
  final socket = args[0] as int;
  final sendPort = args[1] as SendPort;
  // This isolate calls recv(), so it needs its own WSAStartup (Winsock init does
  // not carry across Dart isolates); balanced by the wsaCleanup in finally.
  final ws = WinsockBindings()..startup();
  // Bound how long each recv() blocks (SO_RCVTIMEO). close() on another isolate
  // can't reliably cancel a recv already blocked inside this RFCOMM provider, and
  // Isolate.kill can't interrupt a blocking FFI call — so without this the reader
  // could stay stuck forever after close(), holding the socket open and blocking
  // the next connection. With a timeout, recv() returns periodically; once the
  // socket has been closed it returns an error (not a timeout) and we exit.
  final timeout = calloc<ffi.Uint8>(4);
  timeout.cast<ffi.Uint32>().value = 500; // milliseconds
  ws.setsockopt(socket, solSocket, soRcvTimeo, timeout, 4);
  calloc.free(timeout);
  final buf = calloc<ffi.Uint8>(_recvBufSize);
  try {
    while (true) {
      final n = ws.recv(socket, buf, _recvBufSize, 0);
      if (n > 0) {
        final bytes = Uint8List.fromList(buf.asTypedList(n));
        sendPort.send(TransferableTypedData.fromList([bytes]));
        continue;
      }
      if (n == 0) break; // peer closed the connection (clean EOF)
      // n < 0 (SOCKET_ERROR): a recv timeout just means "no data yet" — keep
      // waiting. Any other error (socket closed by close(), reset, …) is EOF.
      if (ws.wsaGetLastError() == wsaeTimedOut) continue;
      break;
    }
  } catch (_) {
    // fall through to EOF
  } finally {
    calloc.free(buf);
    ws.wsaCleanup(); // balance this isolate's WSAStartup
    sendPort.send(null); // signal closed
  }
}

void _writeEntry(List<Object?> args) {
  final socket = args[0] as int;
  final mainPort = args[1] as SendPort;
  // This isolate calls send(), so it needs its own WSAStartup (Winsock init does
  // not carry across Dart isolates); balanced by the wsaCleanup on shutdown.
  final ws = WinsockBindings()..startup();
  final rp = ReceivePort();
  mainPort.send(rp.sendPort);
  rp.listen((msg) {
    if (msg == null) {
      rp.close();
      ws.wsaCleanup(); // balance this isolate's WSAStartup on shutdown
      return;
    }
    final rec = msg as List<Object?>;
    final data = rec[0] as TransferableTypedData?;
    final ack = rec[1] as SendPort?;
    if (data != null) {
      _sendAll(ws, socket, data.materialize().asUint8List());
    }
    ack?.send(true);
  });
}

void _sendAll(WinsockBindings ws, int socket, Uint8List bytes) {
  final ptr = calloc<ffi.Uint8>(bytes.length);
  try {
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    var offset = 0;
    while (offset < bytes.length) {
      final n = ws.send(
        socket,
        ptr + offset,
        bytes.length - offset,
        _sendChunkFlags,
      );
      if (n == socketError || n <= 0) break; // peer gone
      offset += n;
    }
  } finally {
    calloc.free(ptr);
  }
}

/// RFCOMM transport backed by a Winsock socket, with a dedicated reader isolate
/// (blocking `recv`) and writer isolate (blocking `send` from a FIFO queue) so
/// the calling isolate never blocks.
class _WindowsRfcommTransport implements RfcommTransport {
  _WindowsRfcommTransport({required int socket, required WinsockBindings ws})
    : _socket = socket,
      _ws = ws {
    _start();
  }

  final int _socket;
  final WinsockBindings _ws;

  final StreamController<Uint8List> _incoming = StreamController<Uint8List>(
    sync: false,
  );
  final StreamController<ConnectionState> _state =
      StreamController<ConnectionState>.broadcast();
  ConnectionState _current = ConnectionState.connected;
  bool _closed = false;

  Isolate? _reader;
  Isolate? _writer;
  ReceivePort? _readerPort;
  ReceivePort? _writerControlPort;
  SendPort? _writerSend;
  final List<List<Object?>> _pendingWrites = [];
  final Completer<void> _done = Completer<void>();

  void _start() {
    final readerPort = ReceivePort();
    _readerPort = readerPort;
    readerPort.listen((msg) {
      if (msg == null) {
        _onClosedByPeer();
      } else if (msg is TransferableTypedData &&
          !_closed &&
          !_incoming.isClosed) {
        _incoming.add(msg.materialize().asUint8List());
      }
    });
    // If close() wins the spawn race, kill the isolate as soon as it exists.
    Isolate.spawn(_recvEntry, [_socket, readerPort.sendPort]).then((i) {
      if (_closed) {
        i.kill(priority: Isolate.beforeNextEvent);
      } else {
        _reader = i;
      }
    });

    final control = ReceivePort();
    _writerControlPort = control;
    control.listen((msg) {
      if (msg is SendPort) {
        _writerSend = msg;
        for (final w in _pendingWrites) {
          msg.send(w);
        }
        _pendingWrites.clear();
      }
    });
    Isolate.spawn(_writeEntry, [_socket, control.sendPort]).then((i) {
      if (_closed) {
        i.kill(priority: Isolate.beforeNextEvent);
      } else {
        _writer = i;
      }
    });

    _state.add(ConnectionState.connected);
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<ConnectionState> get stateChanges => _state.stream;

  @override
  ConnectionState get state => _current;

  @override
  void send(Uint8List data) {
    if (_closed) throw const BluetoothWriteException('transport closed');
    final msg = <Object?>[
      TransferableTypedData.fromList([data]),
      null,
    ];
    final w = _writerSend;
    if (w != null) {
      w.send(msg);
    } else {
      _pendingWrites.add(msg);
    }
  }

  @override
  Future<void> flush() async {
    if (_closed) return;
    final ack = ReceivePort();
    final msg = <Object?>[null, ack.sendPort];
    final w = _writerSend;
    if (w != null) {
      w.send(msg);
    } else {
      _pendingWrites.add(msg);
    }
    // Race the writer's ack against close(): if the peer drops and the writer
    // isolate is killed, the ack never arrives — don't hang forever.
    try {
      await Future.any([ack.first, _done.future]);
    } finally {
      ack.close();
    }
  }

  void _onClosedByPeer() {
    if (_closed) return;
    unawaited(close());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final alreadyDisconnected = _current == ConnectionState.disconnected;
    _current = ConnectionState.disconnected;
    // Release any flush() waiting on a writer ack that will never arrive.
    if (!_done.isCompleted) _done.complete();
    // Unblock recv and break the connection. Log the closesocket result: if it
    // fails the socket stays open and holds the device's RFCOMM channel, which is
    // the prime suspect for "the next connect fails until the app restarts".
    try {
      _ws.shutdown(_socket, 2); // SD_BOTH
      final rc = _ws.closesocket(_socket);
      if (rc != 0) {
        logConnection.warning(
          () => 'closesocket failed (rc=$rc, wsa=${_ws.wsaGetLastError()})',
        );
      } else {
        logConnection.fine('socket closed');
      }
    } catch (e) {
      logConnection.warning(() => 'socket teardown error: $e');
    }
    _writerSend?.send(null);
    _writerControlPort?.close();
    _readerPort?.close();
    _writer?.kill(priority: Isolate.beforeNextEvent);
    _reader?.kill(priority: Isolate.beforeNextEvent);
    if (!_state.isClosed) {
      if (!alreadyDisconnected) _state.add(ConnectionState.disconnected);
      await _state.close();
    }
    if (!_incoming.isClosed) await _incoming.close();
  }
}
