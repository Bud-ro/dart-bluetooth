// iOS Bluetooth Classic backend over ExternalAccessory (EASession).
//
// Compiled by the native-assets build hook (code asset) and the iOS SPM plugin.
// EASession input/output streams are NSStreams scheduled on a dedicated worker
// run loop; inbound data and state are forwarded to Dart via the C callbacks
// (NativeCallable.listener on the Dart side).

#import <ExternalAccessory/ExternalAccessory.h>
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>

#import "bluetooth_rfcomm.h"

#pragma mark - Worker run loop

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
  self.thread.name = @"bluetooth_rfcomm.ios.worker";
  [self.thread start];
  dispatch_semaphore_wait(_ready, DISPATCH_TIME_FOREVER);
}
- (void)main {
  @autoreleasepool {
    self.runLoop = [NSRunLoop currentRunLoop];
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

static char *btc_json(id obj) {
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj
                                                options:0
                                                  error:&err];
  if (!data) return NULL;
  return btc_strdup([[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding]);
}

#pragma mark - Session handler

@interface BTCSession : NSObject <NSStreamDelegate>
@property(nonatomic) int64_t token;
@property(nonatomic) btc_data_cb data;
@property(nonatomic) btc_state_cb state;
@property(nonatomic, strong) EASession *session;
@property(nonatomic, strong) NSMutableData *outBuffer;
// Latches NSStreamEventHasSpaceAvailable so _pump only writes when the output
// stream can take bytes without blocking the shared worker run loop.
@property(nonatomic) BOOL hasSpace;
@end

// Backlog cap for outBuffer: past this btc_ea_write fails (-1) instead of
// buffering without bound against a stalled accessory.
static const NSUInteger kBTCWriteBacklogCap = 1 * 1024 * 1024; // 1 MiB

@implementation BTCSession

- (instancetype)init {
  if ((self = [super init])) {
    _outBuffer = [NSMutableData new];
  }
  return self;
}

- (void)open {
  NSInputStream *in = self.session.inputStream;
  NSOutputStream *out = self.session.outputStream;
  in.delegate = self;
  out.delegate = self;
  [in scheduleInRunLoop:[NSRunLoop currentRunLoop]
                forMode:NSDefaultRunLoopMode];
  [out scheduleInRunLoop:[NSRunLoop currentRunLoop]
                 forMode:NSDefaultRunLoopMode];
  [in open];
  [out open];
}

- (void)enqueue:(NSData *)data {
  [self.outBuffer appendData:data];
  [self _pump];
}

- (void)_pump {
  NSOutputStream *out = self.session.outputStream;
  if (out == nil) return;
  // Only write while space is known available: write: with no space blocks
  // until the accessory drains, stalling the shared worker run loop for every
  // session. self.hasSpace latches the edge-triggered HasSpaceAvailable event
  // (which otherwise fires once against an empty buffer and is lost); after
  // each write, polling out.hasSpaceAvailable (non-blocking) re-arms the flag
  // while the stream can still take bytes. When it goes NO we stop and resume
  // from the next NSStreamEventHasSpaceAvailable.
  // Track how much we've drained and compact the buffer ONCE at the end.
  // Removing the written prefix on every iteration memmoves the remaining bytes
  // down each time — O(n^2) when a large payload drains in many small writes.
  NSUInteger drained = 0;
  while (self.hasSpace && drained < self.outBuffer.length) {
    NSInteger written = [out write:(const uint8_t *)self.outBuffer.bytes + drained
                        maxLength:self.outBuffer.length - drained];
    if (written <= 0) {
      // Full or errored despite the flag: wait for the next space event.
      self.hasSpace = NO;
      break;
    }
    drained += (NSUInteger)written;
    self.hasSpace = out.hasSpaceAvailable;
  }
  if (drained > 0) {
    [self.outBuffer replaceBytesInRange:NSMakeRange(0, drained)
                              withBytes:NULL
                                 length:0];
  }
}

- (void)closeSession {
  // Either stream can be nil if the session never fully materialized, and an
  // array literal with a nil element throws NSInvalidArgumentException — so
  // collect only the streams that exist.
  NSMutableArray<NSStream *> *streams = [NSMutableArray new];
  if (self.session.inputStream) [streams addObject:self.session.inputStream];
  if (self.session.outputStream) [streams addObject:self.session.outputStream];
  for (NSStream *s in streams) {
    [s close];
    [s removeFromRunLoop:[NSRunLoop currentRunLoop]
                 forMode:NSDefaultRunLoopMode];
    s.delegate = nil;
  }
  self.session = nil;
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
  switch (event) {
    case NSStreamEventOpenCompleted:
      if (stream == self.session.outputStream && self.state) {
        self.state(self.token, 2 /* connected */);
      }
      break;
    case NSStreamEventHasBytesAvailable: {
      if (stream == self.session.inputStream) {
        uint8_t buf[4096];
        NSInteger n = [(NSInputStream *)stream read:buf maxLength:sizeof(buf)];
        if (n > 0 && self.data) {
          uint8_t *copy = malloc((size_t)n);
          if (copy) {
            memcpy(copy, buf, (size_t)n);
            self.data(self.token, copy, (int32_t)n);
          }
        }
      }
      break;
    }
    case NSStreamEventHasSpaceAvailable:
      if (stream == self.session.outputStream) {
        self.hasSpace = YES;
        [self _pump];
      }
      break;
    case NSStreamEventEndEncountered:
    case NSStreamEventErrorOccurred:
      if (self.state) self.state(self.token, 0 /* disconnected */);
      break;
    default:
      break;
  }
}
@end

static NSMutableDictionary<NSNumber *, BTCSession *> *g_sessions(void) {
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

char *btc_ea_accessories_json(void) {
  __block char *result = NULL;
  [[BTCWorker shared] runSync:^{
    NSArray<EAAccessory *> *accs =
        [[EAAccessoryManager sharedAccessoryManager] connectedAccessories];
    NSMutableArray *arr = [NSMutableArray new];
    for (EAAccessory *a in accs) {
      [arr addObject:@{
        @"id" : [@(a.connectionID) stringValue],
        @"name" : (a.name ?: [NSNull null]),
        @"protocols" : (a.protocolStrings ?: @[]),
        @"manufacturer" : (a.manufacturer ?: [NSNull null]),
        @"modelNumber" : (a.modelNumber ?: [NSNull null]),
        @"serial" : (a.serialNumber ?: [NSNull null]),
      }];
    }
    result = btc_json(arr);
  }];
  return result;
}

int64_t btc_ea_open(int64_t token, const char *accessory_id,
                    const char *protocol, btc_data_cb data,
                    btc_state_cb state) {
  __block int64_t handle = 0;
  if (!accessory_id) return 0;
  NSUInteger wantedId = (NSUInteger)strtoull(accessory_id, NULL, 10);
  NSString *proto = (protocol && protocol[0]) ? @(protocol) : nil;
  [[BTCWorker shared] runSync:^{
    EAAccessory *match = nil;
    for (EAAccessory *a in
         [[EAAccessoryManager sharedAccessoryManager] connectedAccessories]) {
      if (a.connectionID == wantedId) {
        match = a;
        break;
      }
    }
    if (!match) return; // non-MFi or not connected -> 0
    NSString *useProto = proto ?: match.protocolStrings.firstObject;
    if (!useProto) return;
    EASession *session = [[EASession alloc] initWithAccessory:match
                                                 forProtocol:useProto];
    if (!session) return;
    BTCSession *h = [BTCSession new];
    h.token = token;
    h.data = data;
    h.state = state;
    h.session = session;
    [h open];
    handle = g_next_handle++;
    g_sessions()[@(handle)] = h;
  }];
  return handle;
}

int32_t btc_ea_write(int64_t handle, const uint8_t *data, int32_t len) {
  if (len <= 0) return 0;
  NSData *bytes = [NSData dataWithBytes:data length:len];
  __block int32_t result = -1;
  // runSync (not runAsync) so the backlog check is race-free against the
  // worker's own draining; _pump never blocks, so this returns promptly.
  [[BTCWorker shared] runSync:^{
    BTCSession *h = g_sessions()[@(handle)];
    if (!h) return; // unknown/closed handle -> -1
    if (h.outBuffer.length + bytes.length > kBTCWriteBacklogCap) return;
    [h enqueue:bytes];
    result = 0;
  }];
  return result;
}

int32_t btc_ea_close(int64_t handle) {
  [[BTCWorker shared] runSync:^{
    BTCSession *h = g_sessions()[@(handle)];
    if (h) {
      [h closeSession];
      [g_sessions() removeObjectForKey:@(handle)];
    }
  }];
  return 0;
}
