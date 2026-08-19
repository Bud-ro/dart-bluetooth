# bluetooth_rfcomm CLI example

A pure-Dart command-line demo of `bluetooth_rfcomm` — no Flutter required.

```sh
dart pub get
dart run bin/btc.dart doctor    # adapter state / support check
dart run bin/btc.dart list      # paired devices
dart run bin/btc.dart scan      # discover nearby devices
dart run bin/btc.dart connect <ADDRESS>   # open an RFCOMM connection and echo
dart run bin/btc.dart bench <ADDRESS>     # message-loss bench (see below)
```

## `bench` — message-loss measurement

A known-good reference harness for quantifying message loss without trusting
your app's own framing. Run `bench --help` for the full frame spec (works on
any machine, no adapter needed).

```sh
# Request/response loss: device must echo every byte back VERBATIM.
dart run bin/btc.dart bench <ADDRESS> --count 1000 --interval 100 --size 20

# Send-side integrity only (no echo required on the device):
dart run bin/btc.dart bench <ADDRESS> --mode txonly --count 5000 --interval 10
```

Each message is self-framed — magic `0xC0 0xDE`, big-endian uint32 sequence,
uint16 payload length, deterministic payload, CRC16-CCITT (poly `0x1021`,
init `0xFFFF`) — and the receiver reassembles frames from the raw byte
stream, so echoes that bunch into one event or split across events are still
counted correctly. Every sent message is attributed to exactly one bucket:
`ok`, `late` (arrived after `--timeout`, i.e. a stall — not loss), `crc-bad`,
or `missing`. The report also prints RTT percentiles, `rxBytes`/`txBytes`,
the connection's `stats` counters when available, and a verdict attributing
any loss to the send side or beyond the local machine.

On macOS, build and run as a native executable so the IOBluetooth code asset is
compiled by the build hook:

```sh
dart build cli
./build/cli/bin/btc doctor
```

See [`bin/btc.dart`](bin/btc.dart) for the source.
