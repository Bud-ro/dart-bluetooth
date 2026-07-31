// Pure-Dart CLI for bluetooth_rfcomm — runs with `dart run`, no Flutter.
//
//   dart run :btc list
//   dart run :btc scan [--timeout 8]
//   dart run :btc connect <ADDRESS> [--channel N]
//   dart run :btc bench <ADDRESS> [--mode echo|txonly] ...
//
// `connect` opens an RFCOMM serial link, prints everything received, and sends
// anything you type (line by line) to the device. `bench` is a known-good
// message-loss measurement harness (see `bench --help` for the frame spec).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';

Future<void> main(List<String> argv) async {
  final bt = BluetoothRfcomm.instance;

  if (argv.isEmpty) {
    _usage();
    exit(64);
  }

  // We call exit() explicitly throughout: some backends (notably Linux's
  // DBusClient) hold an open socket that would otherwise keep the VM alive and
  // hang the process after the command finishes.

  // `doctor` is a no-hardware smoke check: it loads the native backend and
  // reports state, exiting 0 even with no adapter. A failure to load the native
  // library (missing dylib/DLL, unresolved symbol, code-signing) is NOT a
  // BluetoothException, so it escapes and fails — exactly what CI wants to catch.
  if (argv.first == 'doctor') {
    final supported = await bt.isSupported();
    final state = await bt.adapterState();
    stdout.writeln('supported : $supported');
    stdout.writeln('adapter   : ${state.name}');
    stdout.writeln('OK: native backend loaded.');
    exit(0);
  }

  // `bench --help` documents the frame spec / echo assumption; make it
  // readable on any machine, adapter or not.
  if (argv.first == 'bench' &&
      (argv.contains('--help') || argv.contains('-h'))) {
    _benchUsage(_benchParser());
    exit(0);
  }

  try {
    if (!await bt.isSupported()) {
      stderr.writeln('Bluetooth Classic is not supported on this host.');
      exit(1);
    }
    final state = await bt.adapterState();
    if (!state.isOn) {
      stderr.writeln('Adapter is ${state.name}. Turn Bluetooth on and retry.');
      exit(1);
    }

    switch (argv.first) {
      case 'list':
        await _list(bt, argv.skip(1).toList());
      case 'scan':
        await _scan(bt, argv.skip(1).toList());
      case 'connect':
        await _connect(bt, argv.skip(1).toList());
      case 'bench':
        await _bench(bt, argv.skip(1).toList());
      default:
        _usage();
        exit(64);
    }
  } on BluetoothException catch (e) {
    stderr.writeln('Bluetooth error: $e');
    exit(1);
  }
  exit(0);
}

Future<void> _list(BluetoothRfcomm bt, List<String> args) async {
  final parser = ArgParser()
    ..addOption('scan', abbr: 's', help: 'scan this many seconds first');
  final opts = parser.parse(args);
  final scanSecs = opts['scan'] as String?;
  final window = scanSecs != null
      ? Duration(seconds: int.parse(scanSecs))
      : null;
  if (window != null) stdout.writeln('Scanning for ${scanSecs}s...');
  // The three dedicated listings: connectable (paired ∩ scanned) first — the
  // set a picker cares about — then everything scanned, then the paired list.
  final connectable = await bt.listPairedAndScannedDevices(
    scanDuration: window,
  );
  final scanned = await bt.listScannedDevices();
  final paired = await bt.listPairedDevices();

  void section(String title, Iterable<BluetoothDevice> devices) {
    stdout.writeln('$title:');
    if (devices.isEmpty) stdout.writeln('  (none)');
    for (final d in devices) {
      final rssi = d.rssi != null ? '  [${d.rssi} dBm]' : '';
      stdout.writeln('  ${d.id}  ${d.name ?? '(unknown)'}$rssi');
    }
  }

  section('Paired & nearby (connectable)', connectable);
  final connectableIds = {for (final d in connectable) d.id};
  section(
    'Other scanned',
    scanned.where((d) => !connectableIds.contains(d.id)),
  );
  section('Paired (whether nearby or not)', paired);
}

Future<void> _scan(BluetoothRfcomm bt, List<String> args) async {
  final parser = ArgParser()..addOption('timeout', abbr: 't', defaultsTo: '8');
  final opts = parser.parse(args);
  final timeout = Duration(seconds: int.parse(opts['timeout'] as String));

  stdout.writeln('Scanning for ${timeout.inSeconds}s...');
  // The background scan accumulates every sighting (paired or not) into
  // bt.scannedDevices; in an app you'd start it once in main() and read the
  // cache whenever you need to show a picker.
  final seen = <DeviceId>{};
  final sub = bt.scannedDevicesStream.listen((devices) {
    for (final d in devices) {
      if (seen.add(d.id)) {
        final rssi = d.rssi != null ? ' (${d.rssi} dBm)' : '';
        stdout.writeln('  ${d.id}  ${d.name ?? '(unknown)'}$rssi');
      }
    }
  }, onError: (Object e) => stderr.writeln('scan error: $e'));
  await bt.startScan();
  await Future<void>.delayed(timeout);
  await bt.stopScan();
  await sub.cancel();
  stdout.writeln('Done. ${seen.length} device(s).');
}

Future<void> _connect(BluetoothRfcomm bt, List<String> args) async {
  final parser = ArgParser()..addOption('channel', abbr: 'c');
  final opts = parser.parse(args);
  if (opts.rest.isEmpty) {
    stderr.writeln('Usage: connect <ADDRESS> [--channel N]');
    exitCode = 64;
    return;
  }
  final address = opts.rest.first;
  final channel = opts['channel'] != null
      ? int.parse(opts['channel'] as String)
      : null;

  final device = BluetoothDevice(id: DeviceId.address(address));
  stdout.writeln(
    'Connecting to $address'
    '${channel != null ? ' (channel $channel)' : ' (SDP-resolved channel)'}...',
  );

  final conn = await bt.connect(
    device,
    channel: channel,
    timeout: const Duration(seconds: 15),
  );
  stdout.writeln('Connected. Type lines to send; Ctrl-D to quit.\n');

  final rx = conn.input.listen(
    (bytes) => stdout.write(utf8.decode(bytes, allowMalformed: true)),
    onDone: () => stdout.writeln('\n[peer disconnected]'),
  );

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    conn.add(Uint8List.fromList(utf8.encode('$line\r\n')));
  }
  await rx.cancel();
  await conn.disconnect();
}

// ─── bench: known-good message-loss measurement harness ─────────────────────
//
// Frame layout (all integers big-endian). Total frame length = --size,
// minimum 10 bytes:
//
//   offset 0..1   magic 0xC0 0xDE
//   offset 2..5   uint32 sequence number (0-based, increments per message)
//   offset 6..7   uint16 payload length  (= size - 10)
//   offset 8..    payload: byte i = (seq + i) & 0xff
//   last 2 bytes  CRC16-CCITT (poly 0x1021, init 0xFFFF, no reflection, no
//                 final xor) computed over ALL preceding bytes (magic through
//                 payload)
//
// In echo mode the remote device must echo every received byte back verbatim.
// The receiver reassembles frames from the raw byte stream, so it is immune
// to messages bunching into one event or splitting across events.

const int _magic0 = 0xC0;
const int _magic1 = 0xDE;
const int _headerLen = 8; // magic(2) + seq(4) + payloadLen(2)
const int _minFrameLen = _headerLen + 2; // + CRC16

/// CRC16-CCITT (0x1021, init 0xFFFF) over `data[start..end)`.
int _crc16(Uint8List data, int start, int end) {
  var crc = 0xFFFF;
  for (var i = start; i < end; i++) {
    crc ^= data[i] << 8;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

Uint8List _buildFrame(int seq, int frameLen) {
  final payloadLen = frameLen - _minFrameLen;
  final f = Uint8List(frameLen);
  final bd = ByteData.sublistView(f);
  f[0] = _magic0;
  f[1] = _magic1;
  bd.setUint32(2, seq);
  bd.setUint16(6, payloadLen);
  for (var i = 0; i < payloadLen; i++) {
    f[_headerLen + i] = (seq + i) & 0xff;
  }
  bd.setUint16(frameLen - 2, _crc16(f, 0, frameLen - 2));
  return f;
}

/// Incremental frame reassembler. Feed it raw RX chunks exactly as they
/// arrive; it emits complete, CRC-verified frames no matter how the byte
/// stream was sliced into events (bunched after a link stall, split
/// mid-frame, or interleaved with garbage — it resyncs on the magic bytes).
class _Reassembler {
  _Reassembler({
    required this.maxFrameLen,
    required this.onFrame,
    required this.onCrcBad,
  });

  /// Longest legal frame; a magic hit whose length field implies more than
  /// this is treated as corruption (resync) instead of stalling the buffer.
  final int maxFrameLen;
  final void Function(int seq) onFrame;
  final void Function() onCrcBad;

  /// Bytes skipped while hunting for a valid frame (0 on a clean link).
  int resyncedBytes = 0;

  Uint8List _buf = Uint8List(0);

  void add(Uint8List bytes) {
    final joined = Uint8List(_buf.length + bytes.length)
      ..setAll(0, _buf)
      ..setAll(_buf.length, bytes);
    _buf = joined;
    var start = 0;
    while (_buf.length - start >= _minFrameLen) {
      if (_buf[start] != _magic0 || _buf[start + 1] != _magic1) {
        start++;
        resyncedBytes++;
        continue;
      }
      final bd = ByteData.sublistView(_buf, start);
      final total = _minFrameLen + bd.getUint16(6);
      if (total > maxFrameLen) {
        // Magic matched but the length is impossible — corrupt header.
        onCrcBad();
        start += 2;
        resyncedBytes += 2;
        continue;
      }
      if (_buf.length - start < total) break; // partial frame: wait for more
      if (bd.getUint16(total - 2) != _crc16(_buf, start, start + total - 2)) {
        onCrcBad();
        start += 2; // skip past this magic, rescan (frame body untrusted)
        resyncedBytes += 2;
        continue;
      }
      onFrame(bd.getUint32(2));
      start += total;
    }
    _buf = Uint8List.sublistView(_buf, start);
  }
}

/// The `stats` diagnostic map is being added to BluetoothConnection in a
/// parallel change; probe for it dynamically so this CLI works (and analyzes
/// cleanly) with or without it.
Map<String, Object?>? _statsOf(BluetoothConnection conn) {
  try {
    final Object? s = (conn as dynamic).stats as Object?;
    if (s is Map) return {for (final e in s.entries) '${e.key}': e.value};
  } on NoSuchMethodError {
    return null;
  }
  return null;
}

ArgParser _benchParser() => ArgParser()
  ..addOption('channel', abbr: 'c', help: 'RFCOMM channel (default: SDP)')
  ..addOption('count', defaultsTo: '1000', help: 'messages to send')
  ..addOption('interval', defaultsTo: '100', help: 'ms between sends')
  ..addOption('size', defaultsTo: '20', help: 'frame length in bytes (>=10)')
  ..addOption(
    'mode',
    defaultsTo: 'echo',
    allowed: ['echo', 'txonly'],
    help: 'echo: device must echo bytes back; txonly: send-side only',
  )
  ..addOption(
    'timeout',
    defaultsTo: '2000',
    help: 'ms before a response counts as timed out (later arrival = late)',
  )
  ..addFlag('help', abbr: 'h', negatable: false);

Future<void> _bench(BluetoothRfcomm bt, List<String> args) async {
  final parser = _benchParser();
  final ArgResults opts;
  try {
    opts = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _benchUsage(parser);
    exit(64);
  }
  if (opts['help'] as bool) {
    _benchUsage(parser);
    exit(0);
  }
  if (opts.rest.isEmpty) {
    _benchUsage(parser);
    exit(64);
  }

  final address = opts.rest.first;
  final channel = opts['channel'] != null
      ? int.parse(opts['channel'] as String)
      : null;
  final count = int.parse(opts['count'] as String);
  final intervalMs = int.parse(opts['interval'] as String);
  final requestedSize = int.parse(opts['size'] as String);
  final echoMode = opts['mode'] as String == 'echo';
  final timeoutMs = int.parse(opts['timeout'] as String);

  if (requestedSize > _minFrameLen + 0xFFFF) {
    stderr.writeln('--size may not exceed ${_minFrameLen + 0xFFFF}.');
    exit(64);
  }
  final frameLen = math.max(requestedSize, _minFrameLen);
  if (frameLen != requestedSize) {
    stdout.writeln(
      'note: --size raised to $frameLen (frame overhead is $_minFrameLen B).',
    );
  }

  final device = BluetoothDevice(id: DeviceId.address(address));
  stdout.writeln(
    'Connecting to $address'
    '${channel != null ? ' (channel $channel)' : ' (SDP-resolved channel)'}...',
  );
  final conn = await bt.connect(
    device,
    channel: channel,
    timeout: const Duration(seconds: 15),
  );
  stdout.writeln(
    'Connected. mode=${echoMode ? 'echo' : 'txonly'} count=$count '
    'size=$frameLen B interval=$intervalMs ms timeout=$timeoutMs ms\n',
  );

  final sw = Stopwatch()..start();
  final timeoutUs = timeoutMs * 1000;

  // Accounting. Every sent sequence ends up in exactly one bucket:
  // ok (echo within timeout), late (echo after timeout), or missing (no
  // echo ever). crcBad counts corrupted frames seen on the wire (they name
  // no trustworthy sequence, so they don't retire one; the sequence they
  // mangled will surface as missing).
  final pending = <int, int>{}; // seq -> send time (µs), awaiting echo
  final timedOut = <int, int>{}; // expired, but a LATE echo still counts
  final done = <int>{};
  final okRtts = <int>[]; // µs
  final lateRtts = <int>[]; // µs
  var sent = 0;
  var ok = 0;
  var late = 0;
  var crcBad = 0;
  var dup = 0;
  var dropped = false;
  var finishing = false;

  void reportDrop(String cause) {
    if (dropped || finishing) return;
    dropped = true;
    stderr.writeln('''

!! LINK DROPPED MID-BENCH ($cause)
!!   at drop: sent=$sent/$count ok=$ok late=$late crc-bad=$crcBad
!!   pendingWriteBytes=${conn.pendingWriteBytes} (bytes accepted but never
!!   handed to the OS — anything here was lost in the drop)
!!   ${pending.length + timedOut.length} message(s) were still awaiting a
!!   response. If your app layer auto-reconnects, this drop is exactly the
!!   kind of event that silently eats in-flight messages.
''');
  }

  final reasm = _Reassembler(
    maxFrameLen: frameLen,
    onCrcBad: () => crcBad++,
    onFrame: (seq) {
      final sentAt = pending.remove(seq);
      if (sentAt != null) {
        final rtt = sw.elapsedMicroseconds - sentAt;
        if (rtt > timeoutUs) {
          late++;
          lateRtts.add(rtt);
        } else {
          ok++;
          okRtts.add(rtt);
        }
        done.add(seq);
        return;
      }
      final lateAt = timedOut.remove(seq);
      if (lateAt != null) {
        late++;
        lateRtts.add(sw.elapsedMicroseconds - lateAt);
        done.add(seq);
        return;
      }
      dup++; // echoed twice, or a sequence we never sent
    },
  );

  final rxSub = conn.input.listen(
    echoMode ? reasm.add : (_) {},
    onDone: () => reportDrop('input stream closed'),
  );

  // Sweep pending -> timedOut. The reassembler keeps running, so an echo
  // arriving after this sweep is counted as `late`, never lost.
  final sweep = Timer.periodic(const Duration(milliseconds: 50), (_) {
    final now = sw.elapsedMicroseconds;
    pending.removeWhere((seq, at) {
      if (now - at > timeoutUs) {
        timedOut[seq] = at;
        return true;
      }
      return false;
    });
  });

  // Send loop: absolute schedule (send i is due at i*interval) so cadence
  // doesn't drift with per-send overhead.
  for (var seq = 0; seq < count && !dropped; seq++) {
    final wait = seq * intervalMs - sw.elapsedMilliseconds;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
    if (dropped) break;
    try {
      conn.add(_buildFrame(seq, frameLen));
    } on BluetoothWriteException catch (e) {
      reportDrop('write failed: ${e.message}');
      break;
    }
    pending[seq] = sw.elapsedMicroseconds;
    sent++;
    if (sent % 100 == 0) {
      stdout.writeln(
        '  sent $sent/$count  ok=$ok late=$late crc-bad=$crcBad '
        'in-flight=${pending.length + timedOut.length}',
      );
    }
  }

  // Hand the outbound queue to the OS (drain throws if the link died with
  // bytes still queued — that IS send-side loss, so report it).
  var drainError = '';
  try {
    await conn.drain();
  } on BluetoothWriteException catch (e) {
    drainError = e.message;
    reportDrop('drain failed: ${e.message}');
  }

  if (echoMode) {
    // Wait out the responses: pending empties within --timeout of the last
    // send (via the sweep), then allow one grace window for late stragglers.
    while (!dropped && pending.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!dropped && timedOut.isNotEmpty) {
      final graceEndMs = sw.elapsedMilliseconds + math.min(timeoutMs, 1000);
      while (!dropped &&
          timedOut.isNotEmpty &&
          sw.elapsedMilliseconds < graceEndMs) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }
  sweep.cancel();

  final pendingWrite = conn.pendingWriteBytes;
  final deliveredBytes = conn.txBytes - pendingWrite;
  final missing = pending.length + timedOut.length;
  final stats = _statsOf(conn);

  String rttLine(List<int> us) {
    if (us.isEmpty) return '(none)';
    final s = [...us]..sort();
    String at(double p) =>
        (s[((s.length - 1) * p).round()] / 1000.0).toStringAsFixed(1);
    return '${at(0)} / ${at(0.5)} / ${at(0.95)} / ${at(1)} ms';
  }

  stdout.writeln(
    '''

── bench report ────────────────────────────────────────────────
 mode                 ${echoMode ? 'echo' : 'txonly'}${dropped ? '   (LINK DROPPED MID-BENCH)' : ''}
 sent                 $sent frame(s), ${conn.txBytes} B
 delivered-to-OS      $deliveredBytes B  (pendingWriteBytes=$pendingWrite${drainError.isEmpty ? '' : ', drain error: $drainError'})''',
  );
  if (echoMode) {
    stdout.writeln('''
 responses ok         $ok
 ${'late (>${timeoutMs}ms)'.padRight(20)} $late
 crc-bad              $crcBad
 dup/unexpected       $dup
 missing              $missing
 resynced bytes       ${reasm.resyncedBytes}
 RTT ok   min/med/p95/max  ${rttLine(okRtts)}
 RTT late min/med/p95/max  ${rttLine(lateRtts)}''');
  }
  stdout.writeln('''
 rxBytes / txBytes    ${conn.rxBytes} / ${conn.txBytes}
 stats                ${stats ?? '(stats not available in this build)'}
────────────────────────────────────────────────────────────────''');

  // Verdict: attribute the loss to a side.
  final txEnqueued = stats?['txEnqueuedBytes'] ?? stats?['txEnqueued'];
  final txCompleted = stats?['txCompletedBytes'] ?? stats?['txCompleted'];
  final sendSideClean = txEnqueued != null && txCompleted != null
      ? txEnqueued == txCompleted
      : pendingWrite == 0 && drainError.isEmpty;
  if (dropped) {
    stdout.writeln(
      'verdict: link dropped mid-bench — counts above are at-drop values; '
      'in-flight messages died with the link, not in a queue.',
    );
  } else if (!echoMode) {
    stdout.writeln(
      sendSideClean
          ? 'verdict: send side is clean — every accepted byte reached the '
                'OS. If the device still misses data, it was lost past this '
                'machine (or in the device RX path).'
          : 'verdict: send side did NOT fully drain — see '
                'pendingWriteBytes/stats above.',
    );
  } else if (missing == 0 && crcBad == 0) {
    stdout.writeln(
      'verdict: no loss at this layer — every frame came back intact'
      '${late > 0 ? ' ($late late: link stalls, not loss)' : ''}.',
    );
  } else if (crcBad > 0 || reasm.resyncedBytes > 0) {
    stdout.writeln(
      'verdict: corrupted/garbage bytes on the RX path — the device is not '
      'echoing verbatim, or something is mangling the stream. Fix that '
      'before trusting any loss number.',
    );
  } else if (sendSideClean) {
    stdout.writeln(
      'verdict: missing>0 with txCompleted==txEnqueued ⇒ loss is beyond '
      'the Mac: device RX overrun or response never sent — capture an HCI '
      'trace via Apple PacketLogger to confirm.',
    );
  } else {
    stdout.writeln(
      'verdict: missing>0 AND the send side did not fully drain — loss may '
      'be on this machine; see pendingWriteBytes/stats above.',
    );
  }

  finishing = true;
  await rxSub.cancel();
  await conn.disconnect();
  if (dropped) exit(1);
}

void _benchUsage(ArgParser parser) {
  stdout.writeln('''
Usage: btc bench <ADDR> [options]

Message-loss bench with fully self-framed messages, so loss measurement does
not depend on the app's own (possibly buggy) framing.

ECHO MODE ASSUMPTION: with --mode echo (the default) the remote device MUST
echo every received byte back verbatim — unmodified, in order, byte-for-byte
(a serial mirror / loopback). Each returned frame is CRC-checked and matched
to its sequence number; responses arriving after --timeout are counted as
`late`, never as lost. --mode txonly expects no response at all and verifies
only that every byte was handed to the OS.

Frame layout (integers big-endian), total length = --size (min 10 bytes):
  [0..1]   magic 0xC0 0xDE
  [2..5]   uint32 sequence number (0-based)
  [6..7]   uint16 payload length (= size - 10)
  [8..]    payload: byte i = (seq + i) & 0xff
  [last 2] CRC16-CCITT (poly 0x1021, init 0xFFFF, no reflection, no final
           xor) over all preceding bytes

The receiver reassembles frames from the raw byte stream, so frames that
bunch into one event or split across events are handled correctly.

${parser.usage}

Example:
  btc bench 00:11:22:33:44:55 --count 1000 --interval 100 --size 20
  btc bench 00:11:22:33:44:55 --mode txonly --count 5000 --interval 10
''');
}

void _usage() {
  stdout.writeln('''
bluetooth_rfcomm CLI

Usage:
  btc doctor                        Load the native backend & print state
  btc list [--scan N]               List paired + scanned devices
  btc scan [--timeout 8]            Discover nearby devices
  btc connect <ADDR> [--channel N]  Open an RFCOMM serial link
  btc bench <ADDR> [--mode echo|txonly] [--count N] [--interval MS]
            [--size B] [--timeout MS] [--channel N]
                                    Measure message loss (see `bench --help`;
                                    echo mode needs the device to echo bytes
                                    back verbatim)
''');
}
