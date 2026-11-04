#import "ReadingController.h"
#import "FeedParser.h"
#import "ReadingExtractor.h"
#import "StateStore.h"
#include <cmath>

namespace {
NSString *S(const std::string &s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
std::string C(NSString *s) { return std::string(s.UTF8String ?: ""); }
double Now() { return NSDate.date.timeIntervalSince1970; }
// Below this many words a page isn't an article, so the reader would only show a fragment of it.
constexpr int ReaderMinimumWords = 80;
constexpr NSTimeInterval FeedCheckInterval = 30*60;
constexpr NSUInteger MaxFeedBytes = 8*1024*1024;

// "2 h", "yesterday", "Tue", "12 Oct".
NSString *Age(double when, double now) {
  const double seconds = MAX(0,now-when);
  if (seconds < 90) return @"just now";
  if (seconds < 3600) return [NSString stringWithFormat:@"%.0f min",seconds/60];
  NSCalendar *calendar = NSCalendar.currentCalendar; NSDate *date = [NSDate dateWithTimeIntervalSince1970:when];
  if ([calendar isDateInToday:date]) return [NSString stringWithFormat:@"%.0f h",seconds/3600];
  if ([calendar isDateInYesterday:date]) return @"yesterday";
  NSDateFormatter *format = [[NSDateFormatter alloc] init];
  format.dateFormat = seconds < 6*86400 ? @"EEE" : @"d MMM";
  return [format stringFromDate:date];
}
// A pasted link. Anything else is rejected rather than turned into a search.
NSString *LinkFromText(NSString *input) {
  NSString *text = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!text.length || [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return nil;
  if ([text rangeOfString:@"://"].location == NSNotFound) {
    if ([text rangeOfString:@"."].location == NSNotFound && ![text hasPrefix:@"localhost"]) return nil;
    if ([text hasPrefix:@"javascript:"] || [text hasPrefix:@"file:"] || [text hasPrefix:@"data:"] || [text hasPrefix:@"mailto:"]) return nil;
    BOOL local = [text hasPrefix:@"localhost"] || [text hasPrefix:@"127."];
    text = [(local ? @"http://" : @"https://") stringByAppendingString:text];
  }
  NSURLComponents *parts = [NSURLComponents componentsWithString:text];
  if (!parts.host.length || ![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]) return nil;
  return parts.URL.absoluteString;
}
}

@implementation ReadingController {
  rail::ReadingList _list;
  NSString *_directory, *_selectedID, *_feedFilter;
  BOOL _showingRead, _dirty, _savingAllowed, _shuttingDown;
  ReadingExtractor *_extractor;
  NSURLSession *_feedSession;
  NSTimer *_saveTimer, *_feedTimer;
  NSMutableSet<NSString *> *_checkingFeeds, *_retried;
  NSDictionary *_article;
  NSString *_loadProblem;
  // Where the selection sits in the list, for moving on after the selected item leaves it.
  NSInteger _cursor;
}
- (instancetype)initWithDirectory:(NSString *)directory host:(NSView *)host {
  if ((self = [super init])) {
    _directory = [directory copy]; _savingAllowed = YES; _checkingFeeds = [NSMutableSet set]; _retried = [NSMutableSet set];
    NSError *error = nil;
    if (!rail::LoadReading(_directory,_list,&error)) {
      NSString *path = [_directory stringByAppendingPathComponent:@"reading.json"];
      NSString *backup = [_directory stringByAppendingPathComponent:[NSString stringWithFormat:@"reading-recovery-%.0f.json",Now()]];
      _savingAllowed = [NSFileManager.defaultManager copyItemAtPath:path toPath:backup error:nil];
      _loadProblem = _savingAllowed ? @"The reading list could not be read. A recovery copy was kept." : @"Could not read the reading list. Saving it is disabled to protect the original.";
    }
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration; config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 40;
    config.HTTPAdditionalHeaders = @{@"Accept":@"application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8, */*;q=0.5"};
    _feedSession = [NSURLSession sessionWithConfiguration:config];
    _extractor = [[ReadingExtractor alloc] initWithHost:host];
    __weak ReadingController *weak = self;
    _extractor.onFavicon = ^(NSString *url, NSData *png) { ReadingController *strong = weak; if (strong.storeFavicon) strong.storeFavicon(url,png); };
    _sidebar = [[ReadingSidebarView alloc] initWithFrame:NSZeroRect];
    _sidebar.onSubmit = ^(NSString *text) { ReadingController *strong = weak; if ([strong saveURL:text]) strong->_sidebar.captureField.stringValue = @""; };
    _sidebar.onSelect = ^(NSString *itemID) { [weak select:itemID focus:YES]; };
    _sidebar.onShowRead = ^(BOOL read) { ReadingController *strong = weak; if (!strong) return; strong->_showingRead = read; [strong refreshViews]; };
    _sidebar.onFeed = ^(NSString *feedID) { ReadingController *strong = weak; if (!strong) return; strong->_feedFilter = [strong->_feedFilter isEqual:feedID] ? nil : feedID; [strong refreshViews]; };
    _sidebar.onManageFeeds = ^(NSView *anchor) { [weak showFeedMenuFrom:anchor]; };
    _sidebar.onFeedRetry = ^(NSString *feedID) { [weak checkFeed:feedID]; };
    _sidebar.onRemove = ^(NSString *itemID) { [weak confirmRemoving:itemID]; };
    _sidebar.onKey = ^(NSString *key) { ReadingController *strong = weak; if (strong.reader.onKey) strong.reader.onKey(key); };
    _reader = [[ReaderView alloc] initWithFrame:NSZeroRect];
    _reader.onOpenOriginal = ^{ [weak openSelectedInTab]; };
    _reader.onToggleRead = ^{ [weak toggleSelectedRead]; };
    _reader.onLink = ^(NSString *url) { ReadingController *strong = weak; if (!strong) return; if (strong.openURL) strong.openURL(url,strong.selectedSession); };
    _reader.onProgress = ^(CGFloat progress) { [weak progressChanged:progress]; };
    _reader.onKey = ^(NSString *key) {
      ReadingController *strong = weak;
      if ([key isEqual:@"e"]) [strong toggleSelectedRead];
      else if ([key isEqual:@"remove"]) { if (strong->_selectedID) [strong confirmRemoving:strong->_selectedID]; }
      else [strong selectNeighbour:[key isEqual:@"j"] ? 1 : -1];
    };
  }
  return self;
}
- (void)dealloc { [_saveTimer invalidate]; [_feedTimer invalidate]; [_feedSession invalidateAndCancel]; }
- (NSString *)loadProblem { return _loadProblem; }
- (NSUInteger)unreadCount { return _list.unreadCount(); }
- (const rail::ReadingItem *)selected { return _selectedID ? _list.item(C(_selectedID)) : nullptr; }
- (NSString *)selectedURL { const auto *item = [self selected]; return item ? S(item->url) : nil; }
- (NSString *)selectedTitle { const auto *item = [self selected]; return item ? S(item->title.empty() ? item->site : item->title) : nil; }
- (NSString *)selectedSession { const auto *item = [self selected]; return item ? S(item->sessionID) : nil; }
- (BOOL)selectedHasArticle { const auto *item = [self selected]; return item && item->reader == rail::ReaderStatus::Ready; }
- (NSString *)activeSession { return _extractor.activeSession; }
- (void)start {
  __weak ReadingController *weak = self;
  // Links saved before the last quit may not have been read yet. Feed items wait until they are opened.
  for (const auto &item : _list.state.items) if (item.reader == rail::ReaderStatus::Pending && item.feedID.empty() && item.readAt <= 0) [self extractItem:S(item.id) urgent:NO];
  _feedTimer = [NSTimer scheduledTimerWithTimeInterval:FeedCheckInterval repeats:YES block:^(NSTimer *timer) { (void)timer; [weak checkFeeds]; }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [weak checkFeeds]; });
  [self refreshViews];
}
- (void)opened {
  if (![self selected]) { auto inbox = _list.shown(false); _selectedID = inbox.empty() ? nil : S(inbox.front()->id); }
  if (_selectedID) [self select:_selectedID focus:NO]; else { [self showSelected]; [self refreshViews]; }
}
#pragma mark Saving
- (void)markDirty {
  _dirty = YES; [_saveTimer invalidate]; __weak ReadingController *weak = self;
  _saveTimer = [NSTimer scheduledTimerWithTimeInterval:.5 repeats:NO block:^(NSTimer *timer) { (void)timer; [weak saveNow]; }];
}
- (void)saveNow {
  [_saveTimer invalidate]; _saveTimer = nil; if (!_dirty || !_savingAllowed) return;
  NSError *error = nil; _dirty = !rail::SaveReading(_directory,_list,&error);
  if (_dirty) [self status:[NSString stringWithFormat:@"Could not save the reading list: %@",error.localizedDescription]];
}
- (void)status:(NSString *)message { if (self.onStatus) self.onStatus(message); }
- (BOOL)saveURL:(NSString *)text {
  NSString *url = LinkFromText(text);
  if (!url) { [self status:@"That doesn't look like a link. Links use http or https."]; return NO; }
  [self addURL:url title:nil]; return YES;
}
- (void)saveCurrentPage:(NSString *)url title:(NSString *)title {
  NSString *link = LinkFromText(url);
  if (!link) { [self status:@"Only web pages can be saved to the reading list."]; return; }
  [self addURL:link title:title];
}
- (void)addURL:(NSString *)url title:(NSString *)title {
  bool created = false; const std::string id = _list.add(C(url),C(self.sessionForURL ? self.sessionForURL(url) : @""),Now(),&created);
  if (id.empty()) { [self status:@"Only web pages can be saved to the reading list."]; return; }
  if (title.length) if (auto *item = _list.item(id); item && item->title.empty()) item->title = C(title);
  [self status:created ? @"Saved to your reading list." : @"Already in your list. Moved it to the top."];
  _showingRead = NO; _feedFilter = nil; [self markDirty];
  if (created) [self extractItem:S(id) urgent:YES];
  [self refreshViews];
  // The first link saved has nothing else to compete with.
  if (!_selectedID) [self select:S(id) focus:NO];
}
- (BOOL)saveFromPasteboard {
  NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
  if (!LinkFromText(text)) return NO;
  return [self saveURL:text];
}
#pragma mark Extraction
- (void)extractItem:(NSString *)itemID urgent:(BOOL)urgent {
  const auto *item = _list.item(C(itemID)); if (!item || !self.contextForSession) return;
  NSString *session = S(item->sessionID);
  CefRefPtr<CefRequestContext> context = self.contextForSession(session);
  __weak ReadingController *weak = self;
  [_extractor extract:S(item->url) key:itemID context:context session:session urgent:urgent completion:^(NSDictionary *article) { [weak finishExtraction:itemID article:article]; }];
}
- (NSString *)articlePath:(NSString *)itemID {
  return [[[_directory stringByAppendingPathComponent:@"Reading"] stringByAppendingPathComponent:itemID] stringByAppendingPathExtension:@"json"];
}
- (NSDictionary *)loadArticle:(NSString *)itemID {
  NSData *data = [NSData dataWithContentsOfFile:[self articlePath:itemID]];
  id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
- (void)storeArticle:(NSDictionary *)article item:(NSString *)itemID {
  NSString *path = [self articlePath:itemID];
  [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
  [[NSJSONSerialization dataWithJSONObject:article options:0 error:nil] writeToFile:path atomically:YES];
}
- (void)removeArticle:(NSString *)itemID { [NSFileManager.defaultManager removeItemAtPath:[self articlePath:itemID] error:nil]; }
- (void)finishExtraction:(NSString *)itemID article:(NSDictionary *)article {
  auto *item = _list.item(C(itemID)); if (!item) return;
  // A page that didn't load says nothing about the page itself, so a blip gets a second try.
  if (!article && ![_retried containsObject:itemID]) { [_retried addObject:itemID]; [self extractItem:itemID urgent:NO]; return; }
  [_retried removeObject:itemID];
  const int words = [article[@"words"] intValue];
  NSString *title = [article[@"title"] isKindOfClass:NSString.class] ? article[@"title"] : nil;
  if (title.length && (item->title.empty() || item->feedID.empty())) item->title = C(title);
  if ([article[@"login"] boolValue]) item->reader = rail::ReaderStatus::NeedsLogin;
  else if (article && words >= ReaderMinimumWords) { item->reader = rail::ReaderStatus::Ready; item->minutes = MAX(1,(int)ceil(words/220.0)); [self storeArticle:article item:itemID]; }
  else item->reader = rail::ReaderStatus::Unavailable;
  [self markDirty];
  if ([_selectedID isEqual:itemID]) [self showSelected];
  [self refreshViews];
}
#pragma mark Selection
- (void)select:(NSString *)itemID focus:(BOOL)focus {
  const auto *item = _list.item(C(itemID)); if (!item) return;
  // The reader can't show these, so they go straight to a tab. Opening never marks anything read.
  if (focus && (item->reader == rail::ReaderStatus::NeedsLogin || item->reader == rail::ReaderStatus::Unavailable)) { _selectedID = itemID; [self openSelectedInTab]; [self showSelected]; [self refreshViews]; return; }
  _selectedID = itemID; [self showSelected]; [self refreshViews];
  if (focus) [_reader focusArticle];
}
- (void)showSelected {
  const auto *item = [self selected];
  if (!item) { [_reader showMessage:nil detail:self.emptyDetail action:nil busy:NO]; if (self.onChromeChange) self.onChromeChange(); return; }
  NSString *itemID = _selectedID, *url = S(item->url);
  NSMutableArray *source = [NSMutableArray arrayWithObject:S(item->site)];
  if (item->minutes > 0) [source addObject:[NSString stringWithFormat:@"%d min",item->minutes]];
  [_reader setSource:[source componentsJoinedByString:@" · "] tileKey:S(item->site) favicon:self.faviconForURL ? self.faviconForURL(url) : nil read:item->readAt>0];
  NSString *session = self.sessionName ? self.sessionName(S(item->sessionID)) : @"this";
  switch (item->reader) {
    case rail::ReaderStatus::Ready: {
      NSDictionary *article = [self loadArticle:itemID];
      if (article) { _article = article; [_reader showArticle:article fallbackTitle:self.selectedTitle progress:item->progress]; break; }
      // The cached copy is gone; get it again.
      _list.item(C(itemID))->reader = rail::ReaderStatus::Pending; [self markDirty];
    }
    [[fallthrough]];
    case rail::ReaderStatus::Pending:
      [_reader showMessage:@"Getting this page ready" detail:DisplayHost(url) action:nil busy:YES];
      [self extractItem:itemID urgent:YES]; break;
    case rail::ReaderStatus::NeedsLogin:
      [_reader showMessage:@"This page needs a login" detail:[NSString stringWithFormat:@"The reader couldn't get past the login in your %@ session. Open the page and sign in, then reload here.",session] action:@"Open in a tab" busy:NO]; break;
    case rail::ReaderStatus::Unavailable:
      [_reader showMessage:@"No reader view for this page" detail:@"It didn't load, or there isn't enough article text on it to read plainly." action:@"Open in a tab" busy:NO]; break;
  }
  if (self.onChromeChange) self.onChromeChange();
}
static NSString *DisplayHost(NSString *url) { return S(rail::ReadingList::siteOf(C(url))); }
- (NSString *)emptyDetail { return @"Copy a link and press ⌘V here, or save the page you're on with ⌘⇧D."; }
- (void)progressChanged:(CGFloat)progress {
  auto *item = _list.item(C(_selectedID ?: @"")); if (!item || fabs(item->progress-progress) < .005) return;
  const BOOL visibleChange = rail::ReadingList::minutesLeft(*item) != rail::ReadingList::minutesLeft({.minutes=item->minutes,.progress=progress}) || (item->progress<=0) != (progress<=0);
  _list.setProgress(item->id,progress); [self markDirty];
  if (visibleChange) [self refreshViews];
}
- (void)selectNeighbour:(NSInteger)delta {
  auto shown = _list.shown(_showingRead,C(_feedFilter ?: @"")); if (shown.empty()) return;
  NSInteger index = -1; for (size_t i=0;i<shown.size();i++) if (shown[i]->id==C(_selectedID ?: @"")) index = (NSInteger)i;
  // A selected item that left the list was at the cursor, so the next one has moved up into its place.
  NSInteger next = index>=0 ? index+delta : delta>0 ? _cursor : _cursor-1;
  next = MIN((NSInteger)shown.size()-1,MAX(0,next));
  const std::string id = shown[(size_t)next]->id;
  _selectedID = S(id); [self showSelected]; [self refreshViews]; [_sidebar scrollRowIntoView:_selectedID]; [_reader focusArticle];
}
- (void)toggleSelectedRead {
  const auto *item = [self selected]; if (!item) return;
  if (item->readAt > 0) _list.markUnread(item->id); else _list.markRead(item->id,Now());
  [self markDirty]; [self showHeaderOnly]; [self refreshViews];
}
// Marking read leaves the article where it is, so the same key undoes it.
- (void)showHeaderOnly {
  const auto *item = [self selected]; if (!item) return;
  NSMutableArray *source = [NSMutableArray arrayWithObject:S(item->site)];
  if (item->minutes > 0) [source addObject:[NSString stringWithFormat:@"%d min",item->minutes]];
  [_reader setSource:[source componentsJoinedByString:@" · "] tileKey:S(item->site) favicon:self.faviconForURL ? self.faviconForURL(S(item->url)) : nil read:item->readAt>0];
  if (self.onChromeChange) self.onChromeChange();
}
- (void)openSelectedInTab { if (self.openURL && self.selectedURL) self.openURL(self.selectedURL,self.selectedSession); }
- (void)reloadSelected {
  auto *item = _list.item(C(_selectedID ?: @"")); if (!item) return;
  [_extractor cancel:_selectedID]; [_retried removeObject:_selectedID];
  item->reader = rail::ReaderStatus::Pending; [self markDirty]; [self showSelected]; [self refreshViews];
}
- (void)setSelectedSessionTo:(NSString *)session {
  auto *item = _list.item(C(_selectedID ?: @"")); if (!item || item->sessionID==C(session)) return;
  item->sessionID = C(session); [self reloadSelected];
}
#pragma mark Views
- (NSMenu *)menuForItem:(const rail::ReadingItem &)item {
  NSMenu *menu = [[NSMenu alloc] init]; NSString *itemID = S(item.id);
  NSArray *entries = @[@[@"Open in Tab",@"menuOpen:"],@[item.readAt>0 ? @"Mark Unread" : @"Mark Read",@"menuToggleRead:"],@[@"Try Reader Again",@"menuRetry:"],@[@"Copy Link",@"menuCopy:"],@[@"Remove from List",@"menuRemove:"]];
  for (NSArray *entry in entries) { NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""]; menuItem.target = self; menuItem.representedObject = itemID; [menu addItem:menuItem]; }
  return menu;
}
- (void)menuOpen:(NSMenuItem *)sender { const auto *item = _list.item(C(sender.representedObject)); if (item && self.openURL) self.openURL(S(item->url),S(item->sessionID)); }
- (void)menuToggleRead:(NSMenuItem *)sender {
  const auto *item = _list.item(C(sender.representedObject)); if (!item) return;
  if (item->readAt > 0) _list.markUnread(item->id); else _list.markRead(item->id,Now());
  [self markDirty]; [self showHeaderOnly]; [self refreshViews];
}
- (void)menuRetry:(NSMenuItem *)sender { _selectedID = sender.representedObject; [self reloadSelected]; }
- (void)menuCopy:(NSMenuItem *)sender { const auto *item = _list.item(C(sender.representedObject)); if (!item) return; [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:S(item->url) forType:NSPasteboardTypeString]; [self status:@"Link copied."]; }
- (void)menuRemove:(NSMenuItem *)sender { [self removeItem:sender.representedObject]; }
// A key press is easy to make by accident, and a removed item and its article can't be brought back.
- (void)confirmRemoving:(NSString *)itemID {
  const auto *item = _list.item(C(itemID)); if (!item || !self.confirm) return;
  __weak ReadingController *weak = self;
  self.confirm([NSString stringWithFormat:@"Remove “%@”?",S(item->title.empty() ? item->url : item->title)],@"It leaves your reading list and its saved article is deleted.",@"Remove",^{ [weak removeItem:itemID]; });
}
- (void)removeItem:(NSString *)itemID {
  [_extractor cancel:itemID]; _list.remove(C(itemID)); [self removeArticle:itemID]; [self markDirty];
  if ([_selectedID isEqual:itemID]) {
    // The next row has moved up into its place, so the list keeps the same position.
    auto shown = _list.shown(_showingRead,C(_feedFilter ?: @""));
    _selectedID = shown.empty() ? nil : S(shown[(size_t)MIN((NSInteger)shown.size()-1,_cursor)]->id); [self showSelected];
  }
  [self refreshViews];
}
- (void)refreshViews {
  const double now = Now();
  if (_feedFilter && !_list.feed(C(_feedFilter))) _feedFilter = nil;
  NSMutableArray<ReadingRow *> *rows = [NSMutableArray array];
  for (const auto *item : _list.shown(_showingRead,C(_feedFilter ?: @""))) {
    ReadingRow *row = [[ReadingRow alloc] init]; row.itemID = S(item->id);
    const BOOL noTitle = item->title.empty();
    row.title = noTitle ? S(item->url) : S(item->title); row.pending = noTitle && item->reader==rail::ReaderStatus::Pending;
    if ([_selectedID isEqual:row.itemID]) _cursor = (NSInteger)rows.count;
    row.tileKey = S(item->site); row.favicon = self.faviconForURL ? self.faviconForURL(S(item->url)) : nil; row.selected = [_selectedID isEqual:row.itemID]; row.menu = [self menuForItem:*item];
    NSString *session = self.sessionName ? self.sessionName(S(item->sessionID)) : @"";
    NSMutableArray *meta = [NSMutableArray arrayWithObject:S(item->site)];
    if (item->reader==rail::ReaderStatus::NeedsLogin) { [meta setArray:@[@"Needs login",[NSString stringWithFormat:@"opens as a tab in %@",session]]]; row.metaSymbol = @"lock"; row.metaInk = RailColor(0x7a5838); }
    else if (item->reader==rail::ReaderStatus::Unavailable) { [meta setArray:@[S(item->site),@"opens as a tab"]]; }
    else if (row.pending && [_extractor isExtracting:row.itemID]) { [meta setArray:@[[@"Saved " stringByAppendingString:Age(item->added,now)],@"fetching title"]]; }
    else {
      if (!item->feedID.empty()) row.metaSymbol = @"dot.radiowaves.up.forward";
      if (item->minutes > 0) [meta addObject:item->progress>.01 && item->progress<.99 && item->readAt<=0 ? [NSString stringWithFormat:@"%d min left",rail::ReadingList::minutesLeft(*item)] : [NSString stringWithFormat:@"%d min",item->minutes]];
      if (!(item->minutes>0 && item->progress>.01)) [meta addObject:Age(item->readAt>0 ? item->readAt : item->added,now)];
    }
    row.meta = [meta componentsJoinedByString:@" · "];
    row.progress = item->readAt<=0 && item->progress>.01 && item->progress<.99 ? item->progress : 0;
    [rows addObject:row];
  }
  _sidebar.rows = rows; _sidebar.inboxCount = _list.shown(false,C(_feedFilter ?: @"")).size(); _sidebar.readCount = _list.shown(true,C(_feedFilter ?: @"")).size(); _sidebar.showingRead = _showingRead;
  _sidebar.emptyText = _showingRead ? @"Items you mark read land here." : _feedFilter ? (_list.feed(C(_feedFilter))->error.empty() ? @"Nothing new from this feed." : [NSString stringWithFormat:@"%@. Nothing new until it answers again.",S(_list.feed(C(_feedFilter))->error)]) : @"Your inbox is empty.";
  NSMutableArray<ReadingFeedRow *> *feeds = [NSMutableArray array];
  for (const auto &feed : _list.state.feeds) {
    ReadingFeedRow *row = [[ReadingFeedRow alloc] init]; row.feedID = S(feed.id); row.title = S(feed.title); row.unread = _list.unreadCount(feed.id); row.problem = feed.error.empty() ? nil : S(feed.error); row.selected = [_feedFilter isEqual:row.feedID];
    row.favicon = self.faviconForURL ? self.faviconForURL(S(feed.url)) : nil; row.menu = [self menuForFeed:feed];
    [feeds addObject:row];
  }
  _sidebar.feedRows = feeds; _sidebar.exitKeyView = _reader.keyTarget; [_reader setExitKeyView:_sidebar.captureField]; [_sidebar reload];
  if (self.onChromeChange) self.onChromeChange();
}
#pragma mark Feeds
- (NSMenu *)menuForFeed:(const rail::Feed &)feed {
  NSMenu *menu = [[NSMenu alloc] init]; NSString *feedID = S(feed.id);
  for (NSArray *entry in @[@[@"Mark All Read",@"menuFeedAllRead:"],@[@"Check Now",@"menuFeedCheck:"],@[@"Copy Feed Address",@"menuFeedCopy:"],@[@"Remove Feed…",@"menuFeedRemove:"]]) { NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""]; item.target = self; item.representedObject = feedID; [menu addItem:item]; }
  return menu;
}
- (void)showFeedMenuFrom:(NSView *)anchor {
  NSMenu *menu = [[NSMenu alloc] init];
  NSMenuItem *add = [[NSMenuItem alloc] initWithTitle:@"Add Feed…" action:@selector(menuAddFeed:) keyEquivalent:@""]; add.target = self; [menu addItem:add];
  if (_list.unreadCount(C(_feedFilter ?: @""))) { NSMenuItem *all = [[NSMenuItem alloc] initWithTitle:_feedFilter ? @"Mark This Feed Read" : @"Mark Everything Read" action:@selector(menuAllRead:) keyEquivalent:@""]; all.target = self; [menu addItem:all]; }
  if (!_list.state.feeds.empty()) { NSMenuItem *check = [[NSMenuItem alloc] initWithTitle:@"Check All Now" action:@selector(menuCheckAll:) keyEquivalent:@""]; check.target = self; [menu addItem:check]; }
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,anchor.bounds.size.height+2) inView:anchor];
}
- (void)menuAddFeed:(id)sender {
  (void)sender; __weak ReadingController *weak = self;
  if (self.askForText) self.askForText(@"Feed or site address",^(NSString *text) { if (text.length) [weak addFeed:text]; });
}
- (void)menuAllRead:(id)sender {
  (void)sender; for (const auto *item : _list.shown(false,C(_feedFilter ?: @""))) _list.markRead(item->id,Now());
  [self markDirty]; [self showHeaderOnly]; [self refreshViews];
}
- (void)menuCheckAll:(id)sender { (void)sender; [self checkFeeds]; }
- (void)menuFeedAllRead:(NSMenuItem *)sender {
  for (const auto *item : _list.shown(false,C(sender.representedObject))) _list.markRead(item->id,Now());
  [self markDirty]; [self showHeaderOnly]; [self refreshViews];
}
- (void)menuFeedCheck:(NSMenuItem *)sender { [self checkFeed:sender.representedObject]; }
- (void)menuFeedCopy:(NSMenuItem *)sender { const auto *feed = _list.feed(C(sender.representedObject)); if (!feed) return; [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:S(feed->url) forType:NSPasteboardTypeString]; }
- (void)menuFeedRemove:(NSMenuItem *)sender {
  const auto *feed = _list.feed(C(sender.representedObject)); if (!feed) return;
  NSString *feedID = sender.representedObject; __weak ReadingController *weak = self;
  if (self.confirm) self.confirm([NSString stringWithFormat:@"Remove %@?",S(feed->title)],@"Its items leave your reading list, read or not. Links you saved yourself stay.",@"Remove",^{ [weak removeFeed:feedID]; });
}
- (void)removeFeed:(NSString *)feedID {
  for (const auto &itemID : _list.removeFeed(C(feedID))) { [_extractor cancel:S(itemID)]; [self removeArticle:S(itemID)]; }
  if (![self selected]) { auto inbox = _list.shown(false); _selectedID = inbox.empty() ? nil : S(inbox.front()->id); [self showSelected]; }
  [self markDirty]; [self refreshViews];
}
- (void)fetch:(NSString *)url completion:(void (^)(NSData *data, NSString *problem))completion {
  NSURL *address = [NSURL URLWithString:url];
  if (!address) { completion(nil,@"This address can't be read."); return; }
  [[_feedSession dataTaskWithURL:address completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSString *problem = nil; const NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 200;
    if (error) problem = @"Unreachable"; else if (status >= 400) problem = [NSString stringWithFormat:@"Answered with HTTP %ld",(long)status]; else if (data.length > MaxFeedBytes) problem = @"The feed is too large";
    dispatch_async(dispatch_get_main_queue(), ^{ completion(problem ? nil : data,problem); });
  }] resume];
}
- (void)addFeed:(NSString *)text {
  NSString *url = LinkFromText(text);
  if (!url) { [self status:@"That doesn't look like a feed address."]; return; }
  [self status:@"Looking for a feed…"]; __weak ReadingController *weak = self;
  [self fetch:url completion:^(NSData *data, NSString *problem) {
    ReadingController *strong = weak; if (!strong) return;
    if (problem) { [strong status:[NSString stringWithFormat:@"Could not add the feed: %@.",problem]]; return; }
    rail::ParsedFeed parsed = rail::ParseFeed(data,url);
    if (parsed.valid) { [strong finishAddingFeed:url parsed:parsed]; return; }
    // A site address: follow the feed its page advertises.
    NSString *discovered = rail::DiscoverFeedURL(data,url);
    if (!discovered) { [strong status:@"No feed found at that address."]; return; }
    [strong fetch:discovered completion:^(NSData *feedData, NSString *feedProblem) {
      ReadingController *inner = weak; if (!inner) return;
      rail::ParsedFeed found = rail::ParseFeed(feedData,discovered);
      if (feedProblem || !found.valid) [inner status:@"No feed found at that address."]; else [inner finishAddingFeed:discovered parsed:found];
    }];
  }];
}
- (void)finishAddingFeed:(NSString *)url parsed:(const rail::ParsedFeed &)parsed {
  bool created = false; const std::string id = _list.addFeed(C(url),parsed.title,&created);
  if (!created) { [self status:@"You already follow this feed."]; _feedFilter = S(id); [self refreshViews]; return; }
  [self applyParsed:parsed feed:S(id)];
  [self status:[NSString stringWithFormat:@"Added %@.",S(_list.feed(id)->title)]];
}
- (void)applyParsed:(const rail::ParsedFeed &)parsed feed:(NSString *)feedID {
  auto *feed = _list.feed(C(feedID)); if (!feed) return;
  const auto hadError = !feed->error.empty(); const auto oldTitle = feed->title;
  feed->error.clear(); feed->lastSuccess = Now();
  if (!parsed.title.empty() && oldTitle != parsed.title) { feed->title = parsed.title; for (auto &item : _list.state.items) if (item.feedID==feed->id) item.site = parsed.title; }
  __weak ReadingController *weak = self; std::vector<std::string> removed;
  const size_t added = _list.mergeFeed(C(feedID),parsed.entries,[weak](const std::string &url) {
    ReadingController *strong = weak; return std::string(strong.sessionForURL ? C(strong.sessionForURL(S(url))) : "");
  },Now(),&removed);
  for (const auto &itemID : removed) { [_extractor cancel:S(itemID)]; [self removeArticle:S(itemID)]; }
  [self markDirty];
  if (added || hadError || !removed.empty()) { [self refreshViews]; if (![self selected] && added) { auto inbox = _list.shown(false); _selectedID = S(inbox.front()->id); } }
}
- (void)checkFeed:(NSString *)feedID {
  const auto *feed = _list.feed(C(feedID)); if (!feed || [_checkingFeeds containsObject:feedID]) return;
  [_checkingFeeds addObject:feedID]; NSString *url = S(feed->url); __weak ReadingController *weak = self;
  [self fetch:url completion:^(NSData *data, NSString *problem) {
    ReadingController *strong = weak; if (!strong) return;
    [strong->_checkingFeeds removeObject:feedID];
    auto *current = strong->_list.feed(C(feedID)); if (!current) return;
    rail::ParsedFeed parsed = problem ? rail::ParsedFeed{} : rail::ParseFeed(data,url);
    if (parsed.valid) { [strong applyParsed:parsed feed:feedID]; return; }
    NSString *reason = problem ?: @"The address no longer returns a feed";
    if (current->error != C(reason)) { current->error = C(reason); [strong markDirty]; [strong refreshViews]; }
  }];
}
- (void)checkFeeds { for (const auto &feed : _list.state.feeds) [self checkFeed:S(feed.id)]; }
- (void)shutdown:(void (^)(void))done {
  _shuttingDown = YES; [_feedTimer invalidate]; _feedTimer = nil; [self saveNow]; [_extractor shutdown:done];
}
#pragma mark Automation
- (NSDictionary *)automationState {
  NSMutableArray *items = [NSMutableArray array], *feeds = [NSMutableArray array];
  for (const auto &item : _list.state.items) [items addObject:@{@"id":S(item.id),@"url":S(item.url),@"title":S(item.title),@"site":S(item.site),@"feed":S(item.feedID),@"session":S(item.sessionID),@"read":@(item.readAt>0),@"minutes":@(item.minutes),@"progress":@(item.progress),@"reader":@(rail::readerStatusName(item.reader))}];
  for (const auto &feed : _list.state.feeds) [feeds addObject:@{@"id":S(feed.id),@"url":S(feed.url),@"title":S(feed.title),@"error":S(feed.error),@"unread":@(_list.unreadCount(feed.id))}];
  return @{@"items":items,@"feeds":feeds,@"selected":_selectedID ?: @"",@"unread":@(self.unreadCount),@"showingRead":@(_showingRead),@"filter":_feedFilter ?: @"",@"shownRows":@(_sidebar.rows.count),@"activeSession":self.activeSession ?: @"",@"readerOffset":@(_reader.scrollOffset),@"selectedRowVisible":@([_sidebar rowIsVisible:_selectedID ?: @""]),@"feedsLayout":[_sidebar feedsLayout],@"focus":[self focusDescription]};
}
- (NSString *)focusDescription {
  NSResponder *responder = _reader.window.firstResponder;
  if ([responder isKindOfClass:NSText.class] && ((NSText *)responder).isFieldEditor) return ((NSText *)responder).delegate==(id)_sidebar.captureField ? @"capture" : @"field";
  if (responder==_reader.keyTarget) return @"reader";
  if ([responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:_sidebar]) return ((NSView *)responder).accessibilityLabel ?: NSStringFromClass(responder.class);
  return NSStringFromClass(responder.class);
}
- (void)runAutomation:(NSDictionary *)command action:(NSString *)action {
  if ([action isEqual:@"readingFocusCapture"]) { [_reader.window makeFirstResponder:_sidebar.captureField]; return; }
  NSString *itemID = [command[@"item"] isKindOfClass:NSString.class] ? command[@"item"] : nil;
  if ([action isEqual:@"readingSave"]) [self saveURL:command[@"url"] ?: @""];
  else if ([action isEqual:@"readingSelect"]) [self select:itemID focus:YES];
  else if ([action isEqual:@"readingToggleRead"]) [self toggleSelectedRead];
  else if ([action isEqual:@"readingShowRead"]) { _showingRead = [command[@"read"] boolValue]; [self refreshViews]; }
  else if ([action isEqual:@"readingProgress"]) [self progressChanged:[command[@"progress"] doubleValue]];
  else if ([action isEqual:@"readingOpenOriginal"]) [self openSelectedInTab];
  else if ([action isEqual:@"readingRemove"]) [self removeItem:itemID];
  else if ([action isEqual:@"readingAddFeed"]) [self addFeed:command[@"url"] ?: @""];
  else if ([action isEqual:@"readingCheckFeeds"]) [self checkFeeds];
  else if ([action isEqual:@"readingRemoveFeed"]) [self removeFeed:command[@"feed"] ?: @""];
  else if ([action isEqual:@"readingFilter"]) { _feedFilter = [command[@"feed"] length] ? command[@"feed"] : nil; [self refreshViews]; }
  else if ([action isEqual:@"readingSession"]) [self setSelectedSessionTo:command[@"session"] ?: @""];
  else if ([action isEqual:@"readingReload"]) [self reloadSelected];
}
@end
