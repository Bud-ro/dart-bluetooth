@TestOn('vm')
library;

import 'package:bluetooth_rfcomm/src/platform/windows/windows_ffi.dart';
import 'package:bluetooth_rfcomm/src/platform/windows/windows_platform.dart';
import 'package:test/test.dart';

/// The reader-isolate disconnect classification — the 0.1.1 headline fix for
/// clobbered `WSAGetLastError()` values (dart-lang/sdk#38832). Pure logic, so
/// it runs on any host.
void main() {
  test('data delivers', () {
    expect(classifyRecv(1, 0, 0), RecvOutcome.deliver);
    expect(classifyRecv(8192, 0, 19), RecvOutcome.deliver);
  });

  test('clean EOF (n == 0) disconnects regardless of wsa', () {
    expect(classifyRecv(0, 0, 0), RecvOutcome.disconnect);
    expect(classifyRecv(0, wsaeTimedOut, 0), RecvOutcome.disconnect);
  });

  test('benign error codes keep reading', () {
    for (final wsa in [wsaeTimedOut, wsaeWouldBlock, wsaeIntr]) {
      expect(classifyRecv(-1, wsa, 0), RecvOutcome.keepReading);
      expect(classifyRecv(-1, wsa, 19), RecvOutcome.keepReading);
    }
  });

  test('real error codes disconnect immediately', () {
    for (final wsa in [wsaeConnReset, wsaeConnAborted, wsaeNetDown, 10038]) {
      expect(classifyRecv(-1, wsa, 0), RecvOutcome.disconnect);
    }
  });

  test('clobbered last-error (wsa == 0) is tolerated, but bounded', () {
    // Tolerated while under the bound...
    expect(classifyRecv(-1, 0, 0), RecvOutcome.tolerateSpurious);
    expect(classifyRecv(-1, 0, 19), RecvOutcome.tolerateSpurious);
    // ...then treated as a real disconnect so a clobbered reset can't be
    // swallowed forever.
    expect(classifyRecv(-1, 0, 20), RecvOutcome.disconnect);
    expect(classifyRecv(-1, 0, 21), RecvOutcome.disconnect);
  });

  test('custom bound is honored', () {
    expect(
      classifyRecv(-1, 0, 2, maxSpurious: 3),
      RecvOutcome.tolerateSpurious,
    );
    expect(classifyRecv(-1, 0, 3, maxSpurious: 3), RecvOutcome.disconnect);
  });
}
