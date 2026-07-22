import 'dart:async';
import 'dart:typed_data';

import '../exceptions.dart';
import '../models/bluetooth_device.dart';
import '../models/bluetooth_service.dart';
import '../models/device_id.dart';
import '../models/discovery_result.dart';
import '../models/enums.dart';
import '../models/uuid.dart';
import '../platform/platform_interface.dart';

/// A scriptable, in-memory [BluetoothRfcommPlatform] for tests.
///
/// Populate [bonded], queue [discoveryResults] to emit, and connect against
/// [services]. Each [openRfcomm] returns a [FakeRfcommTransport] you can drive:
/// push inbound bytes with [FakeRfcommTransport.deliver] and inspect everything
/// written via [FakeRfcommTransport.sent].
class FakeBluetoothRfcommPlatform extends BluetoothRfcommPlatform {
  FakeBluetoothRfcommPlatform({
    this.supported = true,
    BluetoothAdapterState adapterState = BluetoothAdapterState.on,
  }) : _adapterState = adapterState;

  bool supported;
  BluetoothAdapterState _adapterState;

  /// Bonded devices returned by [bondedDevices].
  final List<BluetoothDevice> bonded = [];

  /// Sightings emitted (in order) when [startDiscovery] is listened to.
  final List<BluetoothDiscoveryResult> discoveryResults = [];

  /// If set, the discovery stream emits this error (after any [discoveryResults])
  /// so tests can exercise error-surfacing paths.
  Object? discoveryError;

  /// Whether a discovery stream closes after emitting [discoveryResults],
  /// mirroring the real inquiry-completes platforms (Windows/macOS/Android).
  /// Set false to model Linux, whose discovery streams stay open.
  bool discoveryCompletes = true;

  /// If set, [openRfcomm] waits this long before returning — lets tests
  /// observe the facade's connect-in-flight behavior (scan pausing etc.).
  Duration? connectDelay;

  /// SDP services returned by [discoverServices], keyed by device id.
  final Map<DeviceId, List<BluetoothService>> services = {};

  /// Transports handed out by [openRfcomm], in creation order.
  final List<FakeRfcommTransport> transports = [];

  /// If set, [openRfcomm] throws this instead of returning a transport.
  Object? connectError;

  /// Seeds [FakeRfcommTransport.maxPayloadSize] on every transport handed out
  /// by [openRfcomm]. Null (the default) models Windows/Linux/iOS, where the
  /// OS advertises no per-write payload limit.
  int? transportMaxPayloadSize;

  final StreamController<BluetoothAdapterState> _adapterController =
      StreamController<BluetoothAdapterState>.broadcast();

  bool discoveryStarted = false;
  bool discoveryStopped = false;
  final List<DeviceId> paired = [];
  final List<DeviceId> unpaired = [];

  /// A ready-made sample device for convenience.
  static BluetoothDevice sampleDevice({
    String address = 'AA:BB:CC:DD:EE:FF',
    String name = 'Test Device',
  }) => BluetoothDevice(
    id: DeviceId.address(address),
    name: name,
    type: BluetoothDeviceType.classic,
    bondState: BluetoothBondState.bonded,
  );

  void emitAdapterState(BluetoothAdapterState state) {
    _adapterState = state;
    _adapterController.add(state);
  }

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<BluetoothAdapterState> adapterState() async => _adapterState;

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() {
    late StreamController<BluetoothAdapterState> proxy;
    StreamSubscription<BluetoothAdapterState>? sub;
    proxy = StreamController<BluetoothAdapterState>.broadcast(
      onListen: () {
        proxy.add(_adapterState);
        sub = _adapterController.stream.listen(proxy.add);
      },
      onCancel: () async => sub?.cancel(),
    );
    return proxy.stream;
  }

  @override
  Future<void> setAdapterEnabled(bool enabled) async {
    emitAdapterState(
      enabled ? BluetoothAdapterState.on : BluetoothAdapterState.off,
    );
  }

  @override
  Future<List<BluetoothDevice>> bondedDevices() async =>
      List.unmodifiable(bonded);

  @override
  Stream<BluetoothDiscoveryResult> startDiscovery() {
    late StreamController<BluetoothDiscoveryResult> controller;
    controller = StreamController<BluetoothDiscoveryResult>.broadcast(
      onListen: () {
        discoveryStarted = true;
        for (final r in discoveryResults) {
          controller.add(r);
        }
        if (discoveryError != null) controller.addError(discoveryError!);
        if (discoveryCompletes && !controller.isClosed) {
          unawaited(controller.close());
        }
      },
      onCancel: () {
        discoveryStopped = true;
      },
    );
    return controller.stream;
  }

  @override
  Future<void> stopDiscovery() async {
    discoveryStopped = true;
  }

  @override
  Future<List<BluetoothService>> discoverServices(
    DeviceId device, {
    Uuid? serviceUuid,
  }) async {
    final all = services[device] ?? const [];
    if (serviceUuid == null) return all;
    return all.where((s) => s.uuid == serviceUuid).toList();
  }

  @override
  Future<RfcommTransport> openRfcomm(
    DeviceId device, {
    int? channel,
    required Uuid serviceUuid,
    Duration? timeout,
  }) async {
    final delay = connectDelay;
    if (delay != null) await Future<void>.delayed(delay);
    final err = connectError;
    if (err != null) throw err;
    final t = FakeRfcommTransport(
      device: device,
      channel: channel,
      serviceUuid: serviceUuid,
      maxPayloadSize: transportMaxPayloadSize,
    );
    transports.add(t);
    return t;
  }

  @override
  Future<void> pair(DeviceId device) async => paired.add(device);

  @override
  Future<void> unpair(DeviceId device) async => unpaired.add(device);

  @override
  Future<void> dispose() async {
    await _adapterController.close();
  }
}

/// A controllable [RfcommTransport] for tests.
class FakeRfcommTransport implements RfcommTransport {
  FakeRfcommTransport({
    required this.device,
    required this.channel,
    required this.serviceUuid,
    this.maxPayloadSize,
  });

  /// Which device this transport was opened for.
  final DeviceId device;

  /// The channel passed to `openRfcomm` (null if SDP-resolved).
  final int? channel;

  /// The service UUID requested.
  final Uuid serviceUuid;

  /// Everything written via [send], in order.
  final List<Uint8List> sent = [];

  /// Number of times [flush] was awaited.
  int flushCount = 0;

  /// If set, [flush] throws this — models a dead-link flush failure
  /// (Windows/Linux/Android throw a BluetoothWriteException there).
  Object? flushError;

  /// OS-advertised max single-write payload surfaced as
  /// [RfcommTransport.maxPayloadSize]. Mutable so tests can model any
  /// platform: null (the default) for Windows/Linux/iOS, ~1011 for a macOS
  /// RFCOMM MTU, ~990 for an Android max-transmit-packet-size.
  @override
  int? maxPayloadSize;

  /// Whether [flush] models a real drain acknowledgement (Windows, Linux,
  /// Android) by zeroing [pendingWriteBytes] once it resolves. Set false to
  /// model the best-effort platforms (macOS/iOS), where flush resolves
  /// immediately and the queue drains on its own time — tests then lower
  /// [pendingWriteBytes] themselves to simulate the OS draining.
  bool flushDrains = true;

  int _pendingWriteBytes = 0;

  /// Bytes accepted by [send] but not yet "handed to the OS". Grows by
  /// `data.length` on every [send]; returns to 0 on a successful [flush] when
  /// [flushDrains] is true. Also settable, so tests can script arbitrary
  /// queue depths and drain timelines.
  @override
  int get pendingWriteBytes => _pendingWriteBytes;
  set pendingWriteBytes(int value) => _pendingWriteBytes = value;

  // Single-subscription, matching the RfcommTransport contract and every real
  // backend (the facade re-broadcasts via BluetoothConnection.input).
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final StreamController<ConnectionState> _state =
      StreamController<ConnectionState>.broadcast();
  ConnectionState _current = ConnectionState.connected;
  bool _closed = false;

  /// Pushes [bytes] to the connection's input stream as if received.
  void deliver(List<int> bytes) {
    if (_closed) return;
    _incoming.add(Uint8List.fromList(bytes));
  }

  /// Simulates the peer dropping the link. Mirrors real backends, which close
  /// both the state and incoming streams on a peer-initiated disconnect.
  void dropPeer() {
    if (_closed) return;
    _closed = true;
    _current = ConnectionState.disconnected;
    _state.add(ConnectionState.disconnected);
    if (!_state.isClosed) unawaited(_state.close());
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<ConnectionState> get stateChanges => _state.stream;

  @override
  ConnectionState get state => _current;

  @override
  void send(Uint8List data) {
    if (_closed) throw const BluetoothWriteException('transport closed');
    sent.add(data);
    _pendingWriteBytes += data.length;
  }

  @override
  Future<void> flush() async {
    flushCount++;
    final err = flushError;
    if (err != null && !_closed) throw err;
    if (flushDrains) _pendingWriteBytes = 0;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final alreadyDisconnected = _current == ConnectionState.disconnected;
    _current = ConnectionState.disconnected;
    // Mirror every real transport: emit the terminal state before closing.
    if (!_state.isClosed) {
      if (!alreadyDisconnected) _state.add(ConnectionState.disconnected);
      await _state.close();
    }
    if (!_incoming.isClosed) await _incoming.close();
  }
}
