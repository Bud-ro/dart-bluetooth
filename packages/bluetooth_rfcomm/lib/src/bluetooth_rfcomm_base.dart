import 'dart:async';

import 'connection.dart';
import 'exceptions.dart';
import 'logging.dart';
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

  /// The current adapter power/authorization state (one-shot snapshot).
  ///
  /// Mirrors the [BluetoothConnection] convention: [adapterState] is the
  /// snapshot, [adapterStateChanges] is the stream.
  Future<BluetoothAdapterState> adapterState() async {
    final state = await _platform.adapterState();
    logAdapter.fine(() => 'adapter state: ${state.name}');
    return state;
  }

  /// Adapter state changes. Broadcast; emits the current state on listen.
  ///
  /// Live updates only on Linux; other platforms emit the current state once
  /// and then close.
  Stream<BluetoothAdapterState> get adapterStateChanges =>
      _platform.adapterStateChanges().map((s) {
        logAdapter.fine(() => 'adapter -> ${s.name}');
        return s;
      });

  /// Asks the OS to power the radio on. Throws
  /// [BluetoothUnsupportedException] where this isn't programmatically allowed
  /// (macOS, iOS).
  Future<void> requestEnable() {
    logAdapter.fine('requestEnable');
    return _platform.setAdapterEnabled(true);
  }

  /// Asks the OS to power the radio off (where allowed).
  Future<void> requestDisable() {
    logAdapter.fine('requestDisable');
    return _platform.setAdapterEnabled(false);
  }

  /// Paired (bonded) devices known to the OS.
  Future<List<BluetoothDevice>> bondedDevices() async {
    final devices = await _platform.bondedDevices();
    logDiscovery.finer(() => 'bondedDevices: ${devices.length}');
    return devices;
  }

  /// Starts an inquiry and streams sightings. Stop by cancelling the
  /// subscription or calling [stopDiscovery].
  ///
  /// On Windows the inquiry instead runs to completion (~10s) and delivers all
  /// sightings in one batch when it finishes; it cannot be cancelled early.
  /// RSSI is reported during discovery on Linux and Android only (null
  /// elsewhere).
  Stream<BluetoothDiscoveryResult> startDiscovery() {
    logDiscovery.fine('discovery requested');
    return _platform.startDiscovery().map((r) {
      logDiscovery.finer(
        () =>
            'found ${r.device.id}'
            '${r.rssi != null ? ' rssi=${r.rssi}' : ''}',
      );
      return r;
    });
  }

  /// Stops any in-progress inquiry.
  Future<void> stopDiscovery() {
    logDiscovery.fine('discovery stopped');
    return _platform.stopDiscovery();
  }

  /// One-shot snapshot of paired devices seen in a single inquiry — i.e. bonded
  /// AND in range during the [timeout] window. For an always-on list prefer
  /// [bondedAndDiscoveredStream], which keeps scanning and accumulates sightings.
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
      // Cancelling the subscription stops this inquiry via the stream's onCancel
      // (which calls the native stop). Don't also call the public stopDiscovery()
      // — it's global and would tear down any concurrent discovery the caller is
      // running.
      await sub.cancel();
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

  /// How long a sighted device stays in [bondedAndDiscoveredStream]'s cache
  /// after it was last seen, before it's treated as gone. Long enough to ride
  /// out a flaky inquiry cycle, short enough that a device that actually left
  /// drops off.
  static const Duration _nearbyStaleAfter = Duration(seconds: 30);

  // Shared, cached "paired + nearby" state, so every subscriber sees the same
  // continuously-updated set and a new subscriber gets the current snapshot
  // immediately instead of waiting for a fresh ~10s inquiry.
  final Map<DeviceId, BluetoothDevice> _nearby = {};
  final Map<DeviceId, DateTime> _nearbySeenAt = {};
  final StreamController<List<BluetoothDevice>> _nearbyUpdates =
      StreamController<List<BluetoothDevice>>.broadcast();
  int _nearbyListeners = 0;
  bool _nearbyScanRunning = false;
  StreamSubscription<BluetoothDiscoveryResult>? _nearbyScanSub;
  Completer<void>? _nearbyCycleDone;

  /// Continuously scans and emits the set of devices that are **both paired and
  /// nearby**. Results are cached and shared across subscribers: a new listener
  /// receives the current snapshot immediately (no wait for a fresh inquiry),
  /// then live updates as devices appear, refresh their RSSI, or drop off after
  /// [_nearbyStaleAfter] without being seen. Scanning runs while at least one
  /// subscriber is listening and stops when the last one cancels; the cache is
  /// kept so the next subscriber still gets an instant (if slightly stale)
  /// snapshot. The bonded set is re-read each cycle, so devices paired mid-scan
  /// are picked up.
  ///
  /// Because scanning is periodic, a device that just appeared may take up to a
  /// scan cycle to show. Use [bondedAndDiscovered] for a one-shot snapshot, or
  /// [bondedDevices] for the instant (presence-agnostic) paired list.
  Stream<List<BluetoothDevice>> bondedAndDiscoveredStream() {
    return Stream<List<BluetoothDevice>>.multi((controller) {
      // Forward shared updates to this subscriber, then hand it the current
      // cached snapshot right away (only if we already have something, so a
      // fresh stream's `first` is a real sighting, not an empty list).
      final sub = _nearbyUpdates.stream.listen(
        controller.add,
        onError: controller.addError,
      );
      if (_nearby.isNotEmpty) {
        controller.add(_nearby.values.toList(growable: false));
      }
      _nearbyListeners++;
      _startNearbyScan();
      controller.onCancel = () {
        _nearbyListeners--;
        if (_nearbyListeners <= 0) _stopNearbyScan();
        return sub.cancel();
      };
    });
  }

  void _startNearbyScan() {
    if (_nearbyScanRunning) return;
    _nearbyScanRunning = true;
    unawaited(
      _nearbyScanLoop().catchError((Object e) {
        if (!_nearbyUpdates.isClosed) _nearbyUpdates.addError(e);
      }),
    );
  }

  void _stopNearbyScan() {
    if (_nearbyCycleDone != null && !_nearbyCycleDone!.isCompleted) {
      _nearbyCycleDone!.complete();
    }
    unawaited(_nearbyScanSub?.cancel());
    _nearbyScanSub = null;
    unawaited(stopDiscovery());
  }

  Future<void> _nearbyScanLoop() async {
    while (_nearbyListeners > 0) {
      final Map<DeviceId, BluetoothDevice> byId;
      try {
        byId = {for (final d in await bondedDevices()) d.id: d};
      } catch (e) {
        if (!_nearbyUpdates.isClosed) _nearbyUpdates.addError(e);
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      if (_nearbyListeners <= 0) break;
      // Instant first paint: surface the paired list right away instead of
      // making the subscriber wait for a full inquiry cycle (~10s on Windows).
      // The inquiry below then refreshes RSSI/presence as results arrive. On
      // platforms where the inquiry can't tell "paired & nearby" from "paired &
      // absent" cheaply, this means the list appears immediately and stays
      // presence-agnostic until a usable nearby signal exists.
      var seeded = false;
      for (final d in byId.values) {
        if (!_nearby.containsKey(d.id)) {
          _nearby[d.id] = d;
          _nearbySeenAt[d.id] = DateTime.now();
          seeded = true;
        }
      }
      if (seeded) _emitNearby();
      final done = _nearbyCycleDone = Completer<void>();
      _nearbyScanSub = startDiscovery().listen(
        (r) {
          final base = byId[r.device.id];
          if (base == null) return;
          _nearby[r.device.id] = base.copyWith(rssi: r.rssi ?? r.device.rssi);
          _nearbySeenAt[r.device.id] = DateTime.now();
          _emitNearby();
        },
        onError: (Object e) {
          if (!_nearbyUpdates.isClosed) _nearbyUpdates.addError(e);
        },
        // Inquiry finished (macOS/Android/Windows close the stream; Linux keeps
        // it open and streams continuously, so this never fires there).
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: false,
      );
      await done.future;
      await _nearbyScanSub?.cancel();
      _nearbyScanSub = null;
      _evictStaleNearby();
    }
    _nearbyScanRunning = false;
  }

  void _evictStaleNearby() {
    final cutoff = DateTime.now().subtract(_nearbyStaleAfter);
    final gone = _nearbySeenAt.entries
        .where((e) => e.value.isBefore(cutoff))
        .map((e) => e.key)
        .toList();
    if (gone.isEmpty) return;
    for (final id in gone) {
      _nearby.remove(id);
      _nearbySeenAt.remove(id);
    }
    _emitNearby();
  }

  void _emitNearby() {
    if (!_nearbyUpdates.isClosed) {
      _nearbyUpdates.add(_nearby.values.toList(growable: false));
    }
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
  /// The blocking native connect runs off the calling isolate on every platform,
  /// so this never hangs the caller. If [timeout] is null no caller deadline is
  /// applied (the attempt runs until the OS resolves it; Linux additionally caps
  /// it with an internal safety timeout).
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
    // Yield to the event loop before any (potentially blocking) native/isolate
    // setup, so a caller that flips its UI to "connecting" right before calling
    // connect() gets that frame painted immediately — rather than after the
    // worker-isolate spawn that some backends (Windows) do synchronously.
    await Future<void>.delayed(Duration.zero);
    final uuid = serviceUuid ?? Uuid.spp;
    logConnection.fine(
      () =>
          'connecting to ${device.id} '
          '(channel: ${channel ?? 'SDP'}, uuid: $uuid)',
    );
    try {
      final transport = await _platform.openRfcomm(
        device.id,
        channel: channel,
        serviceUuid: uuid,
        timeout: timeout,
      );
      return BluetoothConnection.wrap(device, transport);
    } on BluetoothException catch (e, st) {
      logConnection.severe(() => 'connect to ${device.id} failed: $e', e, st);
      rethrow;
    }
  }

  /// Pairs with [device]. Optional capability — implemented on Linux (BlueZ);
  /// Windows/macOS/Android/iOS throw [BluetoothUnsupportedException] (pair via
  /// the OS settings there). Most devices must be bonded before [connect].
  Future<void> pair(BluetoothDevice device) {
    logConnection.fine(() => 'pair ${device.id}');
    return _platform.pair(device.id);
  }

  /// Removes the bond with [device]. Optional capability — implemented on Linux;
  /// other platforms throw [BluetoothUnsupportedException] (unpair via OS
  /// settings).
  Future<void> unpair(BluetoothDevice device) {
    logConnection.fine(() => 'unpair ${device.id}');
    return _platform.unpair(device.id);
  }

  /// Releases resources held by the backend: closes any still-open connections
  /// and discovery streams, and the Linux D-Bus client. Call when you're done
  /// with this instance — don't call it while operations are still in flight.
  ///
  /// Process-lifetime native callback registrations (the FFI `NativeCallable`
  /// listeners on Android/macOS/iOS) are intentionally not torn down; the shared
  /// [instance] generally lives for the app's lifetime.
  Future<void> dispose() async {
    _nearbyListeners = 0;
    _stopNearbyScan();
    if (!_nearbyUpdates.isClosed) await _nearbyUpdates.close();
    await _platform.dispose();
  }
}
