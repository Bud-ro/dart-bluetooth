# bluetooth_le CLI example

A pure-Dart command-line demo of `bluetooth_le` — no Flutter required.

```sh
dart pub get
dart run bin/ble.dart doctor                 # adapter state / support check
dart run bin/ble.dart scan                   # scan for advertising devices
dart run bin/ble.dart scan --service 6e400001-b5a3-f393-e0a9-e50e24dcca9e
dart run bin/ble.dart connect <DEVICE-ID>    # open as a serial link (Nordic UART)
```

`<DEVICE-ID>` is what `scan` prints — a MAC address on Linux/Windows, or an
opaque identifier on macOS. `connect` discovers services, treats a write+notify
characteristic pair as a serial channel (Nordic UART by default; override with
`--service/--write/--notify`), prints everything received, and sends each line
you type.

On macOS, build and run as a native executable so the CoreBluetooth code asset is
compiled by the build hook:

```sh
dart build cli
./build/cli/bin/ble doctor
```

See [`bin/ble.dart`](bin/ble.dart) for the source.
