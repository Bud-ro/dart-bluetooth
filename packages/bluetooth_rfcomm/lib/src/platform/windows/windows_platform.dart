import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show sleep;
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

/// Windows backend over Winsock Bluetooth (`AF_BTH` / `BTHPROTO_RFCOMM`).
///
/// Pure Dart via `dart:ffi` to system DLLs (`ws2_32.dll`, `bthprops.cpl` for the
/// radio check, `advapi32.dll` for the registry) — no native component to build,
/// so this is identical from `dart run` and a Flutter Windows app. Blocking
/// socket I/O runs on worker isolates so the calling isolate never stalls.
///
/// The paired-device list comes from the registry (radio-silent, instant).
/// Active inquiry is intentionally NOT performed: a classic-Bluetooth inquiry
/// monopolizes the radio for seconds, can't be aborted, and blocks connections —
/// so [startDiscovery] is a paired-list shim here (see its doc).
class WindowsBluetoothRfcomm extends BluetoothRfcommPlatform {
  WindowsBluetoothRfcomm();

  WinsockBindings? _bindings;
  WinsockBindings get _ws => _bindings ??= WinsockBindings()..startup();

  @override
  Future<bool> isSupported() async {
    final sw = Stopwatch()..start();
    try {
      return await Isolate.run(_hasRadio);
    } catch (_) {
      return false;
    } finally {
      logAdapter.fine(
        () => 'isSupported: radio check took ${sw.elapsedMilliseconds}ms',
      );
    }
  }

  @override
  Future<BluetoothAdapterState> adapterState() async {
    final sw = Stopwatch()..start();
    try {
      final present = await Isolate.run(_hasRadio);
      return present
          ? BluetoothAdapterState.on
          : BluetoothAdapterState.unavailable;
    } catch (_) {
      return BluetoothAdapterState.unavailable;
    } finally {
      logAdapter.fine(
        () => 'adapterState: radio check took ${sw.elapsedMilliseconds}ms',
      );
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
      // Read the paired list straight from the registry: radio-silent and so
      // cheap (a handful of small keys) that it runs inline on the calling
      // isolate — spawning a worker just to read it cost more than the read.
      // BluetoothFindFirstDevice is no longer used: it blocks on a per-device
      // remote-name request, which was the whole reason listing felt slow.
      final sw = Stopwatch()..start();
      final raw = _enumeratePairedFromRegistry();
      sw.stop();
      logDiscovery.fine(
        () =>
            'bondedDevices: ${raw.length} paired device(s) from registry in '
            '${sw.elapsedMilliseconds}ms',
      );
      return raw.map(_toDevice).toList();
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
    // Windows intentionally performs NO active inquiry. A classic-Bluetooth
    // inquiry holds the radio for ~1.28s per response (several seconds total),
    // can't be aborted once started, and blocks connections for its whole
    // duration — and for a paired-device workflow it adds nothing. So
    // "discovery" here is a transparent shim that just lists the PAIRED devices
    // (a radio-silent registry read); it does NOT find nearby/non-paired devices
    // and never touches the radio. Re-introduce a real inquiry here only if
    // non-paired discovery is actually needed (and budget for the radio cost).
    final now = DateTime.now();
    final sw = Stopwatch()..start();
    final raw = _enumeratePairedFromRegistry();
    sw.stop();
    logDiscovery.fine(
      () =>
          'discovery (paired-list shim): ${raw.length} device(s) in '
          '${sw.elapsedMilliseconds}ms, no inquiry',
    );
    for (final r in raw) {
      final device = _toDevice(r);
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
    final connectSw = Stopwatch()..start();
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
      connectSw.stop();
      logConnection.fine(
        () =>
            'openRfcomm: native connect to $address '
            '(channel ${channel ?? 'SDP'}) took ${connectSw.elapsedMilliseconds}ms',
      );
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
/// returns instantly even when a paired device is powered off or out of range.
/// classOfDevice/connected aren't in this registry view, so they default (a
/// paired device is authenticated/remembered by definition; live connection
/// state comes from the connection's own stream).
///
/// Heavily instrumented (FINER, [BluetoothRfcommLoggers.discovery]) so the time
/// spent opening the library, opening the key, enumerating, and reading each
/// device name is visible — to catch any operation that unexpectedly stalls.
List<_RawDevice> _enumeratePairedFromRegistry() {
  final total = Stopwatch()..start();
  final reg = RegistryBindings();
  final dllOpenUs = total.elapsedMicroseconds;
  final out = <_RawDevice>[];
  final subPath = _pairedDevicesKey.toNativeUtf16();
  final hDevices = calloc<ffi.IntPtr>();
  // Subkey names are 12 hex chars; 64 WCHARs is ample headroom.
  final nameBuf = calloc<ffi.Uint16>(64);
  final nameLen = calloc<ffi.Uint32>();
  var scanned = 0;
  var nameReadUs = 0;
  var slowestNameUs = 0;
  String? slowestName;
  try {
    final openStart = total.elapsedMicroseconds;
    if (reg.regOpenKeyEx(
          hkeyLocalMachine,
          subPath.cast(),
          0,
          keyRead,
          hDevices,
        ) !=
        0) {
      logDiscovery.finer(
        () =>
            'registry: RegOpenKeyEx(Devices) failed after '
            '${total.elapsedMicroseconds}us',
      );
      return out;
    }
    final openUs = total.elapsedMicroseconds - openStart;
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
        scanned++;
        final mac = _utf16ToString(nameBuf, nameLen.value);
        final addr = _parseRegistryMac(mac);
        if (addr == null) continue; // not a MAC subkey -> skip
        final nameStart = total.elapsedMicroseconds;
        final name = _readRegistryName(reg, devicesKey, nameBuf);
        final thisNameUs = total.elapsedMicroseconds - nameStart;
        nameReadUs += thisNameUs;
        if (thisNameUs > slowestNameUs) {
          slowestNameUs = thisNameUs;
          slowestName = name ?? mac;
        }
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
      logDiscovery.finer(
        () =>
            'registry: ${out.length} device(s) from $scanned subkey(s) — '
            'dllOpen ${dllOpenUs}us, keyOpen ${openUs}us, '
            'nameReads ${nameReadUs}us '
            '(slowest "${slowestName ?? '-'}" ${slowestNameUs}us), '
            'total ${total.elapsedMicroseconds}us',
      );
    } finally {
      reg.regCloseKey(devicesKey);
    }
  } catch (e) {
    logDiscovery.warning(
      () =>
          'registry enumeration failed after '
          '${total.elapsedMicroseconds}us: $e',
    );
    return out;
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

// Diagnostic-message tags sent from the reader isolate to the main isolate.
const String _evtExit = 'reader-exit'; // the read loop ended (n + wsa code)
const String _evtSpurious = 'reader-spurious'; // tolerated SOCKET_ERROR/wsa=0

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
  // DIAGNOSTICS: capture how/why the read loop exits so the main isolate can log
  // it (worker isolates can't reach the app's package:logging handler). `exitN`
  // is the recv() return that ended the loop; `exitErr` is WSAGetLastError() for
  // the non-timeout error path — this is the exact code we need to tell a real
  // disconnect from a transient error treated as EOF.
  int exitN = 0;
  int exitErr = 0;
  // Disconnect classification is FAIL-CLOSED on the one value we can read
  // reliably — recv()'s return — because WSAGetLastError() is only a HINT here:
  // it's a second, separate FFI call, and the Dart VM's safepoint/GC can run
  // between the recv() call and it, clobbering the thread's last-error to 0
  // (dart-lang/sdk#38832 — there's no native build to capture it inline, and the
  // blocking recv() can't be an `isLeaf` call). That's why a fast send/receive
  // burst (more allocation → more GC) intermittently surfaced as
  // `recv=-1, wsa=0` and tore down a live link: the -1 was almost always just a
  // benign SO_RCVTIMEO timeout whose code got clobbered.
  //
  //   n  > 0            -> data
  //   n == 0            -> REAL disconnect (graceful close; return-value based,
  //                        immune to the clobber — the unmissable backstop)
  //   n  < 0 + benign   -> keep reading (timeout / wouldblock / interrupted)
  //   n  < 0 + wsa == 0 -> clobbered code: keep reading, but BOUNDED so a real
  //                        reset clobbered to 0 can't be swallowed forever
  //   n  < 0 + any other code -> REAL disconnect (reset/abort/etc.)
  //
  // A spurious clobber self-corrects (the next recv yields data or a real
  // timeout, resetting the bound); a genuinely dead socket keeps returning -1
  // with no progress and trips the bound within ~200ms.
  var spurious = 0;
  const maxSpurious = 20;
  try {
    while (true) {
      final n = ws.recv(socket, buf, _recvBufSize, 0);
      if (n > 0) {
        spurious = 0;
        final bytes = Uint8List.fromList(buf.asTypedList(n));
        sendPort.send(TransferableTypedData.fromList([bytes]));
        continue;
      }
      if (n == 0) {
        exitN = 0; // peer closed the connection (clean EOF)
        break;
      }
      // n < 0 (SOCKET_ERROR). Whitelist the benign, non-fatal outcomes.
      final err = ws.wsaGetLastError();
      if (err == wsaeTimedOut || err == wsaeWouldBlock || err == wsaeIntr) {
        spurious = 0; // socket is alive, just no data this window
        continue;
      }
      if (err == 0) {
        // Clobbered last-error (see note above). No evidence of a real error, so
        // keep reading — but bounded, so a real reset whose code was clobbered to
        // 0 still exits instead of spinning forever.
        if (++spurious <= maxSpurious) {
          sendPort.send(<String, Object>{
            'event': _evtSpurious,
            'n': n,
            'wsa': 0,
            'count': spurious,
          });
          sleep(const Duration(milliseconds: 10)); // avoid a busy-spin
          continue;
        }
        exitN = n; // never cleared — treat as gone
        exitErr = 0;
        break;
      }
      // Any other WSA code (reset, abort, socket closed by close(), …) — real EOF.
      exitN = n;
      exitErr = err;
      break;
    }
  } catch (e) {
    exitErr = -2; // unexpected Dart-side error; fall through to EOF
  } finally {
    calloc.free(buf);
    ws.wsaCleanup(); // balance this isolate's WSAStartup
    // Report the exit reason (a Map, distinct from data/null), then signal close.
    sendPort.send(<String, Object>{
      'event': _evtExit,
      'n': exitN,
      'wsa': exitErr,
    });
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
      final bytes = data.materialize().asUint8List();
      // DIAGNOSTICS: time the blocking send() and capture any error code. A slow
      // send is the signature of the link waking from sniff (low-power) mode; an
      // error code is the writer-side view of the rare disconnect. Report back to
      // the main isolate only when notable (slow or failed) to limit noise.
      final sw = Stopwatch()..start();
      final err = _sendAll(ws, socket, bytes);
      sw.stop();
      if (err != 0 || sw.elapsedMilliseconds > 50) {
        mainPort.send(<String, int>{
          'bytes': bytes.length,
          'ms': sw.elapsedMilliseconds,
          'wsa': err,
        });
      }
    }
    ack?.send(true);
  });
}

/// Sends [bytes] fully. Returns 0 on success, or the WSA error code (or -1 if
/// `WSAGetLastError()` was 0) when `send` failed before all bytes went out.
int _sendAll(WinsockBindings ws, int socket, Uint8List bytes) {
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
      if (n == socketError || n <= 0) {
        return _wsaError(ws.wsaGetLastError()); // peer gone / error
      }
      offset += n;
    }
    return 0;
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

  // DIAGNOSTICS: time since the previous outbound send, to flag sends that follow
  // a long idle (the case where the link has dropped into sniff mode).
  final Stopwatch _txGap = Stopwatch()..start();

  void _start() {
    final readerPort = ReceivePort();
    _readerPort = readerPort;
    // DIAGNOSTICS: time between inbound chunks. A large gap before a chunk is the
    // link sitting idle (and likely in sniff/low-power mode); correlate the gap
    // with how slow the first post-idle exchange feels.
    final rxGap = Stopwatch()..start();
    readerPort.listen((msg) {
      if (msg == null) {
        _onClosedByPeer();
      } else if (msg is Map) {
        if (msg['event'] == _evtSpurious) {
          // A clobbered-last-error recv we tolerated (kept the link alive).
          // Per-event detail -> FINER.
          logConnection.finer(
            () =>
                'recv SOCKET_ERROR with wsa=0 (clobbered last-error) tolerated '
                '(#${msg['count']}) — link kept alive',
          );
        } else {
          // Reader-loop exit reason: recv() return value + WSA error code. This
          // is a lifecycle event (the disconnect) -> FINE. wsa=0 with n=0 is a
          // clean peer close; a non-zero wsa is the real disconnect code.
          logConnection.fine(
            () => 'reader exit: recv n=${msg['n']} wsa=${msg['wsa']}',
          );
        }
      } else if (msg is TransferableTypedData &&
          !_closed &&
          !_incoming.isClosed) {
        final gapMs = rxGap.elapsedMilliseconds;
        rxGap.reset();
        final bytes = msg.materialize().asUint8List();
        logConnection.finer(() => 'rx ${bytes.length}B (idle gap ${gapMs}ms)');
        _incoming.add(bytes);
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
      } else if (msg is Map) {
        // Notable send from the writer isolate: slow (ms) = link waking from
        // sniff mode; wsa != 0 = the send failed. Per-event detail -> FINER.
        logConnection.finer(
          () =>
              'tx send ${msg['bytes']}B took ${msg['ms']}ms wsa=${msg['wsa']}',
        );
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
    final gapMs = _txGap.elapsedMilliseconds;
    _txGap.reset();
    logConnection.finer(() => 'tx ${data.length}B (idle gap ${gapMs}ms)');
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
