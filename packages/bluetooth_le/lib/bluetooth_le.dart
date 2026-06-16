/// Cross-platform Bluetooth Low Energy (GATT) for Dart and Flutter, with a
/// GATT-as-serial channel.
///
/// One package, usable from a pure-Dart CLI and from Flutter apps, on Windows,
/// macOS, Linux, Android and iOS. See [BleCentral] to get started, and
/// [BleConnection.asSerial] for a UART-style byte stream.
library;

export 'src/ble_central_base.dart' show BleCentral;
export 'src/connection.dart' show BleConnection;
export 'src/serial.dart' show BleSerial;
export 'src/exceptions.dart';
export 'src/logging.dart' show BleLoggers;
export 'src/models/ble_characteristic.dart' show BleCharacteristic;
export 'src/models/ble_device.dart' show BleDevice;
export 'src/models/ble_service.dart' show BleService;
export 'src/models/device_id.dart' show DeviceId;
export 'src/models/enums.dart'
    show BluetoothAdapterState, BleConnectionState, CharacteristicProperty;
export 'src/models/scan_result.dart' show BleScanResult;
export 'src/models/uuid.dart' show Uuid;

/// Advanced: implement a custom backend or inject a fake in tests.
export 'src/platform/platform_interface.dart'
    show BleCentralPlatform, GattConnection;
