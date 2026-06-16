// Apple (macOS + iOS) BLE backend implementing bluetooth_le.h on top of
// CoreBluetooth. Compiled from source by the native-assets build hook (no
// committed binary) for pure-Dart CLI use and Flutter apps.
//
// CoreBluetooth is delegate-driven; the central manager runs on a dedicated
// serial dispatch queue, so all framework callbacks arrive there and framework
// calls are dispatched onto it. Events are forwarded to Dart through the
// registered C callback pointers (NativeCallable.listener on the Dart side).
//
// Built incrementally: adapter state, scanning, and connect + service discovery
// are wired; read/write/subscribe land next.

#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>

#import "bluetooth_le.h"

static ble_scan_cb g_scan;
static ble_state_cb g_state;
static ble_op_cb g_op;
static ble_notify_cb g_notify;

// malloc a NUL-terminated copy of an NSData's bytes (caller frees via ble_free).
static char *copy_data(NSData *data) {
  if (!data) return NULL;
  char *out = malloc(data.length + 1);
  if (!out) return NULL;
  memcpy(out, data.bytes, data.length);
  out[data.length] = '\0';
  return out;
}

static NSString *hex_of(NSData *d) {
  const uint8_t *b = d.bytes;
  NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
  for (NSUInteger i = 0; i < d.length; i++) {
    [s appendFormat:@"%02x", b[i]];
  }
  return s;
}

static NSArray<NSString *> *property_names(CBCharacteristicProperties p) {
  NSMutableArray<NSString *> *a = [NSMutableArray array];
  if (p & CBCharacteristicPropertyRead) [a addObject:@"read"];
  if (p & CBCharacteristicPropertyWrite) [a addObject:@"write"];
  if (p & CBCharacteristicPropertyWriteWithoutResponse)
    [a addObject:@"writeWithoutResponse"];
  if (p & CBCharacteristicPropertyNotify) [a addObject:@"notify"];
  if (p & CBCharacteristicPropertyIndicate) [a addObject:@"indicate"];
  return a;
}

#pragma mark - Per-peripheral delegate

@interface BLEPeripheral : NSObject <CBPeripheralDelegate>
@property(nonatomic) int64_t token;
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic) int64_t discoverReqId;
@property(nonatomic) NSUInteger pendingChars;
- (void)emitServices;
@end

@implementation BLEPeripheral

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverServices:(NSError *)error {
  if (error) {
    if (g_op) g_op(self.discoverReqId, -1, NULL, NULL, 0);
    return;
  }
  self.pendingChars = peripheral.services.count;
  if (self.pendingChars == 0) {
    [self emitServices];
    return;
  }
  for (CBService *s in peripheral.services) {
    [peripheral discoverCharacteristics:nil forService:s];
  }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverCharacteristicsForService:(CBService *)service
                                   error:(NSError *)error {
  (void)service;
  (void)error;
  if (self.pendingChars > 0) self.pendingChars--;
  if (self.pendingChars == 0) [self emitServices];
}

- (void)emitServices {
  NSMutableArray *services = [NSMutableArray array];
  for (CBService *s in self.peripheral.services) {
    NSMutableArray *chars = [NSMutableArray array];
    for (CBCharacteristic *ch in s.characteristics) {
      [chars addObject:@{
        @"uuid" : ch.UUID.UUIDString,
        @"properties" : property_names(ch.properties),
      }];
    }
    [services
        addObject:@{@"uuid" : s.UUID.UUIDString, @"characteristics" : chars}];
  }
  NSData *jd = [NSJSONSerialization dataWithJSONObject:services
                                              options:0
                                                error:nil];
  if (jd && g_op) {
    char *out = copy_data(jd);
    if (out) g_op(self.discoverReqId, 0, out, NULL, 0);
  }
}

@end

#pragma mark - Central (owns the CBCentralManager + its serial queue)

@interface BLECentral : NSObject <CBCentralManagerDelegate>
@property(nonatomic, strong) CBCentralManager *manager;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, CBPeripheral *> *peripherals;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, BLEPeripheral *> *connections;
@property(nonatomic, strong) NSArray<CBUUID *> *scanFilter;
@property(nonatomic) int64_t scanToken;
@property(nonatomic) BOOL wantScan;
@property(nonatomic) BOOL scanning;
+ (instancetype)shared;
- (BLEPeripheral *)wrapperForPeripheral:(CBPeripheral *)p;
@end

@implementation BLECentral

+ (instancetype)shared {
  static BLECentral *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [BLECentral new];
    s.peripherals = [NSMutableDictionary dictionary];
    s.connections = [NSMutableDictionary dictionary];
    s.queue = dispatch_queue_create("bluetooth_le.cb", DISPATCH_QUEUE_SERIAL);
    s.manager = [[CBCentralManager alloc] initWithDelegate:s queue:s.queue];
  });
  return s;
}

- (BLEPeripheral *)wrapperForPeripheral:(CBPeripheral *)p {
  for (BLEPeripheral *w in self.connections.allValues) {
    if (w.peripheral == p) return w;
  }
  return nil;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  if (central.state == CBManagerStatePoweredOn && self.wantScan &&
      !self.scanning) {
    self.scanning = YES;
    [central scanForPeripheralsWithServices:self.scanFilter options:nil];
  }
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary<NSString *, id> *)adv
                     RSSI:(NSNumber *)rssi {
  (void)central;
  if (!g_scan) return;
  NSString *uuid = peripheral.identifier.UUIDString;
  self.peripherals[uuid] = peripheral; // retain so we can connect later

  NSMutableDictionary *j = [NSMutableDictionary dictionary];
  j[@"id"] = uuid;
  NSString *name = adv[CBAdvertisementDataLocalNameKey] ?: peripheral.name;
  if (name) j[@"name"] = name;
  if (rssi) j[@"rssi"] = rssi;
  NSNumber *connectable = adv[CBAdvertisementDataIsConnectable];
  j[@"connectable"] = @(connectable ? connectable.boolValue : YES);

  NSArray<CBUUID *> *services = adv[CBAdvertisementDataServiceUUIDsKey];
  if (services) {
    NSMutableArray *a = [NSMutableArray array];
    for (CBUUID *u in services) {
      [a addObject:u.UUIDString];
    }
    j[@"serviceUuids"] = a;
  }

  NSData *mfg = adv[CBAdvertisementDataManufacturerDataKey];
  if (mfg && mfg.length >= 2) {
    const uint8_t *b = mfg.bytes;
    int company = b[0] | (b[1] << 8);
    NSData *payload = [mfg subdataWithRange:NSMakeRange(2, mfg.length - 2)];
    j[@"manufacturerData"] = @{[@(company) stringValue] : hex_of(payload)};
  }

  NSDictionary<CBUUID *, NSData *> *sd = adv[CBAdvertisementDataServiceDataKey];
  if (sd) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    [sd enumerateKeysAndObjectsUsingBlock:^(CBUUID *k, NSData *v, BOOL *stop) {
      (void)stop;
      m[k.UUIDString] = hex_of(v);
    }];
    j[@"serviceData"] = m;
  }

  NSData *jd = [NSJSONSerialization dataWithJSONObject:j options:0 error:nil];
  if (jd) {
    char *out = copy_data(jd);
    if (out) g_scan(self.scanToken, out);
  }
}

- (void)centralManager:(CBCentralManager *)central
    didConnectPeripheral:(CBPeripheral *)peripheral {
  (void)central;
  BLEPeripheral *w = [self wrapperForPeripheral:peripheral];
  if (w && g_state) g_state(w.token, 2 /* connected */);
}

- (void)centralManager:(CBCentralManager *)central
    didFailToConnectPeripheral:(CBPeripheral *)peripheral
                         error:(NSError *)error {
  (void)central;
  (void)error;
  BLEPeripheral *w = [self wrapperForPeripheral:peripheral];
  if (w) {
    if (g_state) g_state(w.token, 0 /* disconnected */);
    [self.connections removeObjectForKey:@(w.token)];
  }
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral
                      error:(NSError *)error {
  (void)central;
  (void)error;
  BLEPeripheral *w = [self wrapperForPeripheral:peripheral];
  if (w) {
    if (g_state) g_state(w.token, 0 /* disconnected */);
    [self.connections removeObjectForKey:@(w.token)];
  }
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
  (void)[BLECentral shared];
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

int32_t ble_start_scan(int64_t scan_token, const char *service_uuids_csv) {
  BLECentral *c = [BLECentral shared];
  NSMutableArray<CBUUID *> *filter = nil;
  if (service_uuids_csv && service_uuids_csv[0]) {
    filter = [NSMutableArray array];
    NSArray<NSString *> *parts =
        [@(service_uuids_csv) componentsSeparatedByString:@","];
    for (NSString *raw in parts) {
      NSString *t = [raw stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
      if (t.length == 0) continue;
      @try {
        [filter addObject:[CBUUID UUIDWithString:t]];
      } @catch (__unused id e) {
      }
    }
  }
  dispatch_async(c.queue, ^{
    c.scanToken = scan_token;
    c.scanFilter = filter;
    c.wantScan = YES;
    [c.peripherals removeAllObjects];
    if (c.manager.state == CBManagerStatePoweredOn) {
      c.scanning = YES;
      [c.manager scanForPeripheralsWithServices:filter options:nil];
    }
  });
  return 0;
}

void ble_stop_scan(void) {
  BLECentral *c = [BLECentral shared];
  dispatch_async(c.queue, ^{
    c.wantScan = NO;
    c.scanning = NO;
    [c.manager stopScan];
  });
}

int32_t ble_connect(int64_t conn_token, const char *peripheral_id) {
  if (!peripheral_id) return -1;
  BLECentral *c = [BLECentral shared];
  NSString *pid = @(peripheral_id);
  CBPeripheral *p = c.peripherals[pid];
  if (!p) {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:pid];
    if (uuid) {
      NSArray<CBPeripheral *> *known =
          [c.manager retrievePeripheralsWithIdentifiers:@[ uuid ]];
      if (known.count) {
        p = known.firstObject;
        c.peripherals[pid] = p;
      }
    }
  }
  if (!p) return -1; // unknown peripheral -> Dart throws DeviceNotFound

  BLEPeripheral *w = [BLEPeripheral new];
  w.token = conn_token;
  w.peripheral = p;
  p.delegate = w;
  c.connections[@(conn_token)] = w;
  dispatch_async(c.queue, ^{
    [c.manager connectPeripheral:p options:nil];
  });
  return 0;
}

void ble_disconnect(int64_t conn_token) {
  BLECentral *c = [BLECentral shared];
  BLEPeripheral *w = c.connections[@(conn_token)];
  if (!w) return;
  dispatch_async(c.queue, ^{
    [c.manager cancelPeripheralConnection:w.peripheral];
  });
}

void ble_discover_services(int64_t req_id, int64_t conn_token) {
  BLECentral *c = [BLECentral shared];
  BLEPeripheral *w = c.connections[@(conn_token)];
  if (!w) {
    if (g_op) g_op(req_id, -1, NULL, NULL, 0);
    return;
  }
  w.discoverReqId = req_id;
  dispatch_async(c.queue, ^{
    [w.peripheral discoverServices:nil];
  });
}
