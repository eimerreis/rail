#import "BrowserController.h"
#import "CEFBridge.h"
#import "NativeViews.h"
#import "StateStore.h"
#import "ProjectStatus.h"
#import "ProjectsView.h"
#import "ReadingController.h"
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
  // Navigation received while Chromium is creating or closing this tab's browser.
  std::string pendingURL;
  std::string error;
  bool loading = false, back = false, forward = false;
};
// Icons offered for Spaces; any other SF Symbol can be typed in.
NSArray<NSString *> *SpaceSymbols() {
  return @[@"briefcase",@"house",@"book",@"square.grid.2x2",@"star",@"heart",@"bolt",@"flame",@"leaf",@"globe",@"hammer",@"wrench.and.screwdriver",@"terminal",@"chevron.left.forwardslash.chevron.right",@"paintbrush",@"graduationcap",@"cart",@"gamecontroller",@"music.note",@"camera",@"airplane",@"building.2",@"person.2",@"flag"];
}
NSString *SymbolTitle(NSString *symbol) {
  NSDictionary *titles=@{@"square.grid.2x2":@"Grid",@"wrench.and.screwdriver":@"Tools",@"chevron.left.forwardslash.chevron.right":@"Code",@"music.note":@"Music",@"building.2":@"Office",@"person.2":@"People",@"graduationcap":@"Learning",@"gamecontroller":@"Games"};
  return titles[symbol] ?: symbol.capitalizedString;
}
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
- (void)refreshHome;
- (void)checkProjects:(BOOL)force;
- (NSMenu *)projectMenuForTab:(std::string)tabID;
@end

@implementation BrowserController {
  rail::BrowserModel _model;
  rail::Projects _projects;
  ProjectStatusService *_status;
  ProjectsHomeView *_home;
  // The Space home replaces the page area until a tab is selected; it is not saved.
  // Reading replaces the sidebar and page area the same way, and is not saved either.
  ReadingController *_reading;
  BOOL _readingVisible, _readingClosed;
  NSUInteger _shownUnread;
  RailButton *_readerChip;
  BOOL _homeVisible, _projectsDirty, _projectsSavingAllowed, _statusRefreshQueued, _loadingRepositories;
  NSInteger _homeFilter;
  NSTimer *_statusTimer;
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
  // Recent downloads, newest first: name, path, url, received, total, date and a state of
  // active, done, canceled or failed. Chromium's id is only kept while this run lasts.
  NSMutableArray<NSMutableDictionary *> *_downloads;
  std::unordered_map<uint32_t, CefRefPtr<CefDownloadItemCallback>> _downloadCallbacks;
  RailButton *_downloadsButton;
  NSPopover *_downloadsPopover;
  RailDownloadList *_downloadList;
  BOOL _downloadsDirty, _downloadsUnseen;
}
@synthesize window = _window;

- (instancetype)initWithDataDirectory:(NSString *)directory automation:(BOOL)automation {
  if ((self = [super init])) {
    _directory = [directory copy]; _automation = automation; _savingAllowed = YES; _nextGeneration = 1;
    _favicons = [NSMutableDictionary dictionary]; rail::LoadHistory(_directory,_history); [self loadDownloads];
    NSError *error = nil;
    // Projects load first: tabs opened from a project may use profiles that projects own.
    _projectsSavingAllowed = YES;
    if (!rail::LoadProjects(_directory,_projects,&error)) {
      NSString *path = [_directory stringByAppendingPathComponent:@"projects.json"];
      NSString *backup = [_directory stringByAppendingPathComponent:[NSString stringWithFormat:@"projects-recovery-%.0f.json",Now()]];
      _projectsSavingAllowed = [NSFileManager.defaultManager copyItemAtPath:path toPath:backup error:nil];
      _statusMessage = _projectsSavingAllowed ? @"Saved projects could not be read. A recovery copy was kept." : @"Could not read saved projects. Saving projects is disabled to protect the original.";
      error = nil;
    }
    _model.projectProfiles = _projects.ownedProfiles();
    if (!rail::LoadState(_directory,_model,&error)) {
      NSString *statePath = [_directory stringByAppendingPathComponent:@"state.json"];
      NSString *backup = [_directory stringByAppendingPathComponent:[NSString stringWithFormat:@"state-recovery-%.0f.json",Now()]];
      _savingAllowed = [NSFileManager.defaultManager copyItemAtPath:statePath toPath:backup error:nil];
      _statusMessage = _savingAllowed ? @"Saved layout could not be read. A recovery copy was kept." : @"Could not read saved layout. Saving is disabled to protect the original.";
    }
    _projects.sanitize(_model); _model.projectProfiles = _projects.ownedProfiles();
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
  // The top 51 points of the rail, sidebar and toolbar form the window's title bar.
  for (RailPanel *panel in @[_rail,_sidebar,_toolbar]) panel.titlebarHeight = 51;
  _webHost = [[NSView alloc] init]; _webHost.wantsLayer = YES; _webHost.layer.backgroundColor = NSColor.whiteColor.CGColor; [_root addSubview:_webHost];
  _empty = [[RailPanel alloc] init]; _empty.fill = NSColor.whiteColor; [_root addSubview:_empty];
  _emptyTitle = RailLabel(@"A little room for what's next.",27,NSFontWeightMedium,RailColor(0x273445)); _emptyTitle.alignment = NSTextAlignmentCenter; [_empty addSubview:_emptyTitle];
  _emptySubtitle = RailLabel(@"Enter an address or search with ⌘ L.",14,NSFontWeightRegular,RailColor(0x596879)); _emptySubtitle.alignment = NSTextAlignmentCenter; [_empty addSubview:_emptySubtitle];
  _retry = RailAction(@"Search or enter address",@"magnifyingglass",@"Focus address bar",^{ [weak focusAddress:nil]; }); _retry.normalFill = RailColor(0xd8e7f7); _retry.ink = RailColor(0x245b96); _retry.centered = YES; [_empty addSubview:_retry];
  _home = [[ProjectsHomeView alloc] initWithFrame:NSZeroRect]; _home.hidden = YES; [_root addSubview:_home];
  _home.onAddProject = ^{ [weak newProject:nil]; };
  _home.onImportAzure = ^{ [weak importFromAzure:nil]; };
  _home.onImportGitHub = ^{ [weak importFromGitHub:nil]; };
  _home.onCheckNow = ^{ [weak checkProjects:YES]; };
  _home.onFilter = ^(NSInteger filter) { BrowserController *strong = weak; if (strong) strong->_homeFilter = filter; };
  _reading = [[ReadingController alloc] initWithDirectory:_directory host:_root]; [self wireReading];
  _reading.reader.hidden = YES; [_root addSubview:_reading.reader];
  _reading.sidebar.hidden = YES; [_sidebar addSubview:_reading.sidebar];
  _readerChip = RailAction(@"Reader",nil,@"Showing this page in the reader",nil); _readerChip.centered = YES; _readerChip.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]; _readerChip.ink = RailColor(0x245b96); _readerChip.normalFill = RailColor(0xd8e7f7); _readerChip.hoverFill = RailColor(0xd8e7f7); _readerChip.cornerRadius = 4; _readerChip.hidden = YES;
  if (_reading.loadProblem && !_statusMessage) _statusMessage = _reading.loadProblem;
  _status = [[ProjectStatusService alloc] initWithContexts:^CefRefPtr<CefRequestContext>(NSString *session) { BrowserController *strong = weak; return strong ? [strong contextForSession:C(session)] : nullptr; }];
  _status.onChange = ^{ [weak statusChanged]; };
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
  _addressBar = [[RailAddressBar alloc] init]; _addressBar.onFocusChange = ^(BOOL focused) { [weak addressFocusChanged:focused]; }; [_toolbar addSubview:_addressBar]; [_addressBar addSubview:_readerChip];
  _address = _addressBar.field;
  _address.placeholderString = @"Search or enter address"; _address.delegate = self; _address.target = self; _address.action = @selector(addressEntered:); _address.accessibilityLabel = @"Search or enter address";
  _downloadsButton = RailAction(@"",@"arrow.down.circle",@"Downloads",^{ [weak toggleDownloads:nil]; }); _downloadsButton.centered = YES; _downloadsButton.hidden = !_downloads.count; [_toolbar addSubview:_downloadsButton];
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
  [_reading start];
  _idleTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) { (void)timer; [weak checkIdle]; }];
  _statusTimer = [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *timer) { (void)timer; BrowserController *strong = weak; if (strong && strong->_homeVisible && strong->_window.isVisible) [strong checkProjects:NO]; }];
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
    const auto pinned=_model.pinnedTabForURL(C(link.absoluteString));
    if (!pinned.empty()) {
      // Select without waking the old page first, so an unloaded pin loads only the incoming URL.
      _model.selectTab(pinned,Now()); _homeVisible=NO;
      if (_model.tab(pinned)->url!=C(link.absoluteString)) [self navigateTo:link.absoluteString];
      [self selectTabID:pinned];
      continue;
    }
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
  NSArray *groups = @[@[@"Eimerrail",@[@"About Eimerrail",@"about:",@""],@[@"Settings…",@"showSettings:",@","],@[@"Set as Default Browser…",@"makeDefaultBrowser:",@""],@[@"Quit Eimerrail",@"quit:",@"q"]],@[@"File",@[@"New Tab",@"newTab:",@"t"],@[@"New Space…",@"newSpace:",@""],@[@"Space Home",@"showHome:",@"H"],@[@"Add Project…",@"newProject:",@""],@[@"Add Current Page as Project",@"addCurrentPageAsProject:",@""],@[@"Save Page to Reading List",@"savePageToReading:",@"D"],@[@"Close Tab",@"closeCurrentTab:",@"w"],@[@"Reopen Closed Tab",@"reopenClosedTab:",@"T"]],@[@"Edit",@[@"Undo",@"undo:",@"z"],@[@"Cut",@"cut:",@"x"],@[@"Copy",@"copy:",@"c"],@[@"Paste",@"paste:",@"v"],@[@"Select All",@"selectAll:",@"a"],@[@"Find…",@"findInPage:",@"f"]],@[@"View",@[@"Reading List",@"showReading:",@"L"],@[@"Toggle Sidebar",@"toggleSidebar:",@"s"],@[@"Address Bar",@"focusAddress:",@"l"],@[@"Reload",@"reloadPage:",@"r"],@[@"Back",@"goBack:",@"["],@[@"Forward",@"goForward:",@"]"],@[@"Zoom In",@"zoomIn:",@"+"],@[@"Zoom Out",@"zoomOut:",@"-"],@[@"Actual Size",@"zoomReset:",@"0"],@[@"Developer Tools",@"showDevTools:",@"i"]]];
  for (NSArray *group in groups) {
    NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:group[0] action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:group[0]]; top.submenu = menu; [bar addItem:top];
    for (NSUInteger i=1;i<group.count;i++) {
      NSArray *entry = group[i]; SEL action = NSSelectorFromString(entry[1]);
      NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0] action:action keyEquivalent:entry[2]];
      if (action==@selector(showDevTools:)) item.keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagOption;
      item.target = [self respondsToSelector:action] ? self : nil; [menu addItem:item];
    }
  }
}
- (void)layout {
  CGFloat w = _root.bounds.size.width, h = _root.bounds.size.height;
  // The sidebar, rail and Space home are laid out at the small size and drawn larger.
  CGFloat scale = rail::BrowserModel::controlScale(_model.state.controlSize);
  for (RailPanel *panel in @[_rail,_sidebar,_home]) panel.contentScale = scale;
  _rail.titlebarHeight = _sidebar.titlebarHeight = 51/scale;
  CGFloat rail = _model.state.sidebarVisible ? round(45*scale) : 0, side = _model.state.sidebarVisible ? round([self shownSidebarWidth]*scale) : 0, left = rail + side;
  _rail.hidden = !_model.state.sidebarVisible; _sidebar.hidden = !_model.state.sidebarVisible;
  _rail.frame = NSMakeRect(0,0,rail,h); _sidebar.frame = NSMakeRect(rail,0,side,h);
  CGFloat sideH = _sidebar.bounds.size.height, railH = _rail.bounds.size.height; side = _model.state.sidebarVisible ? [self shownSidebarWidth] : 0;
  _toolbar.frame = NSMakeRect(left,0,w-left,51); _webHost.frame = NSMakeRect(left,51,w-left,h-77); _empty.frame = NSMakeRect(left,51,w-left,h-77); _home.frame = NSMakeRect(left,51,w-left,h-77); _reading.reader.frame = NSMakeRect(left,51,w-left,h-77);
  _statusbar.frame = NSMakeRect(left,h-26,w-left,26);
  _spaceLabel.frame = NSMakeRect(15,62,side-55,23); _spaceSubtitle.frame = NSMakeRect(15,91,side-25,16);
  // Centered on the toolbar's buttons, whatever the size.
  _sidebarToggle.frame = NSMakeRect(side-39,25/scale-14,28,28); _spaceOptions.frame = NSMakeRect(side-39,61,28,28);
  _tabScroll.frame = NSMakeRect(0,117,side,MAX(0,sideH-160)); _sleepLabel.frame = NSMakeRect(13,sideH-29,side-25,17);
  _reading.sidebar.frame = NSMakeRect(0,58,side,MAX(0,sideH-58));
  _sidebarHandle.hidden = !_model.state.sidebarVisible || _readingVisible; _sidebarHandle.frame = NSMakeRect(left-3,0,6,h);
  CGFloat x = _model.state.sidebarVisible ? 7 : 86;
  _toggle.hidden = _model.state.sidebarVisible;
  if (!_toggle.hidden) { _toggle.frame = NSMakeRect(x,11,28,28); x += 31; }
  _back.frame = NSMakeRect(x,11,27,28); _forward.frame = NSMakeRect(x+28,11,27,28); _reload.frame = NSMakeRect(x+56,11,27,28); x += 92;
  CGFloat tw = _toolbar.bounds.size.width;
  CGFloat downloads = _downloadsButton.hidden ? 0 : 34;
  _addressBar.frame = NSMakeRect(x,10,MAX(90,tw-x-(_sessionPicker.hidden && !downloads ? 10 : 133)-downloads),30); _sessionPicker.frame = NSMakeRect(tw-123,12,116,28);
  _downloadsButton.frame = NSMakeRect(tw-157,11,28,28);
  _progress.frame = NSMakeRect(0,48,tw,3);
  _readerChip.frame = NSMakeRect(_addressBar.bounds.size.width-58,6,52,18);
  if (!_suggestionList.hidden) { NSRect bar = [_root convertRect:_addressBar.bounds fromView:_addressBar]; _suggestionList.frame = NSMakeRect(NSMinX(bar),NSMaxY(bar)+4,NSWidth(bar),[RailSuggestionList heightForCount:_addressRows.size()]); }
  _sessionLabel.frame = NSMakeRect(13,6,155,14); _statusLabel.frame = NSMakeRect(175,6,MAX(0,tw-188),14); _statusLabel.alignment = NSTextAlignmentRight;
  CGFloat ew = _empty.bounds.size.width, ey = MAX(80,_empty.bounds.size.height*.32);
  _emptyTitle.frame = NSMakeRect(30,ey,ew-60,40); _emptySubtitle.frame = NSMakeRect(35,ey+52,ew-70,45); _emptySubtitle.maximumNumberOfLines = 2;
  _retry.frame = NSMakeRect((ew-220)/2,ey+112,220,34);
  for (auto &[id,slot] : _runtime) { (void)id; slot.container.frame = _webHost.bounds; for (NSView *child in slot.container.subviews) child.frame = slot.container.bounds; }
  CGFloat start = _model.state.sidebarVisible ? MAX(60,rail+15) : 16;
  for (NSUInteger i=0;i<3;i++) {
    NSButton *button = [_window standardWindowButton:(NSWindowButton)i];
    NSRect f = button.frame; f.origin.x = start + i*20; f.origin.y = button.superview.bounds.size.height - 29; button.frame = f;
  }
  for (NSView *v in _rail.subviews) if (v.tag == 900) v.frame = NSMakeRect(6,railH-83,32,30); else if (v.tag == 901) v.frame = NSMakeRect(6,railH-43,32,30);
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
    NSString *symbol = [self symbolForSpace:space index:index];
    RailButton *button = RailAction(@"",symbol,S(space.name),^{ BrowserController *strong = weak; if (!strong) return; strong->_homeVisible = NO; strong->_readingVisible = NO; strong->_model.selectSpace(sid,Now()); [strong ensureBrowser:strong->_model.state.activeTabID]; [strong refresh]; [strong saveSoon]; });
    button.centered = YES; button.frame = NSMakeRect(6,ry,32,32); button.ink = RailColor(0x596879);
    if (space.id == _model.state.activeSpaceID && !_readingVisible) { button.normalFill = RailColor(0x4173aa); button.hoverFill = RailColor(0x37679c); button.ink = NSColor.whiteColor; }
    [_rail addSubview:button]; ry += 41;
  }
  [self addReadingEntryAt:ry];
  RailButton *addSpace = RailAction(@"",@"plus",@"New Space",^{ [weak newSpace:nil]; }); addSpace.centered = YES; addSpace.tag = 900; [_rail addSubview:addSpace];
  RailButton *settings = RailAction(@"",@"slider.horizontal.3",@"Settings",^{ [weak showSettings:nil]; }); settings.centered = YES; settings.tag = 901; [_rail addSubview:settings];
  const auto *space = _model.space(_model.state.activeSpaceID);
  _spaceLabel.stringValue = space ? S(space->name) : @"Space";
  _spaceSubtitle.stringValue = @"A little room for good work.";
  NSPoint offset = _tabScroll.contentView.bounds.origin; CGFloat side = _model.state.sidebarWidth, pinWidth = floor((side-30)/2);
  for (NSView *v in [_tabDocument.subviews copy]) [v removeFromSuperview];
  [_tabDocument addSubview:_dropIndicator];
  CGFloat y = 4; NSUInteger pins = 0, sleeping = 0;
  {
    RailPanel *row = [[RailPanel alloc] initWithFrame:NSMakeRect(7,y,side-14,32)]; row.wantsLayer=YES; row.layer.cornerRadius=7; row.layer.masksToBounds=YES; row.fill=_homeVisible ? RailColor(0xd8e7f7) : nil;
    RailButton *home = RailAction([NSString stringWithFormat:@"%@ home",space ? S(space->name) : @"Space"],@"square.grid.2x2",@"Projects in this Space (⌘ ⇧ H)",^{ [weak showHome:nil]; });
    home.frame = NSMakeRect(0,0,side-14,32); home.font = [NSFont systemFontOfSize:12 weight:_homeVisible ? NSFontWeightSemibold : NSFontWeightRegular]; home.ink = RailColor(_homeVisible ? 0x245b96 : 0x273445); [row addSubview:home];
    NSUInteger attention = [self attentionCountInSpace:_model.state.activeSpaceID];
    if (attention) {
      RailButton *count = RailAction([NSString stringWithFormat:@"%lu",(unsigned long)attention],nil,[NSString stringWithFormat:@"%lu project%@ need%@ attention",(unsigned long)attention,attention==1 ? @"" : @"s",attention==1 ? @"s" : @""],^{ [weak showHome:nil]; });
      count.font=[NSFont systemFontOfSize:9.5 weight:NSFontWeightBold]; count.centered=YES; count.cornerRadius=8; count.normalFill=RailColor(0xd9533f); count.hoverFill=RailColor(0xc4452f); count.ink=NSColor.whiteColor;
      count.frame=NSMakeRect(side-14-30,8,20,16); [row addSubview:count];
    }
    [_tabDocument addSubview:row]; y += 42;
  }
  for (const auto &t : _model.state.tabs) if (t.spaceID == _model.state.activeSpaceID && !_runtime.count(t.id) && t.url != "about:blank") sleeping++;
  NSTextField *pinHeading = RailLabel(@"Pinned",10,NSFontWeightMedium,RailColor(0x596879)); pinHeading.frame = NSMakeRect(15,y,side-30,16); [_tabDocument addSubview:pinHeading]; y += 24;
  for (const auto &tab : _model.state.tabs) {
    if (tab.spaceID != _model.state.activeSpaceID || !tab.pinned) continue;
    std::string tid = tab.id;
    RailButton *button = RailAction(S(tab.shownTitle()),SymbolForURL(tab.url),S(tab.shownTitle()),^{ [weak selectTabID:tid]; });
    [self applyFaviconFor:tab.url button:button sleeping:!_runtime.count(tid) && tab.url != "about:blank"]; button.dragTabID = S(tid);
    button.onDoubleClick = ^{ [weak renameTabID:tid]; };
    button.font = [NSFont systemFontOfSize:11]; button.frame = NSMakeRect(12+(pins%2)*(pinWidth+6),y+(pins/2)*42,pinWidth,36);
    button.normalFill = RailColor(tab.id == _model.state.activeTabID && !_homeVisible ? 0xd4e4f6 : 0xf8fafc); button.stroke = RailColor(0xd4dde5);
    button.ink = RailColor(_runtime.count(tab.id) || tab.url == "about:blank" ? 0x273445 : 0x596879);
    button.toolTip = [NSString stringWithFormat:@"%@ · %@%@",S(tab.shownTitle()),[self sessionName:tab.sessionID],_runtime.count(tab.id) ? @"" : @" · Reloads on open"];
    button.menu = [self menuForTab:tid]; [_tabDocument addSubview:button]; pins++;
  }
  if (pins) y += ((pins+1)/2)*42 + 12;
  else { NSTextField *hint = RailLabel(@"Drag a tab here to pin it.",10,NSFontWeightRegular,RailColor(0x596879)); hint.frame=NSMakeRect(15,y,side-30,18); [_tabDocument addSubview:hint]; y += 35; }
  _pinnedSectionEnd = y;
  NSTextField *tabHeading = RailLabel(@"Tabs",10,NSFontWeightMedium,RailColor(0x596879)); tabHeading.frame = NSMakeRect(15,y,side-30,16); [_tabDocument addSubview:tabHeading]; y += 23;
  for (const auto &tab : _model.state.tabs) {
    if (tab.spaceID != _model.state.activeSpaceID || tab.pinned) continue;
    std::string tid = tab.id; BOOL selected = tid == _model.state.activeTabID && !_homeVisible;
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
    // A close button appears left of the session badge while the pointer is over the row.
    RailButton *close = RailAction(@"",nil,@"Close tab (⌘ W)",^{ [weak closeTabID:tid]; }); close.image=RailSymbol(@"xmark",10);
    close.frame=NSMakeRect(side-59,8,19,19); close.centered=YES; close.cornerRadius=5; close.ink=RailColor(0x596879); close.hoverFill=RailColor(selected ? 0xc4d8ee : 0xdde4ec); close.hidden=YES; [row addSubview:close];
    __weak RailButton *weakTitle = button, *weakClose = close;
    row.onHoverChange = ^(BOOL hovered) { weakClose.hidden=!hovered; NSRect frame=weakTitle.frame; frame.size.width=side-(hovered ? 62 : 40); weakTitle.frame=frame; };
    [_tabDocument addSubview:row]; y += 38;
  }
  RailButton *newTab = RailAction(@"New tab",@"plus",@"New tab (⌘ T)",^{ [weak newTab:nil]; }); newTab.ink=RailColor(0x596879); newTab.frame=NSMakeRect(9,y+8,side-18,33); [_tabDocument addSubview:newTab]; y += 54;
  // Fill the visible area exactly; a fraction more makes a scaled sidebar show a scroller that narrows the rows.
  _tabDocument.frame=NSMakeRect(0,0,side,MAX(y,floor(_tabScroll.contentView.bounds.size.height))); [_tabScroll.contentView scrollToPoint:NSMakePoint(0,MIN(offset.y,MAX(0,y-_tabScroll.contentSize.height)))];
  _sleepLabel.stringValue=[NSString stringWithFormat:@"%lu asleep · after %.0f min",(unsigned long)sleeping,_model.state.idleMinutes];
  [_sessionPicker removeAllItems];
  const auto *active = _model.tab(_model.state.activeTabID);
  for (const auto &session : _model.state.sessions) { [_sessionPicker addItemWithTitle:S(session.name)]; _sessionPicker.lastItem.representedObject=S(session.id); }
  [_sessionPicker addItemWithTitle:@"Isolated"]; _sessionPicker.lastItem.representedObject=@"__isolated__";
  [_sessionPicker.menu addItem:NSMenuItem.separatorItem]; [_sessionPicker addItemWithTitle:@"New session…"]; _sessionPicker.lastItem.representedObject=@"__new__";
  if (active) {
    for (NSMenuItem *item in _sessionPicker.itemArray) if ([item.representedObject isEqual:S(active->sessionID)] || (rail::BrowserModel::isIsolatedSession(active->sessionID) && [item.representedObject isEqual:@"__isolated__"])) [_sessionPicker selectItem:item];
    _sessionLabel.stringValue = [NSString stringWithFormat:@"%@ session",[self sessionName:active->sessionID]];
    if (!_editingAddress) { _address.stringValue = _homeVisible ? @"" : DisplayAddress(active->url); _addressBar.symbolName = _homeVisible ? @"square.grid.2x2" : AddressSymbol(active->url); }
    if (!_editingAddress && _homeVisible) _address.placeholderString = [NSString stringWithFormat:@"%@ home — search or enter address",space ? S(space->name) : @"Space"];
    else _address.placeholderString = @"Search or enter address";
    _window.title = _homeVisible ? [NSString stringWithFormat:@"%@ home — Eimerrail",space ? S(space->name) : @"Space"] : [NSString stringWithFormat:@"%@ — Eimerrail",S(active->title)];
  }
  auto slot = _runtime.find(_model.state.activeTabID);
  const BOOL covered=_homeVisible || _readingVisible;
  _back.enabled=!covered && slot!=_runtime.end() && slot->second.back; _forward.enabled=!covered && slot!=_runtime.end() && slot->second.forward;
  if (!covered && slot!=_runtime.end() && slot->second.loading) [_progress startAnimation:nil]; else [_progress stopAnimation:nil];
  for (auto &[id,runtime] : _runtime) runtime.container.hidden = covered || id != _model.state.activeTabID;
  BOOL error = slot!=_runtime.end() && !slot->second.error.empty();
  _empty.hidden = covered || (active && active->url!="about:blank" && !error);
  _home.hidden = !_homeVisible; if (_homeVisible) [self refreshHome];
  if (error) {
    _emptyTitle.stringValue=@"Couldn't load this page."; _emptySubtitle.stringValue=S(slot->second.error); _retry.title=@"Try again"; _retry.image=RailSymbol(@"arrow.clockwise",15); _retry.handler=^{ [weak reloadPage:nil]; };
  } else {
    _emptyTitle.stringValue=@"A little room for what's next."; _emptySubtitle.stringValue=@"Enter an address or search with ⌘ L."; _retry.title=@"Search or enter address"; _retry.image=RailSymbol(@"magnifyingglass",15); _retry.handler=^{ [weak focusAddress:nil]; };
  }
  [self refreshReadingChrome];
  _statusLabel.stringValue = _statusMessage.length ? _statusMessage : [NSString stringWithFormat:@"Idle tabs unload after %.0f min",_model.state.idleMinutes];
  [self layout];
}
- (NSMenu *)menuForTab:(const std::string &)tabID {
  const auto *tab = _model.tab(tabID); NSMenu *menu = [[NSMenu alloc] init]; if (!tab) return menu;
  NSMutableArray *entries = [NSMutableArray arrayWithObject:@[tab->pinned ? @"Unpin Tab" : @"Pin Tab",@"pinTab:"]];
  if (tab->pinned) [entries addObject:@[@"Rename Tab…",@"renameTabMenu:"]];
  [entries addObjectsFromArray:@[@[@"Unload Tab",@"unloadTab:"],@[@"Close Tab",@"closeTabMenu:"]]];
  for (NSArray *entry in entries) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""]; item.target=self; item.representedObject=S(tabID); [menu addItem:item];
  }
  NSMenuItem *move = [[NSMenuItem alloc] initWithTitle:@"Move to Space" action:nil keyEquivalent:@""]; move.submenu=[[NSMenu alloc] init];
  for (const auto &space : _model.state.spaces) if (space.id!=tab->spaceID) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:S(space.name) action:@selector(moveTabMenu:) keyEquivalent:@""]; item.target=self; item.representedObject=@{@"tab":S(tabID),@"space":S(space.id)}; [move.submenu addItem:item]; }
  [menu addItem:move];
  if (rail::isWebURL(tab->url)) { NSMenuItem *projects=[[NSMenuItem alloc] initWithTitle:@"Add to Project" action:nil keyEquivalent:@""]; projects.submenu=[self projectMenuForTab:tabID]; [menu addItem:projects]; }
  if (rail::isWebURL(tab->url)) { NSMenuItem *save=[[NSMenuItem alloc] initWithTitle:@"Save to Reading List" action:@selector(saveTabToReading:) keyEquivalent:@""]; save.target=self; save.representedObject=S(tabID); [menu addItem:save]; }
  return menu;
}
- (void)selectTabID:(const std::string &)tabID {
  if (_quitting || !_model.selectTab(tabID,Now())) return;
  _homeVisible=NO; _readingVisible=NO;
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
  else {
    if (!it->second.pendingURL.empty()) { browser->GetMainFrame()->LoadURL(it->second.pendingURL); it->second.pendingURL.clear(); }
    if (tabID==_model.state.activeTabID) browser->GetHost()->SetFocus(true);
  }
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
  CloseReason reason=it->second.closeReason; std::string nextSession=it->second.nextSession, pendingURL=it->second.pendingURL;
  const bool wasActive=tabID==_model.state.activeTabID;
  [it->second.container removeFromSuperview]; _runtime.erase(it);
  if (reason==CloseReason::Delete || reason==CloseReason::None) _model.closeTab(tabID,Now());
  if (reason==CloseReason::Session) { if (nextSession=="__isolated__") _model.setIsolated(tabID); else _model.setSession(tabID,nextSession); }
  if (!pendingURL.empty()) if (auto *tab=_model.tab(tabID)) { tab->url=pendingURL; if (wasActive) _model.selectTab(tabID,Now()); }
  // Drop our context reference when its final live tab closes. Chromium may
  // still retain shared process/profile resources during asynchronous teardown.
  for (auto context=_contexts.begin();context!=_contexts.end();) {
    bool used=false;
    for (const auto &[id,slot]:_runtime) { (void)slot; const auto *tab=_model.tab(id); if (tab && tab->sessionID==context->first) { used=true; break; } }
    // Status checks keep using a session's context; recreating it while one is alive would clash.
    for (const auto &connection:_projects.state.connections) if (connection.auth=="session" && connection.sessionID==context->first) used=true;
    if ([_reading.activeSession isEqual:S(context->first)]) used=true;
    if (used) ++context; else context=_contexts.erase(context);
  }
  [self saveSoon];
  if (_quitting) { if (_runtime.empty() && _readingClosed) [self finishQuit]; return; }
  // A tab selected while closing is reopened only after the old browser is fully gone.
  if (tabID==_model.state.activeTabID || reason==CloseReason::Delete || reason==CloseReason::None) [self ensureBrowser:_model.state.activeTabID];
  [self refresh];
}
- (void)closeCancelled:(const std::string &)tabID generation:(uint64_t)generation {
  auto it=_runtime.find(tabID); if (it==_runtime.end() || it->second.generation!=generation) return;
  if (!it->second.pendingURL.empty() && it->second.browser) if (auto *tab=_model.tab(tabID)) tab->url=it->second.browser->GetMainFrame()->GetURL().ToString();
  it->second.pendingURL.clear();
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
#pragma mark Downloads
static const NSUInteger RailKeptDownloads = 20, RailShownDownloads = 8;
- (NSString *)downloadsFile { return [_directory stringByAppendingPathComponent:@"downloads.json"]; }
- (void)loadDownloads {
  _downloads=[NSMutableArray array];
  NSData *data=[NSData dataWithContentsOfFile:[self downloadsFile]];
  id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![value isKindOfClass:NSDictionary.class] || ![value[@"downloads"] isKindOfClass:NSArray.class]) return;
  for (id item in value[@"downloads"]) {
    if (![item isKindOfClass:NSDictionary.class] || ![item[@"path"] isKindOfClass:NSString.class] || ![@[@"done",@"canceled",@"failed"] containsObject:item[@"state"] ?: @""]) continue;
    NSMutableDictionary *download=[NSMutableDictionary dictionary];
    for (NSString *key in @[@"name",@"path",@"url",@"state"]) if ([item[key] isKindOfClass:NSString.class]) download[key]=item[key];
    for (NSString *key in @[@"received",@"total",@"date"]) if ([item[key] isKindOfClass:NSNumber.class]) download[key]=item[key];
    if (!download[@"name"]) download[@"name"]=[download[@"path"] lastPathComponent];
    [_downloads addObject:download]; if (_downloads.count>=RailKeptDownloads) break;
  }
}
- (BOOL)saveDownloads {
  NSMutableArray *list=[NSMutableArray array];
  for (NSDictionary *download in _downloads) {
    if ([download[@"state"] isEqual:@"active"]) continue;
    NSMutableDictionary *saved=[download mutableCopy]; [saved removeObjectForKey:@"id"]; [list addObject:saved];
  }
  NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"downloads":list} options:0 error:nil];
  return data && [NSFileManager.defaultManager createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil] && [data writeToFile:[self downloadsFile] options:NSDataWritingAtomic error:nil];
}
- (NSMutableDictionary *)downloadWithID:(uint32_t)downloadID {
  for (NSMutableDictionary *download in _downloads) if ([download[@"id"] isEqual:@(downloadID)]) return download;
  return nil;
}
- (NSString *)downloadPathForName:(NSString *)name download:(uint32_t)downloadID {
  if (_quitting) return nil;
  NSString *folder=[NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject.path; if (!folder) return nil;
  NSString *file=[[name.lastPathComponent stringByReplacingOccurrencesOfString:@":" withString:@"-"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!file.length || [file isEqualToString:@"/"]) file=@"download";
  if ([file hasPrefix:@"."]) file=[@"download" stringByAppendingString:file];
  // Never overwrite: a taken name gets a number, as in Chrome, also against downloads still running.
  NSMutableSet *taken=[NSMutableSet set]; for (NSDictionary *download in _downloads) if ([download[@"state"] isEqual:@"active"] && download[@"path"]) [taken addObject:download[@"path"]];
  NSFileManager *files=NSFileManager.defaultManager; NSString *base=file.stringByDeletingPathExtension, *extension=file.pathExtension, *path=[folder stringByAppendingPathComponent:file];
  for (NSUInteger n=1; [files fileExistsAtPath:path] || [files fileExistsAtPath:[path stringByAppendingPathExtension:@"crdownload"]] || [taken containsObject:path]; n++) {
    NSString *numbered=[NSString stringWithFormat:@"%@ (%lu)",base,(unsigned long)n];
    path=[folder stringByAppendingPathComponent:extension.length ? [numbered stringByAppendingPathExtension:extension] : numbered];
  }
  NSMutableDictionary *download=[self downloadWithID:downloadID];
  if (!download) { download=[NSMutableDictionary dictionaryWithObject:@(downloadID) forKey:@"id"]; [_downloads insertObject:download atIndex:0]; }
  download[@"path"]=path; download[@"name"]=path.lastPathComponent; download[@"state"]=@"active"; download[@"date"]=@(Now());
  while (_downloads.count>RailKeptDownloads) [_downloads removeLastObject];
  _downloadsUnseen=YES; [self updateDownloads];
  if (_window.isKeyWindow && !_downloadsPopover.shown) [self toggleDownloads:nil];
  return path;
}
- (void)downloadUpdated:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  uint32_t downloadID=item->GetId(); NSMutableDictionary *download=[self downloadWithID:downloadID];
  if (!download) return; // Chromium reports progress before the path is chosen; that starts the entry.
  std::string path=item->GetFullPath().ToString();
  if (!path.empty()) { download[@"path"]=S(path); download[@"name"]=S(path).lastPathComponent; }
  download[@"url"]=S(item->GetOriginalUrl().ToString()); download[@"received"]=@(item->GetReceivedBytes()); download[@"total"]=@(item->GetTotalBytes());
  NSString *state=item->IsComplete() ? @"done" : item->IsCanceled() ? @"canceled" : item->IsInterrupted() ? @"failed" : @"active";
  if ([state isEqual:@"active"]) _downloadCallbacks[downloadID]=callback; else _downloadCallbacks.erase(downloadID);
  if (![state isEqual:download[@"state"]]) {
    download[@"state"]=state; _downloadsDirty=YES; [self saveSoon];
    if ([state isEqual:@"done"]) {
      [self setStatus:[NSString stringWithFormat:@"Downloaded %@",download[@"name"]]];
      // Lets the Dock's Downloads stack bounce, as it does for Safari.
      [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"com.apple.DownloadFileFinished" object:download[@"path"]];
    } else if ([state isEqual:@"failed"]) [self setStatus:[NSString stringWithFormat:@"Download of %@ failed.",download[@"name"]]];
  }
  [self updateDownloads];
}
- (void)updateDownloads {
  if (!_window) return;
  long long received=0,total=0; BOOL active=NO;
  for (NSDictionary *download in _downloads) if ([download[@"state"] isEqual:@"active"]) { active=YES; received+=[download[@"received"] longLongValue]; total+=MAX(0LL,[download[@"total"] longLongValue]); }
  _downloadsButton.progress=active ? (total>0 ? (CGFloat)received/total : 0) : -1;
  _downloadsButton.ink=RailColor(_downloadsUnseen || active ? 0x3976be : 0x273445); _downloadsButton.needsDisplay=YES;
  NSUInteger running=0; for (NSDictionary *download in _downloads) if ([download[@"state"] isEqual:@"active"]) running++;
  _downloadsButton.toolTip=running ? [NSString stringWithFormat:@"Downloads · %lu in progress",(unsigned long)running] : @"Downloads";
  if (_downloadsButton.hidden==(_downloads.count>0)) { _downloadsButton.hidden=!_downloads.count; [self layout]; }
  if (_downloadsPopover.shown) { if (_downloads.count) [self fillDownloadsPopover]; else [_downloadsPopover close]; }
}
- (NSString *)downloadDetail:(NSDictionary *)download exists:(BOOL)exists {
  NSString *state=download[@"state"]; long long received=[download[@"received"] longLongValue], total=[download[@"total"] longLongValue];
  NSString *(^size)(long long)=^NSString *(long long bytes) { return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile]; };
  if ([state isEqual:@"active"]) return total>0 ? [NSString stringWithFormat:@"%@ of %@",size(received),size(total)] : size(received);
  if ([state isEqual:@"canceled"]) return @"Canceled";
  if ([state isEqual:@"failed"]) return @"Failed";
  if (!exists) return @"Moved or deleted";
  NSRelativeDateTimeFormatter *when=[[NSRelativeDateTimeFormatter alloc] init]; when.unitsStyle=NSRelativeDateTimeFormatterUnitsStyleFull;
  NSString *ago=download[@"date"] ? [when localizedStringForDate:[NSDate dateWithTimeIntervalSince1970:[download[@"date"] doubleValue]] relativeToDate:NSDate.date] : nil;
  NSString *bytes=size(total>0 ? total : received);
  return ago ? [NSString stringWithFormat:@"%@ · %@",bytes,ago] : bytes;
}
- (void)fillDownloadsPopover {
  NSMutableArray<RailDownloadRow *> *rows=[NSMutableArray array];
  for (NSDictionary *download in _downloads) {
    if (rows.count>=RailShownDownloads) break;
    NSString *path=download[@"path"], *state=download[@"state"]; BOOL done=[state isEqual:@"done"], exists=done && [NSFileManager.defaultManager fileExistsAtPath:path];
    RailDownloadRow *row=[[RailDownloadRow alloc] init]; row.title=download[@"name"]; row.detail=[self downloadDetail:download exists:exists];
    row.icon=exists ? [NSWorkspace.sharedWorkspace iconForFile:path] : [RailSymbol([state isEqual:@"active"] ? @"arrow.down.doc" : @"doc",22) imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[RailColor(0x8a97a6)]]];
    long long received=[download[@"received"] longLongValue], total=[download[@"total"] longLongValue];
    row.progress=[state isEqual:@"active"] ? (total>0 ? (CGFloat)received/total : 0) : -1;
    if ([state isEqual:@"active"]) { row.accessorySymbol=@"xmark.circle.fill"; row.accessoryHelp=@"Cancel"; }
    else if (exists) { row.accessorySymbol=@"magnifyingglass"; row.accessoryHelp=@"Show in Finder"; }
    [rows addObject:row];
  }
  _downloadList.rows=rows;
  CGFloat listHeight=[RailDownloadList heightForCount:rows.count], width=340;
  NSView *content=_downloadsPopover.contentViewController.view;
  _downloadList.frame=NSMakeRect(4,38,width-8,listHeight);
  for (NSView *v in content.subviews) if (v.tag==910) v.frame=NSMakeRect(10,38+listHeight+4,width-20,30);
  _downloadsPopover.contentSize=NSMakeSize(width,38+listHeight+42);
}
- (void)toggleDownloads:(id)sender {
  (void)sender;
  if (_downloadsPopover.shown) { [_downloadsPopover close]; return; }
  if (!_downloads.count || _downloadsButton.hidden) return;
  __weak BrowserController *weak=self;
  if (!_downloadsPopover) {
    RailPanel *content=[[RailPanel alloc] initWithFrame:NSMakeRect(0,0,340,200)]; content.fill=NSColor.whiteColor;
    NSTextField *heading=RailLabel(@"Downloads",13,NSFontWeightSemibold,RailColor(0x273445)); heading.frame=NSMakeRect(16,12,200,18); [content addSubview:heading];
    RailButton *clear=RailAction(@"Clear",nil,@"Remove finished downloads from this list",^{ [weak clearDownloads]; }); clear.font=[NSFont systemFontOfSize:11]; clear.ink=RailColor(0x245b96); clear.frame=NSMakeRect(340-62,8,50,24); clear.centered=YES; [content addSubview:clear];
    _downloadList=[[RailDownloadList alloc] init];
    _downloadList.onChoose=^(NSInteger index, BOOL accessory) { [weak chooseDownload:index accessory:accessory]; };
    _downloadList.menuForRow=^NSMenu *(NSInteger index) { return [weak menuForDownload:index]; };
    [content addSubview:_downloadList];
    RailButton *folder=RailAction(@"Open Downloads Folder",@"folder",@"Show the Downloads folder in Finder",^{ BrowserController *strong=weak; if (strong) [strong->_downloadsPopover close]; [NSWorkspace.sharedWorkspace openURL:[NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject]; });
    folder.tag=910; folder.font=[NSFont systemFontOfSize:12]; folder.ink=RailColor(0x596879); [content addSubview:folder];
    NSViewController *controller=[[NSViewController alloc] init]; controller.view=content;
    _downloadsPopover=[[NSPopover alloc] init]; _downloadsPopover.behavior=NSPopoverBehaviorTransient; _downloadsPopover.contentViewController=controller;
    _downloadsPopover.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
  }
  _downloadsUnseen=NO; [self fillDownloadsPopover]; [self updateDownloads];
  [_downloadsPopover showRelativeToRect:_downloadsButton.bounds ofView:_downloadsButton preferredEdge:NSRectEdgeMaxY];
}
- (NSMutableDictionary *)shownDownload:(NSInteger)index { return index>=0 && index<(NSInteger)MIN(_downloads.count,RailShownDownloads) ? _downloads[index] : nil; }
- (void)chooseDownload:(NSInteger)index accessory:(BOOL)accessory {
  NSMutableDictionary *download=[self shownDownload:index]; if (!download) return;
  NSString *state=download[@"state"];
  if ([state isEqual:@"active"]) { if (accessory) [self cancelDownload:download]; return; }
  NSURL *file=[NSURL fileURLWithPath:download[@"path"]];
  if (![state isEqual:@"done"] || ![NSFileManager.defaultManager fileExistsAtPath:file.path]) return;
  [_downloadsPopover close];
  if (accessory) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[file]]; else [NSWorkspace.sharedWorkspace openURL:file];
}
- (void)cancelDownload:(NSDictionary *)download {
  auto it=_downloadCallbacks.find([download[@"id"] unsignedIntValue]);
  if (download[@"id"] && it!=_downloadCallbacks.end()) it->second->Cancel();
}
- (NSMenu *)menuForDownload:(NSInteger)index {
  NSMutableDictionary *download=[self shownDownload:index]; if (!download) return nil;
  NSMenu *menu=[[NSMenu alloc] init]; __weak BrowserController *weak=self;
  NSString *state=download[@"state"]; NSURL *file=[NSURL fileURLWithPath:download[@"path"]];
  BOOL exists=[state isEqual:@"done"] && [NSFileManager.defaultManager fileExistsAtPath:file.path];
  if (exists) {
    [menu addItem:[self menuItem:@"Open" block:^{ [NSWorkspace.sharedWorkspace openURL:file]; }]];
    [menu addItem:[self menuItem:@"Show in Finder" block:^{ [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[file]]; }]];
  }
  NSString *link=download[@"url"];
  if (link.length) [menu addItem:[self menuItem:@"Copy Download Link" block:^{ [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:link forType:NSPasteboardTypeString]; }]];
  if ([state isEqual:@"active"]) [menu addItem:[self menuItem:@"Cancel Download" block:^{ [weak cancelDownload:download]; }]];
  else [menu addItem:[self menuItem:@"Remove from List" block:^{ BrowserController *strong=weak; if (!strong) return; [strong->_downloads removeObjectIdenticalTo:download]; strong->_downloadsDirty=YES; [strong saveSoon]; [strong updateDownloads]; }]];
  return menu;
}
- (void)clearDownloads {
  NSIndexSet *finished=[_downloads indexesOfObjectsPassingTest:^BOOL(NSMutableDictionary *download, NSUInteger index, BOOL *stop) { (void)index; (void)stop; return ![download[@"state"] isEqual:@"active"]; }];
  [_downloads removeObjectsAtIndexes:finished]; _downloadsDirty=YES; [self saveSoon]; [self updateDownloads];
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
  [_saveTimer invalidate]; [_reading saveNow]; if (!_savingAllowed) return;
  NSError *error=nil; if (!rail::SaveState(_directory,_model,&error)) [self setStatus:[NSString stringWithFormat:@"Could not save the layout: %@",error.localizedDescription]];
  if (_historyDirty) { _history.prune(5000,Now()); _historyDirty=!rail::SaveHistory(_directory,_history,nil); }
  if (_downloadsDirty) _downloadsDirty=![self saveDownloads];
  if (_projectsDirty && _projectsSavingAllowed) { NSError *projectError=nil; _projectsDirty=!rail::SaveProjects(_directory,_projects,&projectError); if (_projectsDirty) [self setStatus:[NSString stringWithFormat:@"Could not save projects: %@",projectError.localizedDescription]]; }
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
- (void)resizeSidebarTo:(CGFloat)delta { _model.state.sidebarWidth=std::clamp<double>(_dragStartWidth+delta/rail::BrowserModel::controlScale(_model.state.controlSize),180,420); [self refresh]; }
- (void)newTab:(id)sender { (void)sender; if (_quitting) return; _homeVisible=NO; _readingVisible=NO; auto id=_model.addTab(_model.state.activeSpaceID,"about:blank",Now()); _model.selectTab(id,Now()); [self refresh]; [self saveSoon]; [self focusAddress:nil]; }
- (void)closeCurrentTab:(id)sender {
  (void)sender;
  if (NSApp.keyWindow && NSApp.keyWindow!=_window) { [NSApp.keyWindow performClose:nil]; return; }
  // No tab is showing, so ⌘W leaves Reading instead of closing one out of sight.
  if (_readingVisible) { [self showReading:nil]; return; }
  [self closeTabID:_model.state.activeTabID];
}
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
      RailSuggestion *item=[[RailSuggestion alloc] init]; item.title=S(tab->shownTitle()); item.detail=DisplayAddress(tab->url);
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
- (void)renameTabMenu:(NSMenuItem *)sender { [self renameTabID:C(sender.representedObject)]; }
// Pinned tabs keep a chosen name until they are unpinned; an empty name shows the page title again.
- (void)renameTabID:(const std::string &)tabID {
  const auto *tab=_model.tab(tabID); if (!tab || !tab->pinned || _window.attachedSheet) return;
  std::string id=tabID; __weak BrowserController *weak=self;
  [self askForText:@"Rename pinned tab" initial:S(tab->shownTitle()) completion:^(NSString *name) { BrowserController *strong=weak; if (strong && strong->_model.renameTab(id,C(name))) { [strong refresh]; [strong saveSoon]; } }];
}
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
    _address.stringValue = active && active->url!="about:blank" && !_homeVisible && !_readingVisible ? S(active->url) : @"";
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
    [self showInlineCompletion:completed typedLength:typed.length];
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
// Runs inside the field editor's change notification, where setting its string resets the
// selection; editing the text storage keeps the completed part selected so typing replaces it.
- (void)showInlineCompletion:(NSString *)completed typedLength:(NSUInteger)typedLength {
  NSTextView *editor=(NSTextView *)_address.currentEditor; if (!editor) return;
  NSString *suffix=[completed substringFromIndex:typedLength];
  [editor.textStorage replaceCharactersInRange:NSMakeRange(typedLength,editor.string.length-typedLength) withString:suffix];
  [editor setSelectedRange:NSMakeRange(typedLength,suffix.length)];
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
  if (_homeVisible || _readingVisible) {
    // Typing on the Space home or in Reading opens a new tab instead of replacing the last page.
    _homeVisible=NO; _readingVisible=NO; auto id=_model.addTab(_model.state.activeSpaceID,"about:blank",Now()); _model.selectTab(id,Now());
  }
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
  if (it!=_runtime.end() && it->second.browser && it->second.closeReason==CloseReason::None) { it->second.error.clear(); it->second.pendingURL.clear(); it->second.browser->GetMainFrame()->LoadURL(tab->url); it->second.browser->GetHost()->SetFocus(true); }
  else { if (it!=_runtime.end()) it->second.pendingURL=tab->url; [self ensureBrowser:tab->id]; }
  [self refresh]; [self saveSoon];
}
- (CefRefPtr<CefBrowser>)activeBrowser { auto it=_runtime.find(_model.state.activeTabID); return it!=_runtime.end() && it->second.closeReason==CloseReason::None ? it->second.browser : nullptr; }
- (void)goBack:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) if (browser->CanGoBack()) browser->GoBack(); }
- (void)goForward:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) if (browser->CanGoForward()) browser->GoForward(); }
- (void)reloadPage:(id)sender { (void)sender; if (_readingVisible) { [_reading reloadSelected]; return; } if (auto browser=[self activeBrowser]) { auto &slot=_runtime.at(_model.state.activeTabID); slot.error.clear(); browser->Reload(); [self refresh]; } else [self ensureBrowser:_model.state.activeTabID]; }
- (void)showDevTools:(id)sender { (void)sender; if (!_homeVisible && !_readingVisible && !_quitting) ShowRailDevTools([self activeBrowser]); }
- (void)zoomIn:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) browser->GetHost()->SetZoomLevel(browser->GetHost()->GetZoomLevel()+.5); }
- (void)zoomOut:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) browser->GetHost()->SetZoomLevel(browser->GetHost()->GetZoomLevel()-.5); }
- (void)zoomReset:(id)sender { (void)sender; if (auto browser=[self activeBrowser]) browser->GetHost()->SetZoomLevel(0); }
- (void)findInPage:(id)sender {
  (void)sender; if (_readingVisible) { [_reading.reader showFind]; return; }
  auto browser=[self activeBrowser]; if (!browser) return;
  [self askForText:@"Find in page" initial:@"" completion:^(NSString *value) { if (value.length) browser->GetHost()->Find(C(value),true,false,false); }];
}
- (BOOL)handleShortcut:(NSEvent *)event {
  NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  // Releasing Ctrl commits the tab chosen in the switcher.
  if (event.type==NSEventTypeFlagsChanged) { if (!_switcherTabs.empty() && !(flags & NSEventModifierFlagControl)) [self finishTabSwitch:YES]; return NO; }
  if (event.type!=NSEventTypeKeyDown || _window.attachedSheet) return NO;
  // Let the inspector handle its own editing, reload and window shortcuts.
  if (event.window && event.window!=_window) return NO;
  if (event.keyCode==48 && (flags & NSEventModifierFlagControl) && !(flags & NSEventModifierFlagCommand)) { [self cycleRecentTabs:(flags & NSEventModifierFlagShift) ? -1 : 1]; return YES; }
  if (!_switcherTabs.empty() && event.keyCode==53) { [self finishTabSwitch:NO]; return YES; }
  if (!(flags & NSEventModifierFlagCommand)) { _undoCloseArmed=NO; return NO; }
  NSString *key=event.charactersIgnoringModifiers.lowercaseString;
  BOOL shift=(flags & NSEventModifierFlagShift)!=0;
  if ([key isEqual:@"l"] && shift) { [self showReading:nil]; return YES; }
  if ([key isEqual:@"d"] && shift) { [self savePageToReading:nil]; return YES; }
  if ([key isEqual:@"v"] && !shift && _readingVisible && [self pasteIntoReading]) return YES;
  if ([key isEqual:@"i"] && (flags & NSEventModifierFlagOption) && !shift) [self showDevTools:nil];
  else if ([key isEqual:@"t"] && shift) [self reopenClosedTab:nil];
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
  NSMenuItem *icon=[[NSMenuItem alloc] initWithTitle:@"Icon" action:nil keyEquivalent:@""]; icon.submenu=[[NSMenu alloc] init];
  NSString *current=nil; for (size_t i=0;i<_model.state.spaces.size();i++) if (_model.state.spaces[i].id==_model.state.activeSpaceID) current=[self symbolForSpace:_model.state.spaces[i] index:i];
  BOOL known=NO;
  for (NSString *symbol in SpaceSymbols()) {
    NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:SymbolTitle(symbol) action:@selector(spaceIcon:) keyEquivalent:@""]; item.target=self; item.representedObject=symbol; item.image=RailSymbol(symbol,13);
    if ([symbol isEqualToString:current]) { item.state=NSControlStateValueOn; known=YES; }
    [icon.submenu addItem:item];
  }
  [icon.submenu addItem:NSMenuItem.separatorItem];
  NSMenuItem *other=[[NSMenuItem alloc] initWithTitle:@"Other SF Symbol…" action:@selector(customSpaceIcon:) keyEquivalent:@""]; other.target=self; other.state=known ? NSControlStateValueOff : NSControlStateValueOn; [icon.submenu addItem:other];
  [menu addItem:icon];
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
- (NSString *)symbolForSpace:(const rail::Space &)space index:(size_t)index {
  if (!space.icon.empty() && [NSImage imageWithSystemSymbolName:S(space.icon) accessibilityDescription:nil]) return S(space.icon);
  return index==0 ? @"briefcase" : index==1 ? @"house" : index==2 ? @"book" : @"square.grid.2x2";
}
- (void)setActiveSpaceIcon:(NSString *)symbol { if (auto *space=_model.space(_model.state.activeSpaceID)) { space->icon=C(symbol); [self refresh]; [self saveSoon]; } }
- (void)spaceIcon:(NSMenuItem *)sender { [self setActiveSpaceIcon:sender.representedObject]; }
- (void)customSpaceIcon:(id)sender {
  (void)sender; const auto *space=_model.space(_model.state.activeSpaceID); if (!space) return; __weak BrowserController *weak=self;
  [self askForText:@"SF Symbol name, for example leaf or hammer" initial:S(space->icon) completion:^(NSString *name) {
    BrowserController *strong=weak; if (!strong || !name.length) return;
    if (![NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]) { NSBeep(); return; }
    [strong setActiveSpaceIcon:name];
  }];
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
  if (_readingVisible) { [_reading setSelectedSessionTo:value]; return; }
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
  NSViewController *content=[[NSViewController alloc] init]; RailPanel *panel=[[RailPanel alloc] initWithFrame:NSMakeRect(0,0,310,324)]; panel.fill=RailColor(0xedf1f5); content.view=panel;
  NSTextField *sizeTitle=RailLabel(@"Sidebar and Space home size",15,NSFontWeightSemibold,RailColor(0x273445)); sizeTitle.frame=NSMakeRect(18,18,274,24); [panel addSubview:sizeTitle];
  NSSegmentedControl *size=[NSSegmentedControl segmentedControlWithLabels:@[@"Small",@"Normal",@"Large"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(controlSizeChosen:)];
  size.selectedSegment=_model.state.controlSize=="large" ? 2 : _model.state.controlSize=="normal" ? 1 : 0; size.frame=NSMakeRect(18,50,274,26); size.segmentDistribution=NSSegmentDistributionFillEqually; [panel addSubview:size];
  NSTextField *title=RailLabel(@"Give idle tabs a rest",15,NSFontWeightSemibold,RailColor(0x273445)); title.frame=NSMakeRect(18,102,274,24); [panel addSubview:title];
  NSTextField *label=RailLabel(@"Unload after",12,NSFontWeightRegular,RailColor(0x273445)); label.frame=NSMakeRect(18,150,135,22); [panel addSubview:label];
  NSPopUpButton *timeout=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(164,145,126,28) pullsDown:NO];
  for (NSNumber *minutes in @[@1,@5,@10,@15,@30,@60]) { [timeout addItemWithTitle:[NSString stringWithFormat:@"%@ minutes",minutes]]; timeout.lastItem.representedObject=minutes; if (minutes.doubleValue==_model.state.idleMinutes) [timeout selectItem:timeout.lastItem]; }
  timeout.target=self; timeout.action=@selector(timeoutChosen:); [panel addSubview:timeout];
  NSTextField *copy=RailLabel(@"Inactive pages close, including pinned tabs. Their titles and addresses stay; opening a tab reloads its page. The selected tab stays awake.",11,NSFontWeightRegular,RailColor(0x596879)); copy.frame=NSMakeRect(18,189,274,70); copy.maximumNumberOfLines=4; copy.lineBreakMode=NSLineBreakByWordWrapping; [panel addSubview:copy];
  NSTextField *note=RailLabel(@"Unsaved page state may be lost. Isolated sessions keep their own saved logins.",11,NSFontWeightRegular,RailColor(0x596879)); note.frame=NSMakeRect(18,268,274,42); note.maximumNumberOfLines=3; note.lineBreakMode=NSLineBreakByWordWrapping; [panel addSubview:note];
  _settings=[[NSPopover alloc] init]; _settings.contentViewController=content; _settings.behavior=NSPopoverBehaviorTransient;
  [_settings showRelativeToRect:_sessionPicker.bounds ofView:_sessionPicker preferredEdge:NSRectEdgeMinY];
}
- (void)controlSizeChosen:(NSSegmentedControl *)sender {
  NSArray *sizes=@[@"small",@"normal",@"large"]; if (sender.selectedSegment<0 || sender.selectedSegment>=(NSInteger)sizes.count) return;
  _model.state.controlSize=C(sizes[sender.selectedSegment]); [self refresh]; [self saveSoon];
}
- (void)timeoutChosen:(NSPopUpButton *)sender { _model.state.idleMinutes=[sender.selectedItem.representedObject doubleValue]; [self saveSoon]; [self refresh]; [self checkIdle]; }
- (void)about:(id)sender { (void)sender; [NSApp orderFrontStandardAboutPanelWithOptions:@{NSAboutPanelOptionApplicationName:@"Eimerrail",NSAboutPanelOptionApplicationVersion:@"0.1",NSAboutPanelOptionVersion:@"A personal native browser with Chromium Embedded Framework."}]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; [self quit:nil]; return NO; }
- (void)quit:(id)sender {
  (void)sender; if (_quitting) return; _quitting=YES; [self saveNow];
  // Chromium can't shut down while the reader's hidden browser is open.
  __weak BrowserController *weak=self;
  [_reading shutdown:^{ BrowserController *strong=weak; if (!strong) return; strong->_readingClosed=YES; if (strong->_quitting && strong->_runtime.empty()) [strong finishQuit]; }];
  if (_runtime.empty()) { if (_readingClosed) [self finishQuit]; return; }
  std::vector<std::string> ids; for (const auto &[id,slot]:_runtime) { (void)slot; ids.push_back(id); }
  for (const auto &id:ids) [self closeRuntime:id reason:CloseReason::Quit session:""];
}
- (void)finishQuit { [_statusTimer invalidate]; [_idleTimer invalidate]; [_automationTimer invalidate]; [self saveNow]; _contexts.clear(); [_window orderOut:nil]; CefQuitMessageLoop(); }
- (void)dealloc { [_statusTimer invalidate]; [_idleTimer invalidate]; [_automationTimer invalidate]; [_saveTimer invalidate]; _window.delegate=nil; }

#pragma mark Reading
- (CGFloat)shownSidebarWidth { return _readingVisible ? MAX(292,_model.state.sidebarWidth) : _model.state.sidebarWidth; }
- (void)wireReading {
  __weak BrowserController *weak=self;
  _reading.contextForSession=^CefRefPtr<CefRequestContext>(NSString *session) { BrowserController *strong=weak; return strong ? [strong contextForSession:C(session)] : nullptr; };
  // The Space a rule claims the address for decides its session; otherwise the Space in use does.
  _reading.sessionForURL=^NSString *(NSString *url) {
    BrowserController *strong=weak; if (!strong) return @"";
    const std::string ruled=strong->_model.spaceForURL(C(url));
    const auto *space=strong->_model.space(ruled.empty() ? strong->_model.state.activeSpaceID : ruled);
    return space ? S(space->sessionID) : @"";
  };
  _reading.sessionName=^NSString *(NSString *session) { BrowserController *strong=weak; return strong ? [strong sessionName:C(session)] : @""; };
  _reading.faviconForURL=^NSImage *(NSString *url) { BrowserController *strong=weak; return strong ? [strong faviconForURL:C(url)] : nil; };
  _reading.storeFavicon=^(NSString *url, NSData *png) { BrowserController *strong=weak; NSString *key=FaviconKey(C(url)); if (strong && key) [strong storeFavicon:png key:key persist:YES]; };
  _reading.openURL=^(NSString *url, NSString *session) { [weak openReadingURL:url session:session]; };
  _reading.onStatus=^(NSString *message) {
    [weak setStatus:message];
    // A confirmation shouldn't still be there long after the thing it confirmed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ BrowserController *strong=weak; if (strong && strong->_statusMessage==message) { strong->_statusMessage=nil; [strong refresh]; } });
  };
  _reading.onChromeChange=^{ BrowserController *strong=weak; if (strong && strong->_window) [strong refreshReadingChrome]; };
  _reading.askForText=^(NSString *prompt, void (^completion)(NSString *)) { [weak askForText:prompt initial:@"" completion:completion]; };
  _reading.confirm=^(NSString *title, NSString *detail, NSString *action, void (^completion)(void)) {
    BrowserController *strong=weak; if (!strong) return;
    NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=title; alert.informativeText=detail; [alert addButtonWithTitle:action]; [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:strong->_window completionHandler:^(NSModalResponse result) { if (result==NSAlertFirstButtonReturn) completion(); }];
  };
}
- (void)showReading:(id)sender {
  (void)sender; if (_quitting) return;
  _readingVisible=!_readingVisible; if (_readingVisible) _homeVisible=NO;
  _statusMessage=nil; _editingAddress=NO; [_window makeFirstResponder:nil]; [self hideSuggestions];
  if (_readingVisible) [_reading opened];
  [self refresh];
  if (_readingVisible) [_reading.reader focusArticle];
  else if (auto browser=[self activeBrowser]) browser->GetHost()->SetFocus(true); else [self ensureBrowser:_model.state.activeTabID];
}
- (void)addReadingEntryAt:(CGFloat)y {
  __weak BrowserController *weak=self;
  RailPanel *line=[[RailPanel alloc] initWithFrame:NSMakeRect(12,y+1,20,1)]; line.fill=RailColor(0xcbd5df); [_rail addSubview:line];
  const NSUInteger unread=_reading.unreadCount;
  RailButton *entry=RailAction(@"",@"tray",unread ? [NSString stringWithFormat:@"Reading list, %lu unread (⌘ ⇧ L)",(unsigned long)unread] : @"Reading list (⌘ ⇧ L)",^{ [weak showReading:nil]; });
  entry.centered=YES; entry.frame=NSMakeRect(6,y+11,32,32); entry.ink=RailColor(0x596879);
  if (_readingVisible) { entry.normalFill=RailColor(0x4173aa); entry.hoverFill=RailColor(0x37679c); entry.ink=NSColor.whiteColor; }
  [_rail addSubview:entry];
  if (unread) {
    // Blue, not the red used for projects: an unread article doesn't need attention.
    NSTextField *badge=RailLabel(unread>99 ? @"99+" : [NSString stringWithFormat:@"%lu",(unsigned long)unread],9,NSFontWeightBold,NSColor.whiteColor); badge.alignment=NSTextAlignmentCenter;
    badge.lineBreakMode=NSLineBreakByClipping; CGFloat width=unread>99 ? 26 : unread>9 ? 20 : 15;
    RailPanel *back=[[RailPanel alloc] initWithFrame:NSMakeRect(40-width+2,y+6,width,15)]; back.wantsLayer=YES; back.layer.cornerRadius=7.5; back.layer.borderWidth=1.5; back.layer.borderColor=RailColor(0xe2e8ef).CGColor; back.fill=RailColor(0x245b96);
    badge.frame=NSMakeRect(0,1.5,width,12); [back addSubview:badge]; [_rail addSubview:back];
  }
}
// Everything refresh shows that depends on Reading, and which Reading can change by itself.
- (void)refreshReadingChrome {
  const BOOL reading=_readingVisible;
  _reading.reader.hidden=!reading; _reading.sidebar.hidden=!reading;
  for (NSView *view in @[_spaceLabel,_spaceSubtitle,_spaceOptions,_tabScroll,_sleepLabel]) view.hidden=reading;
  NSString *url=reading ? _reading.selectedURL : nil;
  _readerChip.hidden=!(reading && _reading.selectedHasArticle) || _editingAddress;
  // The rail's badge is rebuilt with the rest of the rail; only do that when the number changed.
  if (_shownUnread!=_reading.unreadCount) { _shownUnread=_reading.unreadCount; __weak BrowserController *weak=self; dispatch_async(dispatch_get_main_queue(), ^{ [weak refresh]; }); }
  if (!reading) { if (_sessionPicker.hidden) { _sessionPicker.hidden=NO; [self layout]; } return; }
  if (!_editingAddress) { _address.stringValue=url ? DisplayAddress(C(url)) : @""; _addressBar.symbolName=url ? AddressSymbol(C(url)) : @"tray"; _address.placeholderString=@"Search or enter address"; }
  _window.title=[NSString stringWithFormat:@"%@ — Eimerrail",_reading.selectedTitle ?: @"Reading"];
  // The picker sets the session the page is read in; a one-off isolated profile would forget it.
  [_sessionPicker removeAllItems];
  for (const auto &session : _model.state.sessions) { [_sessionPicker addItemWithTitle:S(session.name)]; _sessionPicker.lastItem.representedObject=S(session.id); }
  if (_sessionPicker.hidden!=!url) { _sessionPicker.hidden=!url; [self layout]; }
  for (NSMenuItem *item in _sessionPicker.itemArray) if ([item.representedObject isEqual:_reading.selectedSession]) [_sessionPicker selectItem:item];
  _sessionLabel.stringValue=url ? [NSString stringWithFormat:@"%@%@ session",_reading.selectedHasArticle ? @"Reader view · " : @"",[self sessionName:C(_reading.selectedSession)]] : @"Reading";
}
- (BOOL)pasteIntoReading {
  NSResponder *responder=_window.firstResponder;
  // Pasting into the address bar stays a paste; so does adding to text in the paste field.
  if ([responder isKindOfClass:NSText.class] && ((NSText *)responder).isFieldEditor) {
    id field=((NSText *)responder).delegate;
    if (field!=_reading.sidebar.captureField || ((NSText *)responder).string.length) return NO;
  }
  return [_reading saveFromPasteboard];
}
- (void)savePageToReading:(id)sender {
  (void)sender; const auto *active=_model.tab(_model.state.activeTabID);
  if (_homeVisible || _readingVisible || !active || !rail::isWebURL(active->url)) { [self setStatus:@"Open a web page to save it to your reading list."]; return; }
  [_reading saveCurrentPage:S(active->url) title:S(active->title)];
}
- (void)saveTabToReading:(NSMenuItem *)sender {
  const auto *tab=_model.tab(C(sender.representedObject)); if (tab) [_reading saveCurrentPage:S(tab->url) title:S(tab->title)];
}
// A pinned tab or a Space rule decides where a link goes, as for links from other apps.
- (void)openReadingURL:(NSString *)url session:(NSString *)session {
  if (_quitting) return;
  const std::string address=C(url);
  if (!_model.pinnedTabForURL(address).empty()) { NSURL *link=[NSURL URLWithString:url]; _readingVisible=NO; if (link) [self openExternalURLs:@[link]]; return; }
  const std::string ruled=_model.spaceForURL(address), spaceID=ruled.empty() ? _model.state.activeSpaceID : ruled;
  std::string tabID;
  for (const auto &tab : _model.state.tabs) if (tab.spaceID==spaceID && tab.url==address) { tabID=tab.id; break; }
  if (tabID.empty()) tabID=_model.addTab(spaceID,address,Now(),C(session));
  if (tabID.empty()) return;
  [self selectTabID:tabID];
  if (const auto *space=_model.space(spaceID); !ruled.empty() && space) [self setStatus:[NSString stringWithFormat:@"Opened in %@.",S(space->name)]];
}

#pragma mark Projects

- (void)runMenuBlock:(NSMenuItem *)item { void (^block)(void) = item.representedObject; if (block) block(); }
- (NSMenuItem *)menuItem:(NSString *)title block:(void (^)(void))block {
  NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:@selector(runMenuBlock:) keyEquivalent:@""]; item.target=self; item.representedObject=[block copy]; return item;
}
- (void)projectsChanged {
  _model.projectProfiles=_projects.ownedProfiles(); _projectsDirty=YES; [self saveSoon]; [self refresh];
}
- (void)statusChanged {
  if (_statusRefreshQueued) return; _statusRefreshQueued=YES; __weak BrowserController *weak=self;
  dispatch_async(dispatch_get_main_queue(), ^{ BrowserController *strong=weak; if (!strong) return; strong->_statusRefreshQueued=NO; [strong refresh]; });
}
- (void)showHome:(id)sender {
  (void)sender; if (_quitting) return;
  _homeVisible=YES; _readingVisible=NO; _statusMessage=nil; _editingAddress=NO; [_window makeFirstResponder:nil]; [self hideSuggestions];
  [self refresh]; [self checkProjects:NO];
}
- (void)checkProjects:(BOOL)force {
  std::vector<rail::Project> list; for (const auto *project : _projects.inSpace(_model.state.activeSpaceID)) list.push_back(*project);
  [_status checkProjects:list connections:_projects.state.connections force:force]; [self refreshHome];
}
- (NSUInteger)attentionCountInSpace:(std::string)spaceID {
  NSUInteger count=0; const auto &status=[_status snapshot];
  for (const auto *project : _projects.inSpace(spaceID)) {
    auto items=rail::attentionFor(*project,_projects.state,status);
    if (std::any_of(items.begin(),items.end(),[](const rail::Attention &a) { return a.tone==rail::Tone::critical || a.tone==rail::Tone::warn; })) count++;
  }
  return count;
}
- (NSString *)sessionMark:(std::string)sessionID style:(NSInteger *)style {
  NSString *name=[self sessionName:sessionID];
  *style=rail::BrowserModel::isIsolatedSession(sessionID) ? 2 : sessionID=="personal" ? 1 : 0;
  return name.length ? [[name substringToIndex:1] uppercaseString] : @"W";
}
static NSString *Ago(double time) {
  if (time<=0) return @"";
  double seconds=MAX(0,Now()-time);
  if (seconds<90) return @"just now";
  if (seconds<3600) return [NSString stringWithFormat:@"%.0f min ago",seconds/60];
  if (seconds<86400) return [NSString stringWithFormat:@"%.0f h ago",seconds/3600];
  return [NSString stringWithFormat:@"%.0f d ago",seconds/86400];
}
static ProjectTone RunTone(const std::string &result) {
  if (result=="succeeded") return ProjectToneOK;
  if (result=="failed") return ProjectToneCritical;
  if (result=="partial") return ProjectToneWarn;
  if (result=="running" || result=="queued") return ProjectToneBusy;
  if (result=="canceled") return ProjectToneStopped;
  return ProjectToneUnknown;
}
// Opens a project URL in the current Space and session, reusing a tab that already shows it.
- (void)openProjectURL:(std::string)url session:(std::string)session exact:(BOOL)exact {
  if (!rail::isWebURL(url)) return;
  const std::string origin=rail::originOf(url);
  for (const auto &tab : _model.state.tabs) {
    if (tab.spaceID!=_model.state.activeSpaceID || tab.sessionID!=session) continue;
    if (exact ? tab.url==url : rail::originOf(tab.url)==origin) { [self selectTabID:tab.id]; return; }
  }
  auto id=_model.addTab(_model.state.activeSpaceID,url,Now(),session); if (id.empty()) return;
  [self selectTabID:id]; [self saveSoon];
}
- (void)handleAttention:(std::string)action target:(std::string)target project:(std::string)projectID {
  const auto *project=_projects.project(projectID); if (!project) return;
  std::string session=_projects.accessSession(*project); if (session.empty()) session=_model.space(project->spaceID)->sessionID;
  if (action=="signIn") [self signInConnection:target];
  else if (action=="openRun") [self openProjectURL:target session:session exact:YES];
  else if (action=="openInstallations") [self openProjectURL:"https://github.com/settings/installations" session:session exact:YES];
  else if (action=="openEnvironment") for (const auto &e : project->environments) if (e.id==target) [self openProjectURL:e.url session:e.sessionID exact:NO];
}
- (NSString *)environmentValue:(const rail::Environment &)environment tone:(ProjectTone *)tone {
  const auto &status=[_status snapshot]; auto found=status.environments.find(environment.id);
  BOOL local=rail::isLocalURL(environment.url); NSString *port=[NSString stringWithFormat:@":%d",rail::portOf(environment.url)];
  NSString *host=S(rail::hostOf(environment.url));
  if (found==status.environments.end() || found->second.health==rail::Health::unknown) { *tone=ProjectToneUnknown; return local ? port : host; }
  const auto &state=found->second; NSString *version=state.version.empty() ? nil : [@"v" stringByAppendingString:[S(state.version) stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV"]]];
  NSString *latency=[NSString stringWithFormat:@"%d ms",state.latencyMs];
  switch (state.health) {
    case rail::Health::up: *tone=local ? ProjectToneRunning : ProjectToneOK; return local ? [port stringByAppendingString:@" running"] : version ? [NSString stringWithFormat:@"%@ · %@",version,latency] : latency;
    case rail::Health::slow: *tone=ProjectToneWarn; return [NSString stringWithFormat:@"%@slow · %.1f s",version ? [version stringByAppendingString:@" · "] : @"",state.latencyMs/1000.0];
    case rail::Health::down: *tone=ProjectToneCritical; return state.error.empty() ? @"down" : [@"down · " stringByAppendingString:S(state.error)];
    case rail::Health::notRunning: *tone=ProjectToneStopped; return [port stringByAppendingString:@" not running"];
    case rail::Health::loginRequired: *tone=ProjectToneOK; return @"up · behind login";
    default: *tone=ProjectToneUnknown; return host;
  }
}
- (NSArray<ProjectCard *> *)projectCards {
  const auto &status=[_status snapshot]; NSMutableArray *cards=[NSMutableArray array]; __weak BrowserController *weak=self;
  for (const auto *project : _projects.inSpace(_model.state.activeSpaceID)) {
    std::string pid=project->id; ProjectCard *card=[[ProjectCard alloc] init]; card.projectID=S(pid); card.name=S(project->name);
    auto attention=rail::attentionFor(*project,_projects.state,status);
    rail::RepoRef repo; for (const auto &link : project->links) if (link.kind=="repo") { repo=rail::recognizeRepo(link.url); if (repo) break; }
    const rail::SourceStatus *source=nullptr; const rail::ConnectionStatus *access=nullptr;
    for (const auto &binding : project->sources) {
      auto found=status.sources.find(rail::sourceKey(binding)); if (found!=status.sources.end() && !source) source=&found->second;
      auto connection=status.connections.find(binding.connectionID); if (connection!=status.connections.end() && !access) access=&connection->second;
    }
    NSMutableArray *meta=[NSMutableArray array];
    if (repo) { [meta addObject:[S(repo.resource()) stringByRemovingPercentEncoding] ?: S(repo.resource())]; if (source && !source->defaultBranch.empty()) [meta addObject:S(source->defaultBranch)]; [meta addObject:repo.provider=="github" ? @"GitHub" : @"Azure DevOps"]; card.provider=repo.provider=="github" ? 2 : 1; }
    else [meta addObject:project->links.empty() && project->environments.empty() ? @"Nothing linked yet" : @"No repository linked"];
    card.meta=[meta componentsJoinedByString:@" · "];
    NSMutableArray *pills=[NSMutableArray array];
    for (const auto &item : attention) {
      if (pills.count==3) break;
      ProjectPill *pill=[[ProjectPill alloc] init]; pill.title=S(item.title); pill.help=S(item.detail);
      pill.tone=item.tone==rail::Tone::critical ? ProjectToneCritical : item.tone==rail::Tone::warn ? ProjectToneWarn : ProjectToneInfo;
      pill.symbol=item.action=="signIn" ? @"person.crop.circle.badge.exclamationmark" : item.action=="openRun" ? @"xmark.circle" : item.action=="openInstallations" ? @"eye.slash" : @"exclamationmark.triangle";
      std::string action=item.action,target=item.target; pill.handler=^{ [weak handleAttention:action target:target project:pid]; };
      [pills addObject:pill];
    }
    if (source) for (const auto &run : source->runs) if ((run.result=="running" || run.result=="queued") && pills.count<3) {
      ProjectPill *pill=[[ProjectPill alloc] init]; pill.tone=ProjectToneInfo; pill.symbol=@"clock";
      pill.title=[NSString stringWithFormat:@"%@ %@",S(run.name),run.result=="running" ? @"running" : @"queued"]; std::string url=run.url;
      std::string session=_projects.accessSession(*project); pill.handler=^{ [weak openProjectURL:url session:session exact:YES]; }; [pills addObject:pill];
    }
    BOOL checked=NO; for (const auto &e : project->environments) { auto f=status.environments.find(e.id); if (f!=status.environments.end() && f->second.health!=rail::Health::unknown) checked=YES; }
    if (source) checked=YES;
    if (attention.empty() && checked && !pills.count) { ProjectPill *pill=[[ProjectPill alloc] init]; pill.tone=ProjectToneOK; pill.symbol=@"checkmark"; pill.title=project->environments.empty() ? @"Pipelines passing" : @"All clear"; [pills addObject:pill]; }
    card.pills=pills;
    if (!attention.empty()) card.detail=S(attention.front().detail);
    else if (project->environments.empty()) card.detail=@"Add where it runs: right-click a tab and choose Add to Project, or use … → Add Environment.";
    NSMutableArray *rows=[NSMutableArray array], *chips=[NSMutableArray array];
    for (const auto &link : project->links) {
      std::string url=link.url,session=link.sessionID,lid=link.id; NSInteger style=0; NSString *mark=[self sessionMark:session style:&style];
      if (link.kind=="custom") {
        ProjectChip *chip=[[ProjectChip alloc] init]; NSString *tag=nil;
        for (const auto &e : project->environments) if (e.id==link.environmentID) tag=S(e.name);
        chip.title=tag ? [NSString stringWithFormat:@"%@ · %@",S(link.label),tag] : S(link.label); chip.help=[NSString stringWithFormat:@"%@ · %@ session",S(link.url),[self sessionName:session]];
        NSImage *favicon=[self faviconForURL:link.url]; chip.icon=favicon; chip.iconKeepsColors=favicon!=nil;
        chip.handler=^{ [weak openProjectURL:url session:session exact:YES]; }; chip.menu=[self menuForLink:lid project:pid];
        [chips addObject:chip]; continue;
      }
      ProjectRow *row=[[ProjectRow alloc] init]; row.label=S(link.label); row.mark=mark; row.markStyle=style; row.tone=ProjectToneNeutral;
      row.symbol=link.kind=="repo" ? @"arrow.triangle.branch" : @"arrow.triangle.2.circlepath";
      row.help=[NSString stringWithFormat:@"%@ · opens in %@",S(link.url),[self sessionName:session]];
      if (link.kind=="repo") {
        if (source && source->openPullRequests>=0) row.value=source->openPullRequests==1 ? @"1 open PR" : source->openPullRequests ? [NSString stringWithFormat:@"%d open PRs",source->openPullRequests] : @"No open PRs";
        else row.value=@"";
      } else {
        if (access && (access->access==rail::Access::signedOut || access->access==rail::Access::rejected)) { row.value=@"Sign-in needed"; row.tone=ProjectToneWarn; }
        else if (source && source->notCovered) { row.value=@"Not visible to Eimerrail"; row.tone=ProjectToneWarn; }
        else if (source && !source->runs.empty()) {
          const rail::PipelineRun *shown=&source->runs.front();
          for (const auto &run : source->runs) if (run.result=="failed") { shown=&run; break; }
          row.tone=RunTone(shown->result);
          // GitHub run numbers are plain numbers; Azure DevOps build numbers are often names, so show the pipeline instead.
          BOOL numeric=!shown->number.empty() && std::all_of(shown->number.begin(),shown->number.end(),[](unsigned char c) { return std::isdigit(c); });
          NSString *what=numeric ? [NSString stringWithFormat:@"#%@",S(shown->number)] : S(shown->name);
          row.value=shown->result=="running" ? [what stringByAppendingString:@" running"] : shown->result=="failed" ? [what stringByAppendingString:@" failed"] : [NSString stringWithFormat:@"%@ · %@",what,Ago(shown->finishedAt)];
        } else if (source && !source->error.empty()) { row.value=S(source->error); row.tone=ProjectToneUnknown; }
        else if (source) row.value=@"No runs on the default branch";
        else row.value=@"";
      }
      row.handler=^{ [weak openProjectURL:url session:session exact:YES]; }; row.menu=[self menuForLink:lid project:pid];
      [rows addObject:row];
    }
    BOOL runsLocally=NO;
    for (const auto &environment : project->environments) {
      std::string url=environment.url,session=environment.sessionID,eid=environment.id; NSInteger style=0;
      ProjectRow *row=[[ProjectRow alloc] init]; row.label=S(environment.name); row.mark=[self sessionMark:session style:&style]; row.markStyle=style;
      BOOL local=rail::isLocalURL(url); row.symbol=local ? @"laptopcomputer" : @"globe";
      ProjectTone tone=ProjectToneUnknown; row.value=[self environmentValue:environment tone:&tone]; row.tone=tone;
      if (local && tone==ProjectToneRunning) runsLocally=YES;
      row.help=[NSString stringWithFormat:@"%@ · opens in %@",S(url),[self sessionName:session]];
      row.handler=^{ [weak openProjectURL:url session:session exact:NO]; }; row.menu=[self menuForEnvironment:eid project:pid];
      [rows addObject:row];
    }
    card.rows=rows; card.chips=chips; card.runsLocally=runsLocally;
    card.needsAttention=std::any_of(attention.begin(),attention.end(),[](const rail::Attention &a) { return a.tone==rail::Tone::critical || a.tone==rail::Tone::warn; });
    card.menu=[self menuForProject:pid];
    [cards addObject:card];
  }
  // Cards that need attention come first; otherwise the user's order holds.
  return [cards sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(ProjectCard *a, ProjectCard *b) { return a.needsAttention==b.needsAttention ? NSOrderedSame : a.needsAttention ? NSOrderedAscending : NSOrderedDescending; }];
}
- (void)refreshHome {
  if (!_homeVisible || !_home) return;
  const auto *space=_model.space(_model.state.activeSpaceID);
  NSArray<ProjectCard *> *cards=[self projectCards];
  NSUInteger attention=0, local=0; double checked=0; const auto &status=[_status snapshot];
  for (ProjectCard *card in cards) { if (card.needsAttention) attention++; if (card.runsLocally) local++; }
  for (const auto *project : _projects.inSpace(_model.state.activeSpaceID)) for (const auto &e : project->environments) { auto f=status.environments.find(e.id); if (f!=status.environments.end()) checked=MAX(checked,f->second.checkedAt); }
  NSMutableArray *summary=[NSMutableArray array];
  if (!cards.count) [summary addObject:@"Repositories, environments and their health, in one place."];
  else {
    [summary addObject:attention ? [NSString stringWithFormat:@"%lu need%@ attention",(unsigned long)attention,attention==1 ? @"s" : @""] : @"Nothing needs attention"];
    if (local) [summary addObject:[NSString stringWithFormat:@"%lu running locally",(unsigned long)local]];
    if (checked>0) { NSDateFormatter *time=[[NSDateFormatter alloc] init]; time.dateStyle=NSDateFormatterNoStyle; time.timeStyle=NSDateFormatterShortStyle; [summary addObject:[@"Checked " stringByAppendingString:[time stringFromDate:[NSDate dateWithTimeIntervalSince1970:checked]]]]; }
  }
  _home.spaceName=space ? S(space->name) : @"this Space"; _home.summary=[summary componentsJoinedByString:@" · "]; _home.cards=cards; _home.filter=_homeFilter; _home.checking=[_status isChecking] || _loadingRepositories;
  NSMenu *add=[[NSMenu alloc] init]; __weak BrowserController *weak=self;
  [add addItem:[self menuItem:@"Add Project…" block:^{ [weak newProject:nil]; }]];
  const auto *active=_model.tab(_model.state.activeTabID);
  if (active && rail::recognizeRepo(active->url)) [add addItem:[self menuItem:[NSString stringWithFormat:@"Add “%@” as Project",S(rail::recognizeRepo(active->url).repo)] block:^{ [weak addCurrentPageAsProject:nil]; }]];
  [add addItem:NSMenuItem.separatorItem];
  [add addItem:[self menuItem:@"Import from Azure DevOps…" block:^{ [weak importFromAzure:nil]; }]];
  [add addItem:[self menuItem:@"Import from GitHub…" block:^{ [weak importFromGitHub:nil]; }]];
  _home.addMenu=add; [_home reload];
}

#pragma mark Project menus

- (NSArray *)sessionOptionsWithIsolated:(NSString *)isolatedTitle current:(std::string)current owner:(std::string)ownerID {
  NSMutableArray *options=[NSMutableArray array];
  for (const auto &session : _model.state.sessions) [options addObject:@[S(session.name),S(session.id)]];
  if (isolatedTitle) [options addObject:@[isolatedTitle,@"__isolated__"]];
  // An adopted isolated profile (from an isolated tab) stays selectable so its login is kept.
  if (rail::BrowserModel::isIsolatedSession(current) && current!=rail::Projects::isolatedProfileFor(ownerID)) [options addObject:@[@"Isolated (kept from tab)",S(current)]];
  return options;
}
- (NSString *)sessionOptionValue:(std::string)session owner:(std::string)ownerID {
  return session==rail::Projects::isolatedProfileFor(ownerID) ? @"__isolated__" : S(session);
}
- (NSMenu *)menuForProject:(std::string)projectID {
  NSMenu *menu=[[NSMenu alloc] init]; __weak BrowserController *weak=self; const auto *project=_projects.project(projectID); if (!project) return menu;
  [menu addItem:[self menuItem:@"Add Environment…" block:^{ [weak editEnvironment:"" project:projectID url:"" session:""]; }]];
  [menu addItem:[self menuItem:@"Add Link…" block:^{ [weak editLink:"" project:projectID url:"" label:"" session:""]; }]];
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItem:[self menuItem:@"Rename…" block:^{ BrowserController *strong=weak; if (!strong) return; const auto *p=strong->_projects.project(projectID); if (!p) return;
    [strong askForText:@"Rename project" initial:S(p->name) completion:^(NSString *name) { BrowserController *inner=weak; if (inner && inner->_projects.renameProject(projectID,C(name))) [inner projectsChanged]; }]; }]];
  for (const auto &link : project->links) if (link.kind=="repo") {
    NSMenuItem *access=[[NSMenuItem alloc] initWithTitle:@"Access Repository As" action:nil keyEquivalent:@""]; access.submenu=[[NSMenu alloc] init];
    for (const auto &session : _model.state.sessions) {
      std::string sid=session.id, lid=link.id;
      NSMenuItem *item=[self menuItem:[NSString stringWithFormat:@"%@ session",S(session.name)] block:^{ BrowserController *strong=weak; if (!strong) return; auto *p=strong->_projects.project(projectID); if (!p) return;
        for (auto l : p->links) if (l.id==lid) { l.sessionID=sid; strong->_projects.updateLink(projectID,l); } [strong projectsChanged]; [strong checkProjects:YES]; }];
      item.state=link.sessionID==session.id ? NSControlStateValueOn : NSControlStateValueOff; [access.submenu addItem:item];
    }
    [menu addItem:access]; break;
  }
  NSMenuItem *move=[[NSMenuItem alloc] initWithTitle:@"Move to Space" action:nil keyEquivalent:@""]; move.submenu=[[NSMenu alloc] init];
  for (const auto &space : _model.state.spaces) if (space.id!=project->spaceID) { std::string target=space.id; [move.submenu addItem:[self menuItem:S(space.name) block:^{ BrowserController *strong=weak; if (strong && strong->_projects.moveProject(projectID,target)) [strong projectsChanged]; }]]; }
  [menu addItem:move];
  [menu addItem:[self menuItem:@"Move Earlier" block:^{ BrowserController *strong=weak; if (strong && strong->_projects.reorderProject(projectID,-1)) [strong projectsChanged]; }]];
  [menu addItem:[self menuItem:@"Move Later" block:^{ BrowserController *strong=weak; if (strong && strong->_projects.reorderProject(projectID,1)) [strong projectsChanged]; }]];
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItem:[self menuItem:@"Remove Project…" block:^{ [weak confirmRemoveProject:projectID]; }]];
  return menu;
}
- (void)confirmRemoveProject:(std::string)projectID {
  const auto *project=_projects.project(projectID); if (!project) return;
  NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=[NSString stringWithFormat:@"Remove “%@”?",S(project->name)];
  alert.informativeText=@"Its card, environments and links are removed. Open tabs, logins and isolated profiles stay.";
  [alert addButtonWithTitle:@"Remove"]; [alert addButtonWithTitle:@"Cancel"]; alert.buttons.firstObject.hasDestructiveAction=YES; __weak BrowserController *weak=self;
  [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) { BrowserController *strong=weak; if (strong && result==NSAlertFirstButtonReturn && strong->_projects.removeProject(projectID)) [strong projectsChanged]; }];
}
- (NSMenu *)menuForEnvironment:(std::string)environmentID project:(std::string)projectID {
  NSMenu *menu=[[NSMenu alloc] init]; __weak BrowserController *weak=self;
  [menu addItem:[self menuItem:@"Edit Environment…" block:^{ [weak editEnvironment:environmentID project:projectID url:"" session:""]; }]];
  [menu addItem:[self menuItem:@"Add Link for This Environment…" block:^{ [weak editLink:"" project:projectID url:"" label:"" session:"" environment:environmentID]; }]];
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItem:[self menuItem:@"Remove Environment" block:^{ BrowserController *strong=weak; if (strong && strong->_projects.removeEnvironment(projectID,environmentID)) [strong projectsChanged]; }]];
  return menu;
}
- (NSMenu *)menuForLink:(std::string)linkID project:(std::string)projectID {
  NSMenu *menu=[[NSMenu alloc] init]; __weak BrowserController *weak=self;
  [menu addItem:[self menuItem:@"Edit Link…" block:^{ [weak editLink:linkID project:projectID url:"" label:"" session:""]; }]];
  [menu addItem:[self menuItem:@"Remove Link" block:^{ BrowserController *strong=weak; if (strong && strong->_projects.removeLink(projectID,linkID)) [strong projectsChanged]; }]];
  return menu;
}
// "Add to Project" for a tab: the current Space's projects first, then a new project from the tab.
- (NSMenu *)projectMenuForTab:(std::string)tabID {
  NSMenu *menu=[[NSMenu alloc] init]; __weak BrowserController *weak=self; const auto *tab=_model.tab(tabID); if (!tab) return menu;
  std::string url=tab->url, session=tab->sessionID, title=tab->title; BOOL local=rail::isLocalURL(url);
  auto addProjects=[&](const std::string &spaceID) {
    for (const auto *project : _projects.inSpace(spaceID)) {
      // Blocks keep their own copies; names captured through the lambda would be references.
      std::string pid=project->id, tabURL=url, tabSession=session, tabTitle=title; NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:S(project->name) action:nil keyEquivalent:@""]; item.submenu=[[NSMenu alloc] init];
      NSArray *names=local ? @[@"Local"] : @[@"INT",@"Staging",@"PROD"];
      for (NSString *name in names) [item.submenu addItem:[self menuItem:[@"as " stringByAppendingString:name] block:^{ BrowserController *strong=weak; if (!strong) return;
        if (!strong->_projects.addEnvironment(pid,C(name),rail::originOf(tabURL),tabSession).empty()) { [strong projectsChanged]; [strong setStatus:[NSString stringWithFormat:@"Added %@ to %@.",name,S(strong->_projects.project(pid)->name)]]; } }]];
      [item.submenu addItem:[self menuItem:@"as New Environment…" block:^{ [weak editEnvironment:"" project:pid url:rail::originOf(tabURL) session:tabSession]; }]];
      [item.submenu addItem:NSMenuItem.separatorItem];
      [item.submenu addItem:[self menuItem:@"as Link…" block:^{ [weak editLink:"" project:pid url:tabURL label:tabTitle session:tabSession]; }]];
      [menu addItem:item];
    }
  };
  addProjects(tab->spaceID);
  BOOL others=NO; for (const auto &space : _model.state.spaces) if (space.id!=tab->spaceID && !_projects.inSpace(space.id).empty()) others=YES;
  if (others) { [menu addItem:NSMenuItem.separatorItem]; for (const auto &space : _model.state.spaces) if (space.id!=tab->spaceID) addProjects(space.id); }
  if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
  [menu addItem:[self menuItem:@"New Project from This Tab…" block:^{ [weak newProjectWithURL:url session:session]; }]];
  return menu;
}

#pragma mark Project forms

// A small sheet with labelled fields. Text fields have "value" and "placeholder"; pop-ups have "options" [[title,value],…].
- (void)showForm:(NSString *)title info:(NSString *)info fields:(NSArray<NSDictionary *> *)fields button:(NSString *)button completion:(void (^)(NSDictionary<NSString *, NSString *> *values))completion {
  NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=title; alert.informativeText=info ?: @"";
  NSMutableArray *rows=[NSMutableArray array]; NSMutableDictionary<NSString *, NSView *> *controls=[NSMutableDictionary dictionary]; NSView *first=nil;
  for (NSDictionary *field in fields) {
    NSTextField *label=[NSTextField labelWithString:field[@"label"]]; label.alignment=NSTextAlignmentRight;
    NSView *control;
    if (field[@"options"]) {
      NSPopUpButton *popup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,280,26) pullsDown:NO];
      for (NSArray *option in field[@"options"]) { [popup addItemWithTitle:option[0]]; popup.lastItem.representedObject=option[1]; if ([option[1] isEqual:field[@"value"]]) [popup selectItem:popup.lastItem]; }
      control=popup;
    } else {
      NSTextField *text=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,280,22)]; text.stringValue=field[@"value"] ?: @""; text.placeholderString=field[@"placeholder"];
      text.cell.scrollable=YES; text.cell.wraps=NO; control=text; if (!first) first=text;
    }
    [control.widthAnchor constraintEqualToConstant:280].active=YES; controls[field[@"key"]]=control; [rows addObject:@[label,control]];
  }
  NSGridView *grid=[NSGridView gridViewWithViews:rows]; grid.rowSpacing=10; grid.columnSpacing=10; [grid columnAtIndex:0].xPlacement=NSGridCellPlacementTrailing;
  for (NSInteger i=0;i<grid.numberOfRows;i++) [grid rowAtIndex:i].yPlacement=NSGridCellPlacementCenter;
  [grid layoutSubtreeIfNeeded]; NSSize size=grid.fittingSize; grid.frame=NSMakeRect(0,0,size.width,size.height); alert.accessoryView=grid;
  [alert addButtonWithTitle:button]; [alert addButtonWithTitle:@"Cancel"];
  [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) {
    if (result!=NSAlertFirstButtonReturn) return;
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    for (NSString *key in controls) {
      NSView *control=controls[key];
      values[key]=[control isKindOfClass:NSPopUpButton.class] ? (((NSPopUpButton *)control).selectedItem.representedObject ?: @"") : [((NSTextField *)control).stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    completion(values);
  }];
  if (first) [alert.window makeFirstResponder:first];
}
- (void)showMessage:(NSString *)title info:(NSString *)info {
  NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=title; alert.informativeText=info ?: @""; [alert addButtonWithTitle:@"OK"];
  [alert beginSheetModalForWindow:_window completionHandler:nil];
}
- (NSString *)addressFromInput:(NSString *)input { NSString *url=NormalizedAddress(input); return url && ![url hasPrefix:@"https://duckduckgo.com/?"] ? url : nil; }
- (void)newProject:(id)sender {
  (void)sender; const auto *active=_model.tab(_model.state.activeTabID);
  std::string url=active && rail::recognizeRepo(active->url) ? rail::recognizeRepo(active->url).repoURL() : "";
  const auto *space=_model.space(_model.state.activeSpaceID);
  [self newProjectWithURL:url session:active && rail::recognizeRepo(active->url) ? active->sessionID : (space ? space->sessionID : "work")];
}
- (void)newProjectWithURL:(std::string)url session:(std::string)session {
  const auto *space=_model.space(_model.state.activeSpaceID); if (!space) return;
  rail::RepoRef repo=rail::recognizeRepo(url); std::string existing=_projects.projectForRepo(repo);
  if (!existing.empty()) { [self revealProject:existing]; return; }
  std::string spaceID=space->id; __weak BrowserController *weak=self;
  NSArray *fields=@[@{@"key":@"name",@"label":@"Name",@"value":repo ? S(repo.repo) : @"",@"placeholder":@"Billing API"},
                    @{@"key":@"repo",@"label":@"Repository",@"value":repo ? S(repo.repoURL()) : (rail::isWebURL(url) ? S(url) : @""),@"placeholder":@"https://dev.azure.com/org/project/_git/repo"},
                    @{@"key":@"session",@"label":@"Open in",@"options":[self sessionOptionsWithIsolated:nil current:"" owner:""],@"value":S(rail::BrowserModel::isIsolatedSession(session) ? space->sessionID : session)}];
  [self showForm:[NSString stringWithFormat:@"Add a project to %@",S(space->name)] info:@"Paste a GitHub or Azure DevOps repository URL to link its repo, pipelines and pull requests. Environments can be added afterwards." fields:fields button:@"Add Project" completion:^(NSDictionary *values) {
    BrowserController *strong=weak; if (!strong) return;
    NSString *repoURL=[values[@"repo"] length] ? [strong addressFromInput:values[@"repo"]] : @"";
    if (!repoURL) { [strong showMessage:@"That repository address doesn't look right." info:@"Use a full address, such as https://github.com/owner/repo."]; return; }
    std::string id=strong->_projects.addProject(C(values[@"name"]),spaceID,C(repoURL),C(values[@"session"]));
    [strong projectsChanged]; [strong showHome:nil]; [strong checkProjects:YES];
    if (!rail::recognizeRepo(C(repoURL)) && repoURL.length) [strong setStatus:@"The repository isn't on GitHub or Azure DevOps, so it's added as a link without status."];
    (void)id;
  }];
}
- (void)revealProject:(std::string)projectID {
  const auto *project=_projects.project(projectID); if (!project) return;
  if (project->spaceID!=_model.state.activeSpaceID) { _model.selectSpace(project->spaceID,Now()); [self ensureBrowser:_model.state.activeTabID]; }
  [self showHome:nil]; [self setStatus:[NSString stringWithFormat:@"%@ is already a project in %@.",S(project->name),S(_model.space(project->spaceID)->name)]];
}
- (void)addCurrentPageAsProject:(id)sender {
  (void)sender; const auto *active=_model.tab(_model.state.activeTabID);
  if (!active || !rail::recognizeRepo(active->url)) { [self setStatus:@"Open a GitHub or Azure DevOps repository page first."]; return; }
  [self newProjectWithURL:active->url session:active->sessionID];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action==@selector(showDevTools:)) return !_quitting && !_homeVisible && [self activeBrowser]!=nullptr;
  if (item.action==@selector(addCurrentPageAsProject:)) { const auto *active=_model.tab(_model.state.activeTabID); return active && rail::recognizeRepo(active->url); }
  return YES;
}
- (void)editEnvironment:(std::string)environmentID project:(std::string)projectID url:(std::string)url session:(std::string)session {
  const auto *project=_projects.project(projectID); if (!project) return;
  const rail::Environment *existing=nullptr; for (const auto &e : project->environments) if (e.id==environmentID) existing=&e;
  std::string current=existing ? existing->sessionID : (session.empty() ? _model.space(project->spaceID)->sessionID : session);
  std::string owner=existing ? existing->id : "";
  NSArray *fields=@[@{@"key":@"name",@"label":@"Name",@"value":existing ? S(existing->name) : (url.empty() ? @"" : S(rail::Projects::suggestedEnvironmentName(url))),@"placeholder":@"INT, PROD, Local…"},
                    @{@"key":@"url",@"label":@"Address",@"value":existing ? S(existing->url) : S(url),@"placeholder":@"https://billing-int.example.com or localhost:3000"},
                    @{@"key":@"health",@"label":@"Health path",@"value":existing ? S(existing->healthPath) : @"",@"placeholder":@"Optional, e.g. /healthz"},
                    @{@"key":@"session",@"label":@"Open in",@"options":[self sessionOptionsWithIsolated:@"Its own isolated profile" current:current owner:owner],@"value":existing ? [self sessionOptionValue:current owner:owner] : S(current)}];
  __weak BrowserController *weak=self;
  [self showForm:existing ? @"Edit environment" : [NSString stringWithFormat:@"Add an environment to %@",S(project->name)]
            info:@"Eimerrail checks local addresses by connecting to their port, and remote ones with a request that carries no cookies. Its own isolated profile keeps a separate login, for example for PROD." fields:fields button:existing ? @"Save" : @"Add Environment" completion:^(NSDictionary *values) {
    BrowserController *strong=weak; if (!strong) return;
    NSString *address=[strong addressFromInput:values[@"url"]];
    if (!address) { [strong showMessage:@"That address doesn't look right." info:@"Use an address such as https://billing-int.example.com or localhost:3000."]; return; }
    bool ok;
    if (environmentID.empty()) ok=!strong->_projects.addEnvironment(projectID,C(values[@"name"]),C(address),C(values[@"session"]),C(values[@"health"])).empty();
    else ok=strong->_projects.updateEnvironment(projectID,{environmentID,C(values[@"name"]),C(address),C(values[@"health"]),C(values[@"session"])});
    if (ok) { [strong projectsChanged]; [strong checkProjects:YES]; }
  }];
}
- (void)editLink:(std::string)linkID project:(std::string)projectID url:(std::string)url label:(std::string)label session:(std::string)session {
  [self editLink:linkID project:projectID url:url label:label session:session environment:""];
}
- (void)editLink:(std::string)linkID project:(std::string)projectID url:(std::string)url label:(std::string)label session:(std::string)session environment:(std::string)environmentID {
  const auto *project=_projects.project(projectID); if (!project) return;
  const rail::ProjectLink *existing=nullptr; for (const auto &l : project->links) if (l.id==linkID) existing=&l;
  std::string current=existing ? existing->sessionID : (session.empty() ? _model.space(project->spaceID)->sessionID : session);
  std::string owner=existing ? existing->id : "";
  NSMutableArray *environments=[NSMutableArray arrayWithObject:@[@"Whole project",@""]];
  for (const auto &e : project->environments) [environments addObject:@[S(e.name),S(e.id)]];
  NSMutableArray *fields=[NSMutableArray arrayWithArray:@[@{@"key":@"label",@"label":@"Label",@"value":existing ? S(existing->label) : S(label),@"placeholder":@"LaunchDarkly"},
                    @{@"key":@"url",@"label":@"Address",@"value":existing ? S(existing->url) : S(url),@"placeholder":@"https://app.launchdarkly.com/…"},
                    @{@"key":@"session",@"label":@"Open in",@"options":[self sessionOptionsWithIsolated:@"Its own isolated profile" current:current owner:owner],@"value":existing ? [self sessionOptionValue:current owner:owner] : S(current)}]];
  if (!existing || existing->kind=="custom") [fields addObject:@{@"key":@"environment",@"label":@"Belongs to",@"options":environments,@"value":existing ? S(existing->environmentID) : S(environmentID)}];
  __weak BrowserController *weak=self;
  [self showForm:existing ? @"Edit link" : [NSString stringWithFormat:@"Add a link to %@",S(project->name)] info:@"Links open with one click from the card, for example feature flags, dashboards or a runbook." fields:fields button:existing ? @"Save" : @"Add Link" completion:^(NSDictionary *values) {
    BrowserController *strong=weak; if (!strong) return;
    NSString *address=[strong addressFromInput:values[@"url"]];
    if (!address) { [strong showMessage:@"That address doesn't look right." info:@"Use a full address, such as https://app.launchdarkly.com."]; return; }
    bool ok;
    if (linkID.empty()) ok=!strong->_projects.addLink(projectID,"custom",C(values[@"label"]),C(address),C(values[@"session"]),C(values[@"environment"] ?: @"")).empty();
    else { auto changed=*existing; changed.label=C(values[@"label"]); changed.url=C(address); changed.sessionID=C(values[@"session"]); if (values[@"environment"]) changed.environmentID=C(values[@"environment"]); ok=strong->_projects.updateLink(projectID,changed); }
    if (ok) [strong projectsChanged];
  }];
}

#pragma mark Import and sign-in

- (NSString *)likelyAzureOrganization {
  std::map<std::string,int> counts;
  for (const auto &entry : _history.entries) { const std::string host=rail::hostOf(entry.url); if (host!="dev.azure.com") continue; NSArray *parts=[[NSURLComponents componentsWithString:S(entry.url)].path componentsSeparatedByString:@"/"]; if (parts.count>1 && [parts[1] length]) counts[C(parts[1])]+=MAX(1,entry.visits); }
  for (const auto &c : _projects.state.connections) if (c.provider=="azureDevOps") counts[c.account]+=1000;
  std::string best; int most=0; for (const auto &[org,count] : counts) if (count>most) { best=org; most=count; }
  return S(best);
}
- (void)importFromAzure:(id)sender {
  (void)sender; const auto *space=_model.space(_model.state.activeSpaceID); if (!space) return;
  __weak BrowserController *weak=self; std::string spaceID=space->id;
  NSArray *fields=@[@{@"key":@"org",@"label":@"Organization",@"value":[self likelyAzureOrganization],@"placeholder":@"contoso"},
                    @{@"key":@"session",@"label":@"Signed in as",@"options":[self sessionOptionsWithIsolated:nil current:"" owner:""],@"value":S(space->sessionID)}];
  [self showForm:@"Import from Azure DevOps" info:@"Eimerrail lists the organization's repositories using the login in the chosen session. Nothing is stored except the projects you pick." fields:fields button:@"List Repositories" completion:^(NSDictionary *values) {
    BrowserController *strong=weak; if (!strong) return; NSString *org=values[@"org"], *session=values[@"session"];
    [strong setStatus:@"Loading repositories…"]; strong->_loadingRepositories=YES; [strong refreshHome];
    [strong->_status azureRepositories:org session:session completion:^(NSArray<ProjectRepository *> *repositories, NSString *error, BOOL signedOut) {
      BrowserController *inner=weak; if (!inner) return; [inner setStatus:nil]; inner->_loadingRepositories=NO; [inner refreshHome];
      if (signedOut) { [inner offerSignIn:[NSString stringWithFormat:@"Sign in to %@ in the %@ session",org,[inner sessionName:C(session)]] url:C([@"https://dev.azure.com/" stringByAppendingString:org]) session:C(session)]; return; }
      if (error) { [inner showMessage:@"Couldn't list repositories" info:error]; return; }
      [inner chooseRepositories:repositories title:[NSString stringWithFormat:@"Repositories in %@",org] space:spaceID session:C(session)];
    }];
  }];
}
- (void)importFromGitHub:(id)sender {
  (void)sender; const auto *space=_model.space(_model.state.activeSpaceID); if (!space) return;
  __weak BrowserController *weak=self; std::string spaceID=space->id;
  NSArray *fields=@[@{@"key":@"session",@"label":@"Signed in as",@"options":[self sessionOptionsWithIsolated:nil current:"" owner:""],@"value":S(space->sessionID)}];
  [self showForm:@"Import from GitHub" info:@"Eimerrail uses its GitHub App to read repositories, workflow runs and pull requests. The first time, GitHub asks you to authorize it in the chosen session." fields:fields button:@"Continue" completion:^(NSDictionary *values) {
    BrowserController *strong=weak; if (!strong) return; std::string session=C(values[@"session"]);
    std::string connectionID=strong->_projects.ensureConnection("github","",session); strong->_projectsDirty=YES; [strong saveSoon];
    void (^list)(void)=^{ BrowserController *inner=weak; if (!inner) return; [inner setStatus:@"Loading repositories…"]; inner->_loadingRepositories=YES; [inner refreshHome];
      [inner->_status gitHubRepositories:S(connectionID) completion:^(NSArray<ProjectRepository *> *repositories, NSString *error, BOOL signedOut) {
        BrowserController *last=weak; if (!last) return; [last setStatus:nil]; last->_loadingRepositories=NO; [last refreshHome];
        if (signedOut) { [last signInConnection:connectionID]; return; }
        if (error) { [last showMessage:@"Couldn't list repositories" info:error]; return; }
        [last chooseRepositories:repositories title:@"Your GitHub repositories" space:spaceID session:session];
      }]; };
    if ([strong->_status hasGitHubToken:S(connectionID)]) list(); else [strong signInToGitHub:connectionID then:list];
  }];
}
- (void)chooseRepositories:(NSArray<ProjectRepository *> *)found title:(NSString *)title space:(std::string)spaceID session:(std::string)session {
  if (!found.count) { [self showMessage:@"No repositories found" info:@"Nothing in this account is visible to Eimerrail."]; return; }
  // Grouped by owner (GitHub user or organization, Azure DevOps project), both levels alphabetical.
  NSArray<ProjectRepository *> *repositories=[found sortedArrayUsingComparator:^NSComparisonResult(ProjectRepository *a, ProjectRepository *b) {
    NSComparisonResult owner=[a.detail localizedCaseInsensitiveCompare:b.detail]; return owner!=NSOrderedSame ? owner : [a.name localizedCaseInsensitiveCompare:b.name]; }];
  NSUInteger groups=0; NSString *last=nil; for (ProjectRepository *repo in repositories) if (![repo.detail isEqualToString:last]) { groups++; last=repo.detail; }
  NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=title;
  alert.informativeText=[NSString stringWithFormat:@"%lu repositories. Each one you pick becomes a project card in this Space.",(unsigned long)repositories.count];
  NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,380,340)]; scroll.hasVerticalScroller=YES; scroll.borderType=NSBezelBorder;
  RailPanel *list=[[RailPanel alloc] initWithFrame:NSMakeRect(0,0,362,MAX(340,repositories.count*26+groups*34+8))]; list.fill=NSColor.textBackgroundColor;
  NSMutableArray<NSButton *> *boxes=[NSMutableArray array]; CGFloat y=4; last=nil;
  for (ProjectRepository *repo in repositories) {
    if (![repo.detail isEqualToString:last]) {
      if (last) { NSBox *line=[[NSBox alloc] initWithFrame:NSMakeRect(8,y+3,346,1)]; line.boxType=NSBoxSeparator; [list addSubview:line]; y+=8; }
      last=repo.detail;
      NSTextField *heading=RailLabel(repo.detail.length ? repo.detail : @"Other",11,NSFontWeightSemibold,NSColor.secondaryLabelColor); heading.frame=NSMakeRect(8,y+4,346,16); [list addSubview:heading]; y+=26;
    }
    BOOL added=!_projects.projectForRepo(rail::recognizeRepo(C(repo.url))).empty();
    NSButton *box=[NSButton checkboxWithTitle:added ? [repo.name stringByAppendingString:@"  (added)"] : repo.name target:nil action:nil]; box.enabled=!added; box.frame=NSMakeRect(14,y,340,22); box.lineBreakMode=NSLineBreakByTruncatingTail;
    [list addSubview:box]; [boxes addObject:box]; y+=26;
  }
  list.frame=NSMakeRect(0,0,362,MAX(340,y+4));
  scroll.documentView=list; alert.accessoryView=scroll; [alert addButtonWithTitle:@"Add Projects"]; [alert addButtonWithTitle:@"Cancel"];
  __weak BrowserController *weak=self;
  [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) {
    BrowserController *strong=weak; if (!strong || result!=NSAlertFirstButtonReturn) return; NSUInteger count=0;
    for (NSUInteger i=0;i<boxes.count;i++) if (boxes[i].enabled && boxes[i].state==NSControlStateValueOn) { strong->_projects.addProject("",spaceID,C(repositories[i].url),session); count++; }
    if (!count) return;
    [strong projectsChanged]; [strong showHome:nil]; [strong checkProjects:YES];
    [strong setStatus:[NSString stringWithFormat:@"Added %lu project%@.",(unsigned long)count,count==1 ? @"" : @"s"]];
  }];
}
- (void)offerSignIn:(NSString *)title url:(std::string)url session:(std::string)session {
  NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=title; alert.informativeText=@"Eimerrail reads Azure DevOps with the login of that session. Sign in there, then try again.";
  [alert addButtonWithTitle:@"Open Azure DevOps"]; [alert addButtonWithTitle:@"Cancel"]; __weak BrowserController *weak=self;
  [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) { if (result==NSAlertFirstButtonReturn) [weak openProjectURL:url session:session exact:NO]; }];
}
- (void)signInConnection:(std::string)connectionID {
  const auto *connection=_projects.connection(connectionID); if (!connection) return;
  if (connection->provider=="azureDevOps") {
    [self openProjectURL:"https://dev.azure.com/"+connection->account session:connection->sessionID exact:NO];
    [self setStatus:@"Sign in, then return to the Space home. Cards update within a minute."];
  } else [self signInToGitHub:connectionID then:nil];
}
- (void)signInToGitHub:(std::string)connectionID then:(void (^)(void))then {
  const auto *connection=_projects.connection(connectionID); if (!connection) return;
  std::string session=connection->sessionID; NSString *sessionName=[self sessionName:session]; __weak BrowserController *weak=self;
  __block NSAlert *prompt=nil;
  [_status signInToGitHub:S(connectionID) code:^(NSString *code, NSString *verification) {
    BrowserController *strong=weak; if (!strong) return;
    [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:code forType:NSPasteboardTypeString];
    prompt=[[NSAlert alloc] init]; prompt.messageText=[NSString stringWithFormat:@"Enter %@ on GitHub",code];
    prompt.informativeText=[NSString stringWithFormat:@"The code is on your clipboard. GitHub opens in the %@ session, where you're usually signed in already. Paste the code and authorize Eimerrail; this closes on its own.",sessionName];
    [prompt addButtonWithTitle:@"Open GitHub"]; [prompt addButtonWithTitle:@"Cancel"];
    [prompt beginSheetModalForWindow:strong->_window completionHandler:^(NSModalResponse result) {
      BrowserController *inner=weak; if (!inner) return;
      if (result==NSAlertFirstButtonReturn) [inner openProjectURL:C(verification) session:session exact:YES];
      else if (result==NSAlertSecondButtonReturn) [inner->_status cancelGitHubSignIn];
    }];
  } done:^(NSString *login, NSString *error) {
    BrowserController *strong=weak; if (!strong) return;
    if (prompt.window.isVisible) [strong->_window endSheet:prompt.window returnCode:NSModalResponseStop];
    if (error) { [strong showMessage:@"GitHub sign-in didn't finish" info:error]; return; }
    if (auto *c=strong->_projects.connection(connectionID)) c->account=C(login ?: @"");
    strong->_projectsDirty=YES; [strong saveSoon]; [strong setStatus:login.length ? [NSString stringWithFormat:@"Signed in to GitHub as %@.",login] : @"Signed in to GitHub."];
    [strong checkProjects:YES]; if (then) then();
  }];
}

// Test-only local control channel. It is disabled unless --automation was explicitly supplied.
// No remote page or production browser session can access this interface.
- (void)processAutomation {
  if (!_automation || _quitting) return;
  NSString *commandPath=[_directory stringByAppendingPathComponent:@"automation-command.json"];
  NSData *data=[NSData dataWithContentsOfFile:commandPath];
  NSDictionary *command=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if ([command isKindOfClass:NSDictionary.class] && [command[@"id"] isKindOfClass:NSString.class] && ![command[@"id"] isEqual:_automationID]) {
    _automationID=command[@"id"]; NSString *action=command[@"action"];
    @try { [self runAutomation:command action:action]; }
    @catch (NSException *exception) { [[NSString stringWithFormat:@"%@: %@\n%@",exception.name,exception.reason,[exception.callStackSymbols componentsJoinedByString:@"\n"]] writeToFile:[_directory stringByAppendingPathComponent:@"automation-exception.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
  }
  [self writeAutomationState];
}
- (void)runAutomation:(NSDictionary *)command action:(NSString *)action {
  {
    std::string tabID=[command[@"tab"] isKindOfClass:NSString.class] ? C(command[@"tab"]) : _model.state.activeTabID;
    if ([action isEqual:@"newTab"]) { auto id=_model.addTab(_model.state.activeSpaceID,C(command[@"url"] ?: @"about:blank"),Now(),C(command[@"session"] ?: @"")); if ([command[@"isolated"] boolValue]) _model.setIsolated(id); [self selectTabID:id]; }
    else if ([action isEqual:@"select"]) [self selectTabID:tabID];
    else if ([action isEqual:@"navigate"]) [self navigateTo:command[@"url"]];
    else if ([action isEqual:@"externalURL"]) {
      NSArray *values=[command[@"urls"] isKindOfClass:NSArray.class] ? command[@"urls"] : @[command[@"url"] ?: @""];
      NSMutableArray<NSURL *> *urls=[NSMutableArray array];
      for (NSString *value in values) { NSURL *url=[NSURL URLWithString:value]; if (url) [urls addObject:url]; }
      [self openExternalURLs:urls];
    }
    else if ([action isEqual:@"close"]) [self closeTabID:tabID];
    else if ([action isEqual:@"session"]) [self changeSession:C(command[@"session"]) tab:tabID];
    else if ([action isEqual:@"pin"]) { _model.togglePin(tabID); [self refresh]; }
    else if ([action isEqual:@"age"]) { if (auto *tab=_model.tab(tabID)) tab->lastUsed=Now()-_model.state.idleMinutes*60-1; [self checkIdle]; }
    else if ([action isEqual:@"sidebar"]) [self toggleSidebar:nil];
    else if ([action isEqual:@"key"]) {
      NSEventModifierFlags flags=([command[@"command"] boolValue] ? NSEventModifierFlagCommand : 0)|([command[@"shift"] boolValue] ? NSEventModifierFlagShift : 0); NSString *chars=command[@"chars"] ?: @"";
      NSEvent *event=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:_window.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:(unsigned short)[command[@"keyCode"] intValue]];
      [NSApp sendEvent:event];
    }
    else if ([action isEqual:@"sheetCancel"]) { if (_window.attachedSheet) [_window endSheet:_window.attachedSheet returnCode:NSModalResponseAbort]; }
    else if ([action isEqual:@"reading"]) { if (!_readingVisible) [self showReading:nil]; }
    else if ([action hasPrefix:@"reading"]) [_reading runAutomation:command action:action];
    else if ([action isEqual:@"menu"]) {
      for (NSMenuItem *group in NSApp.mainMenu.itemArray) {
        NSInteger index=[group.submenu indexOfItemWithTitle:command[@"title"] ?: @""];
        if (index>=0) { [group.submenu performActionForItemAtIndex:index]; break; }
      }
    }
    else if ([action isEqual:@"downloads"]) {
      [self toggleDownloads:nil];
      if (NSView *content=_downloadsPopover.shown ? _downloadsPopover.contentViewController.view : nil) {
        NSBitmapImageRep *bitmap=[content bitmapImageRepForCachingDisplayInRect:content.bounds]; [content cacheDisplayInRect:content.bounds toBitmapImageRep:bitmap];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[_directory stringByAppendingPathComponent:@"downloads.png"] atomically:YES];
      }
    }
    else if ([action isEqual:@"type"]) {
      // Typing waits for the address bar's focus change to settle, as a real keystroke would.
      [self focusAddress:nil]; NSString *text=command[@"text"] ?: @""; __weak BrowserController *weak=self;
      dispatch_async(dispatch_get_main_queue(), ^{ BrowserController *strong=weak; if (!strong) return; ((NSTextView *)strong->_address.currentEditor).string=text; [strong suggestFor:text inline:YES]; });
    }
    else if ([action isEqual:@"keys"]) {
      // Real key events through the field editor, one per character, for address bar tests.
      if (!_address.currentEditor) [self focusAddress:nil];
      NSString *text=command[@"text"] ?: @"";
      for (NSUInteger i=0;i<text.length;i++) {
        NSString *character=[text substringWithRange:NSMakeRange(i,1)]; BOOL back=[character isEqual:@"\b"];
        NSString *chars=back ? [NSString stringWithFormat:@"%C",(unichar)NSDeleteCharacter] : character;
        for (NSEventType type : {NSEventTypeKeyDown,NSEventTypeKeyUp}) {
          NSEvent *event=[NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:_window.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:back ? 51 : 0];
          [NSApp sendEvent:event];
        }
      }
      NSTextView *editor=(NSTextView *)_address.currentEditor;
      [@{@"text":editor.string ?: @"",@"selection":NSStringFromRange(editor.selectedRange)} writeToFile:[_directory stringByAppendingPathComponent:@"address.plist"] atomically:YES];
    }
    else if ([action isEqual:@"shortcut"]) {
      NSString *key=command[@"key"] ?: @"s";
      NSEventModifierFlags flags=NSEventModifierFlagCommand;
      if ([command[@"modifiers"] isKindOfClass:NSArray.class]) {
        flags=0;
        for (NSString *name in command[@"modifiers"]) flags|=[name isEqual:@"ctrl"] ? NSEventModifierFlagControl : [name isEqual:@"shift"] ? NSEventModifierFlagShift : [name isEqual:@"cmd"] ? NSEventModifierFlagCommand : [name isEqual:@"alt"] ? NSEventModifierFlagOption : 0;
      }
      unsigned short keyCode=[command[@"keyCode"] isKindOfClass:NSNumber.class] ? [command[@"keyCode"] unsignedShortValue] : 1;
      BOOL release=[command[@"release"] boolValue];
      NSWindow *targetWindow=[command[@"window"] isEqual:@"key"] ? NSApp.keyWindow : _window;
      NSEvent *event=[NSEvent keyEventWithType:release ? NSEventTypeFlagsChanged : NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:targetWindow.windowNumber context:nil characters:release ? @"" : key charactersIgnoringModifiers:release ? @"" : key isARepeat:NO keyCode:release ? 59 : keyCode];
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
    else if ([action isEqual:@"home"]) [self showHome:nil];
    else if ([action isEqual:@"addProject"]) { _projects.addProject(C(command[@"name"] ?: @""),_model.state.activeSpaceID,C(command[@"repo"] ?: @""),C(command[@"session"] ?: @"work")); [self projectsChanged]; }
    else if ([action isEqual:@"addEnvironment"] || [action isEqual:@"addLink"]) {
      std::string project; for (const auto &p : _projects.state.projects) if (p.name==C(command[@"project"] ?: @"") || p.id==C(command[@"project"] ?: @"")) project=p.id;
      if ([action isEqual:@"addEnvironment"]) _projects.addEnvironment(project,C(command[@"name"] ?: @""),C(command[@"url"] ?: @""),C(command[@"session"] ?: @"work"),C(command[@"health"] ?: @""));
      else _projects.addLink(project,"custom",C(command[@"label"] ?: @""),C(command[@"url"] ?: @""),C(command[@"session"] ?: @"work"),C(command[@"environment"] ?: @""));
      [self projectsChanged];
    }
    else if ([action isEqual:@"checkProjects"]) [self checkProjects:YES];
    else if ([action isEqual:@"importAzure"]) [self importFromAzure:nil];
    else if ([action isEqual:@"sheet"]) {
      // Drives the attached sheet like a user: fill text fields in order, tick checkboxes, click a button.
      NSWindow *sheet=_window.attachedSheet; NSMutableArray<NSView *> *views=[NSMutableArray array];
      NSMutableArray<NSView *> *queue=[NSMutableArray arrayWithObject:sheet.contentView ?: [[NSView alloc] init]];
      while (queue.count) { NSView *v=queue.firstObject; [queue removeObjectAtIndex:0]; [views addObject:v]; [queue addObjectsFromArray:v.subviews]; if ([v isKindOfClass:NSScrollView.class] && ((NSScrollView *)v).documentView) [queue addObject:((NSScrollView *)v).documentView]; }
      NSArray *texts=[command[@"fields"] isKindOfClass:NSArray.class] ? command[@"fields"] : @[]; NSUInteger t=0; NSInteger ticks=[command[@"tick"] integerValue];
      for (NSView *v in views) {
        if ([v isKindOfClass:NSTextField.class] && ((NSTextField *)v).editable && t<texts.count) ((NSTextField *)v).stringValue=texts[t++];
        if ([v isKindOfClass:NSPopUpButton.class] && [command[@"popup"] isKindOfClass:NSString.class]) [(NSPopUpButton *)v selectItemWithTitle:command[@"popup"]];
        if ([v isKindOfClass:NSButton.class] && ticks>0 && ((NSButton *)v).enabled && v.enclosingScrollView) { ((NSButton *)v).state=NSControlStateValueOn; ticks--; }
      }
      for (NSView *v in views) if ([v isKindOfClass:NSButton.class] && [((NSButton *)v).title isEqual:command[@"button"]]) { [(NSButton *)v performClick:nil]; break; }
    }
    else if ([action isEqual:@"openEnvironment"]) { for (const auto &p : _projects.state.projects) for (const auto &e : p.environments) if (e.name==C(command[@"name"] ?: @"") && p.name==C(command[@"project"] ?: @"")) [self openProjectURL:e.url session:e.sessionID exact:NO]; }
    else if ([action isEqual:@"quit"]) { [self quit:nil]; return; }
    [self saveSoon];
  }
}
- (void)writeAutomationState {
  NSMutableArray *tabs=[NSMutableArray array];
  for (const auto &tab:_model.state.tabs) { auto it=_runtime.find(tab.id); [tabs addObject:@{@"id":S(tab.id),@"url":S(tab.url),@"title":S(tab.title),@"session":S(tab.sessionID),@"space":S(tab.spaceID),@"pinned":@(tab.pinned),@"loaded":@(it!=_runtime.end() && it->second.browser.get()!=nullptr),@"closing":@(it!=_runtime.end() && it->second.closeReason!=CloseReason::None),@"error":it!=_runtime.end() ? S(it->second.error) : @""}]; }
  NSMutableArray *projects=[NSMutableArray array]; const auto &status=[_status snapshot];
  for (const auto &p : _projects.state.projects) {
    NSMutableArray *environments=[NSMutableArray array];
    for (const auto &e : p.environments) { auto f=status.environments.find(e.id); [environments addObject:@{@"id":S(e.id),@"name":S(e.name),@"url":S(e.url),@"session":S(e.sessionID),@"health":@(f==status.environments.end() ? 0 : (int)f->second.health)}]; }
    [projects addObject:@{@"id":S(p.id),@"name":S(p.name),@"space":S(p.spaceID),@"environments":environments,@"links":@(p.links.size()),@"attention":@(rail::attentionFor(p,_projects.state,status).size())}];
  }
  NSMutableArray *sheetText=[NSMutableArray array];
  if (NSView *content=_window.attachedSheet.contentView) { NSMutableArray<NSView *> *queue=[NSMutableArray arrayWithObject:content]; while (queue.count) { NSView *v=queue.firstObject; [queue removeObjectAtIndex:0]; [queue addObjectsFromArray:v.subviews]; if ([v isKindOfClass:NSTextField.class] && ((NSTextField *)v).stringValue.length) [sheetText addObject:((NSTextField *)v).stringValue]; if ([v isKindOfClass:NSButton.class]) [sheetText addObject:[@"[" stringByAppendingFormat:@"%@]",((NSButton *)v).title]]; } }
  NSDictionary *snapshot=@{@"sheetText":sheetText,@"sheet":_window.attachedSheet ? @"open" : @"",@"status":_statusLabel.stringValue ?: @"",@"home":@(_homeVisible),@"readingVisible":@(_readingVisible),@"reading":[_reading automationState],@"projects":projects,@"command":_automationID ?: @"",@"activeTab":S(_model.state.activeTabID),@"activeSpace":S(_model.state.activeSpaceID),@"sidebarVisible":@(_model.state.sidebarVisible),@"tabs":tabs,@"runtimeCount":@(_runtime.size())};
  [[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[_directory stringByAppendingPathComponent:@"automation-state.json"] atomically:YES];
}
@end
