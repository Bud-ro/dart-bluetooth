# bluetooth_rfcomm CLI example

A pure-Dart command-line demo of `bluetooth_rfcomm` — no Flutter required.

```sh
dart pub get
dart run bin/btc.dart doctor    # adapter state / support check
dart run bin/btc.dart list      # paired devices
dart run bin/btc.dart scan      # discover nearby devices
dart run bin/btc.dart connect <ADDRESS>   # open an RFCOMM connection and echo
```
