/// Bluetooth radio class of a remote device.
///
/// Mirrors the `classic` / `le` / `dual` distinction exposed by every platform
/// so callers can filter discovery results. This package only operates on the
/// BR/EDR (Classic) capability of a device; a [dual] device works fine.
enum BluetoothDeviceType {
  /// Type could not be determined.
  unknown,

  /// Bluetooth Classic (BR/EDR) only.
  classic,

  /// Bluetooth Low Energy only.
  le,

  /// Supports both Classic and LE.
  dual,
}

/// Pairing / bonding state of a remote device.
///
/// "Bonded" means the OS has stored link keys for the device. On most platforms
/// a Classic RFCOMM connection requires the device to be bonded first.
enum BluetoothBondState {
  /// Bond state could not be determined.
  unknown,

  /// Not bonded.
  none,

  /// Bonding is in progress.
  bonding,

  /// Bonded — the OS has stored link keys.
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
///
/// A [BluetoothConnection] only exists after [connect] resolves, so it starts at
/// [connected]; [connecting] is part of the model but not emitted by a live
/// connection's `stateChanges` (which in practice emits only the terminal
/// [disconnected]).
enum ConnectionState {
  /// Not connected (initial, or after the link dropped / was closed).
  disconnected,

  /// A connection attempt is in progress.
  connecting,

  /// Connected and ready for I/O.
  connected,

  /// A graceful shutdown is in progress.
  disconnecting;

  /// Whether the connection is currently usable.
  bool get isConnected => this == ConnectionState.connected;
}
