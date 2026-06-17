@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:bluetooth_le/bluetooth_le.dart';
import 'package:test/test.dart';

/// Real-backend integration tests for desktop (macOS/CoreBluetooth,
/// Linux/BlueZ, Windows/Win32 GATT). They drive the ACTUAL OS APIs with **no
/// Bluetooth hardware or peer present**, asserting that calls don't crash, don't
/// surface a native loading error, and fail with the package's domain
/// exceptions.
///
/// They can't prove a real GATT session works (that needs a device), but they
/// exercise the full native path end to end — FFI/D-Bus loading, struct/ABI
/// marshaling (notably the Windows BTH_LE_* structs), error mapping — and catch
/// crashes or wrong-exception-type regressions.
///
/// This file lives outside `test/`, so the regular `dart test` does NOT run it.
/// It is run by the manually-triggered "Integration" workflow via
/// `dart test integration`.
void main() {
  final ble = BleCentral.instance;

  // An address that is essentially never a paired peer on a CI runner.
  BleDevice absentDevice() =>
      BleDevice(id: DeviceId.address('00:11:22:33:44:55'));

  test('isSupported() returns a bool without throwing', () async {
    expect(await ble.isSupported(), isA<bool>());
  });

  test('adapterState() returns a valid enum without throwing', () async {
    expect(await ble.adapterState(), isA<BluetoothAdapterState>());
  });

  test(
    'startScan: Windows reports unsupported; macOS/Linux start+cancel cleanly',
    () async {
      if (Platform.isWindows) {
        // Win32 GATT has no unpaired-advertisement scan.
        expect(
          () => ble.startScan().listen((_) {}),
          throwsA(isA<BleUnsupportedException>()),
        );
        return;
      }
      try {
        final sub = ble.startScan().listen((_) {}, onError: (_) {});
        await Future<void>.delayed(const Duration(seconds: 2));
        await sub.cancel();
        await ble.stopScan();
      } on BleException {
        // Tolerated: permission / disabled / unavailable on a headless runner.
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'connect() to an absent device fails with a BleException (not a crash)',
    () async {
      await expectLater(
        ble.connect(absentDevice(), timeout: const Duration(seconds: 5)),
        throwsA(isA<BleException>()),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  tearDownAll(() async {
    await ble.dispose();
  });
}
