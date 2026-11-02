#import <Cocoa/Cocoa.h>

// Disposable protocol handler used by external-app-smoke.mjs. Receives real
// macOS open-URL events and records them outside Rail's profile.
@interface CallbackReceiver : NSObject <NSApplicationDelegate>
@end
@implementation CallbackReceiver
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
  NSString *path = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CallbackFile"];
  NSData *data = [NSData dataWithContentsOfFile:path];
  NSMutableArray *received = data ? [[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] mutableCopy] : [NSMutableArray array];
  for (NSURL *url in urls) [received addObject:url.absoluteString];
  [[NSJSONSerialization dataWithJSONObject:received options:0 error:nil] writeToFile:path atomically:YES];
  [application terminate:nil];
}
@end
int main() {
  @autoreleasepool {
    NSApplication *app = NSApplication.sharedApplication;
    CallbackReceiver *receiver = [[CallbackReceiver alloc] init];
    app.delegate = receiver;
    [app run];
  }
}
