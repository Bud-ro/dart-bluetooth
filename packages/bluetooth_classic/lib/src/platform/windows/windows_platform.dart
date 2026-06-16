import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../exceptions.dart';
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
class WindowsBluetoothClassic extends BluetoothClassicPlatform {
  WindowsBluetoothClassic();

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
      final raw = await Isolate.run(() => _enumerateDevices(remembered: true));
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
    // BluetoothFindFirstDevice with fIssueInquiry blocks for the inquiry window,
    // so we run it on a worker isolate and emit the results when it completes.
    final List<_RawDevice> raw;
    try {
      raw = await Isolate.run(
        () => _enumerateDevices(remembered: true, unknown: true, inquiry: true),
      );
    } on BluetoothException {
      rethrow;
    } catch (e) {
      throw BluetoothDiscoveryException('inquiry failed', cause: e);
    }
    final now = DateTime.now();
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
    final int result;
    try {
      final connectFuture = Isolate.run(
        () => _connectSocket(address, channel, uuid),
      );
      var timedOut = false;
      // Isolate.run can't be cancelled: if connect succeeds AFTER we time out,
      // the returned SOCKET would be dropped without closesocket — leaking the
      // handle and leaving a half-open RFCOMM link. Close any late socket.
      unawaited(
        connectFuture.then((sock) {
          if (timedOut && sock >= 0) {
            try {
              _ws.closesocket(sock);
            } catch (_) {}
          }
        }, onError: (_) {}),
      );
      result = await (timeout == null
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
    if (result < 0) {
      throw BluetoothConnectionException(
        'RFCOMM connect to $address failed',
        code: -result,
      );
    }
    return _WindowsRfcommTransport(socket: result, ws: _ws);
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
    return out;
  } finally {
    calloc.free(params);
    calloc.free(info);
    ws.wsaCleanup(); // balance this isolate's WSAStartup
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

/// Maps a WSA error to a guaranteed-negative failure sentinel (so a spurious
/// `WSAGetLastError()` of 0 can't be mistaken for the valid SOCKET handle 0).
int _connectError(int err) => err == 0 ? -1 : -err;

/// Opens and connects an RFCOMM socket. Returns the SOCKET handle on success,
/// or a negative failure sentinel (see [_connectError]).
int _connectSocket(String address, int? channel, String serviceUuid) {
  final ws = WinsockBindings();
  ws.startup();
  final sock = ws.socket(afBth, sockStream, bthprotoRfcomm);
  if (sock == invalidSocket) return _connectError(ws.wsaGetLastError());

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
      return _connectError(err);
    }
    return sock;
  } finally {
    calloc.free(addr);
  }
}

const int _recvBufSize = 8192;
const int _sendChunkFlags = 0;

void _recvEntry(List<Object?> args) {
  final socket = args[0] as int;
  final sendPort = args[1] as SendPort;
  final ws = WinsockBindings()..startup();
  final buf = calloc<ffi.Uint8>(_recvBufSize);
  try {
    while (true) {
      final n = ws.recv(socket, buf, _recvBufSize, 0);
      if (n <= 0) break;
      final bytes = Uint8List.fromList(buf.asTypedList(n));
      sendPort.send(TransferableTypedData.fromList([bytes]));
    }
  } catch (_) {
    // fall through to EOF
  } finally {
    calloc.free(buf);
    // Balance this isolate's WSAStartup so the per-process Winsock refcount
    // doesn't grow across connect/disconnect cycles.
    ws.wsaCleanup();
    sendPort.send(null); // signal closed
  }
}

void _writeEntry(List<Object?> args) {
  final socket = args[0] as int;
  final mainPort = args[1] as SendPort;
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
    // Unblock recv and break the connection.
    try {
      _ws.shutdown(_socket, 2); // SD_BOTH
      _ws.closesocket(_socket);
    } catch (_) {
      /* already gone */
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
