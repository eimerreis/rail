#import "PasswordService.h"

@implementation PasswordService {
  NSTask *_task;
  NSFileHandle *_input, *_output;
  NSMutableData *_buffer;
  NSString *_pendingID;
  void (^_completion)(NSDictionary *);
  NSString *_connectingAccount;
}
- (NSString *)connectedAccount { return _connectingAccount; }
- (void)finish:(NSDictionary *)response {
  void (^done)(NSDictionary *) = _completion;
  _completion = nil; _pendingID = nil;
  if (done) done(response);
}
- (void)stop {
  _output.readabilityHandler = nil;
  if (_task.running) [_task terminate];
  [_input closeFile]; [_output closeFile];
  _task = nil; _input = nil; _output = nil; _buffer = nil;
  _connectingAccount = nil;
  [self finish:@{@"error":@"interrupted"}];
}
- (BOOL)launch {
  if (_task.running) return YES;
  _task = [[NSTask alloc] init];
  _task.executableURL = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/MacOS/RailPasswordHelper"];
  if (_fixtureOrigin.length) _task.arguments=@[[@"--fixture-origin=" stringByAppendingString:_fixtureOrigin]];
  NSPipe *input = NSPipe.pipe, *output = NSPipe.pipe;
  _task.standardInput = input; _task.standardOutput = output; _task.standardError = NSFileHandle.fileHandleWithNullDevice;
  _input = input.fileHandleForWriting; _output = output.fileHandleForReading; _buffer = NSMutableData.data;
  __weak PasswordService *weak = self;
  _output.readabilityHandler = ^(NSFileHandle *handle) {
    NSData *data = handle.availableData;
    dispatch_async(dispatch_get_main_queue(), ^{
      PasswordService *s = weak; if (!s || s->_output != handle) return;
      if (!data.length || s->_buffer.length + data.length > 1024*1024) { [s stop]; return; }
      [s->_buffer appendData:data];
      const uint8_t *bytes = (const uint8_t *)s->_buffer.bytes;
      if (bytes[s->_buffer.length-1] != '\n') return;
      NSDictionary *result = [NSJSONSerialization JSONObjectWithData:s->_buffer options:0 error:nil];
      s->_buffer.length = 0;
      if (![result isKindOfClass:NSDictionary.class] || ![result[@"id"] isEqual:s->_pendingID]) { [s stop]; return; }
      [s finish:result];
    });
  };
  NSError *error = nil;
  if (![_task launchAndReturnError:&error]) { _output.readabilityHandler = nil; return NO; }
  return YES;
}
- (void)request:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion {
  NSAssert(NSThread.isMainThread,@"PasswordService belongs to the UI thread");
  if (_completion) { completion(@{@"error":@"busy"}); return; }
  if (![self launch]) { completion(@{@"error":@"helper_unavailable"}); return; }
  NSMutableDictionary *payload = [request mutableCopy];
  NSString *requestID = NSUUID.UUID.UUIDString; payload[@"id"] = requestID;
  NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil] mutableCopy];
  if (!data || data.length > 65000) { completion(@{@"error":@"invalid_request"}); return; }
  [data appendBytes:"\n" length:1]; _pendingID = requestID;
  __weak PasswordService *weak = self;
  _completion = ^(NSDictionary *result) {
    PasswordService *s = weak;
    if ([request[@"command"] isEqual:@"connect"] && !result[@"error"]) s->_connectingAccount = request[@"account"];
    completion(result);
  };
  @try { [_input writeData:data]; } @catch (NSException *) { [self stop]; return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,125*NSEC_PER_SEC),dispatch_get_main_queue(),^{
    PasswordService *s = weak;
    if (s && [s->_pendingID isEqual:requestID]) [s stop];
  });
}
- (void)dealloc { _output.readabilityHandler = nil; if (_task.running) [_task terminate]; }
@end
