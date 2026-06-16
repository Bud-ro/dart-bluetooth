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

  /// Continuously scans and emits the set of devices that are **both paired and
  /// have been seen nearby** during this scan. The set is cumulative — once a
  /// paired device is sighted it stays in the list (with its latest RSSI); a new
  /// list is emitted whenever a fresh match appears or a known one's RSSI
  /// updates. The inquiry is re-run automatically so scanning continues until the
  /// subscription is cancelled, which stops it. The bonded set is re-read each
  /// cycle, so devices paired mid-scan are picked up.
  ///
  /// This is the "list of my paired devices that are around right now (and stay
  /// listed once seen)" stream; use [bondedAndDiscovered] for a one-shot snapshot.
  Stream<List<BluetoothDevice>> bondedAndDiscoveredStream() {
    late StreamController<List<BluetoothDevice>> controller;
    StreamSubscription<BluetoothDiscoveryResult>? sub;
    Completer<void>? cycleDone;
    var cancelled = false;
    final seen = <DeviceId, BluetoothDevice>{};

    Future<void> loop() async {
      while (!cancelled) {
        final byId = {for (final d in await bondedDevices()) d.id: d};
        if (cancelled) return;
        final done = cycleDone = Completer<void>();
        sub = startDiscovery().listen(
          (r) {
            final base = byId[r.device.id];
            if (base != null && !controller.isClosed) {
              seen[r.device.id] = base.copyWith(rssi: r.rssi ?? r.device.rssi);
              controller.add(seen.values.toList(growable: false));
            }
          },
          onError: (Object e) {
            if (!controller.isClosed) controller.addError(e);
          },
          // Inquiry finished (macOS/Android/Windows close the stream; Linux keeps
          // it open and streams continuously, so this simply never fires there).
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: false,
        );
        await done.future;
        await sub?.cancel();
        sub = null;
      }
    }

    controller = StreamController<List<BluetoothDevice>>.broadcast(
      onListen: () {
        cancelled = false;
        unawaited(
          loop().catchError((Object e) {
            if (!controller.isClosed) controller.addError(e);
          }),
        );
      },
      onCancel: () async {
        cancelled = true;
        if (cycleDone != null && !cycleDone!.isCompleted) cycleDone!.complete();
        await sub?.cancel();
        await stopDiscovery();
      },
    );
    return controller.stream;
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
  Future<void> dispose() => _platform.dispose();
}
