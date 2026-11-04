#import "NativeViews.h"

// One item in the reading sidebar.
@interface ReadingRow : NSObject
@property(nonatomic, copy) NSString *itemID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *meta;
// Small symbol before the meta text: a feed, or a lock for pages that need a login.
@property(nonatomic, copy) NSString *metaSymbol;
@property(nonatomic, strong) NSColor *metaInk;
@property(nonatomic, copy) NSString *tileKey;     // picks the letter tile's letter and colour
@property(nonatomic, strong) NSImage *favicon;
@property(nonatomic) BOOL selected;
@property(nonatomic) BOOL pending;                // the title is still an address
@property(nonatomic) CGFloat progress;            // 0 hides the bar
@property(nonatomic, strong) NSMenu *menu;
@end

@interface ReadingFeedRow : NSObject
@property(nonatomic, copy) NSString *feedID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic) NSUInteger unread;
@property(nonatomic, copy) NSString *problem;     // why the last check failed
@property(nonatomic) BOOL selected;
@property(nonatomic, strong) NSImage *favicon;
@property(nonatomic, strong) NSMenu *menu;
@end

// The sidebar while Reading is open: paste field, Inbox and Read, the items, then feeds.
@interface ReadingSidebarView : RailPanel
@property(nonatomic, readonly) NSTextField *captureField;
@property(nonatomic, copy) NSArray<ReadingRow *> *rows;
@property(nonatomic, copy) NSArray<ReadingFeedRow *> *feedRows;
@property(nonatomic) BOOL showingRead;
@property(nonatomic) NSUInteger inboxCount, readCount;
@property(nonatomic, copy) NSString *emptyText;
@property(nonatomic, copy) void (^onSubmit)(NSString *text);
@property(nonatomic, copy) void (^onSelect)(NSString *itemID);
@property(nonatomic, copy) void (^onShowRead)(BOOL read);
@property(nonatomic, copy) void (^onFeed)(NSString *feedID);
@property(nonatomic, copy) void (^onManageFeeds)(NSView *anchor);
@property(nonatomic, copy) void (^onFeedRetry)(NSString *feedID);
// ⌘⌫ on a focused item row.
@property(nonatomic, copy) void (^onRemove)(NSString *itemID);
// E, J or K pressed on a focused row.
@property(nonatomic, copy) void (^onKey)(NSString *key);
// Where Tab goes after the last row.
@property(nonatomic, weak) NSView *exitKeyView;
- (BOOL)rowIsVisible:(NSString *)itemID;
- (NSDictionary *)feedsLayout;
- (void)reload;
- (void)scrollRowIntoView:(NSString *)itemID;
@end

// The page area while Reading is open: an action bar over the article or a state message.
@interface ReaderView : RailPanel
@property(nonatomic, copy) void (^onOpenOriginal)(void);
@property(nonatomic, copy) void (^onToggleRead)(void);
@property(nonatomic, copy) void (^onRetry)(void);
@property(nonatomic, copy) void (^onLink)(NSString *url);
@property(nonatomic, copy) void (^onProgress)(CGFloat progress);
// Keys pressed while the reader has focus: e, j, k, or remove for ⌘⌫.
@property(nonatomic, copy) void (^onKey)(NSString *key);
// Source shown at the left of the action bar.
- (void)setSource:(NSString *)source tileKey:(NSString *)tileKey favicon:(NSImage *)favicon read:(BOOL)read;
- (void)showArticle:(NSDictionary *)article fallbackTitle:(NSString *)title progress:(CGFloat)progress;
// A message instead of an article. A title of nil shows the empty page without an action bar.
- (void)showMessage:(NSString *)title detail:(NSString *)detail action:(NSString *)action busy:(BOOL)busy;
// Keys keep working on a message too, so the list can be walked past pages with no article.
- (void)focusArticle;
@property(nonatomic, readonly) CGFloat scrollOffset;
// Whatever takes keyboard focus for the content on show, and where Tab goes after it.
@property(nonatomic, readonly) NSView *keyTarget;
- (void)setExitKeyView:(NSView *)view;
- (void)showFind;
@end

// The attributed article. Images are attachments that are filled in as they load.
NSAttributedString *ReadingAttributedArticle(NSDictionary *article, NSString *fallbackTitle);
