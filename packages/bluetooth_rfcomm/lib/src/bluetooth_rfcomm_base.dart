import 'connection.dart';
import 'exceptions.dart';
import 'models/bluetooth_device.dart';
import 'models/bluetooth_service.dart';
import 'models/device_id.dart';
import 'models/discovery_result.dart';
import 'models/enums.dart';
import 'models/uuid.dart';
import 'platform/platform_interface.dart';

/// Entry point for Bluetooth Classic (RFCOMM serial).
///
/// Use the shared [instance], or construct one with an explicit [platform] for
/// tests. Every method dispatches to the host-appropriate backend and runs its
/// blocking work off the calling isolate.
///
/// ```dart
/// final bt = BluetoothRfcomm.instance;
/// final paired = await bt.bondedDevices();
/// final conn = await bt.connect(paired.first); // SDP-resolved SPP channel
/// ```
class BluetoothRfcomm {
  /// Creates a facade over [platform], or the auto-selected host backend.
  BluetoothRfcomm({BluetoothRfcommPlatform? platform})
    : _platform = platform ?? BluetoothRfcommPlatform.instance;

  /// Shared instance backed by the host's default platform.
  static final BluetoothRfcomm instance = BluetoothRfcomm();

  final BluetoothRfcommPlatform _platform;

  /// Whether this host can do Bluetooth Classic RFCOMM at all.
  Future<bool> isSupported() => _platform.isSupported();

  /// The current adapter power/authorization state.
  Future<BluetoothAdapterState> adapterStateNow() => _platform.adapterState();

  /// Adapter state changes. Broadcast; emits the current state on listen.
  Stream<BluetoothAdapterState> get adapterState =>
      _platform.adapterStateChanges();

  /// Asks the OS to power the radio on. Throws
  /// [BluetoothUnsupportedException] where this isn't programmatically allowed
  /// (macOS, iOS).
  Future<void> requestEnable() => _platform.setAdapterEnabled(true);

  /// Asks the OS to power the radio off (where allowed).
  Future<void> requestDisable() => _platform.setAdapterEnabled(false);

  /// Paired (bonded) devices known to the OS.
  Future<List<BluetoothDevice>> bondedDevices() => _platform.bondedDevices();

  /// Starts an inquiry and streams sightings. Stop by cancelling the
  /// subscription or calling [stopDiscovery].
  ///
  /// On Windows the inquiry instead runs to completion (~10s) and delivers all
  /// sightings in one batch when it finishes; it cannot be cancelled early.
  /// RSSI is reported during discovery on Linux and Android only (null
  /// elsewhere).
  Stream<BluetoothDiscoveryResult> startDiscovery() =>
      _platform.startDiscovery();

  /// Stops any in-progress inquiry.
  Future<void> stopDiscovery() => _platform.stopDiscovery();

  /// Paired devices that were also seen in a fresh inquiry — i.e. bonded AND
  /// currently in range. Runs discovery for [timeout] (default 8s) and returns
  /// the intersection, each carrying the latest RSSI when reported.
  Future<List<BluetoothDevice>> bondedAndDiscovered({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final bonded = await bondedDevices();
    if (bonded.isEmpty) return const [];
    final byId = {for (final d in bonded) d.id: d};
    final seen = <DeviceId, BluetoothDevice>{};

    Object? discoveryError;
    final sub = startDiscovery().listen(
      (r) {
        final base = byId[r.device.id];
        if (base != null) {
          seen[r.device.id] = base.copyWith(rssi: r.rssi ?? r.device.rssi);
        }
      },
      // Without this, a discovery error becomes an unhandled zone error and the
      // caller silently gets partial results. Capture it and surface it below.
      onError: (Object e) => discoveryError ??= e,
      cancelOnError: false,
    );
    try {
      await Future<void>.delayed(timeout);
    } finally {
      await sub.cancel();
      await stopDiscovery();
    }
    if (discoveryError != null && seen.isEmpty) {
      throw discoveryError is BluetoothException
          ? discoveryError as BluetoothException
          : BluetoothDiscoveryException(
              'discovery failed',
              cause: discoveryError,
            );
    }
    return seen.values.toList(growable: false);
  }

  /// Resolves the RFCOMM services [device] advertises via SDP. Pass the result's
  /// [BluetoothService.rfcommChannelId] to [connect] to target a specific one.
  Future<List<BluetoothService>> discoverServices(
    BluetoothDevice device, {
    Uuid? serviceUuid,
  }) => _platform.discoverServices(device.id, serviceUuid: serviceUuid);

  /// Opens an RFCOMM serial connection to [device].
  ///
  /// Channel selection: if [channel] is given it is used directly; otherwise the
  /// channel is resolved from the device's SDP record for [serviceUuid] (SPP by
  /// default). Note macOS requires a real, non-zero channel — passing `0` or
  /// relying on a device that doesn't advertise SDP will fail; pass an explicit
  /// [channel] in that case.
  ///
  /// If [timeout] is null no deadline is applied and the attempt can take as
  /// long as the OS allows. Note that on Android the native socket connect is
  /// synchronous, so it blocks the calling isolate until it succeeds or the OS
  /// gives up (~12s); [timeout] cannot interrupt that window.
  ///
  /// Throws [BluetoothTimeoutException] if [timeout] elapses, and
  /// [BluetoothConnectionException] on failure. Where the platform can tell that
  /// SDP resolved no channel for [serviceUuid] (e.g. macOS), that surfaces as
  /// the more specific [ServiceNotFoundException]; on other platforms an
  /// unresolvable service is a plain [BluetoothConnectionException].
  Future<BluetoothConnection> connect(
    BluetoothDevice device, {
    int? channel,
    Uuid? serviceUuid,
    Duration? timeout,
  }) async {
    final transport = await _platform.openRfcomm(
      device.id,
      channel: channel,
      serviceUuid: serviceUuid ?? Uuid.spp,
      timeout: timeout,
    );
    return BluetoothConnection.wrap(device, transport);
  }

  /// Pairs with [device]. Optional capability; may throw
  /// [BluetoothUnsupportedException].
  Future<void> pair(BluetoothDevice device) => _platform.pair(device.id);

  /// Removes the bond with [device]. Optional capability.
  Future<void> unpair(BluetoothDevice device) => _platform.unpair(device.id);

  /// Releases global resources held by the backend (worker isolates, native
  /// callbacks, D-Bus connection). Call when you're done using this instance.
  /// The shared [instance] generally lives for the app's lifetime.
  Future<void> dispose() => _platform.dispose();
}
