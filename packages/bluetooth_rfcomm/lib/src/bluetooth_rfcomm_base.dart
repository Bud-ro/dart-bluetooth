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

  /// Gap left between inquiry cycles. A classic-Bluetooth radio can't run an
  /// inquiry and open a connection at the same time, so back-to-back inquiries
  /// starve connects (and slow everything on Windows). This leaves the radio idle
  /// between scans; new/RSSI updates still arrive within roughly a cycle.
  static const Duration _nearbyScanInterval = Duration(seconds: 6);

  // Shared, cached "paired + nearby" state, so every subscriber sees the same
  // continuously-updated set and a new subscriber gets the current snapshot
  // immediately instead of waiting for a fresh ~10s inquiry.
  final Map<DeviceId, BluetoothDevice> _nearby = {};
  final StreamController<List<BluetoothDevice>> _nearbyUpdates =
      StreamController<List<BluetoothDevice>>.broadcast();
  int _nearbyListeners = 0;
  bool _nearbyScanRunning = false;
  StreamSubscription<BluetoothDiscoveryResult>? _nearbyScanSub;
  Completer<void>? _nearbyCycleDone;

  /// Number of in-flight [connect] calls. While > 0 the scan loop skips its
  /// inquiry so the radio is free for the connection handshake.
  int _activeConnects = 0;

  /// Emits the set of **paired** devices, refreshing RSSI from a periodic
  /// background inquiry. Results are cached and shared across subscribers: a new
  /// listener receives the current snapshot immediately (no wait for a fresh
  /// inquiry), then live updates as devices are paired/unpaired or their RSSI
  /// changes. Scanning runs while at least one subscriber is listening and stops
  /// when the last one cancels; the cache is kept so the next subscriber still
  /// gets an instant snapshot. The paired set is re-read each cycle, so devices
  /// paired or unpaired mid-scan are picked up.
  ///
  /// The inquiry pauses while a [connect] is in flight (a classic-Bluetooth radio
  /// can't inquire and connect at once) and leaves a gap between cycles, so it
  /// never starves connections. Use [bondedAndDiscovered] for a one-shot
  /// snapshot, or [bondedDevices] for the instant paired list without scanning.
  ///
  /// Note: this currently surfaces every paired device (presence-agnostic);
  /// filtering to only those answering the inquiry depends on the per-platform
  /// inquiry being verified on hardware.
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
      // Reconcile the cache with the current paired set: add newly-paired
      // devices, keep any RSSI already learned, and drop devices that are no
      // longer paired. The paired list is read instantly (registry on Windows),
      // so this is the first paint — no waiting on the ~10s inquiry.
      var changed = false;
      for (final d in byId.values) {
        final existing = _nearby[d.id];
        _nearby[d.id] = existing == null
            ? d
            : d.copyWith(rssi: existing.rssi ?? d.rssi);
        if (existing == null) changed = true;
      }
      for (final id in _nearby.keys.toList()) {
        if (!byId.containsKey(id)) {
          _nearby.remove(id);
          changed = true;
        }
      }
      if (changed) _emitNearby();

      // Skip the inquiry while a connect is in flight: a classic-Bluetooth radio
      // can't inquire and page at once, so inquiring here stalls the connection
      // (and vice versa). The cached paired list stays painted in the meantime.
      if (_activeConnects == 0) {
        final done = _nearbyCycleDone = Completer<void>();
        _nearbyScanSub = startDiscovery().listen(
          (r) {
            final base = byId[r.device.id];
            if (base == null) return;
            _nearby[r.device.id] = base.copyWith(rssi: r.rssi ?? r.device.rssi);
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
      }

      if (_nearbyListeners <= 0) break;
      // Breathing room before the next inquiry so the radio is free for connects
      // and isn't pinned doing back-to-back scans.
      await Future<void>.delayed(_nearbyScanInterval);
    }
    _nearbyScanRunning = false;
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
    // Free the radio for the handshake: a classic-Bluetooth radio can't inquire
    // and page at the same time. Mark a connect in flight (so the scan loop skips
    // its next inquiry) and stop listening to any inquiry already running.
    _activeConnects++;
    unawaited(_nearbyScanSub?.cancel());
    _nearbyScanSub = null;
    if (_nearbyCycleDone != null && !_nearbyCycleDone!.isCompleted) {
      _nearbyCycleDone!.complete();
    }
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
    } finally {
      _activeConnects--;
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
