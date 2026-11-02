#import <Cocoa/Cocoa.h>
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_download_handler.h"

@interface BrowserController : NSObject <NSWindowDelegate, NSTextFieldDelegate>
@property(nonatomic, readonly) NSWindow *window;
- (instancetype)initWithDataDirectory:(NSString *)directory automation:(BOOL)automation;
- (void)start;
- (void)quit:(id)sender;
- (BOOL)handleShortcut:(NSEvent *)event;
- (void)passwordReply:(CefRefPtr<CefProcessMessage>)message tab:(const std::string &)tab generation:(uint64_t)generation;
- (void)passwordPageNavigating:(const std::string &)tab generation:(uint64_t)generation;
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
- (void)findResult:(int)identifier count:(int)count ordinal:(int)ordinal final:(BOOL)finalUpdate tab:(const std::string &)tab generation:(uint64_t)generation;
- (void)openLinkFrom:(const std::string &)source generation:(uint64_t)generation url:(NSString *)url background:(BOOL)background;
- (BOOL)preparePopupFrom:(const std::string &)source generation:(uint64_t)generation popupID:(int)popupID url:(NSString *)url windowInfo:(CefWindowInfo &)info client:(CefRefPtr<CefClient> &)client;
- (void)popupAbortedFrom:(const std::string &)source generation:(uint64_t)generation popupID:(int)popupID;
- (void)setStatus:(NSString *)message;
- (void)requestExternalAppURL:(NSString *)url fromPage:(NSString *)page tab:(const std::string &)tab generation:(uint64_t)generation;
- (void)inspectTab:(const std::string &)tab generation:(uint64_t)generation at:(CefPoint)point;
- (void)devToolsCreated:(CefRefPtr<CefBrowser>)devTools tab:(const std::string &)tab generation:(uint64_t)generation;
- (void)devToolsClosed:(CefRefPtr<CefBrowser>)devTools tab:(const std::string &)tab generation:(uint64_t)generation;
- (BOOL)handleDevToolsShortcut:(NSEvent *)event;
// A free path in the Downloads folder for a new download, or nil to let Chromium cancel it.
- (NSString *)downloadPathForName:(NSString *)name download:(uint32_t)downloadID;
- (void)downloadUpdated:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback;
@end
