/// Bluetooth radio class of a remote device.
///
/// Mirrors the `classic` / `le` / `dual` distinction exposed by every platform
/// so callers can filter discovery results. This package only operates on the
/// BR/EDR (Classic) capability of a device; a [dual] device works fine.
enum BluetoothDeviceType {
  unknown,
  classic,
  le,
  dual,
}

/// Pairing / bonding state of a remote device.
///
/// "Bonded" means the OS has stored link keys for the device. On most platforms
/// a Classic RFCOMM connection requires the device to be bonded first.
enum BluetoothBondState {
  unknown,
  none,
  bonding,
  bonded;

  /// Whether the device currently has stored link keys.
  bool get isBonded => this == BluetoothBondState.bonded;
}

/// State of the local Bluetooth adapter (radio).
///
/// Richer than the typical on/off pair: [unauthorized] surfaces the macOS / iOS
/// privacy (TCC) state where the radio works but the app lacks permission, and
/// [unavailable] covers machines with no Bluetooth radio at all.
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

/// Lifecycle state of a single [BluetoothConnection].
enum ConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting;

  bool get isConnected => this == ConnectionState.connected;
}
