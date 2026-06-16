// Apple (macOS + iOS) BLE backend implementing bluetooth_le.h on top of
// CoreBluetooth. Compiled from source by the native-assets build hook (no
// committed binary) for pure-Dart CLI use and Flutter apps.
//
// CoreBluetooth is delegate-driven; the central manager runs on a dedicated
// serial dispatch queue, so all framework callbacks arrive there. Events are
// forwarded to Dart through the registered C callback pointers (which on the
// Dart side are NativeCallable.listener functions, thread-safe).
//
// NOTE: built incrementally — this revision implements adapter state and the
// callback registration; scan/connect/GATT land in subsequent revisions.

#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>

#import "bluetooth_le.h"

static ble_scan_cb g_scan;
static ble_state_cb g_state;
static ble_op_cb g_op;
static ble_notify_cb g_notify;

#pragma mark - Central (owns the CBCentralManager + its serial queue)

@interface BLECentral : NSObject <CBCentralManagerDelegate>
@property(nonatomic, strong) CBCentralManager *manager;
+ (instancetype)shared;
@end

@implementation BLECentral

+ (instancetype)shared {
  static BLECentral *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [BLECentral new];
    dispatch_queue_t q =
        dispatch_queue_create("bluetooth_le.cb", DISPATCH_QUEUE_SERIAL);
    s.manager = [[CBCentralManager alloc] initWithDelegate:s queue:q];
  });
  return s;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  (void)central; // adapter-state change bridging lands with the scan revision
}

@end

#pragma mark - C ABI

void ble_free(void *ptr) {
  if (ptr) free(ptr);
}

void ble_register(ble_scan_cb scan, ble_state_cb state, ble_op_cb op,
                  ble_notify_cb notify) {
  g_scan = scan;
  g_state = state;
  g_op = op;
  g_notify = notify;
  (void)[BLECentral shared]; // initialise the manager on its queue
}

int32_t ble_adapter_state(void) {
  switch ([BLECentral shared].manager.state) {
    case CBManagerStateUnsupported:
      return BLE_ADAPTER_UNAVAILABLE;
    case CBManagerStateUnauthorized:
      return BLE_ADAPTER_UNAUTHORIZED;
    case CBManagerStatePoweredOff:
      return BLE_ADAPTER_OFF;
    case CBManagerStatePoweredOn:
      return BLE_ADAPTER_ON;
    case CBManagerStateUnknown:
    case CBManagerStateResetting:
    default:
      return BLE_ADAPTER_UNKNOWN;
  }
}
