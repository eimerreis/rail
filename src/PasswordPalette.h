#import <Cocoa/Cocoa.h>
@class PasswordService;
typedef void (^RailPasswordFill)(NSString *username, NSString *password, BOOL creating, void (^completion)(NSString *status));

@interface PasswordPalette : NSObject <NSTextFieldDelegate, NSWindowDelegate>
- (instancetype)initWithService:(PasswordService *)service parent:(NSWindow *)parent url:(NSString *)url title:(NSString *)title fill:(RailPasswordFill)fill;
- (void)show;
- (void)close;
- (void)invalidatePage;
- (BOOL)handleShortcut:(NSEvent *)event;
@property(nonatomic, readonly) NSPanel *panel;
// Disposable-profile smoke tests use native controls; no credential values are exported.
- (void)driveFixture:(NSDictionary *)command;
- (NSDictionary *)automationState;
@end
