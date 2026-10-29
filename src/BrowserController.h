#import <Cocoa/Cocoa.h>
#include "include/cef_browser.h"
#include "include/cef_client.h"

@interface BrowserController : NSObject <NSWindowDelegate, NSTextFieldDelegate>
@property(nonatomic, readonly) NSWindow *window;
- (instancetype)initWithDataDirectory:(NSString *)directory automation:(BOOL)automation;
- (void)start;
- (void)quit:(id)sender;
- (BOOL)handleShortcut:(NSEvent *)event;
- (void)openExternalURLs:(NSArray<NSURL *> *)urls;
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser tab:(const std::string &)tab generation:(uint64_t)generation;
- (void)browserReadyToClose:(CefRefPtr<CefBrowser>)browser tab:(const std::string &)tab generation:(uint64_t)generation;
- (void)browserClosed:(const std::string &)tab generation:(uint64_t)generation;
- (void)closeCancelled:(const std::string &)tab generation:(uint64_t)generation;
- (void)updateTitle:(NSString *)title tab:(const std::string &)tab generation:(uint64_t)generation;
- (void)updateFavicon:(NSString *)iconURL tab:(const std::string &)tab generation:(uint64_t)generation;
- (void)updateURL:(NSString *)url tab:(const std::string &)tab generation:(uint64_t)generation;
- (void)updateLoading:(BOOL)loading back:(BOOL)back forward:(BOOL)forward tab:(const std::string &)tab generation:(uint64_t)generation;
- (void)loadFailed:(NSString *)message tab:(const std::string &)tab generation:(uint64_t)generation;
- (BOOL)preparePopupFrom:(const std::string &)source generation:(uint64_t)generation popupID:(int)popupID url:(NSString *)url windowInfo:(CefWindowInfo &)info client:(CefRefPtr<CefClient> &)client;
- (void)popupAbortedFrom:(const std::string &)source generation:(uint64_t)generation popupID:(int)popupID;
- (void)setStatus:(NSString *)message;
@end
