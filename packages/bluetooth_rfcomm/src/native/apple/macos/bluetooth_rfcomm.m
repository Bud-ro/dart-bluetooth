// macOS Bluetooth Classic backend implementing bluetooth_rfcomm.h on top of
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

#import "bluetooth_rfcomm.h"

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
  self.thread.name = @"bluetooth_rfcomm.worker";
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
  if (!out) return NULL;
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
    @"paired" : @([d isPaired]),
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
- (void)inquiryFinished:(BOOL)aborted;
@end

static BTCInquiry *g_inquiry = nil;

@implementation BTCInquiry
// Single funnel for "this inquiry is over": releases the global slot (so a
// later start doesn't re-signal a stale token) and fires the done callback.
// Runs on the worker thread only.
- (void)inquiryFinished:(BOOL)aborted {
  if (g_inquiry == self) g_inquiry = nil;
  // Capture-and-clear BEFORE firing: a late deviceInquiryComplete can re-enter
  // here after btc_finish_inquiry already ran (the deferred delegate-nil below
  // hasn't executed yet), and must not double-fire `done` for the same token.
  // With the callbacks cleared, the second entry is a no-op.
  btc_inquiry_done_cb done = self.done;
  self.done = NULL;
  self.found = NULL;
  if (done) done(self.token, aborted ? 1 : 0);
  // IOBluetoothDeviceInquiry retains its delegate, so self <-> self.inquiry is
  // a retain cycle once g_inquiry lets go. Break it on the next worker-loop
  // pass so the framework callback that got us here has fully unwound first.
  [[BTCWorker shared] runAsync:^{
    [self.inquiry setDelegate:nil];
    self.inquiry = nil;
  }];
}
- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender
                          device:(IOBluetoothDevice *)device {
  if (self.found) {
    char *json = btc_json(btc_device_dict(device));
    if (json) self.found(self.token, json);
  }
}
- (void)deviceInquiryDeviceNameUpdated:(IOBluetoothDeviceInquiry *)sender
                                device:(IOBluetoothDevice *)device
                      devicesRemaining:(uint32_t)devicesRemaining {
  // Names often resolve only during the inquiry's name-update phase; re-forward
  // the sighting so the Dart side refreshes the (previously nameless) entry.
  if (self.found) {
    char *json = btc_json(btc_device_dict(device));
    if (json) self.found(self.token, json);
  }
}
- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender
                        error:(IOReturn)error
                      aborted:(BOOL)aborted {
  [self inquiryFinished:aborted];
}
@end

// Stops and releases the active inquiry, ALWAYS firing its done callback:
// [IOBluetoothDeviceInquiry stop] does not deliver deviceInquiryComplete, so
// without this a discovery stream whose inquiry was stopped (or replaced by a
// newer one) never closes on the Dart side — callers then hang until their own
// timeout and see no devices. Runs on the worker thread only.
static void btc_finish_inquiry(BOOL aborted) {
  BTCInquiry *old = g_inquiry;
  if (!old) return;
  [old.inquiry stop];
  [old inquiryFinished:aborted];
}

#pragma mark - SDP query target

@interface BTCSDPQuery : NSObject
@property(nonatomic) BOOL complete;
@end

// Outstanding performSDPQuery: target. Non-nil while a query is in flight; it
// doubles as a re-entrancy guard for the nested run-loop pump in
// btc_sdp_channel and keeps the target alive past the pump deadline so a late
// sdpQueryComplete does not message a deallocated object. Worker thread only.
static BTCSDPQuery *g_sdp_query = nil;

@implementation BTCSDPQuery
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
  self.complete = YES;
  if (g_sdp_query == self) g_sdp_query = nil;
}
@end

#pragma mark - RFCOMM channel delegate

@interface BTCChannel : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property(nonatomic) int64_t token;
@property(nonatomic) int64_t handle;
@property(nonatomic) btc_data_cb data;
@property(nonatomic) btc_state_cb state;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
// Outbound FIFO of MTU-sized chunks. writeAsync does NOT copy, so each chunk's
// NSData stays queued (alive) until its rfcommChannelWriteComplete fires.
@property(nonatomic, strong) NSMutableArray<NSData *> *writeQueue;
@property(nonatomic) BOOL writeInFlight;
- (void)enqueueWrite:(NSData *)data;
- (void)teardown;
@end

static NSMutableDictionary<NSNumber *, BTCChannel *> *g_channels(void);

@implementation BTCChannel
// Splits data into MTU-sized chunks and starts draining the queue via
// writeAsync, so the worker run loop never blocks on a stalled peer — a
// blocking writeSync here would freeze every runSync C-ABI call behind it.
// Ordering is preserved: one chunk in flight at a time, next sent from the
// write-complete callback. Worker thread only.
- (void)enqueueWrite:(NSData *)data {
  if (!self.channel) return;
  if (!self.writeQueue) self.writeQueue = [NSMutableArray new];
  BluetoothRFCOMMMTU mtu = [self.channel getMTU];
  if (mtu == 0) mtu = 0xFFFF;
  for (NSUInteger offset = 0; offset < data.length; offset += mtu) {
    NSUInteger chunk = data.length - offset;
    if (chunk > mtu) chunk = mtu;
    [self.writeQueue
        addObject:[data subdataWithRange:NSMakeRange(offset, chunk)]];
  }
  [self _sendNextChunk];
}
- (void)_sendNextChunk {
  if (self.writeInFlight || self.writeQueue.count == 0 || !self.channel) return;
  NSData *chunk = self.writeQueue.firstObject; // stays queued until complete
  self.writeInFlight = YES;
  IOReturn rc = [self.channel writeAsync:(void *)chunk.bytes
                                  length:(UInt16)chunk.length
                                  refcon:NULL];
  if (rc != kIOReturnSuccess) {
    self.writeInFlight = NO;
    [self _writeFailed];
  }
}
// Delegate-safe teardown shared by every close path (local close, remote
// close, failed write, btc_reset). Closes the channel now, but defers the
// delegate-nil to the next worker-loop pass so any framework callback that got
// us here unwinds against a live delegate; that pass also breaks the
// BTCChannel <-> IOBluetoothRFCOMMChannel retain cycle (the framework retains
// its delegate) and nulls the C callback pointers so a late delegate message
// can never dial out into Dart afterwards. Removing the g_channels entry may
// drop the last strong reference; the deferred block's capture of self keeps
// the object alive until it has run. Worker thread only.
- (void)teardown {
  [self.writeQueue removeAllObjects];
  [self.channel closeChannel];
  [[BTCWorker shared] runAsync:^{
    [self.channel setDelegate:nil];
    self.channel = nil;
    self.data = NULL;
    self.state = NULL;
  }];
  if (self.handle != 0) [g_channels() removeObjectForKey:@(self.handle)];
}
// A failed write means the link is gone; surface it as a disconnect instead of
// silently truncating the byte stream, then tear the channel down so the open
// IOBluetoothRFCOMMChannel is not orphaned with a dangling delegate.
- (void)_writeFailed {
  if (self.state) self.state(self.token, BTC_CONN_DISCONNECTED);
  [self teardown];
}
- (void)rfcommChannelWriteComplete:(IOBluetoothRFCOMMChannel *)rfcommChannel
                            refcon:(void *)refcon
                            status:(IOReturn)error {
  self.writeInFlight = NO;
  if (error != kIOReturnSuccess) {
    [self _writeFailed];
    return;
  }
  // Chunk delivered; its NSData may be released now. Send the next one.
  if (self.writeQueue.count > 0) [self.writeQueue removeObjectAtIndex:0];
  [self _sendNextChunk];
}
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)rfcommChannel
                     data:(void *)dataPointer
                   length:(size_t)dataLength {
  if (self.data && dataLength > 0 && dataLength <= INT32_MAX) {
    uint8_t *copy = malloc(dataLength);
    if (!copy) return;
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
  // Remote-initiated close: tear down (delegate-safely) so the BTCChannel and
  // its retained IOBluetoothRFCOMMChannel are released even if Dart never
  // calls btc_rfcomm_close.
  [self teardown];
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
  if (!address || !uuid) return -1;
  NSString *addr = btc_normalize_address(@(address));
  NSString *uuidStr = @(uuid);
  [[BTCWorker shared] runSync:^{
    IOBluetoothDevice *d = btc_device_for(addr);
    if (!d) return;
    // Build a 128-bit SDP UUID from the canonical string. Guard the length so a
    // malformed/short UUID can't throw NSRangeException on the worker thread.
    NSString *hex = [uuidStr stringByReplacingOccurrencesOfString:@"-"
                                                       withString:@""];
    if (hex.length != 32) return;
    uint8_t bytes[16];
    for (int i = 0; i < 16; i++) {
      NSString *b = [hex substringWithRange:NSMakeRange(i * 2, 2)];
      bytes[i] = (uint8_t)strtol([b UTF8String], NULL, 16);
    }
    IOBluetoothSDPUUID *sdpUuid = [IOBluetoothSDPUUID uuidWithBytes:bytes
                                                            length:16];
    IOBluetoothSDPServiceRecord *record = [d getServiceRecordForUUID:sdpUuid];
    if (!record && !g_sdp_query) {
      // getServiceRecordForUUID only consults cached SDP records; a device that
      // was never queried has none. Run a fresh query — its completion is
      // delivered on this run loop, and we're already on the worker thread
      // (inside runSync), so pump the loop in bounded slices until the target
      // fires or the deadline passes, then retry the cached lookup. g_sdp_query
      // being non-nil skips this for any re-entrant call the pump dispatches.
      BTCSDPQuery *q = [BTCSDPQuery new];
      g_sdp_query = q;
      if ([d performSDPQuery:q] == kIOReturnSuccess) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:12.0];
        while (!q.complete && [deadline timeIntervalSinceNow] > 0) {
          [[NSRunLoop currentRunLoop]
                runMode:NSDefaultRunLoopMode
             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        // On timeout g_sdp_query stays set (sdpQueryComplete clears it) so a
        // late completion still finds a live target.
        record = [d getServiceRecordForUUID:sdpUuid];
      } else {
        g_sdp_query = nil; // query never started; no completion is coming
      }
    }
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
    btc_finish_inquiry(YES);
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
    btc_finish_inquiry(YES);
  }];
  return 0;
}

int64_t btc_rfcomm_open(int64_t token, const char *address, int32_t channel,
                        const char *uuid, btc_data_cb data,
                        btc_state_cb state) {
  __block int64_t handle = 0;
  if (!address || !uuid) return 0;
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
    ch.handle = handle;
    g_channels()[@(handle)] = ch;
  }];
  return handle;
}

int32_t btc_rfcomm_write(int64_t handle, const uint8_t *data, int32_t len) {
  if (len <= 0) return 0;
  // Copy now; the caller's buffer may be freed before the async block runs.
  // (NSData copies here — same contract as the previous malloc'd copy.)
  NSData *bytes = [NSData dataWithBytes:data length:(NSUInteger)len];
  [[BTCWorker shared] runAsync:^{
    [g_channels()[@(handle)] enqueueWrite:bytes];
  }];
  return 0;
}

int32_t btc_rfcomm_close(int64_t handle) {
  [[BTCWorker shared] runSync:^{
    BTCChannel *ch = g_channels()[@(handle)];
    if (ch) [ch teardown];
  }];
  return 0;
}

void btc_reset(void) {
  [[BTCWorker shared] runSync:^{
    btc_finish_inquiry(YES);
    // allValues snapshots the map, so teardown's own removal is safe here.
    for (BTCChannel *ch in [g_channels() allValues]) {
      [ch teardown];
    }
    [g_channels() removeAllObjects];
  }];
}
