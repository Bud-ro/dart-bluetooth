// macOS Bluetooth Classic backend implementing bluetooth_rfcomm.h on top of
// IOBluetooth. Compiled from source (no committed binary) by the native-assets
// build hook for pure-Dart CLI use, and by the SPM plugin for Flutter apps.
//
// IOBluetooth is delegate- and run-loop-driven, so all framework calls run on a
// dedicated worker thread that owns a CFRunLoop. Inbound data and state changes
// are forwarded to Dart through the C callback pointers, which on the Dart side
// are NativeCallable.listener functions (thread-safe).

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#import <os/lock.h>
#import <stdio.h>
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

#pragma mark - Per-channel transfer counters

// Monotonic per-channel counters, maintained on the worker thread only (no
// locks needed — every mutation happens on that one thread) and read via
// btc_rfcomm_stats_json (which hops to the worker, so reads are coherent).
// They live in a plain calloc'd struct so the data hot paths increment fields
// with zero allocations, and the struct is OWNED BY A SIDE REGISTRY keyed by
// handle — not by the BTCChannel — so the numbers remain readable AFTER
// teardown: a disconnect/reconnect cycle that purges a write queue must stay
// attributable post-mortem, not vanish with the channel object.
//
// Differential semantics (each byte is counted at the hop it crosses):
//   txEnqueuedBytes  - txSubmittedBytes  = accepted but not yet handed to
//                                          writeAsync (growing while connected
//                                          and idle => queue stall)
//   txSubmittedBytes - txCompletedBytes  = handed to the OS but no completion
//                                          processed (growing => completions
//                                          not arriving / being rejected)
//   txDroppedBytes  > 0                  = bytes discarded (teardown purge or
//                                          a guard bail) — never silent
//   rxBytes vs Dart-side received bytes  = native->Dart delivery loss
//                                          (rxDroppedEvents says how often)
typedef struct {
  int64_t txEnqueuedBytes;  // accepted by btc_rfcomm_write (returned 0)
  int64_t txSubmittedBytes; // handed to writeAsync, rc == success (a retry
                            // re-counts the suffix/chunk it resubmits; with
                            // txRetriedChunks == 0 no byte is double-counted)
  int64_t txCompletedBytes; // confirmed by a write-complete (incl. the
                            // delivered prefix of a partial write)
  int64_t txRetriedChunks;  // transient-error retry attempts
  int64_t txFailedChunks;   // chunks abandoned by a fatal write failure
  int64_t txDroppedBytes;   // bytes discarded for ANY reason
  int64_t rxEvents;         // rfcommChannelData delegate deliveries
  int64_t rxBytes;          // bytes the stack handed us (counted before any
                            // drop, so a drop never hides inbound volume)
  int64_t rxDroppedEvents;  // deliveries whose payload was discarded (malloc
                            // fail, oversize, post-teardown, no callback)
} btc_channel_stats;

// handle -> btc_channel_stats* (boxed in NSValue). Entries outlive their
// channel (post-mortem reads) and are freed only by eviction or btc_reset.
static NSMutableDictionary<NSNumber *, NSValue *> *g_stats(void) {
  static NSMutableDictionary *d;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    d = [NSMutableDictionary new];
  });
  return d;
}

// Cap on retained stats entries: past this, entries whose channel is gone are
// evicted oldest-handle-first at open, so an app that reconnects forever
// cannot grow the registry without bound. Live channels are never evicted.
static const NSUInteger kBTCStatsCap = 1024;

// Accepted-but-not-yet-written byte gauges, keyed by handle. Lock-guarded
// (NOT worker-confined) on purpose: with the blocking writeSync send path an
// in-progress write can hold the worker for the length of a peer stall, and
// both send()'s accept/backlog check and btc_rfcomm_pending reads must never
// block the calling isolate behind that. Every accept (+) is balanced by
// exactly one worker-side (-) — at writeBlocking entry, or in the
// dead-channel path of the write block.
static os_unfair_lock g_gauge_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, NSNumber *> *g_gauges_storage;

static void btc_gauge_add(int64_t handle, int64_t delta) {
  os_unfair_lock_lock(&g_gauge_lock);
  if (!g_gauges_storage) g_gauges_storage = [NSMutableDictionary new];
  NSNumber *k = @(handle);
  int64_t v = g_gauges_storage[k].longLongValue + delta;
  if (v <= 0) {
    [g_gauges_storage removeObjectForKey:k];
  } else {
    g_gauges_storage[k] = @(v);
  }
  os_unfair_lock_unlock(&g_gauge_lock);
}

static int64_t btc_gauge_read(int64_t handle) {
  os_unfair_lock_lock(&g_gauge_lock);
  int64_t v = g_gauges_storage[@(handle)].longLongValue;
  os_unfair_lock_unlock(&g_gauge_lock);
  return v;
}

#pragma mark - RFCOMM channel delegate

@interface BTCChannel : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property(nonatomic) int64_t token;
@property(nonatomic) int64_t handle;
@property(nonatomic) btc_data_cb data;
@property(nonatomic) btc_state_cb state;
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
// MTU cached at rfcommChannelOpenComplete (getMTU is only meaningful once the
// channel is open; before that it can read 0).
@property(nonatomic) BluetoothRFCOMMMTU mtu;
// Set (permanently) by teardown; every late path checks it so a framework
// callback can never resurrect a dead channel or reschedule work.
@property(nonatomic) BOOL tornDown;
// Borrowed pointer into the g_stats() registry (which owns and frees it).
// NULLed synchronously in teardown so a late delegate callback can never touch
// a struct the registry may since have freed. May be NULL if calloc failed at
// open; every increment site checks.
@property(nonatomic) btc_channel_stats *stats;
- (void)writeBlocking:(NSData *)bytes;
- (void)teardown;
@end

static NSMutableDictionary<NSNumber *, BTCChannel *> *g_channels(void);

// Chunk-size fallback when the channel MTU cannot be read. writeAsync REJECTS
// payloads larger than the negotiated MTU, so the fallback must sit BELOW any
// plausible negotiation — 127 bytes is the classic RFCOMM default frame size.
// (The old fallback of 0xFFFF guaranteed a failed write — and therefore a full
// connection teardown — the moment getMTU misreported 0.)
static const NSUInteger kBTCFallbackChunk = 127;

// Cap on bytes accepted but not yet handed to writeSync. Past this
// btc_rfcomm_write fails (-2) instead of buffering without bound against a
// stalled peer.
static const int64_t kBTCWriteBacklogCap = 4 * 1024 * 1024; // 4 MiB

@implementation BTCChannel

// The field-proven 0.1.x send path: writeSync blocks THIS worker thread
// (never the caller) until the controller accepts each MTU-sized chunk.
// Deliberate trade-off for this release: a stalled peer or a sniff-mode wake
// blocks the worker — including inbound delivery and every runSync C-ABI
// call — for the duration of the stall. The completion-driven async queue
// that removes this head-of-line blocking ships separately (send-path PR);
// this release keeps the only macOS write path with hardware mileage.
//
// Latency note (sniff mode): with idle gaps of ~100 ms+ between messages the
// controllers may place the ACL link in sniff/low-power mode; the first write
// after an idle gap then stalls until the next sniff anchor point (commonly
// up to ~1.28 s). That is pure LATENCY — baseband retransmission means no
// bytes are lost on a live link.
//
// writeSync pumps the worker run loop while it waits, so delegate callbacks
// (including rfcommChannelClosed → teardown) can fire mid-loop; the tornDown
// re-check per chunk keeps a dead channel from being written to. Worker
// thread only.
- (void)writeBlocking:(NSData *)bytes {
  // Balance the accept-side increment up front: from here the bytes are
  // "being written", excluded from the pending gauge exactly as an in-flight
  // chunk was under the async queue.
  btc_gauge_add(self.handle, -(int64_t)bytes.length);
  const uint8_t *p = bytes.bytes;
  NSUInteger mtu = self.mtu;
  if (mtu == 0 && self.channel) mtu = [self.channel getMTU];
  if (mtu == 0) mtu = kBTCFallbackChunk;
  size_t offset = 0;
  while (offset < bytes.length) {
    if (self.tornDown || !self.channel) {
      // Channel died between accept and (this part of) the write; the
      // remainder was never transmitted. Count it — never silent. The stats
      // pointer is NULLed by teardown, so go through the registry, which
      // outlives the channel for exactly this kind of post-mortem write.
      NSValue *v = g_stats()[@(self.handle)];
      if (v) {
        ((btc_channel_stats *)[v pointerValue])->txDroppedBytes +=
            (int64_t)(bytes.length - offset);
      }
      return;
    }
    size_t chunk = bytes.length - offset;
    if (chunk > mtu) chunk = mtu;
    if (self.stats) self.stats->txSubmittedBytes += (int64_t)chunk;
    IOReturn rc = [self.channel writeSync:(void *)(p + offset)
                                   length:(UInt16)chunk];
    if (rc != kIOReturnSuccess) {
      // A mid-stream failure means the link is gone. Surface it as a
      // disconnect instead of silently truncating the byte stream, and count
      // the untransmitted remainder.
      if (self.stats) {
        self.stats->txFailedChunks++;
        self.stats->txDroppedBytes += (int64_t)(bytes.length - offset);
      }
      if (self.state) self.state(self.token, BTC_CONN_DISCONNECTED);
      [self teardown];
      return;
    }
    if (self.stats) self.stats->txCompletedBytes += (int64_t)chunk;
    offset += chunk;
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
//
// Bytes still pending (accepted, block not yet run) are NOT purged here: each
// pending writeBlocking block still runs, finds tornDown, and counts its own
// remainder into txDroppedBytes via the registry — one counting site, no
// double-count.
- (void)teardown {
  // Idempotent: a second entry (e.g. rfcommChannelClosed arriving after a
  // failed write already tore down, before the deferred delegate-nil has run)
  // must not re-run the detach below.
  if (self.tornDown) return;
  self.tornDown = YES;
  // Detach from the stats struct NOW (not in the deferred block): the registry
  // owns it and may free it (eviction/btc_reset) once this channel is torn
  // down, and delegate callbacks can still arrive until the deferred
  // delegate-nil below runs — they must find NULL, never a dangling pointer.
  self.stats = NULL;
  [self.channel closeChannel];
  [[BTCWorker shared] runAsync:^{
    [self.channel setDelegate:nil];
    self.channel = nil;
    self.data = NULL;
    self.state = NULL;
  }];
  if (self.handle != 0) [g_channels() removeObjectForKey:@(self.handle)];
}
// Inbound data. Counters first — rxEvents/rxBytes record what the STACK handed
// us, before any drop decision, so the native->Dart differential is exact.
// Every discard path increments rxDroppedEvents; previously a malloc failure
// (or an oversize delivery) vanished without a trace, indistinguishable from
// the peer never sending.
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)rfcommChannel
                     data:(void *)dataPointer
                   length:(size_t)dataLength {
  btc_channel_stats *st = self.stats;
  if (st) {
    st->rxEvents++;
    st->rxBytes += (int64_t)dataLength;
  }
  if (dataLength == 0) return; // nothing to forward; not a drop
  if (self.tornDown || !self.data || dataLength > INT32_MAX) {
    // Post-teardown stragglers (Dart already saw the disconnect and closed the
    // stream), a cleared callback, or a payload the int32 ABI can't carry.
    if (st) st->rxDroppedEvents++;
    return;
  }
  uint8_t *copy = malloc(dataLength);
  if (!copy) {
    if (st) st->rxDroppedEvents++;
    return;
  }
  memcpy(copy, dataPointer, dataLength);
  self.data(self.token, copy, (int32_t)dataLength);
}
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)rfcommChannel
                           status:(IOReturn)error {
  // getMTU is only valid once the channel is open; cache it here so the write
  // path and btc_rfcomm_mtu never see a not-yet-negotiated 0.
  if (error == kIOReturnSuccess && self.channel) {
    self.mtu = [self.channel getMTU];
  }
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
  // TCC (Bluetooth privacy) check first: a denied process still sees a
  // powered-on controller, an empty paired list, and inquiries that complete
  // cleanly with zero sightings — indistinguishable from "no devices nearby"
  // unless we ask. CBCentralManager.authorization is a class property and
  // does NOT trigger the permission prompt. notDetermined passes through:
  // IOBluetooth never prompts, and flagging a never-asked state as denied
  // would be just as misleading.
  if (@available(macOS 10.15, *)) {
    CBManagerAuthorization auth = CBCentralManager.authorization;
    if (auth == CBManagerAuthorizationDenied ||
        auth == CBManagerAuthorizationRestricted) {
      return BTC_ADAPTER_UNAUTHORIZED;
    }
  }
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
    if (result != 0) {
      // A dead inquiry left armed in g_inquiry retains the Dart callback
      // pointers and fires a stale done on the next start/stop.
      inq.inquiry.delegate = nil;
      inq.found = NULL;
      inq.done = NULL;
      g_inquiry = nil;
    }
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
    // Per-channel counters: one calloc at open (never on the data hot paths).
    // Registered in g_stats() — which owns the struct — so they stay readable
    // after teardown; the channel only borrows the pointer.
    btc_channel_stats *stats = calloc(1, sizeof(btc_channel_stats));
    if (stats) {
      NSMutableDictionary<NSNumber *, NSValue *> *sm = g_stats();
      if (sm.count >= kBTCStatsCap) {
        // Evict post-mortem entries oldest-handle-first (handles are issued
        // monotonically and never reused). Never a live channel's.
        NSArray<NSNumber *> *keys =
            [[sm allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *k in keys) {
          if (sm.count < kBTCStatsCap) break;
          if (g_channels()[k]) continue;
          free([sm[k] pointerValue]); // safe: torn-down channels detached
          [sm removeObjectForKey:k];
        }
      }
      sm[@(handle)] = [NSValue valueWithPointer:stats];
      ch.stats = stats;
    }
    g_channels()[@(handle)] = ch;
  }];
  return handle;
}

int32_t btc_rfcomm_write(int64_t handle, const uint8_t *data, int32_t len) {
  if (len <= 0) return 0;
  // No runSync anywhere on this path: with the blocking writeSync engine an
  // in-progress write can hold the worker for the length of a peer stall,
  // and send() must never block the calling isolate behind it (the 0.1.x
  // contract). The handle map is worker-confined, so channel validation
  // happens inside the block: the Dart layer fail-fasts on its own closed
  // flag before calling here, and the narrow accepted-then-torn-down race is
  // counted into txDroppedBytes — never silent. The backlog check reads the
  // lock-guarded gauge; approximate against concurrent draining, exact
  // enough for a 4 MiB cap.
  if (btc_gauge_read(handle) + len > kBTCWriteBacklogCap) {
    return -2; // backlog full: peer has stalled for a long time
  }
  // Copy now; the caller's buffer may be freed before the block runs.
  NSData *bytes = [NSData dataWithBytes:data length:(NSUInteger)len];
  btc_gauge_add(handle, len);
  [[BTCWorker shared] runAsync:^{
    BTCChannel *ch = g_channels()[@(handle)];
    if (!ch || ch.tornDown) {
      // Accepted, but the channel died before the worker got here. Balance
      // the gauge and count the loss post-mortem via the registry.
      btc_gauge_add(handle, -len);
      NSValue *v = g_stats()[@(handle)];
      if (v) {
        ((btc_channel_stats *)[v pointerValue])->txDroppedBytes += len;
      }
      return;
    }
    if (ch.stats) ch.stats->txEnqueuedBytes += len;
    [ch writeBlocking:bytes];
  }];
  return 0;
}

int32_t btc_rfcomm_mtu(int64_t handle) {
  __block int32_t result = 0;
  [[BTCWorker shared] runSync:^{
    BTCChannel *ch = g_channels()[@(handle)];
    if (!ch) return;
    BluetoothRFCOMMMTU mtu = ch.mtu;
    if (mtu == 0 && ch.channel) mtu = [ch.channel getMTU];
    result = (int32_t)mtu;
  }];
  return result;
}

int64_t btc_rfcomm_pending(int64_t handle) {
  // Gauge read only — deliberately does NOT enter the worker, so flush/drain
  // polling stays responsive while a writeSync rides out a peer stall.
  return btc_gauge_read(handle);
}

char *btc_rfcomm_stats_json(int64_t handle) {
  __block char *result = NULL;
  // runSync: the counters are mutated exclusively on the worker thread, so
  // reading them there yields one coherent snapshot. The JSON is built by hand
  // (fixed field order, no Obj-C collections) — this path is cold, but there
  // is no reason to allocate more than the one output string.
  [[BTCWorker shared] runSync:^{
    NSValue *v = g_stats()[@(handle)];
    if (!v) {
      result = strdup("{\"error\":\"unknown handle\"}");
      return;
    }
    const btc_channel_stats *s = [v pointerValue];
    char buf[512];
    snprintf(buf, sizeof(buf),
             "{\"txEnqueuedBytes\":%lld,\"txSubmittedBytes\":%lld,"
             "\"txCompletedBytes\":%lld,\"txRetriedChunks\":%lld,"
             "\"txFailedChunks\":%lld,\"txDroppedBytes\":%lld,"
             "\"rxEvents\":%lld,\"rxBytes\":%lld,\"rxDroppedEvents\":%lld}",
             (long long)s->txEnqueuedBytes, (long long)s->txSubmittedBytes,
             (long long)s->txCompletedBytes, (long long)s->txRetriedChunks,
             (long long)s->txFailedChunks, (long long)s->txDroppedBytes,
             (long long)s->rxEvents, (long long)s->rxBytes,
             (long long)s->rxDroppedEvents);
    result = strdup(buf);
  }];
  return result;
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
    // Stats intentionally outlive their channels for post-mortem reads, but
    // reset is the isolate boundary (fresh construction / dispose): nothing
    // will read them again. Safe to free: every teardown above detached its
    // channel's borrowed pointer synchronously, so no late delegate callback
    // can touch these structs afterwards.
    for (NSValue *v in [g_stats() allValues]) free([v pointerValue]);
    [g_stats() removeAllObjects];
  }];
  os_unfair_lock_lock(&g_gauge_lock);
  [g_gauges_storage removeAllObjects];
  os_unfair_lock_unlock(&g_gauge_lock);
}
