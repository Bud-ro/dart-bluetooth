import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
import 'package:bluetooth_rfcomm/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeBluetoothRfcommPlatform fake;
  late BluetoothRfcomm bt;

  setUp(() {
    fake = FakeBluetoothRfcommPlatform();
    bt = BluetoothRfcomm(platform: fake);
  });

  tearDown(() => fake.dispose());

  test('isSupported / adapter state pass through', () async {
    expect(await bt.isSupported(), isTrue);
    expect(await bt.adapterState(), BluetoothAdapterState.on);
  });

  test('adapterState stream emits current then changes', () async {
    final events = <BluetoothAdapterState>[];
    final sub = bt.adapterStateChanges.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    fake.emitAdapterState(BluetoothAdapterState.turningOff);
    fake.emitAdapterState(BluetoothAdapterState.off);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(events, [
      BluetoothAdapterState.on,
      BluetoothAdapterState.turningOff,
      BluetoothAdapterState.off,
    ]);
  });

  test('bondedDevices', () async {
    fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
    final list = await bt.bondedDevices();
    expect(list, hasLength(1));
    expect(list.first.name, 'Test Device');
  });

  test('bondedAndDiscovered returns intersection with latest rssi', () async {
    final inRange = FakeBluetoothRfcommPlatform.sampleDevice(
      address: 'AA:AA:AA:AA:AA:AA',
      name: 'InRange',
    );
    final outOfRange = FakeBluetoothRfcommPlatform.sampleDevice(
      address: 'BB:BB:BB:BB:BB:BB',
      name: 'OutOfRange',
    );
    fake.bonded.addAll([inRange, outOfRange]);
    fake.discoveryResults.add(
      BluetoothDiscoveryResult(
        device: inRange.copyWith(rssi: -42),
        rssi: -42,
        timestamp: DateTime(2026),
      ),
    );

    final result = await bt.bondedAndDiscovered(
      timeout: const Duration(milliseconds: 20),
    );
    expect(result, hasLength(1));
    expect(result.first.id, inRange.id);
    expect(result.first.rssi, -42);
    expect(fake.discoveryStopped, isTrue);
  });

  test('bondedAndDiscovered short-circuits when nothing is bonded', () async {
    final result = await bt.bondedAndDiscovered(
      timeout: const Duration(milliseconds: 20),
    );
    expect(result, isEmpty);
    // No bonded devices => discovery should never start.
    expect(fake.discoveryStarted, isFalse);
    expect(fake.discoveryStopped, isFalse);
  });

  test(
    'bondedAndDiscovered rethrows discovery error when nothing seen',
    () async {
      fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
      fake.discoveryError = const BluetoothDiscoveryException('inquiry failed');
      expect(
        () => bt.bondedAndDiscovered(timeout: const Duration(milliseconds: 20)),
        throwsA(isA<BluetoothDiscoveryException>()),
      );
    },
  );

  test('bondedAndDiscovered wraps a non-Bluetooth discovery error', () async {
    fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
    fake.discoveryError = StateError('boom');
    await expectLater(
      () => bt.bondedAndDiscovered(timeout: const Duration(milliseconds: 20)),
      throwsA(
        isA<BluetoothDiscoveryException>().having(
          (e) => e.cause,
          'cause',
          isA<StateError>(),
        ),
      ),
    );
  });

  test(
    'bondedAndDiscoveredStream emits ONLY paired∩scanned, with scan RSSI',
    () async {
      final inRange = FakeBluetoothRfcommPlatform.sampleDevice(
        address: 'AA:AA:AA:AA:AA:AA',
        name: 'InRange',
      );
      final pairedOutOfRange = FakeBluetoothRfcommPlatform.sampleDevice(
        address: 'BB:BB:BB:BB:BB:BB',
        name: 'OutOfRange',
      );
      final notBonded = FakeBluetoothRfcommPlatform.sampleDevice(
        address: 'CC:CC:CC:CC:CC:CC',
        name: 'Stranger',
      );
      fake.bonded.addAll([inRange, pairedOutOfRange]);
      fake.discoveryResults.addAll([
        BluetoothDiscoveryResult(
          device: notBonded, // not paired -> excluded
          timestamp: DateTime(2026),
        ),
        BluetoothDiscoveryResult(
          device: BluetoothDevice(id: inRange.id),
          rssi: -42,
          timestamp: DateTime(2026),
        ),
      ]);

      final emissions = <List<BluetoothDevice>>[];
      final sub = bt.bondedAndDiscoveredStream().listen(emissions.add);
      await pumpEventQueue();
      await sub.cancel();

      expect(emissions, isNotEmpty);
      final last = emissions.last;
      // Exactly the intersection: never the paired-but-unseen device, never
      // the unpaired stranger — on every platform.
      expect(last, hasLength(1));
      expect(last.first.id, inRange.id);
      expect(last.first.name, 'InRange'); // bonded metadata retained
      expect(last.first.rssi, -42); // radio knowledge merged in
    },
  );

  test('bondedAndDiscoveredStream drives the shared scan engine', () async {
    fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
    // "Discovered" requires a radio: listening must start the scan engine...
    final sub = bt.bondedAndDiscoveredStream().listen((_) {});
    await pumpEventQueue();
    expect(fake.discoveryStarted, isTrue);
    expect(bt.isScanning, isTrue);
    // ...and the last listener going away releases it (no user startScan).
    await sub.cancel();
    await pumpEventQueue();
    expect(bt.isScanning, isFalse);
  });

  test(
    'bondedAndDiscoveredStream sees sightings cached before it was listened',
    () async {
      final paired = FakeBluetoothRfcommPlatform.sampleDevice();
      fake.bonded.add(paired);
      fake.discoveryResults.add(
        BluetoothDiscoveryResult(
          device: BluetoothDevice(id: paired.id),
          rssi: -50,
          timestamp: DateTime(2026),
        ),
      );
      // Sight it via the background scan first (the startScan-in-main story).
      await bt.startScan();
      await pumpEventQueue();
      await bt.stopScan();
      final first = await bt.bondedAndDiscoveredStream().first;
      expect(first.single.id, paired.id);
      expect(first.single.rssi, -50);
    },
  );

  test('connect with explicit channel', () async {
    final device = FakeBluetoothRfcommPlatform.sampleDevice();
    final conn = await bt.connect(device, channel: 3);
    expect(conn.isConnected, isTrue);
    expect(fake.transports.single.channel, 3);
    expect(fake.transports.single.serviceUuid, Uuid.spp);
  });

  test('connect surfaces backend errors', () async {
    fake.connectError = const BluetoothConnectionException('refused');
    final device = FakeBluetoothRfcommPlatform.sampleDevice();
    expect(
      () => bt.connect(device),
      throwsA(isA<BluetoothConnectionException>()),
    );
  });

  test('pair / unpair pass through', () async {
    final device = FakeBluetoothRfcommPlatform.sampleDevice();
    await bt.pair(device);
    await bt.unpair(device);
    expect(fake.paired.single, device.id);
    expect(fake.unpaired.single, device.id);
  });

  group('background scan', () {
    final nearbyUnpaired = BluetoothDevice(
      id: DeviceId.address('11:22:33:44:55:66'),
      name: 'Nearby Unpaired',
      type: BluetoothDeviceType.classic,
      bondState: BluetoothBondState.none,
    );

    tearDown(() => bt.stopScan());

    test(
      'startScan accumulates sightings, including unpaired devices',
      () async {
        fake.discoveryResults.add(
          BluetoothDiscoveryResult(
            device: nearbyUnpaired,
            rssi: -42,
            timestamp: DateTime(2026),
          ),
        );
        expect(bt.isScanning, isFalse);
        await bt.startScan();
        expect(bt.isScanning, isTrue);
        await pumpEventQueue();
        expect(bt.scannedDevices, hasLength(1));
        final seen = bt.scannedDevices.single;
        expect(seen.id, nearbyUnpaired.id);
        expect(seen.bondState, BluetoothBondState.none);
        expect(seen.rssi, -42);
        await bt.stopScan();
        expect(bt.isScanning, isFalse);
        // The cache survives stopping the scan.
        expect(bt.scannedDevices, hasLength(1));
      },
    );

    test('startScan is idempotent', () async {
      await bt.startScan();
      await bt.startScan();
      await pumpEventQueue();
      await bt.stopScan();
      await bt.stopScan();
      expect(bt.isScanning, isFalse);
    });

    test('immediate stopScan/startScan restart still scans', () async {
      // Regression: a startScan() racing the previous loop's wind-down must
      // chain a fresh loop, not be swallowed by a stale running flag.
      await bt.startScan();
      await pumpEventQueue();
      await bt.stopScan();
      fake.discoveryResults.add(
        BluetoothDiscoveryResult(
          device: nearbyUnpaired,
          rssi: null,
          timestamp: DateTime(2026),
        ),
      );
      await bt.startScan(); // no pump between stop and start — the race window
      expect(bt.isScanning, isTrue);
      await pumpEventQueue();
      expect(bt.scannedDevices.map((d) => d.id), contains(nearbyUnpaired.id));
    });

    test('listPairedDevices returns the paired list, radio-silent', () async {
      final pairedOnly = FakeBluetoothRfcommPlatform.sampleDevice();
      fake.bonded.add(pairedOnly);
      final list = await bt.listPairedDevices();
      expect(list.map((d) => d.id), [pairedOnly.id]);
      expect(fake.discoveryStarted, isFalse);
    });

    test('listScannedDevices(scanDuration:) scans, lists the cache, and '
        'stops the scan it started', () async {
      fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
      fake.discoveryResults.add(
        BluetoothDiscoveryResult(
          device: nearbyUnpaired,
          rssi: -60,
          timestamp: DateTime(2026),
        ),
      );
      final list = await bt.listScannedDevices(
        scanDuration: const Duration(milliseconds: 50),
      );
      expect(bt.isScanning, isFalse); // this call started it, so it stopped it
      expect(fake.discoveryStarted, isTrue);
      // Scanned only: the paired-but-unseen device must NOT appear.
      expect(list.map((d) => d.id), [nearbyUnpaired.id]);
      expect(list.single.rssi, -60);
    });

    test('listPairedAndScannedDevices returns only the intersection, with '
        'bonded metadata plus scan RSSI', () async {
      final paired = FakeBluetoothRfcommPlatform.sampleDevice();
      final pairedUnseen = FakeBluetoothRfcommPlatform.sampleDevice(
        address: 'DD:DD:DD:DD:DD:DD',
        name: 'Out Of Range',
      );
      fake.bonded.addAll([paired, pairedUnseen]);
      fake.discoveryResults.addAll([
        BluetoothDiscoveryResult(
          device: nearbyUnpaired, // scanned but not paired -> excluded
          rssi: -60,
          timestamp: DateTime(2026),
        ),
        BluetoothDiscoveryResult(
          device: BluetoothDevice(id: paired.id),
          rssi: -33,
          timestamp: DateTime(2026),
        ),
      ]);
      final list = await bt.listPairedAndScannedDevices(
        scanDuration: const Duration(milliseconds: 50),
      );
      expect(bt.isScanning, isFalse);
      // Exactly the paired∩scanned set: no paired-but-unseen, no unpaired.
      expect(list.map((d) => d.id), [paired.id]);
      final d = list.single;
      expect(d.bondState, BluetoothBondState.bonded);
      expect(d.name, paired.name);
      expect(d.rssi, -33);
    });

    test(
      'listPairedAndScannedDevices is empty with no cache and no window',
      () async {
        fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
        expect(await bt.listPairedAndScannedDevices(), isEmpty);
        expect(fake.discoveryStarted, isFalse);
      },
    );

    test('connect pauses the scan cycle and it resumes afterwards', () async {
      fake.discoveryResults.add(
        BluetoothDiscoveryResult(
          device: nearbyUnpaired,
          rssi: null,
          timestamp: DateTime(2026),
        ),
      );
      fake.discoveryCompletes = false; // keep a cycle in flight (Linux-style)
      await bt.startScan(rescanDelay: const Duration(milliseconds: 50));
      await pumpEventQueue();
      expect(fake.discoveryStarted, isTrue);
      fake.discoveryStopped = false;

      // A slow connect: while it is in flight the scan cycle must be ended.
      fake.connectDelay = const Duration(milliseconds: 120);
      fake.bonded.add(FakeBluetoothRfcommPlatform.sampleDevice());
      final connecting = bt.connect(FakeBluetoothRfcommPlatform.sampleDevice());
      await pumpEventQueue();
      expect(fake.discoveryStopped, isTrue); // cycle cancelled for the radio
      fake.discoveryStarted = false;

      await connecting;
      // The loop resumes on its own: 50ms rescan park, then the 250ms
      // connect-poll slice(s) while the connect drains, then a fresh cycle.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(fake.discoveryStarted, isTrue);
    });

    test(
      'stopScan under a live stream hold keeps the engine running',
      () async {
        final sub = bt.bondedAndDiscoveredStream().listen((_) {});
        await pumpEventQueue();
        expect(bt.isScanning, isTrue);
        await bt.startScan();
        await bt.stopScan();
        // The stream still needs sightings: stopScan must not kill the engine.
        expect(bt.isScanning, isTrue);
        await sub.cancel();
        await pumpEventQueue();
        expect(bt.isScanning, isFalse);
      },
    );

    test(
      'a stream scanInterval never clobbers the startScan cadence',
      () async {
        await bt.startScan(rescanDelay: const Duration(seconds: 30));
        final sub = bt
            .bondedAndDiscoveredStream(scanInterval: const Duration(seconds: 1))
            .listen((_) {});
        await pumpEventQueue();
        await sub.cancel();
        await pumpEventQueue();
        // After the stream leaves, the user's 30s cadence must be intact — the
        // old bug left the stream's cadence behind forever with no way back.
        expect(bt.debugEffectiveRescanDelay, const Duration(seconds: 30));
        await bt.stopScan();
      },
    );

    test(
      'unpairing mid-stream removes the device from the intersection',
      () async {
        final paired = FakeBluetoothRfcommPlatform.sampleDevice();
        fake.bonded.add(paired);
        fake.discoveryResults.add(
          BluetoothDiscoveryResult(
            device: BluetoothDevice(id: paired.id),
            rssi: -40,
            timestamp: DateTime(2026),
          ),
        );
        bt.bondedPollInterval = const Duration(milliseconds: 30);
        final emissions = <List<BluetoothDevice>>[];
        final sub = bt.bondedAndDiscoveredStream().listen(emissions.add);
        await pumpEventQueue();
        expect(emissions.last.single.id, paired.id);
        // The user unpairs the device in OS settings.
        fake.bonded.clear();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await sub.cancel();
        expect(emissions.last, isEmpty);
      },
    );

    test('list APIs leave an already-running scan running', () async {
      await bt.startScan();
      await pumpEventQueue();
      await bt.listScannedDevices(
        scanDuration: const Duration(milliseconds: 20),
      );
      await bt.listPairedAndScannedDevices(
        scanDuration: const Duration(milliseconds: 20),
      );
      expect(bt.isScanning, isTrue);
    });

    test('one-shot discovery listeners share one platform inquiry', () async {
      final stream = bt.startDiscovery();
      var starts = 0;
      fake.discoveryResults.add(
        BluetoothDiscoveryResult(
          device: nearbyUnpaired,
          rssi: null,
          timestamp: DateTime(2026),
        ),
      );
      final s1 = stream.listen((_) => starts++);
      final s2 = stream.listen((_) {});
      await pumpEventQueue();
      await s1.cancel();
      await s2.cancel();
      // Both listeners fed from a single platform subscription: the fake's
      // broadcast controller ran onListen once, so results arrived once.
      expect(starts, 1);
    });

    test(
      'scannedDevicesStream replays the snapshot to a new listener',
      () async {
        fake.discoveryResults.add(
          BluetoothDiscoveryResult(
            device: nearbyUnpaired,
            rssi: null,
            timestamp: DateTime(2026),
          ),
        );
        await bt.startScan();
        await pumpEventQueue();
        // A listener arriving AFTER the sighting still gets it immediately.
        final first = await bt.scannedDevicesStream.first;
        expect(first.single.id, nearbyUnpaired.id);
      },
    );

    test(
      'forgetScannedDevices clears the cache and emits the empty list',
      () async {
        fake.discoveryResults.add(
          BluetoothDiscoveryResult(
            device: nearbyUnpaired,
            rssi: null,
            timestamp: DateTime(2026),
          ),
        );
        await bt.startScan();
        await pumpEventQueue();
        expect(bt.scannedDevices, isNotEmpty);
        final emissions = <List<BluetoothDevice>>[];
        final sub = bt.scannedDevicesStream.listen(emissions.add);
        await pumpEventQueue();
        bt.forgetScannedDevices();
        await pumpEventQueue();
        await sub.cancel();
        expect(bt.scannedDevices, isEmpty);
        expect(emissions.last, isEmpty);
      },
    );

    test(
      'scan errors surface on scannedDevicesStream, scan keeps running',
      () async {
        fake.discoveryError = const BluetoothDiscoveryException(
          'inquiry failed',
        );
        final errors = <Object>[];
        final sub = bt.scannedDevicesStream.listen((_) {}, onError: errors.add);
        await bt.startScan();
        await pumpEventQueue();
        await sub.cancel();
        expect(errors, isNotEmpty);
        expect(bt.isScanning, isTrue);
      },
    );
  });
}
