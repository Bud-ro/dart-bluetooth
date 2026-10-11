// C ABI for the iOS Bluetooth Classic backend (ExternalAccessory / EASession).
//
// IMPORTANT: iOS only exposes Bluetooth Classic to apps through the MFi program.
// EAAccessoryManager surfaces an accessory ONLY if it contains Apple's MFi
// authentication coprocessor and the app declares the matching protocol string
// in UISupportedExternalAccessoryProtocols (Info.plist). A non-MFi device will
// never appear here — use BLE for those. The Dart layer turns "no accessory"
// into a BluetoothUnsupportedException pointing at the BLE package.

#ifndef BLUETOOTH_CLASSIC_IOS_H
#define BLUETOOTH_CLASSIC_IOS_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

typedef void (*btc_data_cb)(int64_t token, const uint8_t *data, int32_t len);
typedef void (*btc_state_cb)(int64_t token, int32_t state);

void btc_free(void *ptr);

// Connected MFi accessories as a malloc'd UTF-8 JSON array, or NULL.
// Each: {"id","name","protocols":[..],"manufacturer","modelNumber","serial"}.
char *btc_ea_accessories_json(void);

// Opens an EASession to the accessory whose connectionID matches `accessory_id`,
// using `protocol` (a UISupportedExternalAccessoryProtocols string). If
// `protocol` is empty the accessory's first protocol is used. `data` fires per
// inbound chunk (buffer malloc'd; free via btc_free); `state` on open/close.
// Returns a non-zero handle on success, 0 on failure (incl. non-MFi / no match).
int64_t btc_ea_open(int64_t token, const char *accessory_id,
                    const char *protocol, btc_data_cb data, btc_state_cb state);

// Queues bytes for transmission. Returns 0 on success.
int32_t btc_ea_write(int64_t handle, const uint8_t *data, int32_t len);

// Closes the session. Returns 0 on success.
int32_t btc_ea_close(int64_t handle);

#if defined(__cplusplus)
}
#endif

#endif // BLUETOOTH_CLASSIC_IOS_H
