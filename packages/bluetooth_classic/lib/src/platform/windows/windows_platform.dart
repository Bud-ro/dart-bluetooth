import 'dart:async';

import '../../exceptions.dart';
import '../../models/bluetooth_device.dart';
import '../../models/bluetooth_service.dart';
import '../../models/device_id.dart';
import '../../models/discovery_result.dart';
import '../../models/enums.dart';
import '../../models/uuid.dart';
import '../platform_interface.dart';

/// Windows backend over Winsock Bluetooth (`AF_BTH` / `BTHPROTO_RFCOMM`) plus
/// the `BluetoothAPIs` device-enumeration functions.
///
/// Pure Dart via `dart:ffi` to the system `ws2_32.dll` and `bthprops.cpl` —
/// there is no native component to build, so this works identically from a CLI
/// `dart run` and inside a Flutter Windows app. Blocking socket reads run on a
/// worker isolate so the calling isolate never stalls.
///
/// Status: FFI bindings and the recv-isolate are implemented in
/// `windows_ffi.dart` (filled in the Windows iteration). This class wires the
/// public surface; the heavy socket plumbing is added incrementally.
class WindowsBluetoothClassic extends BluetoothClassicPlatform {
  WindowsBluetoothClassic();

  static const _pending = BluetoothUnsupportedException(
    'The Windows Winsock RFCOMM backend is being implemented. The Dart surface '
    'is wired; socket plumbing lands in the Windows iteration.',
  );

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<BluetoothAdapterState> adapterState() async =>
      BluetoothAdapterState.unknown;

  @override
  Stream<BluetoothAdapterState> adapterStateChanges() =>
      Stream<BluetoothAdapterState>.value(BluetoothAdapterState.unknown);

  @override
  Future<void> setAdapterEnabled(bool enabled) async => throw _pending;

  @override
  Future<List<BluetoothDevice>> bondedDevices() async => throw _pending;

  @override
  Stream<BluetoothDiscoveryResult> startDiscovery() =>
      Stream<BluetoothDiscoveryResult>.error(_pending);

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<List<BluetoothService>> discoverServices(
    DeviceId device, {
    Uuid? serviceUuid,
  }) async =>
      throw _pending;

  @override
  Future<RfcommTransport> openRfcomm(
    DeviceId device, {
    int? channel,
    required Uuid serviceUuid,
    Duration? timeout,
  }) async =>
      throw _pending;

  @override
  Stream<ConnectionState> connectionStateChanges(DeviceId device) =>
      const Stream<ConnectionState>.empty();

  @override
  Future<void> pair(DeviceId device) async => throw _pending;

  @override
  Future<void> unpair(DeviceId device) async => throw _pending;
}
