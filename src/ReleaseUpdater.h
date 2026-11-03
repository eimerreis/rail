#import <Cocoa/Cocoa.h>

// Sparkle owns scheduling, persisted preferences, verification, and installation.
@interface ReleaseUpdater : NSObject
@property(nonatomic, readonly) BOOL configured;
@property(nonatomic, readonly) BOOL canCheckForUpdates;
@property(nonatomic) BOOL automaticallyChecksForUpdates;
@property(nonatomic) BOOL automaticallyDownloadsUpdates;
- (void)start;
- (void)checkForUpdates:(id)sender;
@end
