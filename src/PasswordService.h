#import <Foundation/Foundation.h>

// Main-thread API; the helper performs SDK work off the app's event loop.
@interface PasswordService : NSObject
@property(nonatomic, readonly, copy) NSString *connectedAccount;
// Only set by the browser's explicit disposable-profile automation mode.
@property(nonatomic, copy) NSString *fixtureOrigin;
- (void)request:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion;
- (void)stop;
@end
