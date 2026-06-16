// "Does it even launch" smoke test.
//
// Boots the real app on the target device (desktop, Android emulator, or iOS
// simulator), which loads the native backend, and exercises a couple of
// no-hardware calls. There is no Bluetooth adapter on CI, so the point is NOT to
// find devices — it's to prove the native library loads and its symbols resolve
// (catching dylib/DLL/JNI loading and code-signing errors at runtime).
import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
import 'package:bluetooth_rfcomm_flutter_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app launches and the native backend loads', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);

    // These reach into the platform backend, forcing the native library to load
    // and its FFI symbols to resolve. We assert they return *something* without
    // throwing a loading error — not that Bluetooth is present.
    final bt = BluetoothRfcomm.instance;
    final supported = await bt.isSupported();
    final state = await bt.adapterStateNow();
    expect(supported, isA<bool>());
    expect(state, isA<BluetoothAdapterState>());

    // bondedDevices must also not throw a loading error (it may legitimately
    // throw a permission/disabled BluetoothException, which we tolerate).
    try {
      await bt.bondedDevices();
    } on BluetoothException {
      // Expected on a runner with no/blocked adapter.
    }

    // Explicit success marker. On Windows `flutter test integration_test` can
    // run the test but still report "No tests were found" (exit 1); CI asserts
    // on this line instead of trusting the exit code there.
    debugPrint('NATIVE_SMOKE_OK');
  });
}
