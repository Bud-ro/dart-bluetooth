import 'dart:async';
import 'dart:typed_data';

import 'connection.dart';
import 'exceptions.dart';
import 'logging.dart';
import 'models/uuid.dart';

/// A serial-style (UART-like) duplex byte channel over a GATT write+notify
/// characteristic pair — the BLE analogue of an RFCOMM connection.
///
/// Create one with [BleConnection.asSerial] (defaulting to the Nordic UART
/// Service). [input] streams bytes the peripheral pushes (notify); [write]/[add]
/// send bytes (chunked to the ATT payload size). Writes are serialised — GATT
/// can't overlap operations — so byte order is preserved.
///
/// ```dart
/// final serial = (await ble.connect(device)).asSerial();
/// await conn.discoverServices();
/// serial.input.listen((bytes) => stdout.add(bytes));
/// await serial.write(Uint8List.fromList('AT\r\n'.codeUnits));
/// ```
class BleSerial {
  BleSerial(
    this._conn, {
    required this.service,
    required this.writeCharacteristic,
    required this.notifyCharacteristic,
    this.writeWithoutResponse = true,
    this.chunkSize = 20,
  });

  final BleConnection _conn;

  /// Service holding the write/notify characteristics.
  final Uuid service;

  /// Characteristic the central writes to (data → peripheral).
  final Uuid writeCharacteristic;

  /// Characteristic the central subscribes to (data ← peripheral).
  final Uuid notifyCharacteristic;

  /// Whether to use write-without-response (faster; no per-write ack).
  final bool writeWithoutResponse;

  /// Max bytes per GATT write (ATT payload). Defaults to the safe 20 (MTU 23);
  /// raise it with [negotiateMtu].
  int chunkSize;

  StreamController<Uint8List>? _inputCtrl;
  StreamSubscription<Uint8List>? _inputSub;
  Future<void> _chain = Future<void>.value();
  bool _closed = false;

  /// Bytes received while [input] had no listener, replayed (in order) to the
  /// next listener. Bounded by [_maxRxBufferBytes]; beyond that the OLDEST
  /// data is discarded with a WARNING.
  final List<Uint8List> _rxBuffer = [];
  int _rxBufferBytes = 0;
  static const int _maxRxBufferBytes = 1 << 20; // 1 MiB

  /// Bytes received from the peripheral (broadcast). The first listener
  /// enables notifications on [notifyCharacteristic]; they then stay enabled
  /// until [close] releases them.
  ///
  /// Bytes that arrive while NO listener is attached (between a cancel and a
  /// re-listen — e.g. swapping UI screens) are buffered — bounded at 1 MiB —
  /// and replayed in order to the next listener, so nothing is silently lost
  /// (mirroring the rfcomm `BluetoothConnection.input` contract).
  Stream<Uint8List> get input {
    final existing = _inputCtrl;
    if (existing != null) return existing.stream;
    late StreamController<Uint8List> ctrl;
    ctrl = StreamController<Uint8List>.broadcast(
      onListen: () {
        _drainRxBuffer(ctrl);
        if (_inputSub != null) return;
        // Guard the subscribe call: a synchronous throw here (deterministic on
        // Windows, whose subscribe throws BleUnsupportedException) would
        // otherwise be routed by the controller to Zone.handleUncaughtError —
        // an unhandled error that kills a CLI app — instead of the listener.
        try {
          _inputSub = _conn
              .subscribe(service, notifyCharacteristic)
              .listen(
                (bytes) {
                  if (ctrl.isClosed) return;
                  if (ctrl.hasListener) {
                    ctrl.add(bytes);
                  } else {
                    // A broadcast stream DROPS events with no listener; buffer
                    // (bounded) and replay on the next listen instead.
                    _bufferRx(bytes);
                  }
                },
                onError: (Object e, StackTrace st) {
                  if (!ctrl.isClosed) ctrl.addError(e, st);
                },
                onDone: () => unawaited(ctrl.close()),
              );
        } catch (e, st) {
          if (!ctrl.isClosed) ctrl.addError(e, st);
        }
      },
    );
    _inputCtrl = ctrl;
    return ctrl.stream;
  }

  void _bufferRx(Uint8List bytes) {
    _rxBuffer.add(bytes);
    _rxBufferBytes += bytes.length;
    while (_rxBufferBytes > _maxRxBufferBytes && _rxBuffer.isNotEmpty) {
      final dropped = _rxBuffer.removeAt(0);
      _rxBufferBytes -= dropped.length;
      logData.warning(
        () =>
            'input buffer overflow: dropped ${dropped.length}B received '
            'while nothing was listening to input',
      );
    }
  }

  void _drainRxBuffer(StreamController<Uint8List> ctrl) {
    if (_rxBuffer.isEmpty || ctrl.isClosed) return;
    logData.fine(
      () => 'replaying ${_rxBufferBytes}B received without an input listener',
    );
    for (final chunk in _rxBuffer) {
      ctrl.add(chunk);
    }
    _rxBuffer.clear();
    _rxBufferBytes = 0;
  }

  /// Updates [chunkSize] from the connection's usable ATT MTU (header is 3
  /// bytes) and returns that MTU. Most platforms negotiate the MTU automatically
  /// and ignore the requested [mtu]; only Android honours an explicit request,
  /// and Windows is fixed at the ATT default (so chunkSize stays 20 there).
  Future<int> negotiateMtu([int mtu = 247]) async {
    final negotiated = await _conn.requestMtu(mtu);
    // Always (re)set chunkSize so a later small MTU can't leave a stale large
    // value that would overflow the real ATT payload.
    chunkSize = negotiated > 23 ? negotiated - 3 : 20;
    return negotiated;
  }

  /// Sends [data], chunked to [chunkSize], awaiting the OS accepting each chunk.
  /// Serialised after any earlier [add]/[write]. Throws if the serial is closed.
  Future<void> write(Uint8List data) {
    // Return an errored future (not a synchronous throw) so [add] stays
    // fire-and-forget even on a closed serial; `await write(...)` still throws.
    if (_closed) {
      return Future<void>.error(const BleGattException('serial is closed'));
    }
    if (data.isEmpty) return Future<void>.value();
    final result = _chain.then((_) => _writeChunked(data));
    // Keep the ordering chain alive past a failed write (caller still sees the
    // real error via `result`).
    _chain = result.catchError((_) {});
    return result;
  }

  /// Queues [data] for transmission and returns immediately (never blocks). A
  /// failed send is logged rather than thrown; use [write] to observe errors.
  void add(Uint8List data) {
    unawaited(
      write(data).catchError(
        (Object e) => logData.warning(() => 'serial write failed: $e'),
      ),
    );
  }

  /// Completes when all previously [add]ed/[write]n bytes have been sent.
  Future<void> flush() => _chain;

  Future<void> _writeChunked(Uint8List data) async {
    for (var off = 0; off < data.length; off += chunkSize) {
      final end = (off + chunkSize < data.length)
          ? off + chunkSize
          : data.length;
      await _conn.write(
        service,
        writeCharacteristic,
        Uint8List.sublistView(data, off, end),
        withoutResponse: writeWithoutResponse,
      );
    }
  }

  /// Stops accepting writes, releases the notify subscription (disabling
  /// notifications on [notifyCharacteristic]) and closes [input]. The
  /// underlying connection is otherwise unaffected — close it via
  /// [BleConnection.close].
  Future<void> close() async {
    _closed = true;
    final sub = _inputSub;
    _inputSub = null;
    await sub?.cancel();
    final ctrl = _inputCtrl;
    if (ctrl != null && !ctrl.isClosed) await ctrl.close();
  }
}
