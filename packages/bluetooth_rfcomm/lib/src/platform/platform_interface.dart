import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../models/bluetooth_device.dart';
import '../models/bluetooth_service.dart';
import '../models/device_id.dart';
import '../models/discovery_result.dart';
import '../models/enums.dart';
import '../models/uuid.dart';
import 'platform_dispatch.dart';

/// A low-level, full-duplex RFCOMM byte channel returned by a platform.
///
/// This is the platform↔core seam: each platform implements it however it likes
/// (a Winsock socket on a worker isolate, a BlueZ file descriptor, an
/// IOBluetoothRFCOMMChannel feeding a `NativeCallable`), and [BluetoothConnection]
/// wraps it to present the public stream/sink API.
///
/// Implementations MUST:
///  * deliver inbound bytes on [incoming] from the main isolate (marshal off any
///    worker/native thread themselves),
///  * never block the calling isolate in [send],
///  * close [incoming] and emit a final [ConnectionState.disconnected] on
///    [stateChanges] when the peer goes away.
abstract interface class RfcommTransport {
  /// Inbound bytes. Single-subscription; closes on disconnect (clean EOF).
  Stream<Uint8List> get incoming;

  /// Connection-state transitions for this channel.
  Stream<ConnectionState> get stateChanges;

  /// Current state.
  ConnectionState get state;

  /// Queues [data] for transmission. Must return immediately without blocking;
  /// the platform drains the queue off the calling isolate.
  ///
  /// The queue is unbounded and lossless: every byte accepted here is either
  /// eventually handed to the OS or reported lost via [flush] / the terminal
  /// disconnect — a transport must never silently drop accepted bytes.
  void send(Uint8List data);

  /// Completes when all queued bytes have been handed to the OS.
  Future<void> flush();

  /// OS-advertised largest single write payload (RFCOMM MTU on macOS, max
  /// transmit packet size on Android); null where the OS exposes none
  /// (Windows/Linux stream sockets, iOS EA).
  int? get maxPayloadSize;

  /// Bytes accepted by [send] but not yet handed to the OS.
  int get pendingWriteBytes;

  /// Closes the channel. Idempotent.
  Future<void> close();
}

/// The contract every platform backend implements.
///
/// A single concrete implementation is selected at runtime by
/// [BluetoothRfcommPlatform.instance] based on the host OS. All methods run
/// their blocking work off the calling isolate so the app never hangs.
abstract class BluetoothRfcommPlatform {
  BluetoothRfcommPlatform();

  static BluetoothRfcommPlatform? _instance;

  /// The active backend. Defaults to the host-appropriate implementation;
  /// tests may override it with a fake.
  static BluetoothRfcommPlatform get instance =>
      _instance ??= _defaultInstance();

  static set instance(BluetoothRfcommPlatform value) => _instance = value;

  /// Resets to the auto-selected backend (used by tests).
  @visibleForTesting
  static void resetInstance() => _instance = null;

  /// Detaches [platform] from the shared [instance] slot if it currently
  /// occupies it, so the next [instance] read builds a fresh backend instead
  /// of handing out a disposed one. Platform implementations call this from
  /// their `dispose()`; a no-op when [platform] is not the shared instance.
  static void detachInstance(BluetoothRfcommPlatform platform) {
    if (identical(_instance, platform)) _instance = null;
  }

  static BluetoothRfcommPlatform _defaultInstance() {
    // Lazily constructed by the dispatcher so that pulling in, say, the dbus
    // backend never happens on Windows. Kept in a separate file to avoid a
    // cycle and to keep platform-specific imports out of this interface.
    return createDefaultPlatform();
  }

  /// Whether this platform can do Bluetooth Classic RFCOMM at all.
  Future<bool> isSupported();

  /// Current adapter power/authorization state.
  Future<BluetoothAdapterState> adapterState();

  /// Adapter state transitions. Broadcast; emits the current state on listen.
  Stream<BluetoothAdapterState> adapterStateChanges();

  /// Requests the radio be powered on/off. Throws
  /// [BluetoothUnsupportedException] where the OS forbids programmatic control.
  Future<void> setAdapterEnabled(bool enabled);

  /// Paired (bonded) devices known to the OS.
  Future<List<BluetoothDevice>> bondedDevices();

  /// Starts a real radio inquiry and streams sightings of nearby devices,
  /// paired or not. Cancelling the subscription (or calling [stopDiscovery])
  /// aborts the inquiry on every backend.
  Stream<BluetoothDiscoveryResult> startDiscovery();

  /// Stops any in-progress inquiry.
  Future<void> stopDiscovery();

  /// Resolves the RFCOMM services advertised by device [id] via SDP, optionally
  /// filtered to a single [serviceUuid].
  Future<List<BluetoothService>> discoverServices(
    DeviceId id, {
    Uuid? serviceUuid,
  });

  /// Opens an RFCOMM channel to device [id]. If [channel] is given it is used
  /// verbatim; otherwise the channel is resolved from SDP for [serviceUuid].
  Future<RfcommTransport> openRfcomm(
    DeviceId id, {
    int? channel,
    required Uuid serviceUuid,
    Duration? timeout,
  });

  /// Pairs with device [id]. Optional capability — may throw
  /// [BluetoothUnsupportedException].
  Future<void> pair(DeviceId id);

  /// Removes the bond with device [id]. Optional capability.
  Future<void> unpair(DeviceId id);

  /// Releases any global resources held by the backend.
  ///
  /// Overrides MUST also call [detachInstance] (or super) so the shared
  /// [instance] slot never hands a disposed backend to the next facade.
  Future<void> dispose() async {
    detachInstance(this);
  }
}
