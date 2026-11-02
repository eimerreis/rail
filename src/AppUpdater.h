#import <Cocoa/Cocoa.h>

// Builds outside the running bundle; the worker installs only after clean exit.
@interface AppUpdater : NSObject
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, copy) void (^onStatus)(NSString *message);
@property(nonatomic, copy) void (^onReady)(void);
- (instancetype)initWithWindow:(NSWindow *)window;
- (void)start;
@end
