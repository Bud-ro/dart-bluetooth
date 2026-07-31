/// Regression tests for the Android isolate-sendability bug class.
///
/// The original field failure: the closure sent to `Isolate.run` captured the
/// platform's `AndroidBindings` (holding a `DynamicLibrary`), so every connect
/// failed at send time — before ever reaching `BluetoothSocket.connect()` —
/// and surfaced as an instant generic "connect failed".
///
/// The subtle part is that the capture can be INDIRECT: the Dart VM gives all
/// closures created in one scope a single shared context, so a lambda that
/// only mentions sendable locals still ships everything a *sibling* closure
/// in the same method captured (e.g. `this` via `_lib`). The fix is the
/// dedicated top-level spawn helpers, whose scopes contain no other closures.
///
/// These tests run the real helpers on the host VM. A host has no
/// libbluetooth_rfcomm_android.so, so a healthy helper fails INSIDE the
/// worker isolate (library-load error) — proof the closure itself crossed the
/// isolate boundary. The over-capture bug instead fails the send itself with
/// "Illegal argument in isolate message".
@TestOn('vm')
library;

import 'dart:io';

import 'package:bluetooth_rfcomm/src/platform/android/android_platform.dart';
import 'package:test/test.dart';

/// Matches the VM's unsendable-object send failure and nothing else.
bool _isSendFailure(Object e) =>
    '$e'.contains('Illegal argument in isolate message');

void main() {
  test('spawnAndroidOpen closure crosses the isolate boundary', () async {
    Object? sendFailure;
    try {
      await spawnAndroidOpen(1, '00:11:22:33:44:55', 0, 'spp');
    } catch (e) {
      if (_isSendFailure(e)) sendFailure = e;
      // Anything else (library-load error from inside the worker, a JNI
      // failure on a real device) means the send itself succeeded.
    }
    expect(
      sendFailure,
      isNull,
      reason:
          'the Isolate.run closure over-captured non-sendable state '
          '(bindings/DynamicLibrary) — the original Android connect bug',
    );
  });

  test('spawnAndroidFlush closure crosses the isolate boundary', () async {
    Object? sendFailure;
    try {
      await spawnAndroidFlush(1);
    } catch (e) {
      if (_isSendFailure(e)) sendFailure = e;
    }
    expect(sendFailure, isNull);
  });

  test('Isolate.run appears only inside the dedicated spawn helpers', () {
    // Structural guard for the call sites: the helpers prove themselves above,
    // but a future edit could reintroduce an inline Isolate.run(() => ...)
    // in a method whose scope also holds a `this`-capturing closure. Keep
    // every spawn routed through a dedicated top-level scope.
    final src = File(
      'lib/src/platform/android/android_platform.dart',
    ).readAsStringSync();
    final spawns = 'Isolate.run('.allMatches(src).length;
    expect(
      spawns,
      2,
      reason:
          'Android must spawn isolates only via the two dedicated top-level '
          'helpers (spawnAndroidOpen/spawnAndroidFlush); an inline '
          'Isolate.run in a method scope risks shared-context over-capture',
    );
  });
}
