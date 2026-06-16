// C ABI for the macOS Bluetooth Classic (IOBluetooth) backend.
//
// This header is the entire surface Dart sees via dart:ffi. All Objective-C and
// IOBluetooth complexity (delegates, the CFRunLoop worker thread) lives behind
// it in bluetooth_classic.m. Callbacks are plain C function pointers so they can
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
// Each element: {"address","name","classOfDevice","connected"}.
char *btc_paired_devices_json(void);

// Resolves the RFCOMM channel for `uuid` on `address` via the device's SDP
// records. Returns the channel (1..30) or -1 if not found.
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

// Queues `len` bytes for transmission on `handle`. Returns 0 on success.
// Non-blocking: the write is dispatched to the worker thread.
int32_t btc_rfcomm_write(int64_t handle, const uint8_t *data, int32_t len);

// Closes `handle`. Returns 0 on success.
int32_t btc_rfcomm_close(int64_t handle);

#if defined(__cplusplus)
}
#endif

#endif // BLUETOOTH_CLASSIC_H
