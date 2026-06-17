import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_le/bluetooth_le.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bluetooth_le example',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
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
  final _ble = BleCentral.instance;
  final _results = <BleScanResult>[];
  StreamSubscription<BleScanResult>? _scanSub;
  BleConnection? _conn;
  BleSerial? _serial;
  StreamSubscription<Uint8List>? _rx;
  final _log = StringBuffer();
  final _input = TextEditingController();
  bool _scanning = false;

  Future<void> _toggleScan() async {
    if (_scanning) {
      await _scanSub?.cancel();
      setState(() => _scanning = false);
      return;
    }
    setState(() {
      _scanning = true;
      _results.clear();
    });
    final seen = <DeviceId>{};
    _scanSub = _ble.startScan().listen(
      (r) {
        if (seen.add(r.device.id) && mounted) {
          setState(() => _results.add(r));
        }
      },
      onError: (Object e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$e')));
          setState(() => _scanning = false);
        }
      },
    );
  }

  Future<void> _connect(BleDevice device) async {
    await _scanSub?.cancel();
    setState(() => _scanning = false);
    try {
      final conn = await _ble.connect(
        device,
        timeout: const Duration(seconds: 15),
      );
      await conn.discoverServices();
      final serial = conn.asSerial();
      if (!mounted) {
        await conn.close();
        return;
      }
      _rx = serial.input.listen((bytes) {
        if (mounted) {
          setState(() => _log.write(utf8.decode(bytes, allowMalformed: true)));
        }
      });
      setState(() {
        _conn = conn;
        _serial = serial;
      });
    } on BleException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _disconnect() async {
    await _rx?.cancel();
    await _serial?.close();
    await _conn?.close();
    if (!mounted) return;
    setState(() {
      _conn = null;
      _serial = null;
    });
  }

  void _send(String text) {
    _serial?.add(Uint8List.fromList(utf8.encode('$text\r\n')));
  }

  @override
  void dispose() {
    _rx?.cancel();
    _scanSub?.cancel();
    _conn?.close();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluetooth LE'),
        actions: [
          IconButton(
            onPressed: _toggleScan,
            icon: Icon(_scanning ? Icons.stop : Icons.search),
          ),
        ],
      ),
      body: _conn != null ? _terminal() : _deviceList(),
    );
  }

  Widget _deviceList() => ListView(
    children: [
      for (final r in _results)
        ListTile(
          leading: const Icon(Icons.bluetooth),
          title: Text(r.device.name ?? '(unknown)'),
          subtitle: Text('${r.device.id}'),
          trailing: r.rssi != null ? Text('${r.rssi} dBm') : null,
          onTap: () => _connect(r.device),
        ),
    ],
  );

  Widget _terminal() {
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              child: Text(
                _log.toString(),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  decoration: const InputDecoration(hintText: 'send...'),
                  onSubmitted: (String t) {
                    _send(t);
                    _input.clear();
                  },
                ),
              ),
              IconButton(
                onPressed: _disconnect,
                icon: const Icon(Icons.link_off),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
