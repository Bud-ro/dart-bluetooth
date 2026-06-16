/// Cross-platform Bluetooth Classic (RFCOMM serial) for Dart and Flutter.
///
/// One package, usable from a pure-Dart CLI and from Flutter apps, on Windows,
/// macOS, Linux, Android and iOS. See [BluetoothRfcomm] to get started.
library;

export 'src/bluetooth_rfcomm_base.dart' show BluetoothRfcomm;
export 'src/connection.dart' show BluetoothConnection;
export 'src/exceptions.dart';
export 'src/logging.dart' show BluetoothRfcommLoggers;
export 'src/models/bluetooth_device.dart' show BluetoothDevice;
export 'src/models/bluetooth_service.dart' show BluetoothService;
export 'src/models/device_id.dart' show DeviceId;
export 'src/models/discovery_result.dart' show BluetoothDiscoveryResult;
export 'src/models/enums.dart'
    show
        BluetoothAdapterState,
        BluetoothBondState,
        BluetoothDeviceType,
        ConnectionState;
export 'src/models/uuid.dart' show Uuid;

/// Advanced: implement a custom backend or inject a fake in tests.
export 'src/platform/platform_interface.dart'
    show BluetoothRfcommPlatform, RfcommTransport;
