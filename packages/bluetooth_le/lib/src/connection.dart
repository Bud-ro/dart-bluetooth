import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'logging.dart';
import 'models/ble_device.dart';
import 'models/ble_service.dart';
import 'models/enums.dart';
import 'models/uuid.dart';
import 'platform/platform_interface.dart';
import 'serial.dart';

/// A live GATT connection to a device.
///
/// Obtain one from [BleCentral.connect]. Discover services, then read/write
/// characteristics or [subscribe] to notifications. For a serial-style byte
/// stream over a characteristic pair, use [asSerial].
class BleConnection {
  BleConnection._(this.device, this._gatt);

  /// Internal: wrap a platform transport. Not part of the public API.
  @internal
  static BleConnection wrap(BleDevice device, GattConnection gatt) =>
      BleConnection._(device, gatt);

  /// The device this connection talks to.
  final BleDevice device;

  final GattConnection _gatt;

  /// Connection-state transitions; closes when the link drops.
  Stream<BleConnectionState> get stateChanges => _gatt.stateChanges.map((s) {
    logConnection.fine(() => 'state ${device.id} -> ${s.name}');
    return s;
  });

  /// Current connection state.
  BleConnectionState get state => _gatt.state;

  /// Whether the connection is currently open.
  bool get isConnected => _gatt.state.isConnected;

  /// Discovers the device's GATT services and their characteristics.
  Future<List<BleService>> discoverServices() {
    logGatt.fine(() => 'discoverServices ${device.id}');
    return _gatt.discoverServices();
  }

  /// Reads the value of [characteristic] under [service].
  Future<Uint8List> read(Uuid service, Uuid characteristic) {
    logGatt.finer(() => 'read $service/$characteristic');
    return _gatt.readCharacteristic(service, characteristic);
  }

  /// Writes [value] to [characteristic] under [service].
  Future<void> write(
    Uuid service,
    Uuid characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  }) {
    logData.finest(() => 'tx $characteristic ${describeBytes(value)}');
    return _gatt.writeCharacteristic(
      service,
      characteristic,
      value,
      withoutResponse: withoutResponse,
    );
  }

  /// Enables notifications/indications on [characteristic] and streams the
  /// values the peripheral pushes. Cancelling the subscription disables them.
  Stream<Uint8List> subscribe(Uuid service, Uuid characteristic) =>
      _gatt.subscribe(service, characteristic).map((v) {
        logData.finest(() => 'rx $characteristic ${describeBytes(v)}');
        return v;
      });

  /// Requests a larger ATT MTU; returns the negotiated value.
  Future<int> requestMtu(int mtu) async {
    final negotiated = await _gatt.requestMtu(mtu);
    logConnection.fine(() => 'mtu ${device.id} -> $negotiated');
    return negotiated;
  }

  /// Closes the connection. Idempotent.
  Future<void> close() {
    logConnection.fine(() => 'close ${device.id}');
    return _gatt.close();
  }

  /// A serial-style duplex channel over a write+notify characteristic pair.
  ///
  /// Defaults to the Nordic UART Service (write → [Uuid.nordicUartRx], notify ←
  /// [Uuid.nordicUartTx]). Discover services first. See [BleSerial].
  BleSerial asSerial({
    Uuid? service,
    Uuid? writeCharacteristic,
    Uuid? notifyCharacteristic,
    bool writeWithoutResponse = true,
  }) => BleSerial(
    this,
    service: service ?? Uuid.nordicUartService,
    writeCharacteristic: writeCharacteristic ?? Uuid.nordicUartRx,
    notifyCharacteristic: notifyCharacteristic ?? Uuid.nordicUartTx,
    writeWithoutResponse: writeWithoutResponse,
  );
}
