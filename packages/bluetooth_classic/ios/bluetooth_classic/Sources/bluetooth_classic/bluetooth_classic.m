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

#import "bluetooth_classic.h"

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
  self.thread.name = @"bluetooth_classic.ios.worker";
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
@end

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
  while (self.outBuffer.length > 0 && out.hasSpaceAvailable) {
    NSInteger written = [out write:self.outBuffer.bytes
                        maxLength:self.outBuffer.length];
    if (written <= 0) break;
    [self.outBuffer replaceBytesInRange:NSMakeRange(0, written)
                              withBytes:NULL
                                 length:0];
  }
}

- (void)closeSession {
  for (NSStream *s in @[ self.session.inputStream, self.session.outputStream ]) {
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
          uint8_t *copy = malloc(n);
          memcpy(copy, buf, n);
          self.data(self.token, copy, (int32_t)n);
        }
      }
      break;
    }
    case NSStreamEventHasSpaceAvailable:
      [self _pump];
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
  [[BTCWorker shared] runAsync:^{
    BTCSession *h = g_sessions()[@(handle)];
    [h enqueue:bytes];
  }];
  return 0;
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
