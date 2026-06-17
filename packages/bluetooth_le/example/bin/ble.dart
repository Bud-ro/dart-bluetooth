// Pure-Dart CLI for bluetooth_le — runs with `dart run`, no Flutter.
//
//   dart run :ble doctor
//   dart run :ble scan [--timeout 8] [--service <uuid>]
//   dart run :ble connect <DEVICE-ID> [--service <uuid>] [--write <uuid>] [--notify <uuid>]
//
// `connect` opens the device, discovers services, treats a write+notify
// characteristic pair as a serial channel (Nordic UART by default), prints
// everything received, and sends anything you type (line by line).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:bluetooth_le/bluetooth_le.dart';

Future<void> main(List<String> argv) async {
  final ble = BleCentral.instance;

  if (argv.isEmpty) {
    _usage();
    exit(64);
  }

  // We call exit() explicitly: some backends (e.g. Linux's DBusClient) hold an
  // open socket that would otherwise keep the VM alive after the command ends.

  // `doctor` is a no-hardware smoke check: it loads the native backend and
  // reports state, exiting 0 even with no adapter. A failure to LOAD the native
  // library (missing dylib/DLL, unresolved symbol, code-signing) is not a
  // BleException, so it escapes and fails — exactly what CI wants to catch.
  if (argv.first == 'doctor') {
    final supported = await ble.isSupported();
    final state = await ble.adapterState();
    stdout.writeln('supported : $supported');
    stdout.writeln('adapter   : ${state.name}');
    stdout.writeln('OK: native backend loaded.');
    exit(0);
  }

  try {
    if (!await ble.isSupported()) {
      stderr.writeln('Bluetooth LE is not supported on this host.');
      exit(1);
    }

    switch (argv.first) {
      case 'scan':
        await _scan(ble, argv.skip(1).toList());
      case 'connect':
        await _connect(ble, argv.skip(1).toList());
      default:
        _usage();
        exit(64);
    }
  } on BleException catch (e) {
    stderr.writeln('BLE error: $e');
    exit(1);
  }
  exit(0);
}

Future<void> _scan(BleCentral ble, List<String> args) async {
  final parser = ArgParser()
    ..addOption('timeout', abbr: 't', defaultsTo: '8')
    ..addOption('service', abbr: 's');
  final opts = parser.parse(args);
  final timeout = Duration(seconds: int.parse(opts['timeout'] as String));
  final filter = opts['service'] != null
      ? [Uuid(opts['service'] as String)]
      : null;

  stdout.writeln('Scanning for ${timeout.inSeconds}s...');
  final seen = <DeviceId>{};
  final sub = ble.startScan(withServices: filter).listen((r) {
    if (seen.add(r.device.id)) {
      final rssi = r.rssi != null ? ' (${r.rssi} dBm)' : '';
      stdout.writeln('  ${r.device.id}  ${r.device.name ?? '(unknown)'}$rssi');
    }
  });
  await Future<void>.delayed(timeout);
  await sub.cancel();
  await ble.stopScan();
  stdout.writeln('Done. ${seen.length} device(s).');
}

Future<void> _connect(BleCentral ble, List<String> args) async {
  final parser = ArgParser()
    ..addOption('service', abbr: 's')
    ..addOption('write', abbr: 'w')
    ..addOption('notify', abbr: 'n');
  final opts = parser.parse(args);
  if (opts.rest.isEmpty) {
    stderr.writeln(
      'Usage: connect <DEVICE-ID> [--service <uuid>] '
      '[--write <uuid>] [--notify <uuid>]',
    );
    exitCode = 64;
    return;
  }

  // Scan output gives a MAC on Linux/Windows/Android and an opaque id on
  // macOS/iOS; accept either.
  final raw = opts.rest.first;
  final device = BleDevice(id: _parseId(raw));

  stdout.writeln('Connecting to $raw...');
  final conn = await ble.connect(device, timeout: const Duration(seconds: 15));
  await conn.discoverServices();

  final serial = conn.asSerial(
    service: opts['service'] != null ? Uuid(opts['service'] as String) : null,
    writeCharacteristic: opts['write'] != null
        ? Uuid(opts['write'] as String)
        : null,
    notifyCharacteristic: opts['notify'] != null
        ? Uuid(opts['notify'] as String)
        : null,
  );
  stdout.writeln('Connected. Type lines to send; Ctrl-D to quit.\n');

  final rx = serial.input.listen(
    (bytes) => stdout.write(utf8.decode(bytes, allowMalformed: true)),
  );
  conn.stateChanges.listen((s) {
    if (!s.isConnected) stdout.writeln('\n[peer disconnected]');
  });

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    serial.add(Uint8List.fromList(utf8.encode('$line\r\n')));
  }
  await rx.cancel();
  await serial.close();
  await conn.close();
}

DeviceId _parseId(String raw) {
  try {
    return DeviceId.address(raw);
  } on FormatException {
    return DeviceId.opaque(raw);
  }
}

void _usage() {
  stdout.writeln('''
bluetooth_le CLI

Usage:
  ble doctor                          Load the native backend & print state
  ble scan [--timeout 8] [--service <uuid>]
                                      Scan for advertising devices
  ble connect <DEVICE-ID> [--service <uuid>] [--write <uuid>] [--notify <uuid>]
                                      Open a device and use it as a serial link
                                      (Nordic UART by default)
''');
}
