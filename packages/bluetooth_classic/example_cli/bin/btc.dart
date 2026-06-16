// Pure-Dart CLI for bluetooth_classic — runs with `dart run`, no Flutter.
//
//   dart run bluetooth_classic_cli_example list
//   dart run bluetooth_classic_cli_example scan [--timeout 8]
//   dart run bluetooth_classic_cli_example connect <ADDRESS> [--channel N]
//
// `connect` opens an RFCOMM serial link, prints everything received, and sends
// anything you type (line by line) to the device.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:bluetooth_classic/bluetooth_classic.dart';

Future<void> main(List<String> argv) async {
  final bt = BluetoothClassic.instance;

  if (argv.isEmpty) {
    _usage();
    exitCode = 64;
    return;
  }

  try {
    if (!await bt.isSupported()) {
      stderr.writeln('Bluetooth Classic is not supported on this host.');
      exitCode = 1;
      return;
    }
    final state = await bt.adapterStateNow();
    if (!state.isOn) {
      stderr.writeln('Adapter is ${state.name}. Turn Bluetooth on and retry.');
      exitCode = 1;
      return;
    }

    switch (argv.first) {
      case 'list':
        await _list(bt);
      case 'scan':
        await _scan(bt, argv.skip(1).toList());
      case 'connect':
        await _connect(bt, argv.skip(1).toList());
      default:
        _usage();
        exitCode = 64;
    }
  } on BluetoothException catch (e) {
    stderr.writeln('Bluetooth error: $e');
    exitCode = 1;
  }
}

Future<void> _list(BluetoothClassic bt) async {
  final devices = await bt.bondedDevices();
  if (devices.isEmpty) {
    stdout.writeln('No paired devices.');
    return;
  }
  stdout.writeln('Paired devices:');
  for (final d in devices) {
    stdout.writeln('  ${d.id}  ${d.name ?? '(unknown)'}');
  }
}

Future<void> _scan(BluetoothClassic bt, List<String> args) async {
  final parser = ArgParser()..addOption('timeout', abbr: 't', defaultsTo: '8');
  final opts = parser.parse(args);
  final timeout = Duration(seconds: int.parse(opts['timeout'] as String));

  stdout.writeln('Scanning for ${timeout.inSeconds}s...');
  final seen = <DeviceId>{};
  final sub = bt.startDiscovery().listen((r) {
    if (seen.add(r.device.id)) {
      final rssi = r.rssi != null ? ' (${r.rssi} dBm)' : '';
      stdout.writeln('  ${r.device.id}  ${r.device.name ?? '(unknown)'}$rssi');
    }
  });
  await Future<void>.delayed(timeout);
  await sub.cancel();
  await bt.stopDiscovery();
  stdout.writeln('Done. ${seen.length} device(s).');
}

Future<void> _connect(BluetoothClassic bt, List<String> args) async {
  final parser = ArgParser()..addOption('channel', abbr: 'c');
  final opts = parser.parse(args);
  if (opts.rest.isEmpty) {
    stderr.writeln('Usage: connect <ADDRESS> [--channel N]');
    exitCode = 64;
    return;
  }
  final address = opts.rest.first;
  final channel =
      opts['channel'] != null ? int.parse(opts['channel'] as String) : null;

  final device = BluetoothDevice(id: DeviceId.address(address));
  stdout.writeln('Connecting to $address'
      '${channel != null ? ' (channel $channel)' : ' (SDP-resolved channel)'}...');

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

  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    conn.add(Uint8List.fromList(utf8.encode('$line\r\n')));
  }
  await rx.cancel();
  await conn.finish();
}

void _usage() {
  stdout.writeln('''
bluetooth_classic CLI

Usage:
  btc list                          List paired devices
  btc scan [--timeout 8]            Discover nearby devices
  btc connect <ADDR> [--channel N]  Open an RFCOMM serial link
''');
}
