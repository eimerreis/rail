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
  BOOL _automation, _quitting, _editingAddress, _savingAllowed;
  NSString *_automationID, *_statusMessage;
  NSTimer *_idleTimer, *_saveTimer, *_automationTimer;
  RailPanel *_root, *_rail, *_sidebar, *_toolbar, *_statusbar, *_empty;
  NSView *_webHost;
  NSScrollView *_tabScroll;
  RailPanel *_tabDocument;
  NSTextField *_spaceLabel, *_spaceSubtitle, *_sleepLabel, *_statusLabel, *_sessionLabel;
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
  _sleepLabel = RailLabel(@"",10,NSFontWeightRegular,RailColor(0x596879)); [_sidebar addSubview:_sleepLabel];
  _back = RailAction(@"",@"chevron.left",@"Back (⌘ [)",^{ [weak goBack:nil]; });
  _forward = RailAction(@"",@"chevron.right",@"Forward (⌘ ])",^{ [weak goForward:nil]; });
  _reload = RailAction(@"",@"arrow.clockwise",@"Reload (⌘ R)",^{ [weak reloadPage:nil]; });
  _toggle = RailAction(@"",@"sidebar.left",@"Show sidebar (⌘ S)",^{ [weak toggleSidebar:nil]; });
  for (NSView *v in @[_back,_forward,_reload,_toggle]) [_toolbar addSubview:v];
  _address = [[NSTextField alloc] init]; _address.font = [NSFont systemFontOfSize:12]; _address.textColor = RailColor(0x273445);
  _address.backgroundColor = NSColor.whiteColor; _address.bordered = NO; _address.focusRingType = NSFocusRingTypeExterior;
  _address.wantsLayer = YES; _address.layer.cornerRadius = 6; _address.layer.borderWidth = 1; _address.layer.borderColor = RailColor(0xd4dde5).CGColor;
  _address.placeholderString = @"Search or enter address"; _address.delegate = self; _address.target = self; _address.action = @selector(addressEntered:); _address.accessibilityLabel = @"Search or enter address"; [_toolbar addSubview:_address];
  _sessionPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]; _sessionPicker.bordered = NO; _sessionPicker.font = [NSFont systemFontOfSize:11]; _sessionPicker.target = self; _sessionPicker.action = @selector(sessionChosen:); _sessionPicker.accessibilityLabel = @"Session for current tab"; [_toolbar addSubview:_sessionPicker];
  _progress = [[NSProgressIndicator alloc] init]; _progress.style = NSProgressIndicatorStyleBar; _progress.indeterminate = YES; _progress.displayedWhenStopped = NO; [_toolbar addSubview:_progress];
  [self installMenu]; [self refresh]; [self layout];
  [_window center]; [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
  [self ensureBrowser:_model.state.activeTabID];
  _idleTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) { (void)timer; [weak checkIdle]; }];
  if (_automation) _automationTimer = [NSTimer scheduledTimerWithTimeInterval:.1 repeats:YES block:^(NSTimer *timer) { (void)timer; [weak processAutomation]; }];
  [self saveSoon];
}
- (void)installMenu {
  NSMenu *bar = [[NSMenu alloc] init]; NSApp.mainMenu = bar;
  NSArray *groups = @[@[@"Eimerrail",@[@"About Eimerrail",@"about:",@""],@[@"Settings…",@"showSettings:",@","],@[@"Quit Eimerrail",@"quit:",@"q"]],@[@"File",@[@"New Tab",@"newTab:",@"t"],@[@"New Space…",@"newSpace:",@""],@[@"Close Tab",@"closeCurrentTab:",@"w"]],@[@"Edit",@[@"Undo",@"undo:",@"z"],@[@"Cut",@"cut:",@"x"],@[@"Copy",@"copy:",@"c"],@[@"Paste",@"paste:",@"v"],@[@"Select All",@"selectAll:",@"a"],@[@"Find…",@"findInPage:",@"f"]],@[@"View",@[@"Toggle Sidebar",@"toggleSidebar:",@"s"],@[@"Address Bar",@"focusAddress:",@"l"],@[@"Reload",@"reloadPage:",@"r"],@[@"Back",@"goBack:",@"["],@[@"Forward",@"goForward:",@"]"],@[@"Zoom In",@"zoomIn:",@"+"],@[@"Zoom Out",@"zoomOut:",@"-"],@[@"Actual Size",@"zoomReset:",@"0"]]];
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
  CGFloat rail = _model.state.sidebarVisible ? 45 : 0, side = _model.state.sidebarVisible ? 210 : 0, left = rail + side;
  _rail.hidden = !_model.state.sidebarVisible; _sidebar.hidden = !_model.state.sidebarVisible;
  _rail.frame = NSMakeRect(0,0,rail,h); _sidebar.frame = NSMakeRect(rail,0,side,h);
  _toolbar.frame = NSMakeRect(left,0,w-left,51); _webHost.frame = NSMakeRect(left,51,w-left,h-77); _empty.frame = NSMakeRect(left,51,w-left,h-77);
  _statusbar.frame = NSMakeRect(left,h-26,w-left,26);
  _spaceLabel.frame = NSMakeRect(15,62,155,23); _spaceSubtitle.frame = NSMakeRect(15,91,185,16);
  _sidebarToggle.frame = NSMakeRect(171,11,28,28); _spaceOptions.frame = NSMakeRect(171,61,28,28);
  _tabScroll.frame = NSMakeRect(0,117,side,MAX(0,h-160)); _sleepLabel.frame = NSMakeRect(13,h-29,185,17);
  CGFloat x = _model.state.sidebarVisible ? 7 : 86;
  _toggle.hidden = _model.state.sidebarVisible;
  if (!_toggle.hidden) { _toggle.frame = NSMakeRect(x,11,28,28); x += 31; }
  _back.frame = NSMakeRect(x,11,27,28); _forward.frame = NSMakeRect(x+28,11,27,28); _reload.frame = NSMakeRect(x+56,11,27,28); x += 92;
  CGFloat tw = _toolbar.bounds.size.width;
  _address.frame = NSMakeRect(x,13,MAX(90,tw-x-130),27); _sessionPicker.frame = NSMakeRect(tw-123,12,116,28);
  _progress.frame = NSMakeRect(0,48,tw,3);
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
  NSPoint offset = _tabScroll.contentView.bounds.origin;
  for (NSView *v in [_tabDocument.subviews copy]) [v removeFromSuperview];
  CGFloat y = 4; NSUInteger pins = 0, sleeping = 0;
  for (const auto &t : _model.state.tabs) if (t.spaceID == _model.state.activeSpaceID && !_runtime.count(t.id) && t.url != "about:blank") sleeping++;
  NSTextField *pinHeading = RailLabel(@"Pinned",10,NSFontWeightMedium,RailColor(0x596879)); pinHeading.frame = NSMakeRect(15,y,180,16); [_tabDocument addSubview:pinHeading]; y += 24;
  for (const auto &tab : _model.state.tabs) {
    if (tab.spaceID != _model.state.activeSpaceID || !tab.pinned) continue;
    std::string tid = tab.id;
    RailButton *button = RailAction(S(tab.title),SymbolForURL(tab.url),S(tab.title),^{ [weak selectTabID:tid]; });
    button.font = [NSFont systemFontOfSize:11]; button.frame = NSMakeRect(12+(pins%2)*96,y+(pins/2)*42,90,36);
    button.normalFill = RailColor(tab.id == _model.state.activeTabID ? 0xd4e4f6 : 0xf8fafc); button.stroke = RailColor(0xd4dde5);
    button.ink = RailColor(_runtime.count(tab.id) || tab.url == "about:blank" ? 0x273445 : 0x596879);
    button.toolTip = [NSString stringWithFormat:@"%@ · %@%@",S(tab.title),[self sessionName:tab.sessionID],_runtime.count(tab.id) ? @"" : @" · Reloads on open"];
    button.menu = [self menuForTab:tid]; [_tabDocument addSubview:button]; pins++;
  }
  if (pins) y += ((pins+1)/2)*42 + 12;
  else { NSTextField *hint = RailLabel(@"Right-click a tab to pin it.",10,NSFontWeightRegular,RailColor(0x596879)); hint.frame=NSMakeRect(15,y,180,18); [_tabDocument addSubview:hint]; y += 35; }
  NSTextField *tabHeading = RailLabel(@"Tabs",10,NSFontWeightMedium,RailColor(0x596879)); tabHeading.frame = NSMakeRect(15,y,180,16); [_tabDocument addSubview:tabHeading]; y += 23;
  for (const auto &tab : _model.state.tabs) {
    if (tab.spaceID != _model.state.activeSpaceID || tab.pinned) continue;
    std::string tid = tab.id; BOOL selected = tid == _model.state.activeTabID;
    RailPanel *row = [[RailPanel alloc] initWithFrame:NSMakeRect(7,y,196,35)]; row.wantsLayer=YES; row.layer.cornerRadius=7; row.layer.masksToBounds=YES; row.fill=RailColor(selected ? 0xd8e7f7 : 0xedf1f5); row.menu=[self menuForTab:tid];
    BOOL sleepingTab = !_runtime.count(tid) && tab.url != "about:blank";
    RailButton *button = RailAction(S(tab.title),sleepingTab ? @"moon" : SymbolForURL(tab.url),[NSString stringWithFormat:@"%@%@",S(tab.title),sleepingTab ? @", unloaded; reload on open" : @""],^{ [weak selectTabID:tid]; });
    button.frame = NSMakeRect(0,0,170,35); button.font=[NSFont systemFontOfSize:12 weight:selected ? NSFontWeightSemibold : NSFontWeightRegular]; button.ink=RailColor(selected ? 0x245b96 : sleepingTab ? 0x596879 : 0x273445); button.menu=row.menu; [row addSubview:button];
    NSString *sessionName = [self sessionName:tab.sessionID]; NSString *initial = sessionName.length ? [[sessionName substringToIndex:1] uppercaseString] : @"W";
    RailButton *badge = RailAction(initial,nil,[NSString stringWithFormat:@"%@ session; change session",sessionName],^{ [weak selectTabID:tid]; [weak showSessionMenu:nil]; });
    badge.frame=NSMakeRect(173,9,17,17); badge.font=[NSFont systemFontOfSize:9 weight:NSFontWeightSemibold]; badge.centered=YES; badge.cornerRadius=4; badge.ink=[self sessionInk:tab.sessionID];
    badge.normalFill=RailColor(rail::BrowserModel::isIsolatedSession(tab.sessionID) ? 0xeee2d5 : tab.sessionID=="personal" ? 0xdeebdf : 0xdae6f4); [row addSubview:badge];
    [_tabDocument addSubview:row]; y += 38;
  }
  RailButton *newTab = RailAction(@"New tab",@"plus",@"New tab (⌘ T)",^{ [weak newTab:nil]; }); newTab.ink=RailColor(0x596879); newTab.frame=NSMakeRect(9,y+8,192,33); [_tabDocument addSubview:newTab]; y += 54;
  _tabDocument.frame=NSMakeRect(0,0,210,MAX(y,_tabScroll.contentSize.height)); [_tabScroll.contentView scrollToPoint:NSMakePoint(0,MIN(offset.y,MAX(0,y-_tabScroll.contentSize.height)))];
  _sleepLabel.stringValue=[NSString stringWithFormat:@"%lu asleep · after %.0f min",(unsigned long)sleeping,_model.state.idleMinutes];
  [_sessionPicker removeAllItems];
  const auto *active = _model.tab(_model.state.activeTabID);
  for (const auto &session : _model.state.sessions) { [_sessionPicker addItemWithTitle:S(session.name)]; _sessionPicker.lastItem.representedObject=S(session.id); }
  [_sessionPicker addItemWithTitle:@"Isolated"]; _sessionPicker.lastItem.representedObject=@"__isolated__";
  [_sessionPicker.menu addItem:NSMenuItem.separatorItem]; [_sessionPicker addItemWithTitle:@"New session…"]; _sessionPicker.lastItem.representedObject=@"__new__";
  if (active) {
    for (NSMenuItem *item in _sessionPicker.itemArray) if ([item.representedObject isEqual:S(active->sessionID)] || (rail::BrowserModel::isIsolatedSession(active->sessionID) && [item.representedObject isEqual:@"__isolated__"])) [_sessionPicker selectItem:item];
    _sessionLabel.stringValue = [NSString stringWithFormat:@"%@ session",[self sessionName:active->sessionID]];
    if (!_editingAddress) _address.stringValue = active->url=="about:blank" ? @"" : S(active->url);
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
  if (title.length) tab->title=C(title); [self refresh]; [self saveSoon];
}
- (void)updateURL:(NSString *)url tab:(const std::string &)tabID generation:(uint64_t)generation {
  auto it=_runtime.find(tabID); auto *tab=_model.tab(tabID);
  if (!tab || it==_runtime.end() || it->second.generation!=generation) return;
  tab->url=C(url); it->second.error.clear(); [self refresh]; [self saveSoon];
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
}
- (void)newTab:(id)sender { (void)sender; if (_quitting) return; auto id=_model.addTab(_model.state.activeSpaceID,"about:blank",Now()); _model.selectTab(id,Now()); [self refresh]; [self saveSoon]; [self focusAddress:nil]; }
- (void)closeCurrentTab:(id)sender { (void)sender; [self closeTabID:_model.state.activeTabID]; }
- (void)closeTabID:(const std::string &)tabID {
  if (_runtime.count(tabID)) [self closeRuntime:tabID reason:CloseReason::Delete session:""];
  else { _model.closeTab(tabID,Now()); [self ensureBrowser:_model.state.activeTabID]; [self refresh]; [self saveSoon]; }
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
- (void)controlTextDidBeginEditing:(NSNotification *)notification { (void)notification; _editingAddress=YES; }
- (void)controlTextDidEndEditing:(NSNotification *)notification { (void)notification; _editingAddress=NO; }
- (void)addressEntered:(id)sender { (void)sender; [self navigateTo:_address.stringValue]; }
- (void)navigateTo:(NSString *)address {
  NSString *url=NormalizedAddress(address); if (!url) { [self setStatus:@"Enter a web address or a search. Supported addresses use http or https."]; return; }
  auto *tab=_model.tab(_model.state.activeTabID); if (!tab) return;
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
  if (event.type!=NSEventTypeKeyDown || _window.attachedSheet) return NO;
  NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (!(flags & NSEventModifierFlagCommand)) return NO;
  NSString *key=event.charactersIgnoringModifiers.lowercaseString;
  if ([key isEqual:@"s"]) [self toggleSidebar:nil]; else if ([key isEqual:@"l"]) [self focusAddress:nil];
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
  [menu addItem:defaults]; [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,28) inView:_spaceOptions];
}
- (void)renameSpace:(id)sender { (void)sender; auto *space=_model.space(_model.state.activeSpaceID); if (!space) return; std::string id=space->id; __weak BrowserController *weak=self; [self askForText:@"Rename Space" initial:S(space->name) completion:^(NSString *name) { BrowserController *strong=weak; if (strong && name.length) if (auto *s=strong->_model.space(id)) { s->name=C(name); [strong refresh]; [strong saveSoon]; } }]; }
- (void)spaceDefaultSession:(NSMenuItem *)sender { if (auto *space=_model.space(_model.state.activeSpaceID)) space->sessionID=C(sender.representedObject); [self saveSoon]; }
- (void)showSessionMenu:(id)sender { (void)sender; [_sessionPicker performClick:nil]; }
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
  else { if (session=="__isolated__") _model.setIsolated(tabID); else _model.setSession(tabID,session); [self ensureBrowser:tabID]; [self refresh]; [self saveSoon]; }
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
    else if ([action isEqual:@"shortcut"]) {
      NSString *key=command[@"key"] ?: @"s";
      NSEvent *event=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:_window.windowNumber context:nil characters:key charactersIgnoringModifiers:key isARepeat:NO keyCode:1];
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
