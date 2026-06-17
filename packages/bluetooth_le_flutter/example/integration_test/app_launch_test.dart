// "Does it even launch" smoke test.
//
// Boots the real app on the target device (Android emulator / iOS simulator /
// desktop), which loads the native BLE backend, and exercises a couple of
// no-hardware calls. There is no Bluetooth adapter on CI, so the point is NOT to
// find devices — it's to prove the native library loads and its symbols resolve
// (catching JNI/dylib loading and code-signing errors at runtime).
import 'package:bluetooth_le/bluetooth_le.dart';
import 'package:bluetooth_le_flutter_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app launches and the native BLE backend loads', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);

    // These reach into the platform backend, forcing the native library to load
    // and its FFI symbols to resolve. We assert they return *something* without
    // throwing a loading error — not that Bluetooth is present.
    final ble = BleCentral.instance;
    final supported = await ble.isSupported();
    final state = await ble.adapterState();
    expect(supported, isA<bool>());
    expect(state, isA<BluetoothAdapterState>());
  });
}
