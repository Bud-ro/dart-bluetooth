import 'package:bluetooth_rfcomm/bluetooth_rfcomm.dart';
import 'package:bluetooth_rfcomm/testing.dart';
import 'package:test/test.dart';

/// The shared transport contract, enforced against the fake. Real backends run
/// the same checker from hardware rigs (see doc/testing.md) — any transport
/// that diverges from the fake's observable behavior fails the identical
/// checks there, which is what keeps tests-against-the-fake honest.
void main() {
  test(
    'FakeRfcommTransport conforms to the RfcommTransport contract',
    () async {
      final violations = await checkRfcommTransportConformance(
        open: () async => FakeRfcommTransport(
          device: DeviceId.address('AA:BB:CC:DD:EE:FF'),
          channel: 1,
          serviceUuid: Uuid.spp,
        ),
        simulatePeerDrop: (t) async => (t as FakeRfcommTransport).dropPeer(),
      );
      expect(violations, isEmpty);
    },
  );
}
