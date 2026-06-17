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

  Stream<Uint8List>? _input;
  Future<void> _chain = Future<void>.value();
  bool _closed = false;

  /// Bytes received from the peripheral (broadcast). Listening enables
  /// notifications on [notifyCharacteristic]; cancelling all listeners disables
  /// them.
  Stream<Uint8List> get input => _input ??= _conn
      .subscribe(service, notifyCharacteristic)
      .asBroadcastStream();

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

  /// Stops accepting writes. The underlying connection is unaffected — close it
  /// via [BleConnection.close].
  Future<void> close() async {
    _closed = true;
  }
}
