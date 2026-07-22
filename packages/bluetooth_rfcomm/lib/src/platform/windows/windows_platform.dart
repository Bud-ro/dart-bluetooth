import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show sleep;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

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
/// [startDiscovery] runs a real `WSALookupService` inquiry (LUP_FLUSHCACHE,
/// ~10s) on a worker isolate, finding nearby devices whether or not they're
/// paired; it is abortable via `WSALookupServiceEnd`. The facade keeps its
/// BACKGROUND scan's inquiries paused while a connect is in flight; a caller's
/// one-shot discovery is the caller's to cancel before connecting.
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

  /// Live inquiries: controller → lookup handle (null until the worker's
  /// Begin completes), so [stopDiscovery] can abort and close all of them.
  final Map<StreamController<BluetoothDiscoveryResult>, int?> _inquiries = {};

  /// Test hook: replaces the inquiry worker spawn (the real one runs
  /// `WSALookupService*` on a worker isolate, unrunnable off-Windows). The
  /// replacement receives the activation's [SendPort] and drives the worker
  /// protocol itself: optional `{'handle': int}` / `{'error': int}` maps,
  /// sighting maps, then a terminal `null`.
  @visibleForTesting
  Future<void> Function(SendPort port)? debugSpawnInquiry;

  /// Test hook: observes every main-isolate lookup End (called just before
  /// the `WSALookupServiceEnd` FFI call, which off-Windows fails and is
  /// swallowed by [_endLookup]'s catch).
  @visibleForTesting
  void Function(int handle)? debugOnLookupEnd;

  @override
  Stream<BluetoothDiscoveryResult> startDiscovery() {
    // A REAL radio inquiry (WSALookupService with LUP_FLUSHCACHE, ~10s per
    // run) that finds nearby devices whether or not they're paired. It holds
    // the radio while it runs — the facade keeps it away from connects — and
    // it IS abortable: cancelling the subscription (or stopDiscovery) calls
    // WSALookupServiceEnd, which unblocks the worker's WSALookupServiceNext.
    late StreamController<BluetoothDiscoveryResult> controller;
    var cancelled = false;
    // Activation identity, bumped on every onListen. A rapid cancel→re-listen
    // leaves the OLD worker's messages (its terminal null, its onExit null,
    // even its late 'handle') still in flight when the new activation
    // registers; without an identity check the stale null would close the
    // controller and delete the NEW activation's _inquiries slot, and a stale
    // handle would clobber it. A stale message may only close its own
    // ReceivePort (and End its own orphaned handle) — never touch the
    // controller or a newer activation's registration.
    var generation = 0;

    void endThisLookup() {
      final handle = _inquiries.remove(controller);
      _endLookup(handle);
    }

    controller = StreamController<BluetoothDiscoveryResult>.broadcast(
      onListen: () {
        // Fresh activation (broadcast onListen refires when listeners return
        // after dropping to zero): reset the cancel latch or the new inquiry
        // would be aborted the moment its handle arrives. The handle slot in
        // _inquiries is likewise reset by the re-registration below.
        cancelled = false;
        final myGeneration = ++generation;
        _inquiries[controller] = null;
        // Hold a main-isolate Winsock init for the platform's lifetime: the
        // terminal-null path below Ends the lookup from THIS isolate after
        // the worker has already balanced its own WSAStartup with WSACleanup,
        // so without this the process refcount could hit zero in between and
        // tear the still-open handle down with Winsock itself. Best-effort:
        // if Winsock can't load, Begin fails in the worker and surfaces as an
        // inquiry error. (Same lazy init as the _ws getter.)
        try {
          _bindings ??= WinsockBindings()..startup();
        } catch (_) {}
        // Paired set (instant registry read) so sightings of bonded devices
        // carry the right bond state and a name even before the inquiry's
        // remote-name request resolves.
        Map<int, _RawDevice> paired;
        try {
          paired = {for (final r in _enumeratePairedFromRegistry()) r.addr: r};
        } catch (_) {
          paired = const {};
        }
        final rp = ReceivePort();
        rp.listen((msg) {
          if (msg == null) {
            // Worker's terminal null, or its onExit notification (whichever
            // arrives first) — either way the inquiry is over.
            rp.close();
            // Stale activation: a newer onListen owns the controller and the
            // _inquiries slot now — this null may touch neither.
            if (myGeneration != generation) return;
            // The worker never Ends the handle itself (see _inquiryEntry), so
            // End any handle still registered here. Cancel/stopDiscovery End
            // on this same event loop and remove the entry as they do, so
            // exactly one End ever runs per handle.
            _endLookup(_inquiries.remove(controller));
            if (!controller.isClosed) unawaited(controller.close());
            return;
          }
          if (msg is List) {
            // Uncaught error in the worker isolate (delivered via onError).
            // Surface it; the paired onExit null closes the stream right after.
            logDiscovery.warning(() => 'inquiry isolate error: ${msg[0]}');
            if (myGeneration == generation && !controller.isClosed) {
              controller.addError(
                BluetoothDiscoveryException(
                  'Windows inquiry failed',
                  cause: msg[0],
                ),
              );
            }
            return;
          }
          final m = msg as Map;
          if (m.containsKey('handle')) {
            final handle = m['handle'] as int;
            if (myGeneration != generation || cancelled) {
              // Stale activation (superseded by a re-listen), or cancel won
              // the race with the worker's Begin: abort now.
              _endLookup(handle);
            } else if (_inquiries.containsKey(controller)) {
              _inquiries[controller] = handle;
            } else {
              // stopDiscovery() removed us before the handle arrived.
              _endLookup(handle);
            }
          } else if (m.containsKey('error')) {
            logDiscovery.warning(() => 'inquiry failed: wsa=${m['error']}');
            if (myGeneration == generation && !controller.isClosed) {
              controller.addError(
                BluetoothDiscoveryException(
                  'Windows inquiry failed',
                  code: m['error'],
                ),
              );
            }
          } else {
            final addr = m['addr'] as int;
            final inquiryName = m['name'] as String?;
            final known = paired[addr];
            final freshName = (inquiryName != null && inquiryName.isNotEmpty)
                ? inquiryName
                : null;
            // A paired sighting reuses the registry mapping (name, bond state,
            // class) with the inquiry's fresher name layered on top.
            final device = known != null
                ? _toDevice(known).copyWith(name: freshName)
                : BluetoothDevice(
                    id: DeviceId.address(formatBthAddr(addr)),
                    name: freshName,
                    type: BluetoothDeviceType.classic,
                    bondState: BluetoothBondState.none,
                  );
            logDiscovery.finer(() => 'inquiry sighting: ${device.id}');
            if (myGeneration == generation && !controller.isClosed) {
              controller.add(
                BluetoothDiscoveryResult(
                  device: device,
                  rssi: null,
                  timestamp: DateTime.now(),
                ),
              );
            }
          }
        });
        // Never kill this isolate: it must run its cleanup path (WSACleanup +
        // the final null that closes rp) or the open ReceivePort
        // would keep the main isolate alive. Cancellation is delivered by
        // aborting the lookup handle instead. onExit/onError guarantee the
        // terminal null (and the error) still arrive if the worker dies on an
        // uncaught throw before its own cleanup runs — without them rp would
        // stay open and the facade's scan cycle would hang forever.
        final spawnInquiry = debugSpawnInquiry;
        final Future<Object?> spawned = spawnInquiry != null
            ? spawnInquiry(rp.sendPort)
            : Isolate.spawn(
                _inquiryEntry,
                [rp.sendPort],
                onExit: rp.sendPort,
                onError: rp.sendPort,
              );
        spawned.then(
          (_) {},
          onError: (Object e) {
            rp.close();
            if (myGeneration == generation && !controller.isClosed) {
              _inquiries.remove(controller);
              controller.addError(
                BluetoothDiscoveryException('inquiry spawn failed', cause: e),
              );
              unawaited(controller.close());
            }
          },
        );
      },
      onCancel: () {
        cancelled = true;
        // Aborts the blocked WSALookupServiceNext; the worker then runs its
        // cleanup path (WSACleanup, never a second End) and sends the final
        // null itself.
        endThisLookup();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopDiscovery() async {
    // Abort every in-flight inquiry and close its stream (matching the other
    // backends). The workers notice the ended lookup and exit on their own.
    for (final entry in _inquiries.entries.toList()) {
      _endLookup(entry.value);
      if (!entry.key.isClosed) unawaited(entry.key.close());
    }
    _inquiries.clear();
  }

  /// Ends a lookup: `WSALookupServiceEnd` from this isolate unblocks a
  /// worker's blocked `WSALookupServiceNext` — the documented cross-thread
  /// cancel mechanism — and also closes a naturally-completed lookup (the
  /// terminal-null path). This is the ONLY place End is called (the worker
  /// never Ends its own handle), and every caller runs on this isolate's
  /// event loop and removes the handle's _inquiries entry in the same
  /// synchronous step — so a handle can never be Ended twice, which matters
  /// because handle values are recycled and a double End could abort an
  /// unrelated fresh inquiry that reused the value.
  void _endLookup(int? handle) {
    if (handle == null) return;
    debugOnLookupEnd?.call(handle);
    try {
      _ws.lookupServiceEnd(handle);
    } catch (e) {
      logDiscovery.warning(() => 'WSALookupServiceEnd failed: $e');
    }
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
    // The registry view doesn't carry a class of device; report "unknown" the
    // same way every other platform does (null), never a fake 0.
    deviceClass: r.classOfDevice == 0 ? null : r.classOfDevice,
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
    this.authenticated,
  );
  final int addr;
  final String name;
  final int classOfDevice;
  final bool connected;
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
            true, // listed here => authenticated/paired
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
  // Parse before socket(): a malformed address must throw BEFORE a SOCKET
  // exists, or the FormatException path would leak the handle.
  final btAddr = parseBthAddr(address);
  final sock = ws.socket(afBth, sockStream, bthprotoRfcomm);
  if (sock == invalidSocket) return (0, _wsaError(ws.wsaGetLastError()));

  final addr = calloc<SockaddrBth>();
  try {
    addr.ref.addressFamily = afBth;
    addr.ref.btAddr = btAddr;
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

/// Runs one full Bluetooth device inquiry (`WSALookupService*` with
/// LUP_FLUSHCACHE, ~10s) and streams sightings back as
/// `{'addr': int, 'name': String?}` maps, then a final `null`.
///
/// First sends `{'handle': int}` so the main isolate can abort the inquiry with
/// `WSALookupServiceEnd` (the documented cross-thread cancel); on Begin failure
/// sends `{'error': int}` instead. The final `null` is sent on EVERY exit path —
/// the main isolate's ReceivePort stays open until it arrives.
///
/// This worker NEVER calls `WSALookupServiceEnd`, not even on natural
/// completion: handle values are recycled, and a worker-side End racing a
/// main-side cancel/stopDiscovery End could leave one of the two aborting an
/// unrelated fresh inquiry that reused the value. Instead the terminal `null`
/// tells the main isolate to End any handle still registered for this inquiry
/// — all Ends are thereby serialized on the main isolate's event loop (see
/// `_endLookup`). The main isolate holds its own WSAStartup for the platform's
/// lifetime, so the handle survives this worker's balanced `WSACleanup` below.
void _inquiryEntry(List<Object?> args) {
  final sendPort = args[0] as SendPort;
  final ws = WinsockBindings()..startup();
  final hLookup = calloc<ffi.IntPtr>();
  final qs = calloc<WsaQuerySetW>();
  int handle;
  try {
    qs.ref.dwSize = ffi.sizeOf<WsaQuerySetW>();
    qs.ref.dwNameSpace = nsBth;
    final rc = ws.lookupServiceBegin(
      qs,
      lupContainers | lupFlushCache,
      hLookup,
    );
    if (rc != 0) {
      sendPort.send(<String, int>{'error': _wsaError(ws.wsaGetLastError())});
      sendPort.send(null);
      ws.wsaCleanup();
      return;
    }
    handle = hLookup.value;
  } finally {
    calloc.free(qs);
    calloc.free(hLookup);
  }
  sendPort.send(<String, int>{'handle': handle});

  var bufSize = 4096;
  var buf = calloc<ffi.Uint8>(bufSize);
  final size = calloc<ffi.Uint32>();
  try {
    while (true) {
      size.value = bufSize;
      final rc = ws.lookupServiceNext(
        handle,
        lupReturnName | lupReturnAddr,
        size,
        buf.cast(),
      );
      if (rc != 0) {
        final err = ws.wsaGetLastError();
        if (err == wsaEFault) {
          // Result didn't fit; `size` now holds the required byte count.
          final needed = size.value;
          calloc.free(buf);
          bufSize = needed > bufSize ? needed : bufSize * 2;
          buf = calloc<ffi.Uint8>(bufSize);
          continue;
        }
        // WSA_E_CANCELLED (blocked Next aborted by the main isolate's End),
        // WSA_INVALID_HANDLE (End completed before this Next), natural
        // completion (WSA_E_NO_MORE / WSAENOMORE) and real errors all end the
        // scan identically: the main isolate owns every End (see the doc
        // comment above), so there is nothing to close here.
        break;
      }
      final result = buf.cast<WsaQuerySetW>().ref;
      int? addr;
      if (result.dwNumberOfCsAddrs > 0 && result.lpcsaBuffer != ffi.nullptr) {
        final remote = result.lpcsaBuffer.ref.remoteAddr;
        if (remote.lpSockaddr != ffi.nullptr) {
          addr = remote.lpSockaddr.cast<SockaddrBth>().ref.btAddr;
        }
      }
      if (addr == null) continue;
      String? name;
      final namePtr = result.lpszServiceInstanceName;
      if (namePtr != ffi.nullptr) {
        name = namePtr.cast<Utf16>().toDartString();
      }
      sendPort.send(<String, Object?>{'addr': addr, 'name': name});
    }
  } catch (_) {
    // Fall through to cleanup; the main isolate treats early null as "done".
  } finally {
    calloc.free(buf);
    calloc.free(size);
    ws.wsaCleanup();
    sendPort.send(null);
  }
}

const int _recvBufSize = 8192;
const int _sendChunkFlags = 0;

/// What the reader loop should do with one `recv()` return.
enum RecvOutcome { deliver, keepReading, tolerateSpurious, disconnect }

/// Pure classification of a `recv()` return — the 0.1.1 clobbered-last-error
/// rules, extracted so they are unit-testable on any host:
///
///   n  > 0                     -> deliver
///   n == 0                     -> disconnect (clean EOF; return-value based,
///                                 immune to the last-error clobber)
///   n  < 0 + benign wsa        -> keepReading (timeout/wouldblock/interrupted)
///   n  < 0 + wsa == 0          -> tolerateSpurious while under [maxSpurious]
///                                 (clobbered code, dart-lang/sdk#38832), then
///                                 disconnect so a clobbered real reset can't
///                                 be swallowed forever
///   n  < 0 + any other wsa     -> disconnect
@visibleForTesting
RecvOutcome classifyRecv(
  int n,
  int wsa,
  int spuriousCount, {
  int maxSpurious = 20,
}) {
  if (n > 0) return RecvOutcome.deliver;
  if (n == 0) return RecvOutcome.disconnect;
  if (wsa == wsaeTimedOut || wsa == wsaeWouldBlock || wsa == wsaeIntr) {
    return RecvOutcome.keepReading;
  }
  if (wsa == 0) {
    return spuriousCount < maxSpurious
        ? RecvOutcome.tolerateSpurious
        : RecvOutcome.disconnect;
  }
  return RecvOutcome.disconnect;
}

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
  // A spurious clobber self-corrects: on a healthy socket the next recv() blocks
  // (returning data or a real timeout), which resets the bound. A genuinely dead
  // socket returns -1 immediately, so the count bound (maxSpurious) trips quickly
  // and the link closes — the count bound guarantees termination regardless of
  // per-call timing.
  var spurious = 0;
  try {
    var reading = true;
    while (reading) {
      final n = ws.recv(socket, buf, _recvBufSize, 0);
      final err = n < 0 ? ws.wsaGetLastError() : 0;
      switch (classifyRecv(n, err, spurious)) {
        case RecvOutcome.deliver:
          spurious = 0;
          final bytes = Uint8List.fromList(buf.asTypedList(n));
          sendPort.send(TransferableTypedData.fromList([bytes]));
        case RecvOutcome.keepReading:
          spurious = 0; // socket is alive, just no data this window
        case RecvOutcome.tolerateSpurious:
          spurious++;
          sendPort.send(<String, Object>{
            'event': _evtSpurious,
            'n': n,
            'wsa': 0,
            'count': spurious,
          });
          sleep(const Duration(milliseconds: 10)); // avoid a busy-spin
        case RecvOutcome.disconnect:
          exitN = n;
          exitErr = n < 0 ? err : 0;
          reading = false;
      }
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

// Writer-isolate exit notification (sent before wsaCleanup so close() knows
// the writer will never touch the socket again).
const String _evtWriterExit = 'writer-exit';
// Writer-isolate consumed-bytes report: {'event': ..., 'total': cumulative}.
const String _evtConsumed = 'writer-consumed';

/// SO_SNDBUF asked of the OS for the RFCOMM socket (best-effort). A roomier OS
/// send buffer lets the writer's blocking `send()` return as soon as the bytes
/// are queued instead of stalling on a slow link, and makes transient
/// WSAENOBUFS far less likely under bursty traffic.
const int _sendBufBytes = 256 * 1024;

/// Bounded retry policy for TRANSIENT send errors (WSAENOBUFS, a clobbered
/// last-error, …): retry the REMAINDER of the message — never skip bytes —
/// up to [_maxSendRetries] times, [_sendRetryDelay] apart (~500ms total).
/// Exhaustion escalates to disconnect; a hole in the stream is never an option.
const int _maxSendRetries = 100;
const Duration _sendRetryDelay = Duration(milliseconds: 5);

/// Consumed-report granularity: the writer tells the main isolate how many
/// bytes it has handed to the OS at most every [_consumedReportBytes] bytes or
/// [_consumedReportMs] ms (whichever comes first, and only when there is
/// something unreported) — so `pendingWriteBytes` lags reality by at most that
/// much while staying O(1) per message.
const int _consumedReportBytes = 16 * 1024;
const int _consumedReportMs = 25;

/// Accumulates the writer isolate's consumed-byte count and decides when to
/// report it (the [_consumedReportBytes]/[_consumedReportMs] gate). When the
/// gate suppresses a report, a trailing-edge timer is armed so the LAST bytes
/// of a burst still get reported once the queue goes idle — message receipt is
/// the only other trigger, so without the timer `pendingWriteBytes` would
/// stick at a stale nonzero value after a sub-gate burst until the next write
/// or flush (and `drain(belowBytes: n)`, which polls it without flushing,
/// would never complete). Extracted from `_writeEntry` so the trailing-report
/// behaviour is unit-testable on any host.
@visibleForTesting
class ConsumedReporter {
  ConsumedReporter(
    this._send, {
    int reportBytes = _consumedReportBytes,
    Duration reportInterval = const Duration(milliseconds: _consumedReportMs),
  }) : _reportBytes = reportBytes,
       _reportInterval = reportInterval;

  /// Sends a cumulative consumed total to the main isolate.
  final void Function(int total) _send;
  final int _reportBytes;
  final Duration _reportInterval;
  final Stopwatch _gap = Stopwatch()..start();
  Timer? _trailing;
  int _total = 0;
  int _unreported = 0;

  /// Cumulative bytes consumed so far (reported or not) — the exact value the
  /// flush ack carries.
  int get total => _total;

  /// Records [bytes] more consumed bytes and reports if the gate allows.
  void add(int bytes) {
    _total += bytes;
    _unreported += bytes;
    report();
  }

  /// Reports the current total unless gated (small AND recent); [force]
  /// bypasses the gate. A gated call arms the trailing-edge timer.
  void report({bool force = false}) {
    if (_unreported == 0) return;
    if (!force &&
        _unreported < _reportBytes &&
        _gap.elapsed < _reportInterval) {
      // Suppressed: arm the trailing report in case no further message (the
      // usual re-trigger) ever arrives to flush the tail.
      _trailing ??= Timer(_reportInterval, () {
        _trailing = null;
        report(force: true);
      });
      return;
    }
    _trailing?.cancel();
    _trailing = null;
    _send(_total);
    _unreported = 0;
    _gap.reset();
  }

  /// Flushes any unreported tail and cancels the trailing timer (writer exit).
  void dispose() {
    report(force: true);
    _trailing?.cancel();
    _trailing = null;
  }
}

void _writeEntry(List<Object?> args) {
  final socket = args[0] as int;
  final mainPort = args[1] as SendPort;
  // This isolate calls send(), so it needs its own WSAStartup (Winsock init does
  // not carry across Dart isolates); balanced by the wsaCleanup on shutdown.
  final ws = WinsockBindings()..startup();
  // Best-effort SO_SNDBUF sizing (see _sendBufBytes). Failure is harmless —
  // the stack keeps its default.
  final opt = calloc<ffi.Uint8>(4);
  opt.cast<ffi.Uint32>().value = _sendBufBytes;
  ws.setsockopt(socket, solSocket, soSndBuf, opt, 4);
  calloc.free(opt);
  final rp = ReceivePort();
  mainPort.send(rp.sendPort);
  // Reusable grow-only staging buffer: one allocation amortized over the whole
  // connection instead of a calloc/free per message.
  var bufCap = 8192;
  var buf = calloc<ffi.Uint8>(bufCap);
  // First send error that lost bytes; acked back on flush so flush()/write()
  // can fail honestly instead of resolving on a dead link (Linux parity).
  // Once set the writer sends NOTHING further: after losing part of message N,
  // transmitting message N+1 would put a silent hole in a reliable stream.
  var fatalWsa = 0;
  // Cumulative bytes consumed (handed to the OS, or dropped after the link
  // died — the transport is closing then anyway) for pendingWriteBytes. The
  // reporter's trailing timer runs on this isolate's event loop, which stays
  // live between messages (rp is open until the exit-null).
  final consumed = ConsumedReporter(
    (total) =>
        mainPort.send(<String, Object>{'event': _evtConsumed, 'total': total}),
  );

  rp.listen((msg) {
    if (msg == null) {
      // Final consumed report (dispose flushes any gated tail and cancels the
      // trailing timer), then announce exit BEFORE cleanup: after that
      // message the writer will never touch the socket again, so close() may
      // safely closesocket.
      consumed.dispose();
      mainPort.send(<String, Object>{'event': _evtWriterExit});
      rp.close();
      calloc.free(buf);
      ws.wsaCleanup(); // balance this isolate's WSAStartup on shutdown
      return;
    }
    final rec = msg as List<Object?>;
    final data = rec[0] as TransferableTypedData?;
    final ack = rec[1] as SendPort?;
    if (data != null) {
      final bytes = data.materialize().asUint8List();
      if (fatalWsa != 0) {
        // Link already failed mid-stream — never transmit past a hole. Count
        // the bytes consumed so pendingWriteBytes drains while the transport
        // tears down (close() discards unflushed bytes by contract).
        consumed.add(bytes.length);
      } else {
        if (bytes.length > bufCap) {
          calloc.free(buf);
          bufCap = bytes.length * 2;
          buf = calloc<ffi.Uint8>(bufCap);
        }
        buf.asTypedList(bytes.length).setAll(0, bytes);
        // DIAGNOSTICS: time the blocking send() and capture any error code. A
        // slow send is the signature of the link waking from sniff (low-power)
        // mode; an error code is the writer-side view of the rare disconnect.
        // Report back to the main isolate only when notable (slow or failed).
        final sw = Stopwatch()..start();
        final err = _sendAll(ws, socket, buf, bytes.length);
        sw.stop();
        consumed.add(bytes.length);
        if (err != 0) {
          // _sendAll already retried transient errors; any error here means
          // bytes may be missing from the stream — the link is done for.
          fatalWsa = err;
          mainPort.send(<String, int>{
            'bytes': bytes.length,
            'ms': sw.elapsedMilliseconds,
            'wsa': err,
          });
        } else if (sw.elapsedMilliseconds > 50) {
          mainPort.send(<String, int>{
            'bytes': bytes.length,
            'ms': sw.elapsedMilliseconds,
            'wsa': 0,
          });
        }
      }
    }
    // The flush ack carries the first byte-losing error (0 = every byte handed
    // to the OS) plus the up-to-date consumed total, so a flush after a failed
    // send reports the loss and pendingWriteBytes is exact after a flush.
    ack?.send(<int>[fatalWsa, consumed.total]);
  });
}

/// Sends [len] bytes of [buf] fully. Returns 0 only when EVERY byte was handed
/// to the OS; otherwise the WSA error code (or -1 if `WSAGetLastError()` was 0).
///
/// Never skips bytes: a fatal error (connection dead) returns immediately, and
/// a transient one (WSAENOBUFS, clobbered last-error, …) retries the REMAINDER
/// under the bounded [_maxSendRetries]/[_sendRetryDelay] policy — so a nonzero
/// return always means "this stream can no longer be trusted", which the writer
/// escalates to disconnect. A transient blip mid-message therefore either heals
/// invisibly or kills the link; it can never silently drop a message while
/// later ones keep flowing.
int _sendAll(
  WinsockBindings ws,
  int socket,
  ffi.Pointer<ffi.Uint8> buf,
  int len,
) {
  var offset = 0;
  var retries = 0;
  while (offset < len) {
    final n = ws.send(socket, buf + offset, len - offset, _sendChunkFlags);
    if (n > 0) {
      offset += n;
      retries = 0; // progress resets the retry budget
      continue;
    }
    final err = _wsaError(ws.wsaGetLastError());
    if (isFatalWsaSendError(err)) {
      return err; // link is dead — no point retrying
    }
    if (++retries > _maxSendRetries) return err; // transient but not clearing
    sleep(_sendRetryDelay); // writer isolate only; the app isolate never blocks
  }
  return 0;
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

  /// Completed once the respective isolate has reported it will never touch
  /// the socket again — close() waits for BOTH before closesocket, so a
  /// recycled SOCKET value can never be read/written by a stale isolate.
  final Completer<void> _readerExited = Completer<void>();
  final Completer<void> _writerExited = Completer<void>();

  /// First fatal writer-side send error (writer ack / control message), so
  /// flush() can fail honestly instead of resolving on a dead link.
  int? _fatalSendWsa;

  /// Bytes accepted by [send] (counted at enqueue) and cumulative bytes the
  /// writer has reported consumed — their difference is [pendingWriteBytes].
  int _sendEnqueuedBytes = 0;
  int _writerConsumedBytes = 0;

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
        if (!_readerExited.isCompleted) _readerExited.complete();
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
    // A failed spawn is a dead transport, not an unhandled async error.
    Isolate.spawn(_recvEntry, [_socket, readerPort.sendPort]).then(
      (i) {
        if (_closed) {
          i.kill(priority: Isolate.beforeNextEvent);
        } else {
          _reader = i;
        }
      },
      onError: (Object e) {
        logConnection.warning(() => 'reader isolate spawn failed: $e');
        if (!_readerExited.isCompleted) _readerExited.complete();
        _onClosedByPeer();
      },
    );

    final control = ReceivePort();
    _writerControlPort = control;
    control.listen((msg) {
      if (msg is SendPort) {
        if (_closed) {
          // close() won the startup race: its exit-null (teardown step 2) had
          // nowhere to go while _writerSend was still null, so deliver it now
          // — otherwise close() sits out its full 2s bound waiting for a
          // writer exit that was never requested. The queued writes are
          // dropped, not forwarded (close() discards unflushed bytes by
          // contract). The writer hasn't touched the socket since the
          // setsockopt that PRECEDED this SendPort and never will (the
          // exit-null is the only message it gets), so it is already safe to
          // closesocket — complete _writerExited directly rather than wait
          // for a _evtWriterExit that a spawn-race kill may have prevented.
          _pendingWrites.clear();
          msg.send(null);
          if (!_writerExited.isCompleted) _writerExited.complete();
          return;
        }
        _writerSend = msg;
        for (final w in _pendingWrites) {
          msg.send(w);
        }
        _pendingWrites.clear();
      } else if (msg is Map) {
        if (msg['event'] == _evtWriterExit) {
          if (!_writerExited.isCompleted) _writerExited.complete();
          return;
        }
        if (msg['event'] == _evtConsumed) {
          // Cumulative + monotonic, so "take the max" is race-proof against a
          // flush ack that carried a fresher total.
          final total = msg['total'] as int;
          if (total > _writerConsumedBytes) _writerConsumedBytes = total;
          return;
        }
        final wsa = msg['wsa'] as int;
        if (wsa != 0) {
          logConnection.warning(() => 'send failed: ${msg['bytes']}B wsa=$wsa');
          // The writer only reports a send error after its bounded transient-
          // retry budget is exhausted (or a fatal code) — either way bytes may
          // be missing from the stream, so EVERY reported send error escalates
          // to disconnect. Silently resuming after a hole is never an option;
          // and for fatal codes this also beats waiting for the reader's
          // recv() to notice (the link-supervision timeout can be ~20s when
          // the peer just powered off).
          _fatalSendWsa ??= wsa;
          _onClosedByPeer();
        } else {
          // A slow (but successful) send — link waking from sniff mode. Per-event
          // diagnostic detail -> FINER.
          logConnection.finer(
            () => 'tx send ${msg['bytes']}B took ${msg['ms']}ms',
          );
        }
      }
    });
    Isolate.spawn(_writeEntry, [_socket, control.sendPort]).then(
      (i) {
        if (_closed) {
          i.kill(priority: Isolate.beforeNextEvent);
        } else {
          _writer = i;
        }
      },
      onError: (Object e) {
        logConnection.warning(() => 'writer isolate spawn failed: $e');
        if (!_writerExited.isCompleted) _writerExited.complete();
        _onClosedByPeer();
      },
    );

    _state.add(ConnectionState.connected);
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<ConnectionState> get stateChanges => _state.stream;

  @override
  ConnectionState get state => _current;

  /// Winsock RFCOMM is a stream socket: the OS fragments writes of any size,
  /// so there is no OS-advertised per-write payload cap to report.
  @override
  int? get maxPayloadSize => null;

  /// Bytes accepted by [send] but not yet handed to the OS (approximate).
  ///
  /// Granularity: the writer isolate reports its consumed total at most every
  /// [_consumedReportBytes] bytes / [_consumedReportMs] ms, and a [flush] ack
  /// carries an exact total — so this can briefly OVER-state the backlog by up
  /// to that window, never under-state it. A trailing-edge report (see
  /// [ConsumedReporter]) guarantees convergence to the true backlog within
  /// ~2× [_consumedReportMs] of the writer going idle, without needing a
  /// flush. Returns 0 once closed.
  @override
  int get pendingWriteBytes {
    if (_closed) return 0;
    final pending = _sendEnqueuedBytes - _writerConsumedBytes;
    return pending > 0 ? pending : 0;
  }

  @override
  void send(Uint8List data) {
    if (_closed) throw const BluetoothWriteException('transport closed');
    final gapMs = _txGap.elapsedMilliseconds;
    _txGap.reset();
    logConnection.finer(() => 'tx ${data.length}B (idle gap ${gapMs}ms)');
    _sendEnqueuedBytes += data.length;
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
    // isolate exits, the ack never arrives — don't hang forever.
    final Object? result;
    try {
      result = await Future.any<Object?>([ack.first, _done.future]);
    } finally {
      ack.close();
    }
    // The ack is [firstByteLosingWsa, consumedTotal]: 0 in the first slot means
    // every byte was handed to the OS. Failing here — instead of resolving
    // successfully on a dead link — matches the Linux flush semantics.
    int? fatal;
    if (result is List) {
      final ackFatal = result[0] as int;
      final total = result[1] as int;
      if (total > _writerConsumedBytes) _writerConsumedBytes = total;
      if (ackFatal != 0) fatal = ackFatal;
    }
    fatal ??= _fatalSendWsa;
    if (fatal != null && fatal != 0) {
      throw BluetoothWriteException('flush failed — link lost', code: fatal);
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
    // Teardown ORDER matters: SOCKET handle values are recycled by Winsock, so
    // closesocket must not run until the reader/writer isolates have stopped
    // touching this handle — otherwise a stale isolate could recv/send on a
    // brand-new connection that reused the value.
    //  1. shutdown(SD_BOTH): queued/future sends fail (close() discards
    //     unflushed bytes by contract) and the reader's recv returns promptly.
    try {
      _ws.shutdown(_socket, 2); // SD_BOTH
    } catch (e) {
      logConnection.warning(() => 'socket shutdown error: $e');
    }
    //  2. Tell the writer to exit; it announces _evtWriterExit when done. The
    //     reader notices the shutdown within its SO_RCVTIMEO slice and exits.
    //     If the writer's SendPort hasn't arrived yet this no-ops — the
    //     control handler sends the exit-null (and completes _writerExited)
    //     itself when the port shows up, so this close() isn't left waiting
    //     out the full step-3 bound.
    _writerSend?.send(null);
    //  3. Wait (bounded — a wedged isolate must not hang close forever).
    await Future.any<Object?>([
      Future.wait([_readerExited.future, _writerExited.future]),
      Future<void>.delayed(const Duration(seconds: 2)),
    ]);
    //  4. Now the handle is safe to free. Log the result: a failed closesocket
    //     keeps the device's RFCOMM channel busy — the prime suspect for "the
    //     next connect fails until the app restarts".
    try {
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
