// C ABI for the Apple (macOS + iOS) CoreBluetooth BLE backend.
//
// CoreBluetooth is identical on macOS and iOS, so a single source serves both
// (the native-assets hook compiles it for each with the CoreBluetooth +
// Foundation frameworks). All Objective-C/CoreBluetooth complexity (the central
// manager, its serial dispatch queue, delegates) lives behind this header.
// Callbacks are plain C function pointers driven from Dart via
// NativeCallable.listener (thread-safe delivery to the Dart isolate).
//
// Ownership: any char*/uint8_t* handed to a callback or returned by a function
// is malloc'd and must be released by the caller with ble_free().

#ifndef BLUETOOTH_LE_H
#define BLUETOOTH_LE_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

// Adapter power/authorization state, mirroring BluetoothAdapterState on Dart.
typedef enum {
  BLE_ADAPTER_UNKNOWN = 0,
  BLE_ADAPTER_UNAVAILABLE = 1,
  BLE_ADAPTER_UNAUTHORIZED = 2,
  BLE_ADAPTER_OFF = 3,
  BLE_ADAPTER_ON = 5, // matches the Dart enum index for `on`
} ble_adapter_state_t;

// Callback typedefs. `token`/`req_id` correlate events to Dart-side objects.
typedef void (*ble_scan_cb)(int64_t scan_token, const char *peripheral_json);
typedef void (*ble_state_cb)(int64_t conn_token, int32_t state);
typedef void (*ble_op_cb)(int64_t req_id, int32_t status, const char *json,
                          const uint8_t *data, int32_t len);
typedef void (*ble_notify_cb)(int64_t conn_token, const char *characteristic,
                              const uint8_t *data, int32_t len);

// Frees memory returned by this library (JSON strings, copied buffers).
void ble_free(void *ptr);

// Registers the Dart callbacks and initialises the central manager. Call once.
void ble_register(ble_scan_cb scan, ble_state_cb state, ble_op_cb op,
                  ble_notify_cb notify);

// Returns the local adapter state.
int32_t ble_adapter_state(void);

// Starts scanning. `service_uuids_csv` filters to those services (comma-
// separated 16/128-bit UUID strings) or may be NULL/empty for all devices.
// `scan_cb` fires per sighting with a malloc'd JSON object:
//   {id,name?,rssi?,connectable,serviceUuids?,manufacturerData?,serviceData?}
// Returns 0 on success.
int32_t ble_start_scan(int64_t scan_token, const char *service_uuids_csv);

// Stops any in-progress scan.
void ble_stop_scan(void);

// Connects to the peripheral with `peripheral_id` (a CBPeripheral identifier
// from a prior sighting). `state_cb` reports connect/disconnect on `conn_token`.
// Returns 0 if the connect was initiated, or -1 if the peripheral is unknown
// (scan first). `conn_token` is the caller-assigned handle for later ops.
int32_t ble_connect(int64_t conn_token, const char *peripheral_id);

// Disconnects the connection identified by `conn_token`.
void ble_disconnect(int64_t conn_token);

// Discovers services + characteristics on `conn_token`. `op_cb` fires with
// `req_id` and a malloc'd JSON array
//   [{uuid, characteristics:[{uuid, properties:[...]}]}]
// (status 0), or status != 0 on error.
void ble_discover_services(int64_t req_id, int64_t conn_token);

// Reads a characteristic. `op_cb` fires with `req_id` and the value in
// data/len (status 0), or status != 0 on error.
void ble_read(int64_t req_id, int64_t conn_token, const char *service,
              const char *characteristic);

// Writes `len` bytes to a characteristic. With `without_response`, fires `op_cb`
// (status 0) immediately; otherwise after the acknowledged write completes.
void ble_write(int64_t req_id, int64_t conn_token, const char *service,
               const char *characteristic, const uint8_t *data, int32_t len,
               int32_t without_response);

// Enables/disables notifications on a characteristic. While enabled, pushed
// values arrive via `notify_cb` with characteristic = "service|char" (canonical
// lowercase 128-bit UUIDs).
void ble_subscribe(int64_t conn_token, const char *service,
                   const char *characteristic, int32_t enable);

// Returns the usable ATT MTU (max write payload + 3) for the connection.
int32_t ble_max_write_len(int64_t conn_token, int32_t without_response);

#if defined(__cplusplus)
}
#endif

#endif // BLUETOOTH_LE_H
