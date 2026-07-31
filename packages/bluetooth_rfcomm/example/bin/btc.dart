// Pure-Dart CLI for bluetooth_rfcomm — runs with `dart run`, no Flutter.
//
//   dart run :btc list
//   dart run :btc scan [--timeout 8]
//   dart run :btc connect <ADDRESS> [--channel N]
//
// `connect` opens an RFCOMM serial link, prints everything received, and sends
// anything you type (line by line) to the device.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

void _usage() {
  stdout.writeln('''
bluetooth_rfcomm CLI

Usage:
  btc doctor                        Load the native backend & print state
  btc list [--scan N]               List paired + scanned devices
  btc scan [--timeout 8]            Discover nearby devices
  btc connect <ADDR> [--channel N]  Open an RFCOMM serial link
''');
}
