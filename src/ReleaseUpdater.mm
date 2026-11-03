#import "ReleaseUpdater.h"
#import <Sparkle/Sparkle.h>

@implementation ReleaseUpdater {
  SPUStandardUpdaterController *_controller;
}
- (instancetype)init {
  if ((self=[super init])) {
    NSDictionary *info=NSBundle.mainBundle.infoDictionary;
    NSURL *feed=[NSURL URLWithString:info[@"SUFeedURL"] ?: @""];
    NSData *key=[[NSData alloc] initWithBase64EncodedString:info[@"SUPublicEDKey"] ?: @"" options:0];
    _configured=[feed.scheme isEqualToString:@"https"] && feed.host.length && key.length==32;
    if (_configured) _controller=[[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO updaterDelegate:nil userDriverDelegate:nil];
  }
  return self;
}
- (void)start { if (_configured) [_controller startUpdater]; }
- (BOOL)canCheckForUpdates { return _controller.updater.canCheckForUpdates; }
- (void)checkForUpdates:(id)sender { if (self.canCheckForUpdates) [_controller checkForUpdates:sender]; }
- (BOOL)automaticallyChecksForUpdates { return _controller.updater.automaticallyChecksForUpdates; }
- (void)setAutomaticallyChecksForUpdates:(BOOL)enabled { _controller.updater.automaticallyChecksForUpdates=enabled; }
- (BOOL)automaticallyDownloadsUpdates { return _controller.updater.automaticallyDownloadsUpdates; }
- (void)setAutomaticallyDownloadsUpdates:(BOOL)enabled { _controller.updater.automaticallyDownloadsUpdates=enabled; }
@end
