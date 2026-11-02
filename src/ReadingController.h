#import "ReadingView.h"
#include "include/cef_request_context.h"

// Owns the reading list: its data, feeds, article cache and the views that show it. It knows
// nothing about tabs or Spaces; the browser supplies those through the blocks below.
@interface ReadingController : NSObject
@property(nonatomic, readonly) ReadingSidebarView *sidebar;
@property(nonatomic, readonly) ReaderView *reader;
@property(nonatomic, copy) CefRefPtr<CefRequestContext> (^contextForSession)(NSString *session);
// The session a newly saved address belongs to.
@property(nonatomic, copy) NSString *(^sessionForURL)(NSString *url);
@property(nonatomic, copy) NSArray<NSDictionary *> *(^namedSessions)(void);
@property(nonatomic, copy) NSString *(^sessionName)(NSString *session);
@property(nonatomic, copy) NSImage *(^faviconForURL)(NSString *url);
@property(nonatomic, copy) void (^storeFavicon)(NSString *url, NSData *png);
@property(nonatomic, copy) void (^openURL)(NSString *url, NSString *session);
@property(nonatomic, copy) void (^onStatus)(NSString *message);
// The rail badge, address bar or session picker may need updating.
@property(nonatomic, copy) void (^onChromeChange)(void);
@property(nonatomic, copy) void (^askForText)(NSString *prompt, void (^completion)(NSString *text));
@property(nonatomic, copy) void (^confirm)(NSString *title, NSString *detail, NSString *action, void (^completion)(void));
@property(nonatomic, readonly) NSUInteger unreadCount;
// The selected item's page, session and whether the reader is showing it as an article.
@property(nonatomic, readonly, copy) NSString *selectedURL, *selectedTitle, *selectedSession;
@property(nonatomic, readonly) BOOL selectedHasArticle;
// NSError-style message from loading, shown once at startup.
@property(nonatomic, readonly, copy) NSString *loadProblem;
- (instancetype)initWithDirectory:(NSString *)directory host:(NSView *)host;
// Call once the app is running: queues unfinished pages and starts checking feeds.
- (void)start;
// Call when Reading opens: shows the last item, or the first one in the inbox.
- (void)opened;
- (void)saveNow;
- (BOOL)saveURL:(NSString *)text;
- (void)saveCurrentPage:(NSString *)url title:(NSString *)title;
// Saves the clipboard's link. NO when it doesn't hold one.
- (BOOL)saveFromPasteboard;
- (void)setSelectedSessionTo:(NSString *)session;
- (void)toggleSelectedRead;
- (void)reloadSelected;
- (void)selectNeighbour:(NSInteger)delta;
// The session the hidden reader browser is using, whose context must stay open.
@property(nonatomic, readonly, copy) NSString *activeSession;
- (void)shutdown:(void (^)(void))done;
- (NSDictionary *)automationState;
- (void)runAutomation:(NSDictionary *)command action:(NSString *)action;
@end
