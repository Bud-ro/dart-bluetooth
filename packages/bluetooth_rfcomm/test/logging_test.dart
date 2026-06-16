import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
import 'package:bluetooth_rfcomm/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late FakeBluetoothRfcommPlatform fake;
  late BluetoothRfcomm bt;
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> sub;
  late Level previousLevel;

  setUp(() {
    previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    records = [];
    sub = Logger.root.onRecord.listen(records.add);
    fake = FakeBluetoothRfcommPlatform();
    bt = BluetoothRfcomm(platform: fake);
  });

  tearDown(() async {
    await sub.cancel();
    Logger.root.level = previousLevel;
    hierarchicalLoggingEnabled = false;
    await fake.dispose();
  });

  test(
    'connection + data events log under the documented loggers/levels',
    () async {
      final conn = await bt.connect(FakeBluetoothRfcommPlatform.sampleDevice());
      final transport = fake.transports.single;
      conn.input.listen((_) {});
      conn.add(Uint8List.fromList([1, 2, 3])); // tx -> data FINEST
      transport.deliver([9, 9]); // rx -> data FINEST
      await Future<void>.delayed(Duration.zero);
      await conn.close();
      await Future<void>.delayed(Duration.zero);

      final names = records.map((r) => r.loggerName).toSet();
      expect(names, contains(BluetoothRfcommLoggers.connection));
      expect(names, contains(BluetoothRfcommLoggers.data));

      final dataRecords = records.where(
        (r) => r.loggerName == BluetoothRfcommLoggers.data,
      );
      expect(dataRecords, isNotEmpty);
      expect(dataRecords.every((r) => r.level == Level.FINEST), isTrue);

      final connRecords = records.where(
        (r) => r.loggerName == BluetoothRfcommLoggers.connection,
      );
      expect(connRecords.any((r) => r.message.contains('connecting')), isTrue);
      expect(
        connRecords.any((r) => r.message.contains('disconnected')),
        isTrue,
      );
    },
  );

  test('per-namespace level silences data while keeping connection', () async {
    hierarchicalLoggingEnabled = true;
    Logger(BluetoothRfcommLoggers.data).level = Level.OFF;

    final conn = await bt.connect(FakeBluetoothRfcommPlatform.sampleDevice());
    conn.add(Uint8List.fromList([1]));
    await conn.close();
    await Future<void>.delayed(Duration.zero);

    final names = records.map((r) => r.loggerName).toSet();
    expect(names, contains(BluetoothRfcommLoggers.connection));
    expect(names, isNot(contains(BluetoothRfcommLoggers.data)));
  });

  test(
    'nothing is logged at the default level (INFO) for fine/finest events',
    () async {
      Logger.root.level = Level.INFO;
      final conn = await bt.connect(FakeBluetoothRfcommPlatform.sampleDevice());
      conn.add(Uint8List.fromList([1]));
      await conn.close();
      await Future<void>.delayed(Duration.zero);
      expect(records, isEmpty); // package emits only fine/finest for these
    },
  );
}
