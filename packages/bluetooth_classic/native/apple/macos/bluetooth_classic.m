// macOS Bluetooth Classic backend implementing bluetooth_classic.h on top of
// IOBluetooth. Compiled from source (no committed binary) by the native-assets
// build hook for pure-Dart CLI use, and by the SPM plugin for Flutter apps.
//
// IOBluetooth is delegate- and run-loop-driven, so all framework calls run on a
// dedicated worker thread that owns a CFRunLoop. Inbound data and state changes
// are forwarded to Dart through the C callback pointers, which on the Dart side
// are NativeCallable.listener functions (thread-safe).

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <stdlib.h>
#import <string.h>

#import "bluetooth_classic.h"

#pragma mark - Worker thread (owns a CFRunLoop)

@interface BTCWorker : NSObject
@property(nonatomic, strong) NSThread *thread;
@property(nonatomic, strong) NSRunLoop *runLoop;
+ (instancetype)shared;
- (void)runSync:(void (^)(void))block;
- (void)runAsync:(void (^)(void))block;
@end

@implementation BTCWorker {
  dispatch_semaphore_t _ready;
}

+ (instancetype)shared {
  static BTCWorker *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [BTCWorker new];
    [s start];
  });
  return s;
}

- (void)start {
  _ready = dispatch_semaphore_create(0);
  self.thread = [[NSThread alloc] initWithTarget:self
                                        selector:@selector(main)
                                          object:nil];
  self.thread.name = @"bluetooth_classic.worker";
  [self.thread start];
  dispatch_semaphore_wait(_ready, DISPATCH_TIME_FOREVER);
}

- (void)main {
  @autoreleasepool {
    self.runLoop = [NSRunLoop currentRunLoop];
    // Keep the run loop alive with a no-op port source.
    [self.runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
    dispatch_semaphore_signal(_ready);
    while (true) {
      @autoreleasepool {
        [self.runLoop runMode:NSDefaultRunLoopMode
                   beforeDate:[NSDate distantFuture]];
      }
    }
  }
}

- (void)_invoke:(void (^)(void))block {
  @autoreleasepool {
    block();
  }
}

- (void)runAsync:(void (^)(void))block {
  [self performSelector:@selector(_invoke:)
               onThread:self.thread
             withObject:[block copy]
          waitUntilDone:NO];
}

- (void)runSync:(void (^)(void))block {
  if ([NSThread currentThread] == self.thread) {
    block();
    return;
  }
  [self performSelector:@selector(_invoke:)
               onThread:self.thread
             withObject:[block copy]
          waitUntilDone:YES];
}

@end

#pragma mark - Helpers

static char *btc_strdup(NSString *s) {
  if (!s) return NULL;
  const char *utf8 = [s UTF8String];
  if (!utf8) return NULL;
  size_t len = strlen(utf8) + 1;
  char *out = malloc(len);
  memcpy(out, utf8, len);
  return out;
}

static NSString *btc_normalize_address(NSString *addr) {
  return [[addr stringByReplacingOccurrencesOfString:@"-" withString:@":"]
      uppercaseString];
}

static IOBluetoothDevice *btc_device_for(NSString *address) {
  return [IOBluetoothDevice deviceWithAddressString:address];
}

static NSDictionary *btc_device_dict(IOBluetoothDevice *d) {
  return @{
    @"address" : btc_normalize_address([d addressString] ?: @""),
    @"name" : ([d name] ?: [NSNull null]),
    @"classOfDevice" : @([d classOfDevice]),
    @"connected" : @([d isConnected]),
  };
}

static char *btc_json(id obj) {
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj
                                                options:0
                                                  error:&err];
  if (!data) return NULL;
  NSString *s = [[NSString alloc] initWithData:data
                                      encoding:NSUTF8StringEncoding];
  return btc_strdup(s);
}

#pragma mark - Inquiry delegate

@interface BTCInquiry : NSObject <IOBluetoothDeviceInquiryDelegate>
@property(nonatomic) int64_t token;
@property(nonatomic) btc_found_cb found;
@property(nonatomic) btc_inquiry_done_cb done;
@property(nonatomic, strong) IOBluetoothDeviceInquiry *inquiry;
@end

@implementation BTCInquiry
- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender
                          device:(IOBluetoothDevice *)device {
  if (self.found) {
    char *json = btc_json(btc_device_dict(device));
    if (json) self.found(self.token, json);
  }
}
- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender
                        error:(IOReturn)error
                      aborted:(BOOL)aborted {
  if (self.done) self.done(self.token, aborted ? 1 : 0);
}
@end

static BTCInquiry *g_inquiry = nil;

#pragma mark - RFCOMM channel delegate

@interface BTCChannel : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property(nonatomic) int64_t token;
@property(nonatomic) btc_data_cb data;
@property(nonatomic) btc_state_cb state;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
@end

@implementation BTCChannel
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)rfcommChannel
                     data:(void *)dataPointer
                   length:(size_t)dataLength {
  if (self.data && dataLength > 0) {
    uint8_t *copy = malloc(dataLength);
    memcpy(copy, dataPointer, dataLength);
    self.data(self.token, copy, (int32_t)dataLength);
  }
}
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)rfcommChannel
                           status:(IOReturn)error {
  if (self.state) {
    self.state(self.token,
               error == kIOReturnSuccess ? BTC_CONN_CONNECTED
                                         : BTC_CONN_DISCONNECTED);
  }
}
- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)rfcommChannel {
  if (self.state) self.state(self.token, BTC_CONN_DISCONNECTED);
}
@end

static NSMutableDictionary<NSNumber *, BTCChannel *> *g_channels(void) {
  static NSMutableDictionary *d;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    d = [NSMutableDictionary new];
  });
  return d;
}

static int64_t g_next_handle = 1;

#pragma mark - C ABI

void btc_free(void *ptr) {
  if (ptr) free(ptr);
}

int32_t btc_adapter_state(void) {
  __block int32_t result = BTC_ADAPTER_UNKNOWN;
  [[BTCWorker shared] runSync:^{
    IOBluetoothHostController *hc = [IOBluetoothHostController defaultController];
    if (!hc) {
      result = BTC_ADAPTER_UNAVAILABLE;
      return;
    }
    result = ([hc powerState] == kBluetoothHCIPowerStateON) ? BTC_ADAPTER_ON
                                                            : BTC_ADAPTER_OFF;
  }];
  return result;
}

char *btc_paired_devices_json(void) {
  __block char *result = NULL;
  [[BTCWorker shared] runSync:^{
    NSArray *paired = [IOBluetoothDevice pairedDevices];
    NSMutableArray *arr = [NSMutableArray new];
    for (IOBluetoothDevice *d in paired) {
      [arr addObject:btc_device_dict(d)];
    }
    result = btc_json(arr);
  }];
  return result;
}

int32_t btc_sdp_channel(const char *address, const char *uuid) {
  __block int32_t result = -1;
  NSString *addr = btc_normalize_address(@(address));
  NSString *uuidStr = @(uuid);
  [[BTCWorker shared] runSync:^{
    IOBluetoothDevice *d = btc_device_for(addr);
    if (!d) return;
    IOBluetoothSDPUUID *sdpUuid =
        [IOBluetoothSDPUUID uuidWithBytes:NULL length:0]; // replaced below
    // Build a 128-bit SDP UUID from the canonical string.
    NSString *hex = [uuidStr stringByReplacingOccurrencesOfString:@"-"
                                                       withString:@""];
    uint8_t bytes[16];
    for (int i = 0; i < 16; i++) {
      NSString *b = [hex substringWithRange:NSMakeRange(i * 2, 2)];
      bytes[i] = (uint8_t)strtol([b UTF8String], NULL, 16);
    }
    sdpUuid = [IOBluetoothSDPUUID uuidWithBytes:bytes length:16];
    IOBluetoothSDPServiceRecord *record = [d getServiceRecordForUUID:sdpUuid];
    if (!record) return;
    BluetoothRFCOMMChannelID channelID = 0;
    if ([record getRFCOMMChannelID:&channelID] == kIOReturnSuccess) {
      result = channelID;
    }
  }];
  return result;
}

int32_t btc_start_discovery(int64_t token, btc_found_cb found,
                            btc_inquiry_done_cb done) {
  __block int32_t result = -1;
  [[BTCWorker shared] runSync:^{
    if (g_inquiry) {
      [g_inquiry.inquiry stop];
      g_inquiry = nil;
    }
    BTCInquiry *inq = [BTCInquiry new];
    inq.token = token;
    inq.found = found;
    inq.done = done;
    inq.inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:inq];
    g_inquiry = inq;
    result = ([inq.inquiry start] == kIOReturnSuccess) ? 0 : -1;
  }];
  return result;
}

int32_t btc_stop_discovery(void) {
  [[BTCWorker shared] runSync:^{
    if (g_inquiry) {
      [g_inquiry.inquiry stop];
      g_inquiry = nil;
    }
  }];
  return 0;
}

int64_t btc_rfcomm_open(int64_t token, const char *address, int32_t channel,
                        const char *uuid, btc_data_cb data,
                        btc_state_cb state) {
  __block int64_t handle = 0;
  NSString *addr = btc_normalize_address(@(address));
  NSString *uuidStr = @(uuid);
  [[BTCWorker shared] runSync:^{
    IOBluetoothDevice *d = btc_device_for(addr);
    if (!d) return;
    BluetoothRFCOMMChannelID channelID = channel;
    if (channelID <= 0) {
      int32_t resolved = btc_sdp_channel([addr UTF8String],
                                         [uuidStr UTF8String]);
      if (resolved <= 0) return;
      channelID = resolved;
    }
    BTCChannel *ch = [BTCChannel new];
    ch.token = token;
    ch.data = data;
    ch.state = state;
    IOBluetoothRFCOMMChannel *rf = nil;
    IOReturn rc = [d openRFCOMMChannelAsync:&rf
                             withChannelID:channelID
                                  delegate:ch];
    if (rc != kIOReturnSuccess) return;
    ch.channel = rf;
    handle = g_next_handle++;
    g_channels()[@(handle)] = ch;
  }];
  return handle;
}

int32_t btc_rfcomm_write(int64_t handle, const uint8_t *data, int32_t len) {
  if (len <= 0) return 0;
  // Copy now; the caller's buffer may be freed before the async runs.
  uint8_t *copy = malloc(len);
  memcpy(copy, data, len);
  [[BTCWorker shared] runAsync:^{
    BTCChannel *ch = g_channels()[@(handle)];
    if (ch && ch.channel) {
      [ch.channel writeAsync:copy length:(UInt16)len refcon:NULL];
    }
    free(copy);
  }];
  return 0;
}

int32_t btc_rfcomm_close(int64_t handle) {
  [[BTCWorker shared] runSync:^{
    BTCChannel *ch = g_channels()[@(handle)];
    if (ch) {
      [ch.channel closeChannel];
      [g_channels() removeObjectForKey:@(handle)];
    }
  }];
  return 0;
}
