import 'dart:async';

import 'package:meta/meta.dart';

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
/// await bt.startScan(); // e.g. in main()
/// // Paired AND actually nearby — the connectable set.
/// final connectable = await bt.listPairedAndScannedDevices();
/// final conn = await bt.connect(connectable.first); // SDP-resolved SPP channel
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

  /// Asks the OS to power the radio on. Only Linux (BlueZ) allows this;
  /// macOS, iOS, Windows and modern Android all throw
  /// [BluetoothUnsupportedException] — prompt the user to the system settings
  /// instead.
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

  /// Starts a radio inquiry and streams sightings of nearby devices, paired or
  /// not. Stop by cancelling the subscription or calling [stopDiscovery].
  ///
  /// This is a real inquiry on every platform (Windows included, via
  /// `WSALookupService` on a worker isolate — abortable, unlike a classic
  /// HCI inquiry). An inquiry occupies the radio while it runs: the BACKGROUND
  /// scan is paused automatically during a [connect], but a one-shot discovery
  /// you started here is yours to manage — cancel it before connecting or the
  /// handshake is delayed until the inquiry ends. RSSI is reported during
  /// discovery on Linux and Android only (null elsewhere).
  ///
  /// While a one-shot discovery is live the background scan ([startScan]) is
  /// paused, so the two never fight over the radio (or over macOS's single
  /// native inquiry slot); the scan resumes when discovery ends.
  Stream<BluetoothDiscoveryResult> startDiscovery() {
    logDiscovery.fine('discovery requested');
    // One platform stream per startDiscovery() CALL, shared by every listener
    // of the returned stream (platform streams are broadcast) — so two
    // listeners never start two competing native inquiries.
    final source = _platform.startDiscovery();
    return Stream<BluetoothDiscoveryResult>.multi((controller) {
      _activeDiscoveries++;
      _pauseScanCycle();
      var released = false;
      void release() {
        if (!released) {
          released = true;
          _activeDiscoveries--;
        }
      }

      final sub = source.listen(
        (r) {
          logDiscovery.finer(
            () =>
                'found ${r.device.id}'
                '${r.rssi != null ? ' rssi=${r.rssi}' : ''}',
          );
          controller.add(r);
        },
        onError: controller.addError,
        onDone: () {
          release();
          controller.close();
        },
        cancelOnError: false,
      );
      controller.onCancel = () {
        release();
        return sub.cancel();
      };
    });
  }

  /// Stops any in-progress inquiry.
  Future<void> stopDiscovery() {
    logDiscovery.fine('discovery stopped');
    return _platform.stopDiscovery();
  }

  // --- Background scan -------------------------------------------------------

  // Devices sighted by the background scan, keyed by identity. Survives across
  // scan cycles (and across stopScan/startScan) until forgetScannedDevices().
  final Map<DeviceId, BluetoothDevice> _scanned = {};
  final StreamController<List<BluetoothDevice>> _scannedUpdates =
      StreamController<List<BluetoothDevice>>.broadcast();
  bool _scanRequested = false;

  /// Internal holds on the scan engine (a [bondedAndDiscoveredStream] listener,
  /// a `scanDuration` window). The engine runs while the user requested it OR
  /// any hold is live, so an explicit stopScan() doesn't kill the scan out from
  /// under a stream that needs it — and vice versa.
  int _scanHolds = 0;

  bool get _scanShouldRun => _scanRequested || _scanHolds > 0;

  /// Completion of the most recently launched scan loop. Chained (never merely
  /// flag-checked) so a startScan() racing a just-stopped loop's exit still
  /// launches a fresh loop instead of being swallowed by a stale running flag.
  Future<void>? _scanLoopFuture;
  StreamSubscription<BluetoothDiscoveryResult>? _scanCycleSub;
  Completer<void>? _scanCycleDone;

  /// Completed to interrupt the loop's inter-cycle rescan-delay park, so a
  /// stopScan() exits promptly and a quick stop→start restart doesn't sit out
  /// the remainder of the old delay before scanning again.
  Completer<void>? _scanWake;

  /// Bumped by every startScan(); a cycle that observes a bump skips the
  /// inter-cycle delay, so a stop→start restart that lands while the old loop
  /// is between `await`s (not yet parked) also rescans immediately.
  int _scanEpoch = 0;

  static const Duration _defaultRescanDelay = Duration(seconds: 2);

  /// The cadence the user asked for via [startScan] (only honored while
  /// [_scanRequested]).
  Duration _userRescanDelay = _defaultRescanDelay;

  /// Cadences requested by live [bondedAndDiscoveredStream] listeners; each
  /// entry is added on listen and removed on cancel, so a stream can never
  /// permanently clobber the user's [startScan] cadence.
  final List<Duration> _streamScanIntervals = [];

  /// Test hook: the cadence the scan engine is currently running at.
  @visibleForTesting
  Duration get debugEffectiveRescanDelay => _effectiveRescanDelay;

  /// The cadence the engine actually runs at: the most demanding (shortest) of
  /// all active requests; the default when nobody stated a preference.
  Duration get _effectiveRescanDelay {
    Duration? d = _scanRequested ? _userRescanDelay : null;
    for (final s in _streamScanIntervals) {
      if (d == null || s < d) d = s;
    }
    return d ?? _defaultRescanDelay;
  }

  /// Number of live [startDiscovery] listeners. While > 0 the background scan
  /// pauses, so a one-shot discovery never fights the scan for the radio.
  int _activeDiscoveries = 0;

  /// Whether the background scan engine is currently running — because of an
  /// explicit [startScan], a live [bondedAndDiscoveredStream] listener, or an
  /// in-flight `scanDuration` window.
  bool get isScanning => _scanShouldRun;

  /// Starts a continuous **background scan** that accumulates every sighted
  /// device (paired or not) into [scannedDevices] / [scannedDevicesStream].
  ///
  /// This is the recommended way to build a device picker: call `startScan()`
  /// early (e.g. from `main`), and by the time you list devices the cache is
  /// already populated — combine [bondedDevices] with [scannedDevices] and you
  /// get paired *and* nearby devices in one instant, radio-silent read. Without
  /// this, platforms whose inquiry takes ~10s (macOS, Windows) appear to
  /// "return paired but not scanned devices" on a first listing.
  ///
  /// The scan runs real radio inquiries in a loop ([rescanDelay] apart, on
  /// platforms whose inquiry completes; Linux streams continuously). Because a
  /// classic-Bluetooth radio can't inquire and connect at the same time, the
  /// scan **pauses automatically** while a [connect] or a one-shot
  /// [startDiscovery] is in flight and resumes afterwards — so it's safe to
  /// just leave it running, or call `startScan()` again after establishing a
  /// connection (it's idempotent). Once a connection is OPEN the scan keeps
  /// running so new devices stay discoverable; inquiries can reduce the
  /// throughput of a live link, so call [stopScan] first when starting a
  /// heavy transfer. [bondedAndDiscoveredStream] shares this same scan engine
  /// (it holds it running while listened), so combining them is fine.
  ///
  /// Platform notes: on iOS there is no inquiry — the "scan" surfaces the
  /// currently-connected MFi accessories.
  ///
  /// Scan errors (adapter off, permission missing, …) are reported on
  /// [scannedDevicesStream]; the loop keeps retrying on the [rescanDelay]
  /// cadence.
  Future<void> startScan({
    Duration rescanDelay = const Duration(seconds: 2),
  }) async {
    // While already requested this is a pure no-op: in particular it must NOT
    // silently reset a custom rescanDelay back to the default. To change the
    // cadence, stopScan() first.
    if (_scanRequested) return;
    _scanRequested = true;
    _userRescanDelay = rescanDelay;
    logDiscovery.fine('background scan started');
    _ensureScanLoop();
  }

  /// Stops the background scan started by [startScan]. The accumulated
  /// [scannedDevices] cache is kept — clear it with [forgetScannedDevices].
  ///
  /// Only this facade's background scan request is withdrawn: a live
  /// [bondedAndDiscoveredStream] listener keeps the engine running (it needs
  /// sightings to mean anything), and a concurrent one-shot [startDiscovery]
  /// the app may be running is left untouched.
  Future<void> stopScan() async {
    if (!_scanRequested) return;
    _scanRequested = false;
    logDiscovery.fine('background scan stopped');
    if (_scanShouldRun) return; // a stream/window still holds the engine
    _pauseScanCycle();
    _wakeScanLoop();
  }

  /// One queued (not-yet-run) scan-loop runner at most; further ensures while
  /// it's pending are satisfied by that runner re-checking [_scanShouldRun]
  /// when it eventually runs — without this, every ensure while a loop is
  /// healthily running would chain another pending future indefinitely.
  bool _scanRunnerQueued = false;

  /// Makes sure a scan loop is running (or will run) while [_scanShouldRun].
  /// Chained on the previous loop's completion (never merely flag-checked) so
  /// a start racing a just-stopped loop's exit still launches a fresh loop.
  void _ensureScanLoop() {
    _scanEpoch++;
    // A quick stop→start can catch the previous loop still parked in its
    // inter-cycle delay; wake it so it either continues scanning now (it
    // re-reads _scanShouldRun) or exits and hands over to the runner below.
    _wakeScanLoop();
    if (_scanRunnerQueued) return;
    _scanRunnerQueued = true;
    final previous = _scanLoopFuture;
    _scanLoopFuture = Future(() async {
      // If a just-stopped loop is still winding down, let it exit fully before
      // starting the next one — two loops must never run concurrently. A loop
      // that is still healthily running only exits once _scanShouldRun goes
      // false, at which point this runner sees that and does nothing.
      if (previous != null) await previous;
      // Reset BEFORE the check so an ensure arriving later re-queues.
      _scanRunnerQueued = false;
      if (!_scanShouldRun) return;
      try {
        await _scanLoop();
      } catch (e, st) {
        // The loop died unexpectedly (it already tolerates per-cycle stream
        // errors, so this is a bug or a backend teardown). Don't let
        // isScanning keep claiming a scan that no longer exists.
        logDiscovery.severe('background scan loop crashed', e, st);
        _scanRequested = false;
        if (!_scannedUpdates.isClosed) _scannedUpdates.addError(e);
      }
    });
  }

  /// Internal hold on the scan engine (stream listener / scanDuration window).
  void _holdScan() {
    _scanHolds++;
    _ensureScanLoop();
  }

  void _releaseScan() {
    _scanHolds--;
    if (!_scanShouldRun) {
      _pauseScanCycle();
      _wakeScanLoop();
    }
  }

  /// Clears the [scannedDevices] cache (and emits the now-empty list on
  /// [scannedDevicesStream]). Useful when stale sightings should be dropped —
  /// e.g. after the user pulls to refresh, or when a scan has been off for a
  /// while and devices may have moved out of range.
  void forgetScannedDevices() {
    logDiscovery.fine('scanned-device cache cleared');
    _scanned.clear();
    _emitScanned();
  }

  /// Snapshot of every device sighted by the background scan since the last
  /// [forgetScannedDevices], newest data per device. Instant and radio-silent.
  List<BluetoothDevice> get scannedDevices =>
      List.unmodifiable(_scanned.values);

  // --- The three dedicated listing APIs -------------------------------------
  //
  // Deliberately separate, never a union: a list that mixes "actually nearby"
  // with "merely remembered by the OS" makes paired-but-out-of-range devices
  // look connectable when they aren't.

  /// **1. All scanned devices** — everything the background scan has sighted
  /// (paired or not) since the last [forgetScannedDevices].
  ///
  /// With no [scanDuration] this is instant and radio-silent (the current
  /// cache, same as the [scannedDevices] getter). Pass a [scanDuration] to
  /// scan for that window first, replacing the startScan → wait → list →
  /// stopScan dance with one call. A background scan that was already running
  /// is left running; one this call started is stopped again (the sightings
  /// stay cached). Time the scan spends paused for a [connect] counts against
  /// the window.
  Future<List<BluetoothDevice>> listScannedDevices({
    Duration? scanDuration,
  }) async {
    await _scanWindow(scanDuration);
    logDiscovery.fine(() => 'listScannedDevices: ${_scanned.length} device(s)');
    return scannedDevices;
  }

  /// **2. All paired devices** — what the OS remembers, whether or not it is
  /// anywhere nearby. Instant and radio-silent.
  ///
  /// A paired device is NOT necessarily reachable; don't build a "connect to
  /// one of these" picker from this list alone — that's what
  /// [listPairedAndScannedDevices] is for.
  Future<List<BluetoothDevice>> listPairedDevices() => bondedDevices();

  /// **3. Paired AND scanned** — devices you've bonded with that the scan has
  /// actually sighted: the "I care about it AND can probably connect to it"
  /// set, which is what a connect picker almost always wants.
  ///
  /// Entries carry the bonded metadata (bond state, class) plus what only the
  /// radio knows (RSSI, and a name when the OS has none cached).
  ///
  /// The intersection is against the scan cache, so scanning must have run:
  /// either have [startScan] going (e.g. from `main`), or pass a
  /// [scanDuration] to scan for that window first ([listScannedDevices]
  /// describes the window semantics). With no cache and no window this
  /// returns an empty list.
  Future<List<BluetoothDevice>> listPairedAndScannedDevices({
    Duration? scanDuration,
  }) async {
    await _scanWindow(scanDuration);
    final bonded = await bondedDevices();
    final result = <BluetoothDevice>[
      for (final b in bonded)
        if (_scanned[b.id] case final sighted?)
          b.copyWith(name: b.name ?? sighted.name, rssi: sighted.rssi),
    ];
    logDiscovery.fine(
      () =>
          'listPairedAndScannedDevices: ${result.length} of ${bonded.length} '
          'paired device(s) in the scan cache (${_scanned.length} scanned)',
    );
    return result;
  }

  /// Runs the scan engine for [scanDuration] (no-op when null) via an internal
  /// hold, so it composes with — and never stops — a user-level [startScan] or
  /// a live [bondedAndDiscoveredStream].
  Future<void> _scanWindow(Duration? scanDuration) async {
    if (scanDuration == null) return;
    _holdScan();
    try {
      await Future<void>.delayed(scanDuration);
    } finally {
      _releaseScan();
    }
  }

  /// Live view of [scannedDevices]: emits the current snapshot immediately on
  /// listen, then again whenever a scan sighting adds or refreshes a device.
  /// Scan failures surface here as errors (the stream stays alive).
  Stream<List<BluetoothDevice>> get scannedDevicesStream {
    return Stream<List<BluetoothDevice>>.multi((controller) {
      final sub = _scannedUpdates.stream.listen(
        controller.add,
        onError: controller.addError,
      );
      controller.add(scannedDevices);
      controller.onCancel = sub.cancel;
    });
  }

  Future<void> _scanLoop() async {
    logDiscovery.fine('background scan loop running');
    while (_scanShouldRun) {
      // Keep the radio free for connects and one-shot discoveries.
      if (_activeConnects > 0 || _activeDiscoveries > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        continue;
      }
      final epoch = _scanEpoch;
      final done = _scanCycleDone = Completer<void>();
      final sub = _platform.startDiscovery().listen(
        (r) {
          final existing = _scanned[r.device.id];
          final device = r.device.copyWith(
            name: r.device.name ?? existing?.name,
            rssi: r.rssi ?? r.device.rssi ?? existing?.rssi,
          );
          // Re-sightings with nothing new are common (Linux streams
          // continuously) — don't rebuild and re-emit the snapshot for them.
          if (existing != null &&
              existing.name == device.name &&
              existing.rssi == device.rssi &&
              existing.bondState == device.bondState &&
              existing.isConnected == device.isConnected) {
            return;
          }
          _scanned[device.id] = device;
          logDiscovery.finer(() => 'scan sighting: ${device.id}');
          _emitScanned();
        },
        onError: (Object e) {
          if (!_scannedUpdates.isClosed) _scannedUpdates.addError(e);
          if (!done.isCompleted) done.complete();
        },
        // Inquiry finished (never fires on Linux, whose discovery streams
        // continuously — there the cycle ends only via _pauseScanCycle/stopScan).
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: false,
      );
      _scanCycleSub = sub;
      await done.future;
      _scanCycleSub = null;
      await sub.cancel();
      if (!_scanShouldRun) break;
      // A restart arrived during this cycle: rescan immediately.
      if (epoch != _scanEpoch) continue;
      // Interruptible park: _wakeScanLoop() (stopScan / a quick restart) cuts
      // it short so state changes take effect now, not up to a cadence later.
      final wake = _scanWake = Completer<void>();
      await Future.any([
        Future<void>.delayed(_effectiveRescanDelay),
        wake.future,
      ]);
      _scanWake = null;
    }
    logDiscovery.fine('background scan loop exited');
  }

  void _wakeScanLoop() {
    final wake = _scanWake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Ends the current scan cycle (if any) so the radio is free right now; the
  /// scan loop re-checks its preconditions and starts a fresh cycle later.
  void _pauseScanCycle() {
    final sub = _scanCycleSub;
    _scanCycleSub = null;
    if (sub != null) unawaited(sub.cancel());
    final done = _scanCycleDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  void _emitScanned() {
    if (!_scannedUpdates.isClosed) {
      _scannedUpdates.add(List.unmodifiable(_scanned.values));
    }
  }

  /// One-shot snapshot of paired devices seen in a single inquiry — i.e. bonded
  /// AND in range during the [timeout] window, on every platform (Windows runs
  /// a real `WSALookupService` inquiry). For an always-on list prefer
  /// [bondedAndDiscoveredStream], which keeps scanning and accumulates
  /// sightings; for the scan-cache-based intersection in one call see
  /// [listPairedAndScannedDevices].
  ///
  /// Returns as soon as discovery completes; [timeout] caps platforms whose
  /// discovery streams continuously (Linux) or whose inquiry outlasts it
  /// (macOS/Windows/Android inquiries run ~10s — cancelling at [timeout]
  /// aborts them).
  Future<List<BluetoothDevice>> bondedAndDiscovered({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final bonded = await bondedDevices();
    if (bonded.isEmpty) return const [];
    final byId = {for (final d in bonded) d.id: d};
    final seen = <DeviceId, BluetoothDevice>{};

    Object? discoveryError;
    final done = Completer<void>();
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
      // Complete as soon as the inquiry finishes so we don't wait out the whole
      // timeout when discovery is fast.
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );
    try {
      // Whichever comes first: discovery finishing, or the timeout elapsing.
      await Future.any([done.future, Future<void>.delayed(timeout)]);
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

  /// How often the paired list is re-read while [bondedAndDiscoveredStream] is
  /// listened to, so devices paired/unpaired (via the OS) while the app runs
  /// are picked up. A cheap, radio-silent read (the registry on Windows), so
  /// it never competes with [connect]. Mutable only so tests can shrink it.
  @visibleForTesting
  Duration bondedPollInterval = const Duration(seconds: 4);

  // Shared paired∩scanned state for bondedAndDiscoveredStream, so every
  // subscriber sees the same continuously-updated set and a new subscriber
  // gets the current snapshot immediately.
  final Map<DeviceId, BluetoothDevice> _nearby = {};
  final StreamController<List<BluetoothDevice>> _nearbyUpdates =
      StreamController<List<BluetoothDevice>>.broadcast();
  int _nearbyListeners = 0;
  Future<void>? _nearbyLoopFuture;
  bool _nearbyRunnerQueued = false;

  /// Completed to interrupt the nearby loop's poll park, so the last listener
  /// cancelling (or dispose) doesn't leave the loop lingering for a poll tick.
  Completer<void>? _nearbyWake;

  /// Number of in-flight [connect] calls. While > 0 the scan loop skips its
  /// inquiry so the radio is free for the connection handshake (a classic-
  /// Bluetooth radio can't inquire and page at the same time).
  int _activeConnects = 0;

  /// Live stream of devices that are **paired AND have been sighted by the
  /// scan** — "I care about it AND can probably connect to it", the streaming
  /// version of [listPairedAndScannedDevices]. Identical semantics on every
  /// platform, Windows included: a device appears only once the radio has
  /// actually seen it.
  ///
  /// Listening holds the shared background scan engine running (the same one
  /// as [startScan] — they compose, never conflict), so sightings keep
  /// arriving while subscribed; [scanInterval] adjusts the engine's rescan
  /// cadence. The paired list is re-polled radio-silently every few seconds,
  /// so pairing/unpairing in OS settings is picked up too. Emissions carry the
  /// bonded metadata plus the scan's RSSI.
  ///
  /// A new listener immediately receives the current snapshot when non-empty.
  /// Sightings persist in the scan cache until [forgetScannedDevices], so a
  /// device that just went out of range remains listed until then — treat the
  /// set as "probably reachable", and handle a failed [connect] gracefully.
  ///
  /// For a one-shot "paired AND in range right now" snapshot (fresh sightings
  /// only) use [bondedAndDiscovered]; for the plain paired list use
  /// [listPairedDevices].
  Stream<List<BluetoothDevice>> bondedAndDiscoveredStream({
    Duration? scanInterval,
  }) {
    return Stream<List<BluetoothDevice>>.multi((controller) {
      // Time from subscription to the first list actually delivered to this
      // subscriber — this is "how long until your UI can paint the list". If
      // this is ~0ms but the UI still lags, the delay is downstream of us.
      final sw = Stopwatch()..start();
      var firstDelivered = false;
      void deliver(List<BluetoothDevice> list) {
        if (!firstDelivered) {
          firstDelivered = true;
          logDiscovery.fine(
            () =>
                'bondedAndDiscoveredStream: first emission delivered to '
                'subscriber after ${sw.elapsedMilliseconds}ms '
                '(${list.length} device(s))',
          );
        }
        controller.add(list);
      }

      // Forward shared updates to this subscriber, then hand it the current
      // cached snapshot right away (only if we already have something, so a
      // fresh stream's `first` is a real intersection, not an empty list).
      final sub = _nearbyUpdates.stream.listen(
        deliver,
        onError: controller.addError,
      );
      if (_nearby.isNotEmpty) {
        deliver(_nearby.values.toList(growable: false));
      }
      if (scanInterval != null) _streamScanIntervals.add(scanInterval);
      _nearbyListeners++;
      logDiscovery.fine(
        () =>
            'bondedAndDiscoveredStream: subscriber added '
            '(listeners=$_nearbyListeners, cached=${_nearby.length})',
      );
      // "Discovered" requires a radio: hold the shared scan engine while
      // subscribed, and run the paired-side reconcile loop.
      _holdScan();
      _startNearbyLoop();
      controller.onCancel = () {
        if (scanInterval != null) _streamScanIntervals.remove(scanInterval);
        _nearbyListeners--;
        if (_nearbyListeners <= 0) _wakeNearbyLoop();
        _releaseScan();
        return sub.cancel();
      };
    });
  }

  void _startNearbyLoop() {
    // Chained on the previous loop's completion, exactly like _ensureScanLoop:
    // a bare running-flag would let a subscriber arriving during the old
    // loop's wind-down window end up with no loop at all (silent stream).
    if (_nearbyRunnerQueued) return;
    _nearbyRunnerQueued = true;
    final previous = _nearbyLoopFuture;
    _nearbyLoopFuture = Future(() async {
      if (previous != null) await previous;
      _nearbyRunnerQueued = false;
      if (_nearbyListeners <= 0) return;
      try {
        await _nearbyLoop();
      } catch (e) {
        if (!_nearbyUpdates.isClosed) _nearbyUpdates.addError(e);
      }
    });
  }

  void _wakeNearbyLoop() {
    final wake = _nearbyWake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Maintains `_nearby` = paired ∩ scanned: recomputes on every scan-cache
  /// update, and re-reads the (radio-silent) paired list every
  /// [_bondedPollInterval]. The radio side lives entirely in the shared scan
  /// engine — this loop never touches it.
  Future<void> _nearbyLoop() async {
    logDiscovery.fine('paired∩scanned loop started');
    var bondedById = <DeviceId, BluetoothDevice>{};

    void recompute() {
      var changed = false;
      for (final b in bondedById.values) {
        final sighted = _scanned[b.id];
        if (sighted == null) {
          if (_nearby.remove(b.id) != null) changed = true;
          continue;
        }
        final merged = b.copyWith(
          name: b.name ?? sighted.name,
          rssi: sighted.rssi,
        );
        final prev = _nearby[b.id];
        if (prev == null ||
            prev.name != merged.name ||
            prev.rssi != merged.rssi ||
            prev.isConnected != merged.isConnected) {
          _nearby[b.id] = merged;
          changed = true;
        }
      }
      for (final id in _nearby.keys.toList()) {
        if (!bondedById.containsKey(id)) {
          _nearby.remove(id);
          changed = true;
        }
      }
      if (changed && !_nearbyUpdates.isClosed) {
        _nearbyUpdates.add(_nearby.values.toList(growable: false));
      }
    }

    // New sightings (or forgetScannedDevices) → recompute against the latest
    // paired set. Scan errors are relayed so subscribers of this stream see
    // inquiry failures too, not only scannedDevicesStream listeners.
    final scannedSub = _scannedUpdates.stream.listen(
      (_) => recompute(),
      onError: (Object e) {
        if (!_nearbyUpdates.isClosed) _nearbyUpdates.addError(e);
      },
    );
    try {
      while (_nearbyListeners > 0) {
        try {
          bondedById = {for (final d in await bondedDevices()) d.id: d};
          recompute();
        } catch (e) {
          if (!_nearbyUpdates.isClosed) _nearbyUpdates.addError(e);
        }
        // Interruptible park: the last listener leaving (or dispose) wakes it
        // so the loop exits now instead of after a full poll tick.
        final wake = _nearbyWake = Completer<void>();
        await Future.any([
          Future<void>.delayed(bondedPollInterval),
          wake.future,
        ]);
        _nearbyWake = null;
      }
    } finally {
      await scannedSub.cancel();
      logDiscovery.fine('paired∩scanned loop exited');
    }
  }

  /// Resolves the RFCOMM services [device] advertises via SDP. Pass the result's
  /// [BluetoothService.rfcommChannelId] to [connect] to target a specific one.
  ///
  /// Platform honesty: only macOS consults the device's actual SDP records
  /// (querying the device if none are cached). Windows, Linux and Android
  /// return the REQUESTED service with a sentinel channel of 0, meaning
  /// "resolved at connect time by the OS" — a non-empty result there does NOT
  /// confirm the device advertises the service. iOS returns an empty list
  /// (ExternalAccessory has no SDP access).
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
    // End any inquiry cycle in flight; the scan loop stays paused while a
    // connect is in flight and resumes on its own afterwards.
    _pauseScanCycle();
    final sw = Stopwatch()..start();
    try {
      final transport = await _platform.openRfcomm(
        device.id,
        channel: channel,
        serviceUuid: uuid,
        timeout: timeout,
      );
      logConnection.fine(
        () => 'connected to ${device.id} in ${sw.elapsedMilliseconds}ms',
      );
      return BluetoothConnection.wrap(device, transport);
    } on BluetoothException catch (e, st) {
      logConnection.severe(
        () =>
            'connect to ${device.id} failed after ${sw.elapsedMilliseconds}ms: $e',
        e,
        st,
      );
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

  /// Stops this facade's scan/stream loops and releases backend resources
  /// (discovery streams; on macOS/Android/iOS also still-open connections; the
  /// Linux D-Bus client if this instance created it). Windows connections are
  /// NOT tracked centrally — close them yourself before disposing. Call when
  /// you're done with this instance, not while operations are in flight.
  ///
  /// Process-lifetime native callback registrations (the FFI `NativeCallable`
  /// listeners on Android/macOS/iOS) are intentionally not torn down; the shared
  /// [instance] generally lives for the app's lifetime.
  Future<void> dispose() async {
    _nearbyListeners = 0;
    _scanRequested = false;
    _scanHolds = 0;
    _pauseScanCycle();
    _wakeScanLoop();
    _wakeNearbyLoop();
    // Join the loops before tearing the backend down, so no scan cycle is
    // mid-flight against a disposing platform. Bounded: a loop wedged in a
    // backend call must not make dispose hang forever.
    final loops = <Future<void>>[
      if (_scanLoopFuture != null) _scanLoopFuture!,
      if (_nearbyLoopFuture != null) _nearbyLoopFuture!,
    ];
    if (loops.isNotEmpty) {
      await Future.wait(
        loops,
      ).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    }
    if (!_scannedUpdates.isClosed) await _scannedUpdates.close();
    if (!_nearbyUpdates.isClosed) await _nearbyUpdates.close();
    await _platform.dispose();
  }
}
