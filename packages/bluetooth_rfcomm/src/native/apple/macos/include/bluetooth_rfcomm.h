// C ABI for the macOS Bluetooth Classic (IOBluetooth) backend.
//
// This header is the entire surface Dart sees via dart:ffi. All Objective-C and
// IOBluetooth complexity (delegates, the CFRunLoop worker thread) lives behind
// it in bluetooth_rfcomm.m. Callbacks are plain C function pointers so they can
// be driven from Dart with NativeCallable.listener (thread-safe delivery to the
// Dart isolate).
//
// Ownership: any `char*`/`uint8_t*` handed to a callback or returned by a
// function is malloc'd and must be released by the caller with btc_free().

#ifndef BLUETOOTH_CLASSIC_H
#define BLUETOOTH_CLASSIC_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

// Adapter power state, mirroring BluetoothAdapterState on the Dart side.
typedef enum {
  BTC_ADAPTER_UNKNOWN = 0,
  BTC_ADAPTER_UNAVAILABLE = 1,
  BTC_ADAPTER_UNAUTHORIZED = 2,
  BTC_ADAPTER_OFF = 3,
  BTC_ADAPTER_ON = 5, // matches Dart enum index for `on`
} btc_adapter_state_t;

// RFCOMM channel connection state.
typedef enum {
  BTC_CONN_DISCONNECTED = 0,
  BTC_CONN_CONNECTING = 1,
  BTC_CONN_CONNECTED = 2,
  BTC_CONN_DISCONNECTING = 3,
} btc_conn_state_t;

// Callback typedefs. `token` correlates the event to a Dart-side object.
typedef void (*btc_found_cb)(int64_t token, const char *device_json);
typedef void (*btc_inquiry_done_cb)(int64_t token, int32_t aborted);
typedef void (*btc_data_cb)(int64_t token, const uint8_t *data, int32_t len);
typedef void (*btc_state_cb)(int64_t token, int32_t state);

// Frees memory returned by this library (JSON strings, copied data buffers).
void btc_free(void *ptr);

// Returns the local adapter state.
int32_t btc_adapter_state(void);

// Returns a malloc'd UTF-8 JSON array of paired devices, or NULL on error.
// Each element: {"address","name","classOfDevice","connected","paired"}.
char *btc_paired_devices_json(void);

// Resolves the RFCOMM channel for `uuid` on `address` via the device's SDP
// records, issuing a fresh SDP query (bounded, ~12s) when none are cached.
// Returns the channel (1..30) or -1 if not found.
int32_t btc_sdp_channel(const char *address, const char *uuid);

// Starts a device inquiry. `found` fires per sighting (device_json malloc'd);
// `done` fires when the inquiry ends. Returns 0 on success.
int32_t btc_start_discovery(int64_t token, btc_found_cb found,
                            btc_inquiry_done_cb done);

// Stops any in-progress inquiry. Returns 0 on success.
int32_t btc_stop_discovery(void);

// Opens an RFCOMM channel to `address`. If `channel` <= 0, it is resolved from
// SDP for `uuid`. `data` fires per inbound chunk (buffer malloc'd, caller frees
// via btc_free); `state` fires on connect/disconnect. On success returns a
// non-zero opaque handle; on failure returns 0.
int64_t btc_rfcomm_open(int64_t token, const char *address, int32_t channel,
                        const char *uuid, btc_data_cb data, btc_state_cb state);

// Accepts `len` bytes for transmission on `handle`. Returns 0 on acceptance,
// -2 if the buffered backlog cap (4 MiB) would be exceeded. Never blocks the
// caller: bytes are written on the worker thread via blocking writeSync (the
// field-proven engine; the completion-driven async queue with transient-error
// retry ships separately). A write that finds the channel already torn down
// counts its bytes into txDroppedBytes — never a silent drop; the Dart layer
// fail-fasts on its own closed flag before calling. A mid-stream write error
// surfaces as a disconnect (state callback) with the untransmitted remainder
// counted.
int32_t btc_rfcomm_write(int64_t handle, const uint8_t *data, int32_t len);

// The RFCOMM channel MTU (largest single write payload) negotiated for
// `handle`, cached when the channel finished opening. Returns 0 if unknown or
// the handle is closed.
int32_t btc_rfcomm_mtu(int64_t handle);

// Bytes accepted by btc_rfcomm_write for `handle` but not yet handed to the
// OS. Decremented per MTU-sized chunk as writeSync completes, so during a
// large stalled write it reflects the true unsent remainder. 0 for an
// unknown/closed handle. Never blocks (lock-guarded gauge; no worker hop).
int64_t btc_rfcomm_pending(int64_t handle);

// Returns a malloc'd UTF-8 JSON object of monotonic per-channel transfer
// counters for `handle` (caller frees via btc_free), with exactly the fields:
//   {"txEnqueuedBytes","txSubmittedBytes","txCompletedBytes",
//    "txRetriedChunks","txFailedChunks","txDroppedBytes",
//    "rxEvents","rxBytes","rxDroppedEvents"}
// all int64, counted at the hop each name implies: enqueued = accepted by
// btc_rfcomm_write; submitted = offered to writeSync; completed = writeSync
// returned success; retried = always 0 in this engine (the async-queue
// rework's counter, kept for a stable JSON shape); dropped = discarded for any
// reason, including a teardown purging the queue; rxEvents/rxBytes = what the
// stack delivered natively; rxDroppedEvents = deliveries whose payload was
// discarded before reaching Dart (e.g. allocation failure). Counters survive
// disconnect — they remain readable after the channel is torn down (until
// btc_reset) so post-mortem loss stays attributable. For an unknown handle
// returns {"error":"unknown handle"}.
char *btc_rfcomm_stats_json(int64_t handle);

// Closes `handle`. Returns 0 on success.
int32_t btc_rfcomm_close(int64_t handle);

// Quiesces the backend: finishes any in-progress inquiry (firing its done
// callback) and tears down every open RFCOMM channel delegate-safely, clearing
// the handle map. The Dart layer calls this at construction (hot-restart
// recovery: stop every native event source left behind by a dead isolate
// BEFORE new callbacks are registered) and at dispose (so nothing native ever
// invokes a torn-down callback trampoline afterwards).
void btc_reset(void);

#if defined(__cplusplus)
}
#endif

#endif // BLUETOOTH_CLASSIC_H
