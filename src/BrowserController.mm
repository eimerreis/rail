#import "BrowserController.h"
#import "CEFBridge.h"
#import "NativeViews.h"
#import "StateStore.h"
#include "include/cef_request_context.h"
#include <algorithm>
#include <unordered_map>

namespace {
NSString *S(const std::string &s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
std::string C(NSString *s) { return std::string(s.UTF8String ?: ""); }
double Now() { return NSDate.date.timeIntervalSince1970; }
std::string PopupKey(const std::string &source, uint64_t generation, int popupID) { return source+":"+std::to_string(generation)+":"+std::to_string(popupID); }
enum class CloseReason { None, Idle, Delete, Session, Quit };
struct RuntimeTab {
  uint64_t generation = 0;
  CefRefPtr<CefBrowser> browser;
  __strong NSView *container = nil;
  CloseReason closeReason = CloseReason::None;
  std::string nextSession;
  std::string error;
  bool loading = false, back = false, forward = false;
};
NSString *SymbolForURL(const std::string &url) {
  NSString *host = [NSURLComponents componentsWithString:S(url)].host.lowercaseString ?: @"";
  if ([host containsString:@"github"]) return @"chevron.left.forwardslash.chevron.right";
  if ([host containsString:@"mail"]) return @"envelope";
  if ([host containsString:@"calendar"]) return @"calendar";
  if ([host containsString:@"figma"]) return @"square.on.circle";
  if ([host containsString:@"linear"]) return @"circle.lefthalf.filled";
  return url == "about:blank" ? @"plus.square" : @"globe";
}
// One rendered row of the address suggestions; url is where choosing it leads.
struct AddressRow {
  std::string url;
  __strong NSString *text;
};
// Favicons are cached per site so sleeping tabs and history rows can show them too.
NSString *FaviconKey(const std::string &url) {
  NSString *host = [NSURLComponents componentsWithString:S(url)].host.lowercaseString;
  if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
  if (!host.length || [host rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789.-"].invertedSet].location != NSNotFound) return nil;
  return host;
}
class FaviconCallback final : public CefDownloadImageCallback {
 public:
  explicit FaviconCallback(void (^done)(NSData *png)) : done_(done) {}
  void OnDownloadImageFinished(const CefString &, int, CefRefPtr<CefImage> image) override {
    NSData *png = nil;
    if (image && !image->IsEmpty()) {
      int width = 0, height = 0; CefRefPtr<CefBinaryValue> data = image->GetAsPNG(2.0f,true,width,height);
      if (data && data->GetSize()) { NSMutableData *bytes = [NSMutableData dataWithLength:data->GetSize()]; data->GetData(bytes.mutableBytes,bytes.length,0); png = bytes; }
    }
    done_(png);
  }
 private:
  void (^done_)(NSData *);
  IMPLEMENT_REFCOUNTING(FaviconCallback);
};
NSString *DisplayAddress(const std::string &url) {
  if (url == "about:blank") return @"";
  NSString *text = S(url);
  NSURLComponents *parts = [NSURLComponents componentsWithString:text];
  if (![parts.scheme.lowercaseString isEqualToString:@"https"]) return text;
  text = [text substringFromIndex:@"https://".length];
  if ([text.lowercaseString hasPrefix:@"www."]) text = [text substringFromIndex:4];
  if ([text hasSuffix:@"/"] && parts.path.length <= 1 && !parts.query && !parts.fragment) text = [text substringToIndex:text.length-1];
  return text;
}
NSString *AddressSymbol(const std::string &url) {
  NSString *scheme = [NSURLComponents componentsWithString:S(url)].scheme.lowercaseString;
  if ([scheme isEqualToString:@"https"]) return @"lock.fill";
  if ([scheme isEqualToString:@"http"]) return @"exclamationmark.triangle";
  return @"magnifyingglass";
}
NSString *NormalizedAddress(NSString *input) {
  NSString *text = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!text.length) return nil;
  if ([text isEqualToString:@"about:blank"]) return text;
  if ([text rangeOfString:@"://"].location != NSNotFound) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:text];
    return ([@[@"http",@"https"] containsObject:parts.scheme.lowercaseString] && parts.host.length) ? parts.URL.absoluteString : nil;
  }
  if ([text hasPrefix:@"javascript:"] || [text hasPrefix:@"file:"] || [text hasPrefix:@"data:"]) return nil;
  BOOL noSpaces = [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound;
  if (noSpaces && ([text containsString:@"."] || [text hasPrefix:@"localhost"] || [text hasPrefix:@"[::1]"])) {
    BOOL local = [text hasPrefix:@"localhost"] || [text hasPrefix:@"127."] || [text hasPrefix:@"[::1]"];
    NSURLComponents *parts = [NSURLComponents componentsWithString:[(local ? @"http://" : @"https://") stringByAppendingString:text]];
    return parts.host.length ? parts.URL.absoluteString : nil;
  }
  NSURLComponents *search = [NSURLComponents componentsWithString:@"https://duckduckgo.com/"];
  search.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:text]];
  return search.URL.absoluteString;
}
}

@interface BrowserController ()
- (void)layout;
- (void)refresh;
- (void)saveSoon;
- (void)saveNow;
- (void)ensureBrowser:(const std::string &)tabID;
- (void)closeRuntime:(const std::string &)tabID reason:(CloseReason)reason session:(const std::string &)session;
- (void)selectTabID:(const std::string &)tabID;
- (void)navigateTo:(NSString *)address;
- (void)processAutomation;
@end

@implementation BrowserController {
  rail::BrowserModel _model;
  std::unordered_map<std::string, RuntimeTab> _runtime;
  std::unordered_map<std::string, CefRefPtr<CefRequestContext>> _contexts;
  std::unordered_map<std::string, std::string> _pendingPopups;
  uint64_t _nextGeneration;
  NSString *_directory;
  BOOL _automation, _quitting, _editingAddress, _savingAllowed, _historyDirty, _deletingAddress;
  // ⌘Z reopens a closed tab only until the user types again; after that it undoes text as usual.
  BOOL _undoCloseArmed;
  rail::History _history;
  NSMutableDictionary<NSString *, id> *_favicons;
  std::vector<AddressRow> _addressRows;
  NSString *_typedAddress;
  NSMutableArray<NSURL *> *_pendingExternalURLs;
  RailSuggestionList *_suggestionList;
  RailResizeHandle *_sidebarHandle;
  RailPanel *_dropIndicator;
  // Ctrl+Tab switcher: tabs of the current Space, most recently used first, while Ctrl is held.
  RailSuggestionList *_tabSwitcher;
  std::vector<std::string> _switcherTabs;
  CGFloat _pinnedSectionEnd;
  CGFloat _dragStartWidth;
  NSString *_automationID, *_statusMessage;
  NSTimer *_idleTimer, *_saveTimer, *_automationTimer;
  RailPanel *_root, *_rail, *_sidebar, *_toolbar, *_statusbar, *_empty;
  NSView *_webHost;
  NSScrollView *_tabScroll;
  RailPanel *_tabDocument;
  NSTextField *_spaceLabel, *_spaceSubtitle, *_sleepLabel, *_statusLabel, *_sessionLabel;
  RailAddressBar *_addressBar;
  NSTextField *_address, *_emptyTitle, *_emptySubtitle;
  RailButton *_back, *_forward, *_reload, *_toggle, *_sidebarToggle, *_retry, *_spaceOptions;
  NSPopUpButton *_sessionPicker;
  NSProgressIndicator *_progress;
  NSPopover *_settings;
}
@synthesize window = _window;

- (instancetype)initWithDataDirectory:(NSString *)directory automation:(BOOL)automation {
  if ((self = [super init])) {
    _directory = [directory copy]; _automation = automation; _savingAllowed = YES; _nextGeneration = 1;
    _favicons = [NSMutableDictionary dictionary]; rail::LoadHistory(_directory,_history);
    NSError *error = nil;
    if (!rail::LoadState(_directory,_model,&error)) {
      NSString *statePath = [_directory stringByAppendingPathComponent:@"state.json"];
      NSString *backup = [_directory stringByAppendingPathComponent:[NSString stringWithFormat:@"state-recovery-%.0f.json",Now()]];
      _savingAllowed = [NSFileManager.defaultManager copyItemAtPath:statePath toPath:backup error:nil];
      _statusMessage = _savingAllowed ? @"Saved layout could not be read. A recovery copy was kept." : @"Could not read saved layout. Saving is disabled to protect the original.";
    }
  }
  return self;
}
- (void)start {
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,1180,800) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
  _window.title = @"Eimerrail"; _window.titleVisibility = NSWindowTitleHidden;
  _window.titlebarAppearsTransparent = YES; _window.delegate = self;
  _window.minSize = NSMakeSize(760,520); _window.backgroundColor = RailColor(0xf4f6f8);
  _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  _window.releasedWhenClosed = NO; [_window setFrameAutosaveName:_automation ? @"EimerrailAutomation" : @"EimerrailMain"];
  _root = [[RailPanel alloc] initWithFrame:_window.contentView.bounds]; _root.fill = RailColor(0xf4f6f8);
  _window.contentView = _root;
  __weak BrowserController *weak = self;
  _root.onResize = ^{ [weak layout]; };
  _rail = [[RailPanel alloc] init]; _rail.fill = RailColor(0xe2e8ef); [_root addSubview:_rail];
  _sidebar = [[RailPanel alloc] init]; _sidebar.fill = RailColor(0xedf1f5); [_root addSubview:_sidebar];
  _toolbar = [[RailPanel alloc] init]; _toolbar.fill = RailColor(0xf4f6f8); [_root addSubview:_toolbar];
  _webHost = [[NSView alloc] init]; _webHost.wantsLayer = YES; _webHost.layer.backgroundColor = NSColor.whiteColor.CGColor; [_root addSubview:_webHost];
  _empty = [[RailPanel alloc] init]; _empty.fill = NSColor.whiteColor; [_root addSubview:_empty];
  _emptyTitle = RailLabel(@"A little room for what's next.",27,NSFontWeightMedium,RailColor(0x273445)); _emptyTitle.alignment = NSTextAlignmentCenter; [_empty addSubview:_emptyTitle];
  _emptySubtitle = RailLabel(@"Enter an address or search with ⌘ L.",14,NSFontWeightRegular,RailColor(0x596879)); _emptySubtitle.alignment = NSTextAlignmentCenter; [_empty addSubview:_emptySubtitle];
  _retry = RailAction(@"Search or enter address",@"magnifyingglass",@"Focus address bar",^{ [weak focusAddress:nil]; }); _retry.normalFill = RailColor(0xd8e7f7); _retry.ink = RailColor(0x245b96); _retry.centered = YES; [_empty addSubview:_retry];
  _statusbar = [[RailPanel alloc] init]; _statusbar.fill = RailColor(0xf4f6f8); [_root addSubview:_statusbar];
  _statusLabel = RailLabel(@"",10,NSFontWeightRegular,RailColor(0x596879)); [_statusbar addSubview:_statusLabel];
  _sessionLabel = RailLabel(@"",10,NSFontWeightRegular,RailColor(0x596879)); [_statusbar addSubview:_sessionLabel];
  _spaceLabel = RailLabel(@"Work",14,NSFontWeightSemibold,RailColor(0x273445)); [_sidebar addSubview:_spaceLabel];
  _spaceSubtitle = RailLabel(@"A little room for good work.",10,NSFontWeightRegular,RailColor(0x596879)); [_sidebar addSubview:_spaceSubtitle];
  _sidebarToggle = RailAction(@"",@"sidebar.left",@"Hide sidebar (⌘ S)",^{ [weak toggleSidebar:nil]; }); [_sidebar addSubview:_sidebarToggle];
  _spaceOptions = RailAction(@"",@"ellipsis",@"Space options",^{ [weak spaceMenu:nil]; }); [_sidebar addSubview:_spaceOptions];
  _tabScroll = [[NSScrollView alloc] init]; _tabScroll.drawsBackground = NO; _tabScroll.hasVerticalScroller = YES; _tabScroll.autohidesScrollers = YES; _tabScroll.horizontalScrollElasticity = NSScrollElasticityNone;
  _tabDocument = [[RailPanel alloc] init]; _tabDocument.fill = RailColor(0xedf1f5); _tabScroll.documentView = _tabDocument; [_sidebar addSubview:_tabScroll];
  [_tabDocument registerForDraggedTypes:@[RailTabPasteboardType]];
  _tabDocument.onTabDragOver = ^NSDragOperation(NSString *tabID, NSPoint point) { BrowserController *strong = weak; return strong ? [strong tabDragOver:tabID at:point drop:NO] : NSDragOperationNone; };
  _tabDocument.onTabDrop = ^BOOL(NSString *tabID, NSPoint point) { BrowserController *strong = weak; return strong && [strong tabDragOver:tabID at:point drop:YES]!=NSDragOperationNone; };
  _tabDocument.onTabDragEnd = ^{ BrowserController *strong = weak; if (strong) strong->_dropIndicator.hidden = YES; };
  _dropIndicator = [[RailPanel alloc] init]; _dropIndicator.fill = RailColor(0xe2ebf5); _dropIndicator.hidden = YES; _dropIndicator.wantsLayer = YES;
  _dropIndicator.layer.cornerRadius = 8; _dropIndicator.layer.borderWidth = 1.5; _dropIndicator.layer.borderColor = RailColor(0x3976be).CGColor;
  _sleepLabel = RailLabel(@"",10,NSFontWeightRegular,RailColor(0x596879)); [_sidebar addSubview:_sleepLabel];
  _back = RailAction(@"",@"chevron.left",@"Back (⌘ [)",^{ [weak goBack:nil]; });
  _forward = RailAction(@"",@"chevron.right",@"Forward (⌘ ])",^{ [weak goForward:nil]; });
  _reload = RailAction(@"",@"arrow.clockwise",@"Reload (⌘ R)",^{ [weak reloadPage:nil]; });
  _toggle = RailAction(@"",@"sidebar.left",@"Show sidebar (⌘ S)",^{ [weak toggleSidebar:nil]; });
  for (NSView *v in @[_back,_forward,_reload,_toggle]) [_toolbar addSubview:v];
  _addressBar = [[RailAddressBar alloc] init]; _addressBar.onFocusChange = ^(BOOL focused) { [weak addressFocusChanged:focused]; }; [_toolbar addSubview:_addressBar];
  _address = _addressBar.field;
  _address.placeholderString = @"Search or enter address"; _address.delegate = self; _address.target = self; _address.action = @selector(addressEntered:); _address.accessibilityLabel = @"Search or enter address";
  _sessionPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]; _sessionPicker.bordered = NO; _sessionPicker.font = [NSFont systemFontOfSize:11]; _sessionPicker.target = self; _sessionPicker.action = @selector(sessionChosen:); _sessionPicker.accessibilityLabel = @"Session for current tab"; [_toolbar addSubview:_sessionPicker];
  _progress = [[NSProgressIndicator alloc] init]; _progress.style = NSProgressIndicatorStyleBar; _progress.indeterminate = YES; _progress.displayedWhenStopped = NO; [_toolbar addSubview:_progress];
  _sidebarHandle = [[RailResizeHandle alloc] init];
  _sidebarHandle.onBegin = ^{ BrowserController *strong = weak; if (strong) strong->_dragStartWidth = strong->_model.state.sidebarWidth; };
  _sidebarHandle.onDrag = ^(CGFloat delta) { [weak resizeSidebarTo:delta]; };
  _sidebarHandle.onEnd = ^{ [weak saveSoon]; };
  [_root addSubview:_sidebarHandle];
  _suggestionList = [[RailSuggestionList alloc] init]; _suggestionList.hidden = YES;
  _suggestionList.onChoose = ^(NSInteger index) { [weak chooseSuggestion:index]; }; [_root addSubview:_suggestionList];
  _tabSwitcher = [[RailSuggestionList alloc] init]; _tabSwitcher.hidden = YES;
  _tabSwitcher.onChoose = ^(NSInteger index) { BrowserController *strong = weak; if (!strong) return; strong->_tabSwitcher.selectedIndex = index; [strong finishTabSwitch:YES]; };
  [_root addSubview:_tabSwitcher];
  [self installMenu]; [self refresh]; [self layout];
  [_window center]; [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
  [self ensureBrowser:_model.state.activeTabID];
  _idleTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) { (void)timer; [weak checkIdle]; }];
  if (_automation) _automationTimer = [NSTimer scheduledTimerWithTimeInterval:.1 repeats:YES block:^(NSTimer *timer) { (void)timer; [weak processAutomation]; }];
  [self saveSoon];
  if (_pendingExternalURLs.count) { NSArray *urls=_pendingExternalURLs; _pendingExternalURLs=nil; [self openExternalURLs:urls]; }
}
// Links from other apps. They can arrive before Chromium has started, so they wait for the window.
- (void)openExternalURLs:(NSArray<NSURL *> *)urls {
  if (_quitting) return;
  if (!_window) { if (!_pendingExternalURLs) _pendingExternalURLs=[NSMutableArray array]; [_pendingExternalURLs addObjectsFromArray:urls]; return; }
  for (NSURL *link in urls) {
    NSString *scheme=link.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) { [self setStatus:@"Local files can't be opened yet."]; continue; }
    auto *active=_model.tab(_model.state.activeTabID);
    std::string space=_model.spaceForURL(C(link.absoluteString)); if (space.empty()) space=_model.state.activeSpaceID;
    // An empty tab is reused, as in other browsers; otherwise the link gets its own tab.
    if (active && active->url=="about:blank" && active->spaceID==space) [self navigateTo:link.absoluteString];
    else { auto id=_model.addTab(space,C(link.absoluteString),Now()); [self selectTabID:id]; }
  }
  [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
- (void)makeDefaultBrowser:(id)sender {
  (void)sender; NSURL *app=NSBundle.mainBundle.bundleURL; __weak BrowserController *weak=self;
  // macOS asks the user to confirm; https follows once http is accepted.
  [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:app toOpenURLsWithScheme:@"http" completionHandler:^(NSError *error) {
    if (error) { dispatch_async(dispatch_get_main_queue(), ^{ [weak setStatus:@"Eimerrail was not set as the default browser."]; }); return; }
    [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:app toOpenURLsWithScheme:@"https" completionHandler:^(NSError *httpsError) {
      dispatch_async(dispatch_get_main_queue(), ^{ [weak setStatus:httpsError ? @"Eimerrail was not set as the default browser." : @"Eimerrail is now your default browser."]; });
    }];
  }];
}
- (void)installMenu {
  NSMenu *bar = [[NSMenu alloc] init]; NSApp.mainMenu = bar;
  NSArray *groups = @[@[@"Eimerrail",@[@"About Eimerrail",@"about:",@""],@[@"Settings…",@"showSettings:",@","],@[@"Set as Default Browser…",@"makeDefaultBrowser:",@""],@[@"Quit Eimerrail",@"quit:",@"q"]],@[@"File",@[@"New Tab",@"newTab:",@"t"],@[@"New Space…",@"newSpace:",@""],@[@"Close Tab",@"closeCurrentTab:",@"w"],@[@"Reopen Closed Tab",@"reopenClosedTab:",@"T"]],@[@"Edit",@[@"Undo",@"undo:",@"z"],@[@"Cut",@"cut:",@"x"],@[@"Copy",@"copy:",@"c"],@[@"Paste",@"paste:",@"v"],@[@"Select All",@"selectAll:",@"a"],@[@"Find…",@"findInPage:",@"f"]],@[@"View",@[@"Toggle Sidebar",@"toggleSidebar:",@"s"],@[@"Address Bar",@"focusAddress:",@"l"],@[@"Reload",@"reloadPage:",@"r"],@[@"Back",@"goBack:",@"["],@[@"Forward",@"goForward:",@"]"],@[@"Zoom In",@"zoomIn:",@"+"],@[@"Zoom Out",@"zoomOut:",@"-"],@[@"Actual Size",@"zoomReset:",@"0"]]];
  for (NSArray *group in groups) {
    NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:group[0] action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:group[0]]; top.submenu = menu; [bar addItem:top];
    for (NSUInteger i=1;i<group.count;i++) {
      NSArray *entry = group[i]; SEL action = NSSelectorFromString(entry[1]);
      NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0] action:action keyEquivalent:entry[2]];
      item.target = [self respondsToSelector:action] ? self : nil; [menu addItem:item];
    }
  }
}
- (void)layout {
  CGFloat w = _root.bounds.size.width, h = _root.bounds.size.height;
  CGFloat rail = _model.state.sidebarVisible ? 45 : 0, side = _model.state.sidebarVisible ? _model.state.sidebarWidth : 0, left = rail + side;
  _rail.hidden = !_model.state.sidebarVisible; _sidebar.hidden = !_model.state.sidebarVisible;
  _rail.frame = NSMakeRect(0,0,rail,h); _sidebar.frame = NSMakeRect(rail,0,side,h);
  _toolbar.frame = NSMakeRect(left,0,w-left,51); _webHost.frame = NSMakeRect(left,51,w-left,h-77); _empty.frame = NSMakeRect(left,51,w-left,h-77);
  _statusbar.frame = NSMakeRect(left,h-26,w-left,26);
  _spaceLabel.frame = NSMakeRect(15,62,side-55,23); _spaceSubtitle.frame = NSMakeRect(15,91,side-25,16);
  _sidebarToggle.frame = NSMakeRect(side-39,11,28,28); _spaceOptions.frame = NSMakeRect(side-39,61,28,28);
  _tabScroll.frame = NSMakeRect(0,117,side,MAX(0,h-160)); _sleepLabel.frame = NSMakeRect(13,h-29,side-25,17);
  _sidebarHandle.hidden = !_model.state.sidebarVisible; _sidebarHandle.frame = NSMakeRect(left-3,0,6,h);
  CGFloat x = _model.state.sidebarVisible ? 7 : 86;
  _toggle.hidden = _model.state.sidebarVisible;
  if (!_toggle.hidden) { _toggle.frame = NSMakeRect(x,11,28,28); x += 31; }
  _back.frame = NSMakeRect(x,11,27,28); _forward.frame = NSMakeRect(x+28,11,27,28); _reload.frame = NSMakeRect(x+56,11,27,28); x += 92;
  CGFloat tw = _toolbar.bounds.size.width;
  _addressBar.frame = NSMakeRect(x,10,MAX(90,tw-x-133),30); _sessionPicker.frame = NSMakeRect(tw-123,12,116,28);
  _progress.frame = NSMakeRect(0,48,tw,3);
  if (!_suggestionList.hidden) { NSRect bar = [_root convertRect:_addressBar.bounds fromView:_addressBar]; _suggestionList.frame = NSMakeRect(NSMinX(bar),NSMaxY(bar)+4,NSWidth(bar),[RailSuggestionList heightForCount:_addressRows.size()]); }
  _sessionLabel.frame = NSMakeRect(13,6,155,14); _statusLabel.frame = NSMakeRect(175,6,MAX(0,tw-188),14); _statusLabel.alignment = NSTextAlignmentRight;
  CGFloat ew = _empty.bounds.size.width, ey = MAX(80,_empty.bounds.size.height*.32);
  _emptyTitle.frame = NSMakeRect(30,ey,ew-60,40); _emptySubtitle.frame = NSMakeRect(35,ey+52,ew-70,45); _emptySubtitle.maximumNumberOfLines = 2;
  _retry.frame = NSMakeRect((ew-220)/2,ey+112,220,34);
  for (auto &[id,slot] : _runtime) { (void)id; slot.container.frame = _webHost.bounds; for (NSView *child in slot.container.subviews) child.frame = slot.container.bounds; }
  CGFloat start = _model.state.sidebarVisible ? 60 : 16;
  for (NSUInteger i=0;i<3;i++) {
    NSButton *button = [_window standardWindowButton:(NSWindowButton)i];
    NSRect f = button.frame; f.origin.x = start + i*20; f.origin.y = button.superview.bounds.size.height - 29; button.frame = f;
  }
  for (NSView *v in _rail.subviews) if (v.tag == 900) v.frame = NSMakeRect(6,h-83,32,30); else if (v.tag == 901) v.frame = NSMakeRect(6,h-43,32,30);
}
- (NSString *)sessionName:(const std::string &)sessionID {
  if (rail::BrowserModel::isIsolatedSession(sessionID)) return @"Isolated";
  const auto *session = _model.session(sessionID); return session ? S(session->name) : @"Work";
}
- (NSColor *)sessionInk:(const std::string &)sessionID {
  return RailColor(rail::BrowserModel::isIsolatedSession(sessionID) ? 0x7a5838 : sessionID == "personal" ? 0x476d4e : 0x3c5f88);
}
- (void)refresh {
  if (!_window) return;
  __weak BrowserController *weak = self;
  for (NSView *v in [_rail.subviews copy]) [v removeFromSuperview];
  NSImageView *logo = [[NSImageView alloc] initWithFrame:NSMakeRect(13,15,19,19)]; logo.image = RailSymbol(@"square.stack.3d.up",17); logo.contentTintColor = RailColor(0x587089); [_rail addSubview:logo];
  CGFloat ry = 89;
  for (size_t index=0;index<_model.state.spaces.size();index++) {
    const auto &space = _model.state.spaces[index]; std::string sid = space.id;
    NSString *symbol = index==0 ? @"briefcase" : index==1 ? @"house" : index==2 ? @"book" : @"square.grid.2x2";
    RailButton *button = RailAction(@"",symbol,S(space.name),^{ BrowserController *strong = weak; if (!strong) return; strong->_model.selectSpace(sid,Now()); [strong ensureBrowser:strong->_model.state.activeTabID]; [strong refresh]; [strong saveSoon]; });
    button.centered = YES; button.frame = NSMakeRect(6,ry,32,32); button.ink = RailColor(0x596879);
    if (space.id == _model.state.activeSpaceID) { button.normalFill = RailColor(0x4173aa); button.hoverFill = RailColor(0x37679c); button.ink = NSColor.whiteColor; }
    [_rail addSubview:button]; ry += 41;
  }
  RailButton *addSpace = RailAction(@"",@"plus",@"New Space",^{ [weak newSpace:nil]; }); addSpace.centered = YES; addSpace.tag = 900; [_rail addSubview:addSpace];
  RailButton *settings = RailAction(@"",@"slider.horizontal.3",@"Settings",^{ [weak showSettings:nil]; }); settings.centered = YES; settings.tag = 901; [_rail addSubview:settings];
  const auto *space = _model.space(_model.state.activeSpaceID);
  _spaceLabel.stringValue = space ? S(space->name) : @"Space";
  _spaceSubtitle.stringValue = @"A little room for good work.";
  NSPoint offset = _tabScroll.contentView.bounds.origin; CGFloat side = _model.state.sidebarWidth, pinWidth = floor((side-30)/2);
  for (NSView *v in [_tabDocument.subviews copy]) [v removeFromSuperview];
  [_tabDocument addSubview:_dropIndicator];
  CGFloat y = 4; NSUInteger pins = 0, sleeping = 0;
  for (const auto &t : _model.state.tabs) if (t.spaceID == _model.state.activeSpaceID && !_runtime.count(t.id) && t.url != "about:blank") sleeping++;
  NSTextField *pinHeading = RailLabel(@"Pinned",10,NSFontWeightMedium,RailColor(0x596879)); pinHeading.frame = NSMakeRect(15,y,side-30,16); [_tabDocument addSubview:pinHeading]; y += 24;
  for (const auto &tab : _model.state.tabs) {
    if (tab.spaceID != _model.state.activeSpaceID || !tab.pinned) continue;
    std::string tid = tab.id;
    RailButton *button = RailAction(S(tab.title),SymbolForURL(tab.url),S(tab.title),^{ [weak selectTabID:tid]; });
    [self applyFaviconFor:tab.url button:button sleeping:!_runtime.count(tid) && tab.url != "about:blank"]; button.dragTabID = S(tid);
    button.font = [NSFont systemFontOfSize:11]; button.frame = NSMakeRect(12+(pins%2)*(pinWidth+6),y+(pins/2)*42,pinWidth,36);
    button.normalFill = RailColor(tab.id == _model.state.activeTabID ? 0xd4e4f6 : 0xf8fafc); button.stroke = RailColor(0xd4dde5);
    button.ink = RailColor(_runtime.count(tab.id) || tab.url == "about:blank" ? 0x273445 : 0x596879);
    button.toolTip = [NSString stringWithFormat:@"%@ · %@%@",S(tab.title),[self sessionName:tab.sessionID],_runtime.count(tab.id) ? @"" : @" · Reloads on open"];
    button.menu = [self menuForTab:tid]; [_tabDocument addSubview:button]; pins++;
  }
  if (pins) y += ((pins+1)/2)*42 + 12;
  else { NSTextField *hint = RailLabel(@"Drag a tab here to pin it.",10,NSFontWeightRegular,RailColor(0x596879)); hint.frame=NSMakeRect(15,y,side-30,18); [_tabDocument addSubview:hint]; y += 35; }
  _pinnedSectionEnd = y;
  NSTextField *tabHeading = RailLabel(@"Tabs",10,NSFontWeightMedium,RailColor(0x596879)); tabHeading.frame = NSMakeRect(15,y,side-30,16); [_tabDocument addSubview:tabHeading]; y += 23;
  for (const auto &tab : _model.state.tabs) {
    if (tab.spaceID != _model.state.activeSpaceID || tab.pinned) continue;
    std::string tid = tab.id; BOOL selected = tid == _model.state.activeTabID;
    RailPanel *row = [[RailPanel alloc] initWithFrame:NSMakeRect(7,y,side-14,35)]; row.wantsLayer=YES; row.layer.cornerRadius=7; row.layer.masksToBounds=YES; row.fill=selected ? RailColor(0xd8e7f7) : nil; row.menu=[self menuForTab:tid];
    BOOL sleepingTab = !_runtime.count(tid) && tab.url != "about:blank";
    RailButton *button = RailAction(S(tab.title),sleepingTab ? @"moon" : SymbolForURL(tab.url),[NSString stringWithFormat:@"%@%@",S(tab.title),sleepingTab ? @", unloaded; reload on open" : @""],^{ [weak selectTabID:tid]; });
    [self applyFaviconFor:tab.url button:button sleeping:sleepingTab]; button.dragTabID = S(tid); button.dragView = row;
    button.frame = NSMakeRect(0,0,side-40,35); button.font=[NSFont systemFontOfSize:12 weight:selected ? NSFontWeightSemibold : NSFontWeightRegular]; button.ink=RailColor(selected ? 0x245b96 : sleepingTab ? 0x596879 : 0x273445); button.menu=row.menu; [row addSubview:button];
    NSString *sessionName = [self sessionName:tab.sessionID]; NSString *initial = sessionName.length ? [[sessionName substringToIndex:1] uppercaseString] : @"W";
    RailButton *badge = RailAction(initial,nil,[NSString stringWithFormat:@"%@ session; change session",sessionName],nil);
    __weak RailButton *weakBadge = badge; badge.handler = ^{ [weak showSessionMenuForTab:tid from:weakBadge]; };
    badge.frame=NSMakeRect(side-37,9,17,17); badge.font=[NSFont systemFontOfSize:9 weight:NSFontWeightSemibold]; badge.centered=YES; badge.cornerRadius=4; badge.ink=[self sessionInk:tab.sessionID];
    badge.normalFill=RailColor(rail::BrowserModel::isIsolatedSession(tab.sessionID) ? 0xeee2d5 : tab.sessionID=="personal" ? 0xdeebdf : 0xdae6f4); [row addSubview:badge];
    [_tabDocument addSubview:row]; y += 38;
  }
  RailButton *newTab = RailAction(@"New tab",@"plus",@"New tab (⌘ T)",^{ [weak newTab:nil]; }); newTab.ink=RailColor(0x596879); newTab.frame=NSMakeRect(9,y+8,side-18,33); [_tabDocument addSubview:newTab]; y += 54;
  _tabDocument.frame=NSMakeRect(0,0,side,MAX(y,_tabScroll.contentSize.height)); [_tabScroll.contentView scrollToPoint:NSMakePoint(0,MIN(offset.y,MAX(0,y-_tabScroll.contentSize.height)))];
  _sleepLabel.stringValue=[NSString stringWithFormat:@"%lu asleep · after %.0f min",(unsigned long)sleeping,_model.state.idleMinutes];
  [_sessionPicker removeAllItems];
  const auto *active = _model.tab(_model.state.activeTabID);
  for (const auto &session : _model.state.sessions) { [_sessionPicker addItemWithTitle:S(session.name)]; _sessionPicker.lastItem.representedObject=S(session.id); }
  [_sessionPicker addItemWithTitle:@"Isolated"]; _sessionPicker.lastItem.representedObject=@"__isolated__";
  [_sessionPicker.menu addItem:NSMenuItem.separatorItem]; [_sessionPicker addItemWithTitle:@"New session…"]; _sessionPicker.lastItem.representedObject=@"__new__";
  if (active) {
    for (NSMenuItem *item in _sessionPicker.itemArray) if ([item.representedObject isEqual:S(active->sessionID)] || (rail::BrowserModel::isIsolatedSession(active->sessionID) && [item.representedObject isEqual:@"__isolated__"])) [_sessionPicker selectItem:item];
    _sessionLabel.stringValue = [NSString stringWithFormat:@"%@ session",[self sessionName:active->sessionID]];
    if (!_editingAddress) { _address.stringValue = DisplayAddress(active->url); _addressBar.symbolName = AddressSymbol(active->url); }
    _window.title = [NSString stringWithFormat:@"%@ — Eimerrail",S(active->title)];
  }
  auto slot = _runtime.find(_model.state.activeTabID);
  _back.enabled=slot!=_runtime.end() && slot->second.back; _forward.enabled=slot!=_runtime.end() && slot->second.forward;
  if (slot!=_runtime.end() && slot->second.loading) [_progress startAnimation:nil]; else [_progress stopAnimation:nil];
  for (auto &[id,runtime] : _runtime) runtime.container.hidden = id != _model.state.activeTabID;
  BOOL error = slot!=_runtime.end() && !slot->second.error.empty();
  _empty.hidden = active && active->url!="about:blank" && !error;
  if (error) {
    _emptyTitle.stringValue=@"Couldn't load this page."; _emptySubtitle.stringValue=S(slot->second.error); _retry.title=@"Try again"; _retry.image=RailSymbol(@"arrow.clockwise",15); _retry.handler=^{ [weak reloadPage:nil]; };
  } else {
    _emptyTitle.stringValue=@"A little room for what's next."; _emptySubtitle.stringValue=@"Enter an address or search with ⌘ L."; _retry.title=@"Search or enter address"; _retry.image=RailSymbol(@"magnifyingglass",15); _retry.handler=^{ [weak focusAddress:nil]; };
  }
  _statusLabel.stringValue = _statusMessage.length ? _statusMessage : [NSString stringWithFormat:@"Idle tabs unload after %.0f min",_model.state.idleMinutes];
  [self layout];
}
- (NSMenu *)menuForTab:(const std::string &)tabID {
  const auto *tab = _model.tab(tabID); NSMenu *menu = [[NSMenu alloc] init]; if (!tab) return menu;
  for (NSArray *entry in @[@[tab->pinned ? @"Unpin Tab" : @"Pin Tab",@"pinTab:"],@[@"Unload Tab",@"unloadTab:"],@[@"Close Tab",@"closeTabMenu:"]]) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""]; item.target=self; item.representedObject=S(tabID); [menu addItem:item];
  }
  NSMenuItem *move = [[NSMenuItem alloc] initWithTitle:@"Move to Space" action:nil keyEquivalent:@""]; move.submenu=[[NSMenu alloc] init];
  for (const auto &space : _model.state.spaces) if (space.id!=tab->spaceID) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:S(space.name) action:@selector(moveTabMenu:) keyEquivalent:@""]; item.target=self; item.representedObject=@{@"tab":S(tabID),@"space":S(space.id)}; [move.submenu addItem:item]; }
  [menu addItem:move]; return menu;
}
- (void)selectTabID:(const std::string &)tabID {
  if (_quitting || !_model.selectTab(tabID,Now())) return;
  _statusMessage=nil; [self ensureBrowser:tabID]; [self refresh]; [self saveSoon];
  auto it=_runtime.find(tabID); if (it!=_runtime.end() && it->second.browser && it->second.closeReason==CloseReason::None) it->second.browser->GetHost()->SetFocus(true);
}
- (CefRefPtr<CefRequestContext>)contextForSession:(const std::string &)sessionID {
  auto it=_contexts.find(sessionID); if (it!=_contexts.end()) return it->second;
  // Model sanitization restricts IDs; this boundary additionally prevents path traversal.
  if (sessionID.empty() || sessionID.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")!=std::string::npos) return nullptr;
  CefRequestContextSettings settings;
  NSString *path=[[_directory stringByAppendingPathComponent:@"Chromium"] stringByAppendingPathComponent:S(sessionID)];
  CefString(&settings.cache_path)=path.UTF8String; settings.persist_session_cookies=true;
  CefRefPtr<CefRequestContext> context=CefRequestContext::CreateContext(settings,nullptr);
  _contexts.emplace(sessionID,context); return context;
}
- (RuntimeTab &)makeRuntime:(const std::string &)tabID {
  RuntimeTab slot; slot.generation=_nextGeneration++; slot.container=[[NSView alloc] initWithFrame:_webHost.bounds];
  slot.container.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; slot.container.hidden=tabID!=_model.state.activeTabID;
  [_webHost addSubview:slot.container]; auto result=_runtime.emplace(tabID,std::move(slot)); return result.first->second;
}
- (void)ensureBrowser:(const std::string &)tabID {
  auto *tab=_model.tab(tabID); if (!tab || _quitting || tab->url=="about:blank") return;
  if (_runtime.count(tabID)) return;
  CefRefPtr<CefRequestContext> context=[self contextForSession:tab->sessionID]; if (!context) { [self setStatus:@"Invalid session. Select a named session to recover."]; return; }
  auto &slot=[self makeRuntime:tabID]; CefWindowInfo info; info.SetAsChild((__bridge CefWindowHandle)slot.container,CefRect(0,0,(int)_webHost.bounds.size.width,(int)_webHost.bounds.size.height)); info.runtime_style=CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings; settings.background_color=CefColorSetARGB(255,255,255,255);
  CefRefPtr<CefClient> client=MakeRailClient(self,tabID,slot.generation);
  if (!CefBrowserHost::CreateBrowser(info,client,tab->url,settings,nullptr,context)) {
    [slot.container removeFromSuperview]; _runtime.erase(tabID); [self setStatus:@"Couldn't create the browser. Try opening the tab again."];
  }
}
- (BOOL)preparePopupFrom:(const std::string &)source generation:(uint64_t)generation popupID:(int)popupID url:(NSString *)url windowInfo:(CefWindowInfo &)info client:(CefRefPtr<CefClient> &)client {
  const auto *opener=_model.tab(source); if (!opener || _quitting) return NO;
  const std::string space=opener->spaceID,session=opener->sessionID;
  const std::string ruled=url.length ? _model.spaceForURL(C(url)) : "";
  if (!ruled.empty() && ruled!=space) {
    // A rule sends the link to another Space; it opens there with that Space's session, without an opener.
    std::string tabID=_model.addTab(ruled,C(url),Now()); if (tabID.empty()) return NO;
    [self selectTabID:tabID]; [self setStatus:[NSString stringWithFormat:@"Opened in %@.",S(_model.space(ruled)->name)]]; return NO;
  }
  std::string tabID=_model.addTab(space,url.length ? C(url) : "about:blank",Now(),session);
  if (tabID.empty()) return NO;
  if (rail::BrowserModel::isIsolatedSession(session)) {
    // An isolated tab must never silently share its profile with another tab.
    // Cancel the inherited-context popup and navigate in a fresh isolated tab.
    _model.setIsolated(tabID); [self selectTabID:tabID];
    [self setStatus:@"Opened in a separate isolated session."]; return NO;
  }
  // Named-session popups retain Chromium's window.opener behavior for login flows.
  _model.selectTab(tabID,Now()); auto &slot=[self makeRuntime:tabID];
  _pendingPopups.emplace(PopupKey(source,generation,popupID),tabID);
  info.SetAsChild((__bridge CefWindowHandle)slot.container,CefRect(0,0,(int)_webHost.bounds.size.width,(int)_webHost.bounds.size.height)); info.runtime_style=CEF_RUNTIME_STYLE_ALLOY;
  client=MakeRailClient(self,tabID,slot.generation); [self refresh]; [self saveSoon]; return YES;
}
- (void)popupAbortedFrom:(const std::string &)source generation:(uint64_t)generation popupID:(int)popupID {
  auto pending=_pendingPopups.find(PopupKey(source,generation,popupID)); if (pending==_pendingPopups.end()) return;
  std::string tabID=pending->second; _pendingPopups.erase(pending);
  auto slot=_runtime.find(tabID); if (slot!=_runtime.end() && !slot->second.browser) [self browserClosed:tabID generation:slot->second.generation];
}
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser tab:(const std::string &)tabID generation:(uint64_t)generation {
  auto it=_runtime.find(tabID);
  if (it==_runtime.end() || it->second.generation!=generation) { browser->GetHost()->CloseBrowser(true); return; }
  it->second.browser=browser;
  for (auto pending=_pendingPopups.begin();pending!=_pendingPopups.end();) { if (pending->second==tabID) pending=_pendingPopups.erase(pending); else ++pending; }
  NSView *view=(__bridge NSView *)browser->GetHost()->GetWindowHandle(); view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  if (it->second.closeReason!=CloseReason::None || _quitting) browser->GetHost()->CloseBrowser(_quitting);
  else if (tabID==_model.state.activeTabID) browser->GetHost()->SetFocus(true);
  [self refresh];
}
- (void)closeRuntime:(const std::string &)tabID reason:(CloseReason)reason session:(const std::string &)session {
  auto it=_runtime.find(tabID); if (it==_runtime.end()) return;
  it->second.closeReason=reason; it->second.nextSession=session;
  if (it->second.browser) it->second.browser->GetHost()->CloseBrowser(false);
}
- (void)browserReadyToClose:(CefRefPtr<CefBrowser>)browser tab:(const std::string &)tabID generation:(uint64_t)generation {
  (void)browser;
  auto it=_runtime.find(tabID); if (it==_runtime.end() || it->second.generation!=generation) return;
  // Destroy only the embedded NSView. Returning true from DoClose avoids closing the whole native window.
  for (NSView *view in [it->second.container.subviews copy]) [view removeFromSuperview];
  [it->second.container removeFromSuperview];
}
- (void)browserClosed:(const std::string &)tabID generation:(uint64_t)generation {
  auto it=_runtime.find(tabID); if (it==_runtime.end() || it->second.generation!=generation) return;
  CloseReason reason=it->second.closeReason; std::string nextSession=it->second.nextSession;
  [it->second.container removeFromSuperview]; _runtime.erase(it);
  if (reason==CloseReason::Delete || reason==CloseReason::None) _model.closeTab(tabID,Now());
  if (reason==CloseReason::Session) { if (nextSession=="__isolated__") _model.setIsolated(tabID); else _model.setSession(tabID,nextSession); }
  // Drop our context reference when its final live tab closes. Chromium may
  // still retain shared process/profile resources during asynchronous teardown.
  for (auto context=_contexts.begin();context!=_contexts.end();) {
    bool used=false;
    for (const auto &[id,slot]:_runtime) { (void)slot; const auto *tab=_model.tab(id); if (tab && tab->sessionID==context->first) { used=true; break; } }
    if (used) ++context; else context=_contexts.erase(context);
  }
  [self saveSoon];
  if (_quitting) { if (_runtime.empty()) [self finishQuit]; return; }
  // A tab selected while closing is reopened only after the old browser is fully gone.
  if (tabID==_model.state.activeTabID || reason==CloseReason::Delete || reason==CloseReason::None) [self ensureBrowser:_model.state.activeTabID];
  [self refresh];
}
- (void)closeCancelled:(const std::string &)tabID generation:(uint64_t)generation {
  auto it=_runtime.find(tabID); if (it==_runtime.end() || it->second.generation!=generation) return;
  it->second.closeReason=CloseReason::None; it->second.nextSession.clear(); _quitting=NO;
  if (auto *tab=_model.tab(tabID)) tab->lastUsed=Now(); [self setStatus:@"Page kept open to protect unsaved changes."];
}
- (void)updateTitle:(NSString *)title tab:(const std::string &)tabID generation:(uint64_t)generation {
  auto it=_runtime.find(tabID); auto *tab=_model.tab(tabID);
  if (!tab || it==_runtime.end() || it->second.generation!=generation) return;
  if (title.length) { tab->title=C(title); _history.setTitle(tab->url,tab->title); _historyDirty=YES; } [self refresh]; [self saveSoon];
}
- (void)updateURL:(NSString *)url tab:(const std::string &)tabID generation:(uint64_t)generation {
  auto it=_runtime.find(tabID); auto *tab=_model.tab(tabID);
  if (!tab || it==_runtime.end() || it->second.generation!=generation) return;
  tab->url=C(url); it->second.error.clear();
  // Isolated tabs stay out of history so they leave no trace in suggestions.
  if (!rail::BrowserModel::isIsolatedSession(tab->sessionID)) { _history.recordVisit(tab->url,Now()); _historyDirty=YES; }
  [self refresh]; [self saveSoon];
}
- (void)updateFavicon:(NSString *)iconURL tab:(const std::string &)tabID generation:(uint64_t)generation {
  auto it=_runtime.find(tabID); const auto *tab=_model.tab(tabID);
  if (!tab || it==_runtime.end() || it->second.generation!=generation || !it->second.browser || !iconURL.length) return;
  NSString *key=FaviconKey(tab->url); if (!key) return;
  BOOL persist=!rail::BrowserModel::isIsolatedSession(tab->sessionID); __weak BrowserController *weak=self;
  it->second.browser->GetHost()->DownloadImage(C(iconURL),true,32,false,new FaviconCallback(^(NSData *png) { [weak storeFavicon:png key:key persist:persist]; }));
}
- (NSString *)faviconPath:(NSString *)key { return [[_directory stringByAppendingPathComponent:@"Favicons"] stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"png"]]; }
- (void)storeFavicon:(NSData *)png key:(NSString *)key persist:(BOOL)persist {
  NSImage *image=png ? [[NSImage alloc] initWithData:png] : nil; if (!image) return;
  image.size=NSMakeSize(16,16); _favicons[key]=image;
  if (persist) {
    NSString *path=[self faviconPath:key];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    [png writeToFile:path atomically:YES];
  }
  [self refresh];
}
- (NSImage *)faviconForURL:(const std::string &)url {
  NSString *key=FaviconKey(url); if (!key) return nil;
  id cached=_favicons[key];
  if (!cached) {
    NSImage *image=[[NSImage alloc] initWithContentsOfFile:[self faviconPath:key]];
    if (image) image.size=NSMakeSize(16,16);
    cached=image ?: (id)NSNull.null; _favicons[key]=cached;
  }
  return cached==NSNull.null ? nil : cached;
}
- (void)applyFaviconFor:(const std::string &)url button:(RailButton *)button sleeping:(BOOL)sleeping {
  NSImage *favicon=[self faviconForURL:url]; if (!favicon) return;
  button.image=favicon; button.keepsImageColors=YES; button.imageOpacity=sleeping ? .45 : 1;
}
- (void)updateLoading:(BOOL)loading back:(BOOL)back forward:(BOOL)forward tab:(const std::string &)tabID generation:(uint64_t)generation {
  auto it=_runtime.find(tabID); if (it==_runtime.end() || it->second.generation!=generation) return;
  it->second.loading=loading; it->second.back=back; it->second.forward=forward;
  if (loading) it->second.error.clear(); [self refresh];
}
- (void)loadFailed:(NSString *)message tab:(const std::string &)tabID generation:(uint64_t)generation {
  auto it=_runtime.find(tabID); if (it==_runtime.end() || it->second.generation!=generation) return;
  it->second.error=C(message); it->second.loading=false; [self refresh];
}
- (void)setStatus:(NSString *)message { _statusMessage=[message copy]; _statusLabel.stringValue=message ?: @""; }
- (void)checkIdle {
  if (_quitting) return;
  for (const auto &id : _model.idleTabs(Now())) {
    auto it=_runtime.find(id); if (it!=_runtime.end() && it->second.closeReason==CloseReason::None) [self closeRuntime:id reason:CloseReason::Idle session:""];
  }
}
- (void)saveSoon {
  [_saveTimer invalidate]; __weak BrowserController *weak=self;
  _saveTimer=[NSTimer scheduledTimerWithTimeInterval:.5 repeats:NO block:^(NSTimer *timer) { (void)timer; [weak saveNow]; }];
}
- (void)saveNow {
  [_saveTimer invalidate]; if (!_savingAllowed) return;
  NSError *error=nil; if (!rail::SaveState(_directory,_model,&error)) [self setStatus:[NSString stringWithFormat:@"Could not save the layout: %@",error.localizedDescription]];
  if (_historyDirty) { _history.prune(5000,Now()); _historyDirty=!rail::SaveHistory(_directory,_history,nil); }
}
// Dragging a tab into the Pinned section pins it; dragging a pinned tab out unpins it.
- (NSDragOperation)tabDragOver:(NSString *)tabID at:(NSPoint)point drop:(BOOL)drop {
  const auto *tab=_model.tab(C(tabID)); BOOL pin=point.y<_pinnedSectionEnd;
  if (!tab || tab->spaceID!=_model.state.activeSpaceID || tab->pinned==pin) { _dropIndicator.hidden=YES; return NSDragOperationNone; }
  if (drop) {
    // The dragged button is rebuilt by refresh, so the change waits until the drag session finishes.
    std::string id=tab->id; __weak BrowserController *weak=self;
    dispatch_async(dispatch_get_main_queue(), ^{ BrowserController *strong=weak; if (!strong || !strong->_model.setPinned(id,pin)) return; [strong refresh]; [strong saveSoon]; });
    _dropIndicator.hidden=YES; return NSDragOperationMove;
  }
  CGFloat side=_model.state.sidebarWidth, height=_tabDocument.bounds.size.height;
  _dropIndicator.frame=pin ? NSMakeRect(5,0,side-10,_pinnedSectionEnd-6) : NSMakeRect(5,_pinnedSectionEnd-2,side-10,MAX(40,height-_pinnedSectionEnd-2));
  _dropIndicator.hidden=NO; return NSDragOperationMove;
}
- (void)resizeSidebarTo:(CGFloat)delta { _model.state.sidebarWidth=std::clamp<double>(_dragStartWidth+delta,180,420); [self refresh]; }
- (void)newTab:(id)sender { (void)sender; if (_quitting) return; auto id=_model.addTab(_model.state.activeSpaceID,"about:blank",Now()); _model.selectTab(id,Now()); [self refresh]; [self saveSoon]; [self focusAddress:nil]; }
- (void)closeCurrentTab:(id)sender { (void)sender; [self closeTabID:_model.state.activeTabID]; }
- (void)closeTabID:(const std::string &)tabID {
  _undoCloseArmed=YES;
  if (_runtime.count(tabID)) [self closeRuntime:tabID reason:CloseReason::Delete session:""];
  else { _model.closeTab(tabID,Now()); [self ensureBrowser:_model.state.activeTabID]; [self refresh]; [self saveSoon]; }
}
- (void)cycleRecentTabs:(NSInteger)step {
  if (_quitting) return;
  if (_switcherTabs.empty()) {
    std::vector<const rail::Tab *> tabs;
    for (const auto &tab : _model.state.tabs) if (tab.spaceID==_model.state.activeSpaceID) tabs.push_back(&tab);
    if (tabs.size()<2) return;
    const std::string active=_model.state.activeTabID;
    std::stable_sort(tabs.begin(),tabs.end(),[&](const rail::Tab *a, const rail::Tab *b) { if ((a->id==active)!=(b->id==active)) return a->id==active; return a->lastUsed>b->lastUsed; });
    if (tabs.size()>12) tabs.resize(12);
    NSMutableArray<RailSuggestion *> *items=[NSMutableArray array];
    for (const auto *tab : tabs) {
      _switcherTabs.push_back(tab->id);
      RailSuggestion *item=[[RailSuggestion alloc] init]; item.title=S(tab->title); item.detail=DisplayAddress(tab->url);
      NSImage *favicon=[self faviconForURL:tab->url]; item.icon=favicon ?: RailSymbol(SymbolForURL(tab->url),13); item.iconKeepsColors=favicon!=nil;
      [items addObject:item];
    }
    _tabSwitcher.suggestions=items; _tabSwitcher.selectedIndex=0;
    NSRect web=_webHost.frame; CGFloat width=MIN(480,NSWidth(web)-40), height=[RailSuggestionList heightForCount:items.count];
    _tabSwitcher.frame=NSMakeRect(NSMinX(web)+(NSWidth(web)-width)/2,NSMinY(web)+40,width,height); _tabSwitcher.hidden=NO;
  }
  NSInteger count=(NSInteger)_switcherTabs.size();
  _tabSwitcher.selectedIndex=((_tabSwitcher.selectedIndex+step)%count+count)%count;
}
- (void)finishTabSwitch:(BOOL)commit {
  if (_switcherTabs.empty()) return;
  NSInteger index=_tabSwitcher.selectedIndex; std::string id=index>=0 && index<(NSInteger)_switcherTabs.size() ? _switcherTabs[index] : "";
  _switcherTabs.clear(); _tabSwitcher.hidden=YES;
  if (commit && !id.empty() && id!=_model.state.activeTabID && _model.tab(id)) [self selectTabID:id];
}
- (void)reopenClosedTab:(id)sender {
  (void)sender; if (_quitting) return;
  std::string id=_model.reopenClosedTab(Now()); if (id.empty()) return;
  // A pinned tab may still be loaded; send it back to the page it was on.
  auto it=_runtime.find(id); const auto *tab=_model.tab(id);
  if (tab && it!=_runtime.end() && it->second.browser && it->second.closeReason==CloseReason::None) it->second.browser->GetMainFrame()->LoadURL(tab->url);
  [self ensureBrowser:id]; [self refresh]; [self saveSoon];
  if (it!=_runtime.end() && it->second.browser) it->second.browser->GetHost()->SetFocus(true);
}
- (void)closeTabMenu:(NSMenuItem *)sender { [self closeTabID:C(sender.representedObject)]; }
- (void)pinTab:(NSMenuItem *)sender { _model.togglePin(C(sender.representedObject)); [self refresh]; [self saveSoon]; }
- (void)unloadTab:(NSMenuItem *)sender {
  std::string id=C(sender.representedObject);
  if (id==_model.state.activeTabID) { [self setStatus:@"Switch to another tab before unloading this one."]; return; }
  [self closeRuntime:id reason:CloseReason::Idle session:""];
}
- (void)moveTabMenu:(NSMenuItem *)sender { _model.moveTab(C(sender.representedObject[@"tab"]),C(sender.representedObject[@"space"]),Now()); [self ensureBrowser:_model.state.activeTabID]; [self refresh]; [self saveSoon]; }
- (void)toggleSidebar:(id)sender { (void)sender; _model.state.sidebarVisible=!_model.state.sidebarVisible; [self layout]; [self saveSoon]; }
- (void)focusAddress:(id)sender { (void)sender; [_window makeFirstResponder:_address]; [_address selectText:nil]; }
- (void)addressFocusChanged:(BOOL)focused {
  _editingAddress=focused;
  if (focused) {
    // Show the full address while editing, like browsers do.
    const auto *active=_model.tab(_model.state.activeTabID);
    _address.stringValue = active && active->url!="about:blank" ? S(active->url) : @"";
    _addressBar.symbolName=@"magnifyingglass";
  } else { [self hideSuggestions]; [self refresh]; }
}
- (void)controlTextDidChange:(NSNotification *)notification {
  if (notification.object!=_address) return;
  NSTextView *editor=(NSTextView *)_address.currentEditor; NSString *typed=editor.string;
  // Never complete over a deletion, otherwise backspace could not remove the suggested text.
  BOOL allowInline=!_deletingAddress && editor.selectedRange.location==typed.length; _deletingAddress=NO;
  [self suggestFor:typed inline:allowInline];
}
- (void)suggestFor:(NSString *)typed inline:(BOOL)allowInline {
  _typedAddress=[typed copy]; _addressRows.clear();
  NSString *query=[typed stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if (!query.length) { [self hideSuggestions]; return; }
  auto matches=_history.suggest(C(query),Now(),6);
  NSMutableArray<RailSuggestion *> *items=[NSMutableArray array];
  auto addRow=[&](const std::string &url, NSString *text, NSString *title, NSString *detail, NSImage *icon) {
    for (const auto &row : _addressRows) if (row.url==url) return;
    RailSuggestion *item=[[RailSuggestion alloc] init]; item.title=title; item.detail=detail;
    NSImage *favicon=[self faviconForURL:url]; item.icon=icon ?: favicon ?: RailSymbol(@"globe",13); item.iconKeepsColors=!icon && favicon;
    [items addObject:item]; _addressRows.push_back({url,text});
  };
  size_t first=0;
  BOOL completes=allowInline && [typed isEqualToString:query] && !matches.empty() && !matches[0].completion.empty();
  if (completes) {
    // Like Chrome, the best history match is typed ahead in the field and selected so typing replaces it.
    const auto &match=matches[0]; NSString *completed=[typed stringByAppendingString:S(match.completion)];
    BOOL page=match.url==match.entry->url && !match.entry->title.empty();
    addRow(match.url,completed,page ? S(match.entry->title) : S(rail::History::displayURL(match.url)),page ? S(rail::History::displayURL(match.url)) : nil,nil);
    NSTextView *editor=(NSTextView *)_address.currentEditor;
    if (editor) { editor.string=completed; editor.selectedRange=NSMakeRange(typed.length,completed.length-typed.length); }
    first=1;
  } else if (NSString *url=NormalizedAddress(query)) {
    BOOL search=[url hasPrefix:@"https://duckduckgo.com/?"] && ![query.lowercaseString containsString:@"duckduckgo"];
    addRow(C(url),typed,search ? query : S(rail::History::displayURL(C(url))),search ? @"Search DuckDuckGo" : nil,search ? RailSymbol(@"magnifyingglass",13) : nil);
  }
  for (size_t i=first;i<matches.size() && items.count<6;i++) {
    const auto *entry=matches[i].entry; NSString *display=S(rail::History::displayURL(entry->url));
    addRow(entry->url,display,entry->title.empty() ? display : S(entry->title),entry->title.empty() ? nil : display,nil);
  }
  if (!items.count) { [self hideSuggestions]; return; }
  _suggestionList.suggestions=items; _suggestionList.selectedIndex=0; _suggestionList.hidden=NO; [self layout];
}
- (void)hideSuggestions { _suggestionList.hidden=YES; _addressRows.clear(); }
- (void)chooseSuggestion:(NSInteger)index {
  if (index<0 || index>=(NSInteger)_addressRows.size()) return;
  std::string url=_addressRows[index].url; [self hideSuggestions]; [self navigateTo:S(url)];
}
- (void)moveSuggestion:(NSInteger)step {
  NSInteger count=(NSInteger)_addressRows.size(), index=MAX(0,MIN(count-1,_suggestionList.selectedIndex+step));
  _suggestionList.selectedIndex=index;
  NSTextView *editor=(NSTextView *)_address.currentEditor; editor.string=_addressRows[index].text; editor.selectedRange=NSMakeRange(editor.string.length,0);
}
- (void)controlTextDidBeginEditing:(NSNotification *)notification { (void)notification; _editingAddress=YES; }
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
  (void)textView;
  if (control!=_address) return NO;
  BOOL listed=!_suggestionList.hidden && !_addressRows.empty();
  if ([NSStringFromSelector(command) hasPrefix:@"delete"]) { _deletingAddress=YES; return NO; }
  if (listed && (command==@selector(moveUp:) || command==@selector(moveDown:))) { [self moveSuggestion:command==@selector(moveUp:) ? -1 : 1]; return YES; }
  if (listed && command==@selector(insertNewline:)) { [self chooseSuggestion:_suggestionList.selectedIndex]; return YES; }
  if (command!=@selector(cancelOperation:)) return NO;
  // First Escape closes the suggestions, the next one returns to the page.
  if (listed) { [self hideSuggestions]; ((NSTextView *)_address.currentEditor).string=_typedAddress ?: @""; return YES; }
  [_window makeFirstResponder:nil];
  if (auto browser=[self activeBrowser]) browser->GetHost()->SetFocus(true);
  return YES;
}
- (void)addressEntered:(id)sender { (void)sender; [self navigateTo:_address.stringValue]; }
- (void)navigateTo:(NSString *)address {
  NSString *url=NormalizedAddress(address); if (!url) { [self setStatus:@"Enter a web address or a search. Supported addresses use http or https."]; return; }
  auto *tab=_model.tab(_model.state.activeTabID); if (!tab) return;
  [self hideSuggestions];
  // A new tab that is sent elsewhere by a rule moves there before it loads anything.
  const std::string ruled=_model.spaceForURL(C(url));
  if (tab->url=="about:blank" && !_runtime.count(tab->id) && !ruled.empty() && ruled!=tab->spaceID) {
    const auto *from=_model.space(tab->spaceID); const bool defaultSession=from && from->sessionID==tab->sessionID;
    std::string tabID=tab->id; _model.moveTab(tabID,ruled,Now());
    tab=_model.tab(tabID); if (!tab) return;
    if (defaultSession) _model.setSession(tabID,_model.space(ruled)->sessionID);
  }
  if (!rail::BrowserModel::isIsolatedSession(tab->sessionID)) { _history.recordTyped(C(url),Now()); _historyDirty=YES; }
  tab->url=C(url); tab->title=C([NSURLComponents componentsWithString:url].host ?: @"New Tab"); tab->lastUsed=Now();
  _editingAddress=NO; [_window makeFirstResponder:nil]; _statusMessage=nil;
  auto it=_runtime.find(tab->id);
  if (it!=_runtime.end() && it->second.browser && it->second.closeReason==CloseReason::None) { it->second.error.clear(); it->second.browser->GetMainFrame()->LoadURL(tab->url); it->second.browser->GetHost()->SetFocus(true); }
  else [self ensureBrowser:tab->id];
  [self refresh]; [self saveSoon];
}
- (CefRefPtr<CefBrowser>)activeBrowser { auto it=_runtime.find(_model.state.activeTabID); return it!=_runtime.end() && it->second.closeReason==CloseReason::None ? it->second.browser : nullptr; }
- (void)goBack:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) if (browser->CanGoBack()) browser->GoBack(); }
- (void)goForward:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) if (browser->CanGoForward()) browser->GoForward(); }
- (void)reloadPage:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) { auto &slot=_runtime.at(_model.state.activeTabID); slot.error.clear(); browser->Reload(); [self refresh]; } else [self ensureBrowser:_model.state.activeTabID]; }
- (void)zoomIn:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) browser->GetHost()->SetZoomLevel(browser->GetHost()->GetZoomLevel()+.5); }
- (void)zoomOut:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) browser->GetHost()->SetZoomLevel(browser->GetHost()->GetZoomLevel()-.5); }
- (void)zoomReset:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) browser->GetHost()->SetZoomLevel(0); }
- (void)findInPage:(id)sender {
  (void)sender; auto browser=[self activeBrowser]; if (!browser) return;
  [self askForText:@"Find in page" initial:@"" completion:^(NSString *value) { if (value.length) browser->GetHost()->Find(C(value),true,false,false); }];
}
- (BOOL)handleShortcut:(NSEvent *)event {
  NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  // Releasing Ctrl commits the tab chosen in the switcher.
  if (event.type==NSEventTypeFlagsChanged) { if (!_switcherTabs.empty() && !(flags & NSEventModifierFlagControl)) [self finishTabSwitch:YES]; return NO; }
  if (event.type!=NSEventTypeKeyDown || _window.attachedSheet) return NO;
  if (event.keyCode==48 && (flags & NSEventModifierFlagControl) && !(flags & NSEventModifierFlagCommand)) { [self cycleRecentTabs:(flags & NSEventModifierFlagShift) ? -1 : 1]; return YES; }
  if (!_switcherTabs.empty() && event.keyCode==53) { [self finishTabSwitch:NO]; return YES; }
  if (!(flags & NSEventModifierFlagCommand)) { _undoCloseArmed=NO; return NO; }
  NSString *key=event.charactersIgnoringModifiers.lowercaseString;
  BOOL shift=(flags & NSEventModifierFlagShift)!=0;
  if ([key isEqual:@"t"] && shift) [self reopenClosedTab:nil];
  else if ([key isEqual:@"z"] && !shift && _undoCloseArmed && !_model.closedTabs.empty()) [self reopenClosedTab:nil];
  else if ([key isEqual:@"s"]) [self toggleSidebar:nil]; else if ([key isEqual:@"l"]) [self focusAddress:nil];
  else if ([key isEqual:@"t"]) [self newTab:nil]; else if ([key isEqual:@"w"]) [self closeCurrentTab:nil];
  else if ([key isEqual:@"r"]) [self reloadPage:nil]; else if ([key isEqual:@"f"]) [self findInPage:nil];
  else if ([key isEqual:@"["]) [self goBack:nil]; else if ([key isEqual:@"]"]) [self goForward:nil];
  else if ([key isEqual:@"q"]) [self quit:nil];
  else if (key.integerValue>=1 && key.integerValue<=9) {
    NSInteger target=key.integerValue-1,count=0;
    for (const auto &tab:_model.state.tabs) if (tab.spaceID==_model.state.activeSpaceID) { if (count++==target) { [self selectTabID:tab.id]; break; } }
  } else return NO;
  return YES;
}
- (void)askForText:(NSString *)prompt initial:(NSString *)initial completion:(void (^)(NSString *))completion {
  NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=prompt;
  NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,300,26)]; field.stringValue=initial ?: @""; alert.accessoryView=field;
  [alert addButtonWithTitle:@"Continue"]; [alert addButtonWithTitle:@"Cancel"];
  [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) { if (result==NSAlertFirstButtonReturn) completion([field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]); }];
  [alert.window makeFirstResponder:field];
}
- (void)newSpace:(id)sender {
  (void)sender; __weak BrowserController *weak=self;
  [self askForText:@"Name your Space" initial:@"" completion:^(NSString *name) { BrowserController *strong=weak; if (!strong || !name.length) return; const auto *space=strong->_model.space(strong->_model.state.activeSpaceID); auto id=strong->_model.addSpace(C(name),space ? space->sessionID : "work",Now()); strong->_model.selectSpace(id,Now()); [strong refresh]; [strong saveSoon]; }];
}
- (void)spaceMenu:(id)sender {
  (void)sender; NSMenu *menu=[[NSMenu alloc] init];
  NSMenuItem *rename=[[NSMenuItem alloc] initWithTitle:@"Rename Space…" action:@selector(renameSpace:) keyEquivalent:@""]; rename.target=self; [menu addItem:rename];
  NSMenuItem *defaults=[[NSMenuItem alloc] initWithTitle:@"Default Session for New Tabs" action:nil keyEquivalent:@""]; defaults.submenu=[[NSMenu alloc] init];
  const auto *space=_model.space(_model.state.activeSpaceID);
  for (const auto &session:_model.state.sessions) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:S(session.name) action:@selector(spaceDefaultSession:) keyEquivalent:@""]; item.target=self; item.representedObject=S(session.id); item.state=space && space->sessionID==session.id ? NSControlStateValueOn : NSControlStateValueOff; [defaults.submenu addItem:item]; }
  [menu addItem:defaults];
  NSMenuItem *rules=[[NSMenuItem alloc] initWithTitle:@"Open Links in This Space…" action:@selector(editSpaceRules:) keyEquivalent:@""]; rules.target=self; [menu addItem:rules];
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,28) inView:_spaceOptions];
}
- (void)renameSpace:(id)sender { (void)sender; auto *space=_model.space(_model.state.activeSpaceID); if (!space) return; std::string id=space->id; __weak BrowserController *weak=self; [self askForText:@"Rename Space" initial:S(space->name) completion:^(NSString *name) { BrowserController *strong=weak; if (strong && name.length) if (auto *s=strong->_model.space(id)) { s->name=C(name); [strong refresh]; [strong saveSoon]; } }]; }
- (void)editSpaceRules:(id)sender {
  (void)sender; const auto *space=_model.space(_model.state.activeSpaceID); if (!space) return; std::string id=space->id;
  NSMutableArray *lines=[NSMutableArray array]; for (const auto &pattern:_model.rulesForSpace(id)) [lines addObject:S(pattern)];
  NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=[NSString stringWithFormat:@"Open links in %@",S(space->name)];
  alert.informativeText=@"One address pattern per line, for example dev.azure.com/contoso/**. * matches within a path segment, ** matches anything below. Links from other apps, links that open a new tab, and addresses typed into a new tab open here. The most specific pattern wins.";
  NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,320,120)]; scroll.hasVerticalScroller=YES; scroll.borderType=NSBezelBorder;
  NSTextView *field=[[NSTextView alloc] initWithFrame:scroll.contentView.bounds]; field.string=[lines componentsJoinedByString:@"\n"];
  field.font=[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]; field.richText=NO; field.automaticQuoteSubstitutionEnabled=NO; field.automaticDashSubstitutionEnabled=NO; field.automaticTextReplacementEnabled=NO; field.automaticSpellingCorrectionEnabled=NO;
  field.autoresizingMask=NSViewWidthSizable; field.textContainerInset=NSMakeSize(2,4); field.accessibilityLabel=@"Address patterns"; scroll.documentView=field; alert.accessoryView=scroll;
  [alert addButtonWithTitle:@"Save"]; [alert addButtonWithTitle:@"Cancel"]; __weak BrowserController *weak=self;
  [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) {
    BrowserController *strong=weak; if (!strong || result!=NSAlertFirstButtonReturn) return;
    std::vector<std::string> patterns; for (NSString *line in [field.string componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) patterns.push_back(C(line));
    if (strong->_model.setSpaceRules(id,patterns)) [strong saveSoon];
  }];
  [alert.window makeFirstResponder:field];
}
- (void)spaceDefaultSession:(NSMenuItem *)sender { if (auto *space=_model.space(_model.state.activeSpaceID)) space->sessionID=C(sender.representedObject); [self saveSoon]; }
- (void)showSessionMenu:(id)sender { (void)sender; [_sessionPicker performClick:nil]; }
// The tab badge opens its session menu in place and changes that tab, selected or not.
- (void)showSessionMenuForTab:(const std::string &)tabID from:(NSView *)anchor {
  const auto *tab=_model.tab(tabID); if (!tab || !anchor) return;
  NSMenu *menu=[[NSMenu alloc] init]; NSString *tid=S(tabID);
  auto add=[&](NSString *title, NSString *session, BOOL current) {
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:@selector(tabSessionChosen:) keyEquivalent:@""];
    item.target=self; item.representedObject=@{@"tab":tid,@"session":session}; item.state=current ? NSControlStateValueOn : NSControlStateValueOff; [menu addItem:item];
  };
  for (const auto &session : _model.state.sessions) add(S(session.name),S(session.id),session.id==tab->sessionID);
  add(@"Isolated",@"__isolated__",rail::BrowserModel::isIsolatedSession(tab->sessionID));
  [menu addItem:NSMenuItem.separatorItem]; add(@"New session…",@"__new__",NO);
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(anchor.bounds)+4) inView:anchor];
}
- (void)tabSessionChosen:(NSMenuItem *)sender {
  std::string tabID=C(sender.representedObject[@"tab"]); NSString *session=sender.representedObject[@"session"];
  if (![session isEqual:@"__new__"]) { [self changeSession:C(session) tab:tabID]; return; }
  __weak BrowserController *weak=self;
  [self askForText:@"Name a reusable session" initial:@"" completion:^(NSString *name) { BrowserController *strong=weak; if (!strong || !name.length) return; auto id=strong->_model.addSession(C(name)); [strong changeSession:id tab:tabID]; }];
}
- (void)sessionChosen:(id)sender {
  (void)sender; NSString *value=_sessionPicker.selectedItem.representedObject; if (!value) return;
  if ([value isEqual:@"__new__"]) {
    __weak BrowserController *weak=self; [self askForText:@"Name a reusable session" initial:@"" completion:^(NSString *name) { BrowserController *strong=weak; if (!strong || !name.length) return; auto id=strong->_model.addSession(C(name)); [strong changeSession:id tab:strong->_model.state.activeTabID]; }]; [self refresh];
  } else [self changeSession:C(value) tab:_model.state.activeTabID];
}
- (void)changeSession:(const std::string &)session tab:(const std::string &)tabID {
  auto *tab=_model.tab(tabID); if (!tab) return;
  if ((session=="__isolated__" && rail::BrowserModel::isIsolatedSession(tab->sessionID)) || session==tab->sessionID) return;
  if (_runtime.count(tabID)) [self closeRuntime:tabID reason:CloseReason::Session session:session];
  else {
    if (session=="__isolated__") _model.setIsolated(tabID); else _model.setSession(tabID,session);
    if (tabID==_model.state.activeTabID) [self ensureBrowser:tabID];
    [self refresh]; [self saveSoon];
  }
}
- (void)showSettings:(id)sender {
  (void)sender;
  if (_settings.shown) { [_settings close]; return; }
  NSViewController *content=[[NSViewController alloc] init]; RailPanel *panel=[[RailPanel alloc] initWithFrame:NSMakeRect(0,0,310,240)]; panel.fill=RailColor(0xedf1f5); content.view=panel;
  NSTextField *title=RailLabel(@"Give idle tabs a rest",15,NSFontWeightSemibold,RailColor(0x273445)); title.frame=NSMakeRect(18,18,274,24); [panel addSubview:title];
  NSTextField *label=RailLabel(@"Unload after",12,NSFontWeightRegular,RailColor(0x273445)); label.frame=NSMakeRect(18,66,135,22); [panel addSubview:label];
  NSPopUpButton *timeout=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(164,61,126,28) pullsDown:NO];
  for (NSNumber *minutes in @[@1,@5,@10,@15,@30,@60]) { [timeout addItemWithTitle:[NSString stringWithFormat:@"%@ minutes",minutes]]; timeout.lastItem.representedObject=minutes; if (minutes.doubleValue==_model.state.idleMinutes) [timeout selectItem:timeout.lastItem]; }
  timeout.target=self; timeout.action=@selector(timeoutChosen:); [panel addSubview:timeout];
  NSTextField *copy=RailLabel(@"Inactive pages close, including pinned tabs. Their titles and addresses stay; opening a tab reloads its page. The selected tab stays awake.",11,NSFontWeightRegular,RailColor(0x596879)); copy.frame=NSMakeRect(18,105,274,70); copy.maximumNumberOfLines=4; copy.lineBreakMode=NSLineBreakByWordWrapping; [panel addSubview:copy];
  NSTextField *note=RailLabel(@"Unsaved page state may be lost. Isolated sessions keep their own saved logins.",11,NSFontWeightRegular,RailColor(0x596879)); note.frame=NSMakeRect(18,184,274,42); note.maximumNumberOfLines=3; note.lineBreakMode=NSLineBreakByWordWrapping; [panel addSubview:note];
  _settings=[[NSPopover alloc] init]; _settings.contentViewController=content; _settings.behavior=NSPopoverBehaviorTransient;
  [_settings showRelativeToRect:_sessionPicker.bounds ofView:_sessionPicker preferredEdge:NSRectEdgeMinY];
}
- (void)timeoutChosen:(NSPopUpButton *)sender { _model.state.idleMinutes=[sender.selectedItem.representedObject doubleValue]; [self saveSoon]; [self refresh]; [self checkIdle]; }
- (void)about:(id)sender { (void)sender; [NSApp orderFrontStandardAboutPanelWithOptions:@{NSAboutPanelOptionApplicationName:@"Eimerrail",NSAboutPanelOptionApplicationVersion:@"0.1",NSAboutPanelOptionVersion:@"A personal native browser with Chromium Embedded Framework."}]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; [self quit:nil]; return NO; }
- (void)quit:(id)sender {
  (void)sender; if (_quitting) return; _quitting=YES; [self saveNow];
  if (_runtime.empty()) { [self finishQuit]; return; }
  std::vector<std::string> ids; for (const auto &[id,slot]:_runtime) { (void)slot; ids.push_back(id); }
  for (const auto &id:ids) [self closeRuntime:id reason:CloseReason::Quit session:""];
}
- (void)finishQuit { [_idleTimer invalidate]; [_automationTimer invalidate]; [self saveNow]; _contexts.clear(); [_window orderOut:nil]; CefQuitMessageLoop(); }
- (void)dealloc { [_idleTimer invalidate]; [_automationTimer invalidate]; [_saveTimer invalidate]; _window.delegate=nil; }

// Test-only local control channel. It is disabled unless --automation was explicitly supplied.
// No remote page or production browser session can access this interface.
- (void)processAutomation {
  if (!_automation || _quitting) return;
  NSString *commandPath=[_directory stringByAppendingPathComponent:@"automation-command.json"];
  NSData *data=[NSData dataWithContentsOfFile:commandPath];
  NSDictionary *command=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if ([command isKindOfClass:NSDictionary.class] && [command[@"id"] isKindOfClass:NSString.class] && ![command[@"id"] isEqual:_automationID]) {
    _automationID=command[@"id"]; NSString *action=command[@"action"];
    std::string tabID=[command[@"tab"] isKindOfClass:NSString.class] ? C(command[@"tab"]) : _model.state.activeTabID;
    if ([action isEqual:@"newTab"]) { auto id=_model.addTab(_model.state.activeSpaceID,C(command[@"url"] ?: @"about:blank"),Now(),C(command[@"session"] ?: @"")); if ([command[@"isolated"] boolValue]) _model.setIsolated(id); [self selectTabID:id]; }
    else if ([action isEqual:@"select"]) [self selectTabID:tabID];
    else if ([action isEqual:@"navigate"]) [self navigateTo:command[@"url"]];
    else if ([action isEqual:@"close"]) [self closeTabID:tabID];
    else if ([action isEqual:@"session"]) [self changeSession:C(command[@"session"]) tab:tabID];
    else if ([action isEqual:@"pin"]) { _model.togglePin(tabID); [self refresh]; }
    else if ([action isEqual:@"age"]) { if (auto *tab=_model.tab(tabID)) tab->lastUsed=Now()-_model.state.idleMinutes*60-1; [self checkIdle]; }
    else if ([action isEqual:@"sidebar"]) [self toggleSidebar:nil];
    else if ([action isEqual:@"type"]) {
      // Typing waits for the address bar's focus change to settle, as a real keystroke would.
      [self focusAddress:nil]; NSString *text=command[@"text"] ?: @""; __weak BrowserController *weak=self;
      dispatch_async(dispatch_get_main_queue(), ^{ BrowserController *strong=weak; if (!strong) return; ((NSTextView *)strong->_address.currentEditor).string=text; [strong suggestFor:text inline:YES]; });
    }
    else if ([action isEqual:@"shortcut"]) {
      NSString *key=command[@"key"] ?: @"s";
      NSEventModifierFlags flags=NSEventModifierFlagCommand;
      if ([command[@"modifiers"] isKindOfClass:NSArray.class]) {
        flags=0;
        for (NSString *name in command[@"modifiers"]) flags|=[name isEqual:@"ctrl"] ? NSEventModifierFlagControl : [name isEqual:@"shift"] ? NSEventModifierFlagShift : [name isEqual:@"cmd"] ? NSEventModifierFlagCommand : 0;
      }
      unsigned short keyCode=[command[@"keyCode"] isKindOfClass:NSNumber.class] ? [command[@"keyCode"] unsignedShortValue] : 1;
      BOOL release=[command[@"release"] boolValue];
      NSEvent *event=[NSEvent keyEventWithType:release ? NSEventTypeFlagsChanged : NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:_window.windowNumber context:nil characters:release ? @"" : key charactersIgnoringModifiers:release ? @"" : key isARepeat:NO keyCode:release ? 59 : keyCode];
      [NSApp sendEvent:event];
    }
    else if ([action isEqual:@"capture"]) {
      [_window displayIfNeeded];
      NSMutableString *hierarchy=[NSMutableString stringWithFormat:@"Window %ld %@\nRoot %@\n",(long)_window.windowNumber,NSStringFromRect(_window.frame),_root];
      for (NSView *view in _root.subviews) [hierarchy appendFormat:@"%@ frame=%@ bounds=%@ hidden=%d children=%lu\n",view,NSStringFromRect(view.frame),NSStringFromRect(view.bounds),view.hidden,(unsigned long)view.subviews.count];
      [hierarchy writeToFile:[_directory stringByAppendingPathComponent:@"native-layout.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
      NSBitmapImageRep *rep=[_root bitmapImageRepForCachingDisplayInRect:_root.bounds]; [_root cacheDisplayInRect:_root.bounds toBitmapImageRep:rep];
      [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[_directory stringByAppendingPathComponent:@"native-window.png"] atomically:YES];
    }
    else if ([action isEqual:@"quit"]) { [self quit:nil]; return; }
    [self saveSoon];
  }
  NSMutableArray *tabs=[NSMutableArray array];
  for (const auto &tab:_model.state.tabs) { auto it=_runtime.find(tab.id); [tabs addObject:@{@"id":S(tab.id),@"url":S(tab.url),@"title":S(tab.title),@"session":S(tab.sessionID),@"space":S(tab.spaceID),@"pinned":@(tab.pinned),@"loaded":@(it!=_runtime.end() && it->second.browser.get()!=nullptr),@"closing":@(it!=_runtime.end() && it->second.closeReason!=CloseReason::None),@"error":it!=_runtime.end() ? S(it->second.error) : @""}]; }
  NSDictionary *snapshot=@{@"command":_automationID ?: @"",@"activeTab":S(_model.state.activeTabID),@"activeSpace":S(_model.state.activeSpaceID),@"sidebarVisible":@(_model.state.sidebarVisible),@"tabs":tabs,@"runtimeCount":@(_runtime.size())};
  [[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[_directory stringByAppendingPathComponent:@"automation-state.json"] atomically:YES];
}
@end
