/// State of the local Bluetooth adapter (radio).
enum BluetoothAdapterState {
  /// State could not be determined yet.
  unknown,

  /// No Bluetooth radio present on this machine.
  unavailable,

  /// Radio present but the app is not authorized to use it (macOS/iOS privacy).
  unauthorized,

  /// Radio is powered off.
  off,

  /// Radio is powering on.
  turningOn,

  /// Radio is powered on and usable.
  on,

  /// Radio is powering off.
  turningOff;

  /// Whether the adapter is powered on and usable right now.
  bool get isOn => this == BluetoothAdapterState.on;
}

/// Lifecycle state of a single GATT [BleConnection].
enum BleConnectionState {
  /// Not connected (initial, or after the link dropped / was closed).
  disconnected,

  /// A connection attempt is in progress.
  connecting,

  /// Connected and ready for GATT operations.
  connected,

  /// A graceful shutdown is in progress.
  disconnecting;

  /// Whether the connection is currently usable.
  bool get isConnected => this == BleConnectionState.connected;
}

/// A GATT characteristic property (what operations it supports).
enum CharacteristicProperty {
  /// Supports `read`.
  read,

  /// Supports `write` with a response (acknowledged).
  write,

  /// Supports `write` without a response (fire-and-forget, higher throughput).
  writeWithoutResponse,

  /// Supports `notify` (peripheral pushes values; no acknowledgement).
  notify,

  /// Supports `indicate` (peripheral pushes values; acknowledged).
  indicate,
}
