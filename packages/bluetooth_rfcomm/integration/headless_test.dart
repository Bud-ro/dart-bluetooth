@TestOn('vm')
library;

import 'dart:async';

import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
import 'package:test/test.dart';

/// Real-backend integration tests for desktop (Windows/Winsock, Linux/BlueZ,
/// macOS/IOBluetooth). They drive the ACTUAL OS APIs with **no Bluetooth
/// hardware or peer present**, asserting that calls don't crash, don't surface a
/// native loading error, and fail with the package's domain exceptions.
///
/// They can't prove a real connection works (that needs a device), but they do
/// exercise the full native path end to end — FFI loading, struct/ABI marshaling
/// (notably the Windows SOCKADDR_BTH), error mapping — and catch crashes or
/// wrong-exception-type regressions.
///
/// This file lives outside `test/`, so the regular `dart test` does NOT run it.
/// It is run by the manually-triggered "Integration" workflow via
/// `dart test integration`.
void main() {
  final bt = BluetoothRfcomm.instance;

  // A MAC that is essentially never present on a CI runner.
  BluetoothDevice absentDevice() =>
      BluetoothDevice(id: DeviceId.address('00:11:22:33:44:55'));

  test('isSupported() returns a bool without throwing', () async {
    expect(await bt.isSupported(), isA<bool>());
  });

  test('adapterState() returns a valid enum without throwing', () async {
    expect(await bt.adapterState(), isA<BluetoothAdapterState>());
  });

  test('bondedDevices() returns a list, or a BluetoothException', () async {
    try {
      expect(await bt.bondedDevices(), isA<List<BluetoothDevice>>());
    } on BluetoothException {
      // Tolerated: permission / disabled / unavailable on a headless runner.
    }
  });

  test(
    'discovery can be started and cancelled without crashing',
    () async {
      try {
        final sub = bt.startDiscovery().listen((_) {}, onError: (_) {});
        await Future<void>.delayed(const Duration(seconds: 2));
        await sub.cancel();
        await bt.stopDiscovery();
      } on BluetoothException {
        // Tolerated.
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'connect() to an absent device fails with a BluetoothException (not a crash)',
    () async {
      await expectLater(
        bt.connect(absentDevice(), timeout: const Duration(seconds: 5)),
        throwsA(isA<BluetoothException>()),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'discoverServices() on an absent device: a list, or a BluetoothException',
    () async {
      try {
        expect(
          await bt.discoverServices(absentDevice()),
          isA<List<BluetoothService>>(),
        );
      } on BluetoothException {
        // Tolerated.
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'pair() throws a BluetoothException (unsupported or device-not-found)',
    () async {
      await expectLater(
        bt.pair(absentDevice()),
        throwsA(isA<BluetoothException>()),
      );
    },
  );

  tearDownAll(() async {
    await bt.dispose();
  });
}
