/// Optional transport capability: delivery-path counters.
///
/// A platform transport that can report how many bytes/events crossed each
/// hop of its delivery path (native enqueue → OS submit → completion, and
/// native rx event → Dart port → stream) implements this in ADDITION to
/// `RfcommTransport`. `BluetoothConnection.stats` probes for it with an
/// `is`-check and merges the result into its own Dart-side counters; a
/// transport that doesn't implement it (e.g. the test fake) simply
/// contributes nothing.
///
/// Kept out of `RfcommTransport` on purpose: the counters are a diagnostic
/// surface whose keys are platform-dependent and NOT covered by semver.
abstract interface class TransportStats {
  /// A snapshot of this transport's delivery counters.
  ///
  /// Keys and availability are platform-dependent. Must not throw for a
  /// closed transport — return the last snapshot (or an empty/partial map)
  /// instead, so post-mortem diagnostics after a disconnect still work.
  Map<String, int> nativeStats();
}
