/// Cross-platform Bluetooth Classic (RFCOMM serial) for Dart and Flutter.
///
/// One package, usable from a pure-Dart CLI and from Flutter apps, on Windows,
/// macOS, Linux, Android and iOS. See [BluetoothClassic] to get started.
library;

export 'src/bluetooth_classic_base.dart' show BluetoothClassic;
export 'src/connection.dart' show BluetoothConnection;
export 'src/exceptions.dart';
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
    show BluetoothClassicPlatform, RfcommTransport;
