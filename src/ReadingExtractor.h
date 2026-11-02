#import <Cocoa/Cocoa.h>
#include "include/cef_request_context.h"

// Turns web pages into articles for the reader. Each page loads in a hidden browser that uses
// the item's session, one at a time, and can't open popups, download, or show dialogs.
// The result is plain data: title, site, byline, published, words, login and blocks.
@interface ReadingExtractor : NSObject
// The hidden browsers are placed in this view.
- (instancetype)initWithHost:(NSView *)host;
// A nil article means the page could not be loaded. Urgent pages go first.
- (void)extract:(NSString *)url key:(NSString *)key context:(CefRefPtr<CefRequestContext>)context session:(NSString *)session urgent:(BOOL)urgent completion:(void (^)(NSDictionary *article))completion;
- (void)cancel:(NSString *)key;
// Whether this page is being loaded or waiting its turn.
- (BOOL)isExtracting:(NSString *)key;
// A site's icon, when a page being read advertises one.
@property(nonatomic, copy) void (^onFavicon)(NSString *url, NSData *png);
// The session of the hidden browser, whose context must stay alive while it runs.
@property(nonatomic, readonly, copy) NSString *activeSession;
// Closes any browser and calls done once none is left. Chromium can't shut down before that.
- (void)shutdown:(void (^)(void))done;
@end
