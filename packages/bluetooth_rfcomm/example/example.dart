// Minimal `bluetooth_rfcomm` usage: connect to the first paired device and do a
// round-trip over the RFCOMM serial channel. For a fuller CLI (list / scan /
// connect / doctor), see `bin/btc.dart` and this directory's README.
//
// ignore_for_file: avoid_print
import 'dart:typed_data';

import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';

Future<void> main() async {
  final bt = BluetoothRfcomm.instance;

  if (!await bt.isSupported()) {
    print('Bluetooth Classic is not available on this host.');
    return;
  }

  // Paired devices — instant and radio-silent (no inquiry).
  final paired = await bt.bondedDevices();
  if (paired.isEmpty) {
    print('No paired devices. Pair one in your OS settings first.');
    return;
  }

  final device = paired.first;
  print('Connecting to ${device.name ?? device.id.address}…');

  // Open the RFCOMM channel. The SPP channel is resolved via SDP unless you pass
  // an explicit `channel:`. (macOS requires a real, non-zero channel.)
  final conn = await bt.connect(device);

  conn.input.listen(
    (Uint8List bytes) => print('rx ${bytes.length} bytes'),
    onDone: () => print('disconnected'),
  );

  conn.add(Uint8List.fromList('AT\r\n'.codeUnits)); // non-blocking send
  await conn.finish(); // flush, then close
}
