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

#if defined(__cplusplus)
}
#endif

#endif // BLUETOOTH_LE_H
