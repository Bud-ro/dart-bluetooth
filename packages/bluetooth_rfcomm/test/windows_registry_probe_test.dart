/// Runs the REAL paired-device registry enumeration on a real Windows host.
///
/// Hosted CI runners have no Bluetooth radio, so the CLI (which gates on
/// isSupported()) can never exercise this path there — but the registry API
/// itself needs no radio. This is the one hardware-true gate for the
/// enumeration/parse code on the platform without a dev test machine: a
/// registry-layout assumption gone wrong, an FFI fault, or a leak-crash fails
/// the suite on every push.
@TestOn('windows')
library;

import 'package:bluetooth_rfcomm/src/platform/windows/windows_platform.dart';
import 'package:test/test.dart';

void main() {
  test('paired-device registry enumeration parses without faulting', () {
    // Radio-less runners legitimately have no BTHPORT device key: zero is a
    // valid answer. What must never happen is a throw or native fault.
    expect(debugPairedRegistryProbe(), greaterThanOrEqualTo(0));
  });
}
