import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bluetooth_classic example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _bt = BluetoothClassic.instance;
  final _devices = <BluetoothDevice>[];
  BluetoothConnection? _conn;
  StreamSubscription<Uint8List>? _rx;
  final _log = StringBuffer();
  bool _scanning = false;

  Future<void> _refresh() async {
    final bonded = await _bt.bondedDevices();
    setState(() => _devices
      ..clear()
      ..addAll(bonded));
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final seen = {for (final d in _devices) d.id};
    final sub = _bt.startDiscovery().listen((r) {
      if (seen.add(r.device.id)) setState(() => _devices.add(r.device));
    });
    await Future<void>.delayed(const Duration(seconds: 8));
    await sub.cancel();
    await _bt.stopDiscovery();
    setState(() => _scanning = false);
  }

  Future<void> _connect(BluetoothDevice device) async {
    try {
      final conn = await _bt.connect(device, timeout: const Duration(seconds: 15));
      _rx = conn.input.listen((bytes) {
        setState(() => _log.write(utf8.decode(bytes, allowMalformed: true)));
      }, onDone: () => setState(() => _log.writeln('\n[disconnected]')));
      setState(() => _conn = conn);
    } on BluetoothException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _disconnect() async {
    await _rx?.cancel();
    await _conn?.finish();
    setState(() => _conn = null);
  }

  void _send(String text) =>
      _conn?.add(Uint8List.fromList(utf8.encode('$text\r\n')));

  @override
  void dispose() {
    _rx?.cancel();
    _conn?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _conn != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluetooth Classic'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
          IconButton(
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
          ),
        ],
      ),
      body: connected ? _terminal() : _deviceList(),
    );
  }

  Widget _deviceList() => ListView(
        children: [
          for (final d in _devices)
            ListTile(
              leading: Icon(d.bondState.isBonded
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth),
              title: Text(d.name ?? '(unknown)'),
              subtitle: Text('${d.id}'),
              trailing: d.rssi != null ? Text('${d.rssi} dBm') : null,
              onTap: () => _connect(d),
            ),
        ],
      );

  Widget _terminal() {
    final controller = TextEditingController();
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              child: Text(_log.toString(),
                  style: const TextStyle(fontFamily: 'monospace')),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: controller,
                decoration: const InputDecoration(hintText: 'send...'),
                onSubmitted: (String t) {
                  _send(t);
                  controller.clear();
                },
              ),
            ),
            IconButton(
                onPressed: _disconnect, icon: const Icon(Icons.link_off)),
          ]),
        ),
      ],
    );
  }
}
