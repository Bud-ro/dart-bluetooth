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
// MTU cached at rfcommChannelOpenComplete (getMTU is only meaningful once the
// channel is open; before that it can read 0).
@property(nonatomic) BluetoothRFCOMMMTU mtu;
// Set (permanently) by teardown; every queue/retry path checks it so a late
// framework callback can never resurrect a dead channel or reschedule work.
@property(nonatomic) BOOL tornDown;
// Transient-write-error retry state: consecutive failed attempts for the
// current head chunk (reset on any successful completion) and whether a
// delayed retry is already queued on the worker run loop.
@property(nonatomic) int retryAttempts;
@property(nonatomic) BOOL retryScheduled;
- (void)enqueueWrite:(NSData *)data;
- (int64_t)pendingBytes;
- (void)teardown;
@end

static NSMutableDictionary<NSNumber *, BTCChannel *> *g_channels(void);

// Chunk-size fallback when the channel MTU cannot be read. writeAsync REJECTS
// payloads larger than the negotiated MTU, so the fallback must sit BELOW any
// plausible negotiation — 127 bytes is the classic RFCOMM default frame size.
// (The old fallback of 0xFFFF guaranteed a failed write — and therefore a full
// connection teardown — the moment getMTU misreported 0.)
static const NSUInteger kBTCFallbackChunk = 127;

// Cap on bytes buffered in a channel's writeQueue. Past this btc_rfcomm_write
// fails (-2) instead of buffering without bound against a stalled peer.
static const int64_t kBTCWriteBacklogCap = 4 * 1024 * 1024; // 4 MiB

// Bounded budget of consecutive transient-error retries for one chunk before
// the error is treated as fatal (~7.5 s worst case with the backoff below).
static const int kBTCMaxWriteRetries = 10;

// Transient write statuses: conditions that clear on their own once the peer
// drains, grants RFCOMM credits, or the link wakes from sniff/low-power mode.
// These must NOT tear down the connection (that would eat the whole queue);
// they are retried with bounded backoff. Anything else — not-open, bad
// argument, device gone — is genuinely fatal. If the link really died, the
// framework also delivers rfcommChannelClosed, which tears down regardless.
static BOOL btc_write_status_is_transient(IOReturn rc) {
  switch (rc) {
    case kIOReturnNoResources: // out of credits / outgoing queue full
    case kIOReturnNoSpace:
    case kIOReturnNoMemory:
    case kIOReturnBusy:
    case kIOReturnTimeout: // e.g. sniff-mode wake latency exceeded a deadline
      return YES;
    default:
      return NO;
  }
}

@implementation BTCChannel
// Splits data into MTU-sized chunks and starts draining the queue via
// writeAsync, so the worker run loop never blocks on a stalled peer — a
// blocking writeSync here would freeze every runSync C-ABI call behind it.
// Ordering is preserved: one chunk in flight at a time, next sent from the
// write-complete callback. Worker thread only.
//
// Latency note (sniff mode): with idle gaps of ~100 ms+ between messages the
// controllers may place the ACL link in sniff/low-power mode; the first write
// after an idle gap then stalls until the next sniff anchor point (commonly up
// to ~1.28 s). That is pure LATENCY — RFCOMM/L2CAP retransmission means no
// bytes are lost — and IOBluetooth exposes no public knob to veto sniff
// (link-policy HCI control is private API). Callers who need tight latency
// should keep the link busy (keepalives) or budget for the wake latency. The
// transient-retry logic below exists precisely so a credit/queue stall during
// such a wake never tears the connection down.
- (void)enqueueWrite:(NSData *)data {
  if (!self.channel || self.tornDown) return;
  if (!self.writeQueue) self.writeQueue = [NSMutableArray new];
  NSUInteger mtu = self.mtu;
  if (mtu == 0 && self.channel) mtu = [self.channel getMTU];
  if (mtu == 0) mtu = kBTCFallbackChunk;
  if (data.length <= mtu) {
    // Common case (small message): no subdata copy needed.
    [self.writeQueue addObject:data];
  } else {
    for (NSUInteger offset = 0; offset < data.length; offset += mtu) {
      NSUInteger chunk = data.length - offset;
      if (chunk > mtu) chunk = mtu;
      [self.writeQueue
          addObject:[data subdataWithRange:NSMakeRange(offset, chunk)]];
    }
  }
  [self _sendNextChunk];
}
// Bytes accepted by btc_rfcomm_write but not yet handed to the OS. The head
// chunk, while in flight, HAS been handed over (writeAsync accepted it), so it
// is excluded. Worker thread only.
- (int64_t)pendingBytes {
  int64_t total = 0;
  for (NSData *d in self.writeQueue) total += (int64_t)d.length;
  if (self.writeInFlight && self.writeQueue.count > 0) {
    total -= (int64_t)((NSData *)self.writeQueue[0]).length;
  }
  return total;
}
- (void)_sendNextChunk {
  if (self.writeInFlight || self.writeQueue.count == 0 || !self.channel ||
      self.tornDown) {
    return;
  }
  NSData *chunk = self.writeQueue.firstObject; // stays queued until complete
  self.writeInFlight = YES;
  IOReturn rc = [self.channel writeAsync:(void *)chunk.bytes
                                  length:(UInt16)chunk.length
                                  refcon:NULL];
  if (rc != kIOReturnSuccess) {
    // Submission failed: no write-complete is coming for this attempt. The
    // chunk is still at the queue head; classify and retry or fail.
    self.writeInFlight = NO;
    [self _writeErrored:rc bytesWritten:0];
  }
}
// A write attempt failed with `rc` (submission return or completion status);
// the affected chunk is still at the queue head. Transient statuses back off
// and retry (bounded); anything else — or an exhausted retry budget — is a
// real link failure and funnels to _writeFailed. `bytesWritten` (from the
// bytesWritten: completion variant, 0 elsewhere) trims any delivered prefix so
// a retry never re-sends bytes the peer already received.
- (void)_writeErrored:(IOReturn)rc bytesWritten:(size_t)bytesWritten {
  if (self.tornDown) return;
  if (btc_write_status_is_transient(rc) &&
      self.retryAttempts < kBTCMaxWriteRetries) {
    self.retryAttempts++;
    if (bytesWritten > 0 && self.writeQueue.count > 0) {
      NSData *head = self.writeQueue[0];
      if (bytesWritten >= head.length) {
        [self.writeQueue removeObjectAtIndex:0];
      } else {
        self.writeQueue[0] = [head
            subdataWithRange:NSMakeRange(bytesWritten,
                                         head.length - bytesWritten)];
      }
    }
    [self _scheduleRetry];
    return;
  }
  [self _writeFailed];
}
// Exponential backoff: 40 ms, 80 ms, ... capped at 1.28 s — long enough to
// ride out an RFCOMM credit stall or a sniff-mode wake (sniff intervals are
// commonly <= 1.28 s), short enough that a truly dead link still fails fast
// (rfcommChannelClosed usually beats the budget anyway). A queue-space /
// flow-control delegate event retries sooner. Worker thread only.
- (void)_scheduleRetry {
  if (self.retryScheduled || self.tornDown) return;
  self.retryScheduled = YES;
  NSTimeInterval delay = 0.02 * (double)(1 << MIN(self.retryAttempts, 6));
  [self performSelector:@selector(_retryNow)
             withObject:nil
             afterDelay:delay];
}
- (void)_retryNow {
  self.retryScheduled = NO;
  [self _sendNextChunk];
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
  self.tornDown = YES;
  // Cancel any delayed _retryNow still queued on the worker run loop so it
  // cannot fire into a dead channel (it would no-op on tornDown, but the
  // pending perform also retains self).
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  self.retryScheduled = NO;
  self.writeInFlight = NO;
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
// A GENUINELY fatal write failure (non-transient status, or the bounded retry
// budget is spent): surface it as a disconnect instead of silently truncating
// the byte stream, then tear the channel down so the open
// IOBluetoothRFCOMMChannel is not orphaned with a dangling delegate. Transient
// conditions never reach here — see _writeErrored.
- (void)_writeFailed {
  if (self.state) self.state(self.token, BTC_CONN_DISCONNECTED);
  [self teardown];
}
// Shared handler for both write-complete delegate variants. `haveBytes` is YES
// only for the bytesWritten: variant. The writeInFlight guard makes a
// duplicate or post-teardown delivery a no-op (a failed submission never gets
// a completion, so nothing legitimate is swallowed).
- (void)_writeCompleteStatus:(IOReturn)error
                bytesWritten:(size_t)bytesWritten
                   haveBytes:(BOOL)haveBytes {
  if (!self.writeInFlight) return;
  self.writeInFlight = NO;
  if (error != kIOReturnSuccess) {
    [self _writeErrored:error bytesWritten:haveBytes ? bytesWritten : 0];
    return;
  }
  self.retryAttempts = 0;
  // Chunk delivered; its NSData may be released now. Send the next one.
  if (self.writeQueue.count > 0) [self.writeQueue removeObjectAtIndex:0];
  [self _sendNextChunk];
}
// IOBluetoothRFCOMMChannelDelegate declares TWO write-complete selectors:
//   rfcommChannelWriteComplete:refcon:status:
//   rfcommChannelWriteComplete:refcon:status:bytesWritten:
// The framework probes the delegate with respondsToSelector: and invokes
// whichever variant it finds (newer SDKs prefer the bytesWritten one).
// Implement BOTH so completions arrive regardless of which the installed OS
// probes for — if neither matched, the one-in-flight queue would stall forever
// after the first chunk and every later message would look "dropped". The
// refcon is the opaque value passed to writeAsync (NULL here — legal; it is
// only echoed back, never interpreted) and is deliberately not matched on.
- (void)rfcommChannelWriteComplete:(IOBluetoothRFCOMMChannel *)rfcommChannel
                            refcon:(void *)refcon
                            status:(IOReturn)error {
  [self _writeCompleteStatus:error bytesWritten:0 haveBytes:NO];
}
- (void)rfcommChannelWriteComplete:(IOBluetoothRFCOMMChannel *)rfcommChannel
                            refcon:(void *)refcon
                            status:(IOReturn)error
                      bytesWritten:(size_t)bytesWritten {
  [self _writeCompleteStatus:error bytesWritten:bytesWritten haveBytes:YES];
}
// The framework's own "you may write again" signals. After a transient
// kIOReturnNoResources-style failure these fire as soon as the outgoing queue
// drains / the peer grants RFCOMM credits, so the queue resumes immediately
// instead of waiting out the backoff timer. Harmless when idle: _sendNextChunk
// no-ops if a write is already in flight or the queue is empty.
- (void)rfcommChannelQueueSpaceAvailable:
    (IOBluetoothRFCOMMChannel *)rfcommChannel {
  [self _sendNextChunk];
}
- (void)rfcommChannelFlowControlChanged:
    (IOBluetoothRFCOMMChannel *)rfcommChannel {
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
  // Copy now; the caller's buffer may be freed before the block runs.
  // (NSData copies here — same contract as the previous malloc'd copy.)
  NSData *bytes = [NSData dataWithBytes:data length:(NSUInteger)len];
  __block int32_t result = -1;
  // runSync (not runAsync) so the backlog check is race-free against the
  // worker's own draining and so an unknown/closed handle is REPORTED instead
  // of silently swallowing the payload. Nothing on the worker blocks anymore
  // (writes are writeAsync), so this returns promptly.
  [[BTCWorker shared] runSync:^{
    BTCChannel *ch = g_channels()[@(handle)];
    if (!ch || ch.tornDown) return; // -1: not open (never silently drop)
    if ([ch pendingBytes] + len > kBTCWriteBacklogCap) {
      result = -2; // backlog full: peer has stalled for a long time
      return;
    }
    [ch enqueueWrite:bytes];
    result = 0;
  }];
  return result;
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
  __block int64_t result = 0;
  [[BTCWorker shared] runSync:^{
    BTCChannel *ch = g_channels()[@(handle)];
    if (ch) result = [ch pendingBytes];
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
  }];
}
