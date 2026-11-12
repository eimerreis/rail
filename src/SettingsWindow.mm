#import "SettingsWindow.h"
#import "NativeViews.h"
#import "Theme.h"
#include "SearchEngine.h"
#include <algorithm>
#include <cmath>

namespace {
NSString *S(const std::string &s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
std::string C(NSString *s) { return std::string(s.UTF8String ?: ""); }
double Now() { return NSDate.date.timeIntervalSince1970; }
constexpr CGFloat WindowWidth = 800, WindowHeight = 600, SideWidth = 214, TitleHeight = 52, Inset = 22;

struct Category { NSString *pane, *title, *symbol, *keywords; unsigned int tile; bool gapAfter; };
const std::vector<Category> &Categories() {
  static const std::vector<Category> list = {
    {@"appearance",@"Appearance",@"sidebar.left",@"theme porcelain nightline daylight dark light color colour interface size sidebar animation motion scale small normal large",0x587089,false},
    {@"search",@"Search",@"magnifyingglass",@"search engine google bing duckduckgo address query default",0x4173aa,false},
    {@"tabs",@"Tabs",@"square.stack",@"idle unload sleep asleep memory minutes reopen",0x4173aa,false},
    {@"developer",@"Developer",@"wrench.and.screwdriver",@"devtools inspector dock docked window inspect",0x2d3b4d,false},
    {@"browser",@"Default Browser",@"safari",@"default links other apps downloads",0x3f7d84,true},
    {@"spaces",@"Spaces",@"rectangle.stack",@"space icon rail name session link rules patterns address open",0x35618e,false},
    {@"sessions",@"Sessions",@"person.2",@"session profile cookies login isolated",0x476d4e,true},
    {@"projects",@"Projects",@"square.grid.2x2",@"project environments cards home",0x6b4fa6,false},
    {@"connections",@"Connections",@"key",@"github azure devops sign in account token",0x2d3b4d,false},
  };
  return list;
}
const Category *CategoryFor(NSString *pane) { for (const auto &c : Categories()) if ([c.pane isEqualToString:pane]) return &c; return nullptr; }

// The category tiles keep their own colours in every theme, like System Settings' icons.

// A label that wraps to width; returns it sized to its text.
NSTextField *Wrapped(NSString *text, CGFloat size, NSColor *color, CGFloat x, CGFloat y, CGFloat width) {
  NSTextField *field = [NSTextField wrappingLabelWithString:text ?: @""];
  field.font = RailFont(size,NSFontWeightRegular); field.textColor = color; field.selectable = NO;
  CGFloat height = ceil([field.cell cellSizeForBounds:NSMakeRect(0,0,width,CGFLOAT_MAX)].height);
  field.frame = NSMakeRect(x,y,width,height); return field;
}
NSColor *Ink() { return RailInk(); }
NSColor *Muted() { return RailMuted(); }
// Session markers as in the sidebar: a letter on the session's tint. 0 work and others, 1 personal, 2 isolated.
NSInteger SessionStyle(const std::string &sessionID) {
  return rail::BrowserModel::isIsolatedSession(sessionID) ? 2 : sessionID == "personal" ? 1 : 0;
}
NSString *ThemeDetail(NSString *themeID) {
  NSDictionary *moods = @{@"porcelain":@"Warm limestone and ivory with dark sage.",@"nightline":@"Deep petrol with cream type; uses the dark system appearance.",@"daylight":@"Airy blue with a coral marker for the current Space."};
  return [NSString stringWithFormat:@"%@ Applies to every Rail window. Web pages keep their own colors.",moods[themeID] ?: moods[@"porcelain"]];
}
}

// Target for a control whose action is a block; kept alive by the controller until the pane is rebuilt.
@interface SettingsAction : NSObject
@property(nonatomic, copy) void (^block)(id sender);
- (void)run:(id)sender;
@end
@implementation SettingsAction
- (void)run:(id)sender { if (self.block) self.block(sender); }
@end

@interface SettingsWindowController () <NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
@end

@implementation SettingsWindowController {
  __weak id<SettingsHost> _host;
  RailPanel *_root, *_side, *_list, *_doc, *_box;
  NSSearchField *_search;
  NSTextField *_title;
  RailButton *_back, *_forward;
  NSScrollView *_scroll;
  NSMutableArray<NSString *> *_history;
  NSInteger _historyIndex;
  NSMutableArray<SettingsAction *> *_actions;
  NSArray<NSString *> *_visiblePanes;
  // Build cursor: _y in the pane, _boxY inside the current inset group.
  CGFloat _y, _boxY;
  std::string _expandedSpace;
  NSMutableArray<NSString *> *_rules;
  NSTableView *_rulesTable;
  NSTextField *_focusAfterReload, *_tryField, *_tryResult;
  BOOL _reloadQueued, _focusSpaceName, _revealExpanded;
  NSString *_tryText;
  CGFloat _expandedTop;
  std::string _focusSession;
}
- (instancetype)initWithHost:(id<SettingsHost>)host {
  if ((self = [super init])) { _host = host; _pane = @"appearance"; _history = [NSMutableArray array]; _actions = [NSMutableArray array]; }
  return self;
}
- (SettingsAction *)action:(void (^)(id sender))block { SettingsAction *a = [[SettingsAction alloc] init]; a.block = block; [_actions addObject:a]; return a; }
- (void)bind:(NSControl *)control to:(void (^)(id sender))block { SettingsAction *a = [self action:block]; control.target = a; control.action = @selector(run:); }

#pragma mark Window

- (void)makeWindow {
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,WindowWidth,WindowHeight) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
  _window.titlebarAppearsTransparent = YES; _window.titleVisibility = NSWindowTitleHidden; _window.releasedWhenClosed = NO;
  _window.appearance = RailThemeAppearance(); _window.delegate = self; _window.backgroundColor = RailTint(RailRoleContent);
  [_window setFrameAutosaveName:@"RailSettings"]; if (![_window setFrameUsingName:@"RailSettings"]) [_window center];
  _root = [[RailPanel alloc] initWithFrame:NSMakeRect(0,0,WindowWidth,WindowHeight)]; _root.fill = RailTint(RailRoleContent); _window.contentView = _root;

  _side = [[RailPanel alloc] initWithFrame:NSMakeRect(0,0,SideWidth,WindowHeight)]; _side.fill = RailTint(RailRoleSidebar); _side.titlebarHeight = TitleHeight; [_root addSubview:_side];
  RailPanel *edge = [[RailPanel alloc] initWithFrame:NSMakeRect(SideWidth-1,0,1,WindowHeight)]; edge.fill = RailLine(); [_side addSubview:edge];
  _search = [[NSSearchField alloc] initWithFrame:NSMakeRect(10,TitleHeight,SideWidth-20,28)]; _search.placeholderString = @"Search"; _search.delegate = self; _search.sendsSearchStringImmediately = YES;
  _search.accessibilityLabel = @"Search settings"; [_side addSubview:_search];
  _list = [[RailPanel alloc] initWithFrame:NSMakeRect(0,TitleHeight+38,SideWidth-1,WindowHeight-TitleHeight-38)]; _list.fill = RailTint(RailRoleSidebar); [_side addSubview:_list];

  RailPanel *bar = [[RailPanel alloc] initWithFrame:NSMakeRect(SideWidth,0,WindowWidth-SideWidth,TitleHeight)]; bar.fill = RailTint(RailRoleContent); bar.titlebarHeight = TitleHeight; [_root addSubview:bar];
  RailPanel *rule = [[RailPanel alloc] initWithFrame:NSMakeRect(0,TitleHeight-1,WindowWidth-SideWidth,1)]; rule.fill = RailTint(RailRoleLineSoft); [bar addSubview:rule];
  __weak SettingsWindowController *weak = self;
  _back = RailAction(@"",@"chevron.left",@"Back",^{ [weak go:-1]; }); _back.frame = NSMakeRect(14,12,26,28); _back.centered = YES; [bar addSubview:_back];
  _forward = RailAction(@"",@"chevron.right",@"Forward",^{ [weak go:1]; }); _forward.frame = NSMakeRect(40,12,26,28); _forward.centered = YES; [bar addSubview:_forward];
  _title = RailLabel(@"",13,NSFontWeightSemibold,Ink()); _title.frame = NSMakeRect(74,16,400,20); [bar addSubview:_title];

  _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(SideWidth,TitleHeight,WindowWidth-SideWidth,WindowHeight-TitleHeight)];
  _scroll.drawsBackground = NO; _scroll.hasVerticalScroller = YES; _scroll.autohidesScrollers = YES; _scroll.horizontalScrollElasticity = NSScrollElasticityNone;
  _doc = [[RailPanel alloc] initWithFrame:_scroll.contentView.bounds]; _doc.fill = RailTint(RailRoleContent); _scroll.documentView = _doc; [_root addSubview:_scroll];
  [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(reloadIfIdle) name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(themeChanged) name:RailThemeDidChangeNotification object:nil];
}
- (void)dealloc { [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
// Boxes and tiles copy colours into their layers, so the pane is rebuilt. Later, not now: the change
// usually comes from the Theme control's own action, which must not be torn down while it runs.
- (void)themeChanged {
  if (!_window) return;
  _window.appearance = RailThemeAppearance(); _window.backgroundColor = RailTint(RailRoleContent);
  [self reloadSoon];
}
- (void)showSpace:(NSString *)spaceID { _expandedSpace = C(spaceID); _revealExpanded = YES; [self showPane:@"spaces"]; }
- (void)showPane:(NSString *)pane {
  if (!_window) [self makeWindow];
  // Link rules used to have their own pane; they now live with each Space.
  if ([pane isEqualToString:@"rules"]) pane = @"spaces";
  if (pane.length && CategoryFor(pane)) [self select:pane record:YES];
  else [self select:_pane record:_history.count==0];
  [_window makeKeyAndOrderFront:nil];
}
- (void)windowDidBecomeKey:(NSNotification *)note { (void)note; [self reloadIfIdle]; }
- (void)go:(NSInteger)step {
  NSInteger target = _historyIndex + step; if (target < 0 || target >= (NSInteger)_history.count) return;
  _historyIndex = target; [self select:_history[target] record:NO];
}
- (void)select:(NSString *)pane record:(BOOL)record {
  if (record && !(_history.count && [_history[_historyIndex] isEqualToString:pane])) {
    if (_history.count) [_history removeObjectsInRange:NSMakeRange(_historyIndex+1,_history.count-_historyIndex-1)];
    [_history addObject:pane]; _historyIndex = _history.count-1;
  }
  BOOL changed = ![_pane isEqualToString:pane]; _pane = pane;
  if (changed) [_scroll.contentView scrollToPoint:NSZeroPoint];
  [self reload];
}

#pragma mark Category list

- (void)buildList {
  for (NSView *v in [_list.subviews copy]) [v removeFromSuperview];
  NSString *query = [_search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
  NSMutableArray *visible = [NSMutableArray array]; CGFloat y = 0; __weak SettingsWindowController *weak = self;
  for (const auto &c : Categories()) {
    if (query.length && ![c.title.lowercaseString containsString:query] && ![c.keywords containsString:query]) continue;
    [visible addObject:c.pane]; BOOL selected = [c.pane isEqualToString:_pane];
    RailPanel *row = [[RailPanel alloc] initWithFrame:NSMakeRect(8,y,SideWidth-17,30)]; row.wantsLayer = YES; row.layer.cornerRadius = 7;
    row.fill = selected ? RailTint(RailRoleAccent) : RailTint(RailRoleSidebar);
    RailPanel *tile = [[RailPanel alloc] initWithFrame:NSMakeRect(8,5,20,20)]; tile.wantsLayer = YES; tile.layer.cornerRadius = 5; tile.fill = RailColor(c.tile);
    if (selected) { tile.layer.borderWidth = 1; tile.layer.borderColor = [NSColor colorWithWhite:1 alpha:.55].CGColor; }
    NSImageView *glyph = [NSImageView imageViewWithImage:RailSymbol(c.symbol,11)]; glyph.contentTintColor = NSColor.whiteColor; glyph.frame = tile.bounds; [tile addSubview:glyph]; [row addSubview:tile];
    NSTextField *label = RailLabel(c.title,12,selected ? NSFontWeightMedium : NSFontWeightRegular,selected ? RailTint(RailRoleOnAccent) : Ink()); label.frame = NSMakeRect(37,7,SideWidth-60,17); [row addSubview:label];
    NSString *pane = c.pane;
    RailButton *hit = RailAction(@"",nil,c.title,^{ [weak select:pane record:YES]; }); hit.hoverFill = nil; hit.frame = row.bounds; hit.accessibilityLabel = c.title; [row addSubview:hit];
    [_list addSubview:row]; y += 31; if (c.gapAfter && !query.length) y += 12;
  }
  if (!visible.count) { NSTextField *none = RailLabel(@"No matching settings",11,NSFontWeightRegular,Muted()); none.frame = NSMakeRect(18,6,SideWidth-36,16); [_list addSubview:none]; }
  _visiblePanes = visible;
}
- (void)controlTextDidChange:(NSNotification *)note {
  if (note.object == _search) { [self buildList]; return; }
  if (note.object == _tryField) { _tryText = _tryField.stringValue; [self updateTry]; }
}
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
  (void)textView; if (control != _search || !_visiblePanes.count) return NO;
  // Arrow keys and Return in the search field move through the matching categories.
  NSInteger index = [_visiblePanes indexOfObject:_pane];
  if (command == @selector(moveDown:)) { [self select:_visiblePanes[index==NSNotFound ? 0 : MIN(index+1,(NSInteger)_visiblePanes.count-1)] record:YES]; return YES; }
  if (command == @selector(moveUp:)) { [self select:_visiblePanes[index==NSNotFound ? 0 : MAX(index-1,0)] record:YES]; return YES; }
  if (command == @selector(insertNewline:)) { [self select:index==NSNotFound ? _visiblePanes[0] : _pane record:YES]; return YES; }
  return NO;
}

#pragma mark Pane building blocks

- (CGFloat)width { return _scroll.contentSize.width - 2*Inset; }
- (void)intro:(NSString *)text { NSTextField *f = Wrapped(text,11.5,Muted(),Inset+2,_y,self.width-4); [_doc addSubview:f]; _y += f.frame.size.height + 12; }
- (void)heading:(NSString *)text { NSTextField *f = RailLabel(text,13,NSFontWeightSemibold,Ink()); f.frame = NSMakeRect(Inset+2,_y,self.width-4,18); [_doc addSubview:f]; _y += 26; }
- (void)beginBox {
  _box = [[RailPanel alloc] initWithFrame:NSMakeRect(Inset,_y,self.width,0)]; _box.fill = RailTint(RailRoleRaised); _box.wantsLayer = YES;
  _box.layer.cornerRadius = 10; _box.layer.borderWidth = 1; _box.layer.borderColor = RailLine().CGColor; _box.layer.masksToBounds = YES;
  [_doc addSubview:_box]; _boxY = 0;
}
- (void)endBox { NSRect f = _box.frame; f.size.height = _boxY; _box.frame = f; _y += _boxY + 14; _box = nil; }
- (void)separator { if (_boxY <= 0) return; RailPanel *line = [[RailPanel alloc] initWithFrame:NSMakeRect(0,_boxY,self.width,1)]; line.fill = RailTint(RailRoleLineSoft); [_box addSubview:line]; }
// A titled row in the current group: the description wraps beside the control on the right.
- (void)row:(NSString *)title detail:(NSString *)detail control:(NSView *)control {
  [self separator];
  CGFloat controlWidth = control ? control.frame.size.width : 0, textWidth = self.width - 28 - (control ? controlWidth + 20 : 0);
  NSTextField *name = RailLabel(title,12.5,NSFontWeightSemibold,Ink()); name.frame = NSMakeRect(14,_boxY+13,textWidth,18); [_box addSubview:name];
  CGFloat bottom = _boxY + 31;
  if (detail.length) { NSTextField *d = Wrapped(detail,11,Muted(),14,_boxY+33,textWidth); [_box addSubview:d]; bottom = NSMaxY(d.frame); }
  if (control) { NSRect f = control.frame; f.origin = NSMakePoint(self.width-14-controlWidth,_boxY+11); control.frame = f; [_box addSubview:control]; bottom = MAX(bottom,NSMaxY(f)); }
  _boxY = bottom + 13;
}
- (void)note:(NSString *)text symbol:(NSString *)symbol {
  NSImageView *icon = [NSImageView imageViewWithImage:RailSymbol(symbol,12)]; icon.contentTintColor = RailMuted(); icon.frame = NSMakeRect(Inset+2,_y,16,16); [_doc addSubview:icon];
  NSTextField *f = Wrapped(text,11,Muted(),Inset+24,_y,self.width-26); [_doc addSubview:f]; _y += MAX(16,f.frame.size.height) + 12;
}
- (NSSegmentedControl *)segments:(NSArray<NSString *> *)labels selected:(NSInteger)selected width:(CGFloat)width change:(void (^)(NSInteger index))change {
  NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithLabels:labels trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
  seg.selectedSegment = selected; seg.segmentDistribution = NSSegmentDistributionFillEqually; seg.frame = NSMakeRect(0,0,width,24);
  [self bind:seg to:^(NSSegmentedControl *sender) { change(sender.selectedSegment); }]; return seg;
}
- (NSButton *)button:(NSString *)title width:(CGFloat)width press:(void (^)(void))press {
  NSButton *b = [NSButton buttonWithTitle:title target:nil action:nil]; b.bezelStyle = NSBezelStyleRounded; b.controlSize = NSControlSizeRegular;
  [b sizeToFit]; b.frame = NSMakeRect(0,0,MAX(width,b.frame.size.width),26); [self bind:b to:^(id sender) { (void)sender; press(); }]; return b;
}
- (NSView *)marker:(const std::string &)sessionID letter:(NSString *)letter at:(NSPoint)point {
  NSInteger style = SessionStyle(sessionID);
  RailPanel *m = [[RailPanel alloc] initWithFrame:NSMakeRect(point.x,point.y,17,17)]; m.wantsLayer = YES; m.layer.cornerRadius = 4; m.fill = RailSessionFill(style);
  NSTextField *l = RailLabel(letter,9,NSFontWeightSemibold,RailSessionInk(style)); l.alignment = NSTextAlignmentCenter; l.frame = NSMakeRect(0,2,17,13); [m addSubview:l]; return m;
}
- (NSString *)sessionName:(const std::string &)sessionID {
  if (rail::BrowserModel::isIsolatedSession(sessionID)) return @"Isolated";
  const auto *s = [_host settingsModel].session(sessionID); return s ? S(s->name) : @"Work";
}
- (NSString *)letterFor:(const std::string &)sessionID { NSString *name = [self sessionName:sessionID]; return name.length ? [name substringToIndex:1].uppercaseString : @"W"; }
- (NSTextField *)editField:(NSString *)value width:(CGFloat)width commit:(void (^)(NSString *value))commit {
  NSTextField *field = [NSTextField textFieldWithString:value ?: @""]; field.frame = NSMakeRect(0,0,width,24); field.font = [NSFont systemFontOfSize:12];
  ((NSTextFieldCell *)field.cell).sendsActionOnEndEditing = YES; field.cell.scrollable = YES;
  __weak SettingsWindowController *weak = self;
  [self bind:field to:^(NSTextField *sender) {
    NSString *text = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length || [text isEqualToString:value]) { sender.stringValue = value ?: @""; return; }
    commit(text); [weak reloadSoon];
  }];
  return field;
}
- (void)changed { [_host settingsChanged]; [self reloadSoon]; }

#pragma mark Reload

- (void)reloadSoon {
  if (_reloadQueued) return; _reloadQueued = YES; __weak SettingsWindowController *weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{ SettingsWindowController *strong = weak; if (!strong) return; strong->_reloadQueued = NO; [strong reload]; });
}
- (BOOL)editingInPane { NSResponder *r = _window.firstResponder; return [r isKindOfClass:NSTextView.class] && [(NSView *)r isDescendantOf:_doc]; }
// Refreshes from outside changes, e.g. when the window comes forward, without disturbing text being typed.
- (void)reloadIfIdle { if (_window && ![self editingInPane]) [self reload]; }
// Rebuilds the pane. Text being edited is committed first, so moving on never gets stuck on a focused field.
- (void)reload {
  if (!_window || !_host) return;
  if ([self editingInPane]) [_window makeFirstResponder:nil];
  [self buildList];
  const Category *category = CategoryFor(_pane); _title.stringValue = category ? category->title : @""; _window.title = [NSString stringWithFormat:@"%@ — Settings",_title.stringValue];
  _back.enabled = _historyIndex > 0; _forward.enabled = _historyIndex+1 < (NSInteger)_history.count;
  _back.imageOpacity = _back.enabled ? 1 : .35; _forward.imageOpacity = _forward.enabled ? 1 : .35;
  NSPoint offset = _scroll.contentView.bounds.origin;
  for (NSView *v in [_doc.subviews copy]) [v removeFromSuperview];
  [_actions removeAllObjects]; _rulesTable = nil; _tryField = _tryResult = nil; _focusAfterReload = nil;
  _y = 18;
  SEL builder = NSSelectorFromString([NSString stringWithFormat:@"build%@",_pane.capitalizedString]);
  if ([self respondsToSelector:builder]) ((void (*)(id,SEL))[self methodForSelector:builder])(self,builder);
  CGFloat height = MAX(_y+10,_scroll.contentSize.height);
  _doc.frame = NSMakeRect(0,0,_scroll.contentSize.width,height);
  [_scroll.contentView scrollToPoint:NSMakePoint(0,MIN(offset.y,MAX(0,height-_scroll.contentSize.height)))]; [_scroll reflectScrolledClipView:_scroll.contentView];
  if (_revealExpanded && _expandedTop > 0) [_doc scrollRectToVisible:NSMakeRect(0,_expandedTop-12,10,MIN(360,_scroll.contentSize.height))];
  _revealExpanded = NO;
  if (_focusAfterReload) { [_window makeFirstResponder:_focusAfterReload]; [_focusAfterReload selectText:nil]; [_focusAfterReload scrollRectToVisible:_focusAfterReload.bounds]; }
}

#pragma mark Appearance, Search, Tabs, Developer, Default Browser

- (void)buildAppearance {
  rail::BrowserModel &model = [_host settingsModel]; __weak SettingsWindowController *weak = self;
  [self intro:@"How the sidebar, Spaces rail and Space home look and move. Web pages keep their own zoom."];
  [self beginBox];
  NSArray<NSString *> *themes = RailThemeIDs(); NSInteger theme = [themes indexOfObject:S(model.state.theme)]; if (theme == NSNotFound) theme = 0;
  NSMutableArray *themeNames = [NSMutableArray array]; for (NSString *themeID in themes) [themeNames addObject:RailThemeName(themeID)];
  NSSegmentedControl *themeControl = [self segments:themeNames selected:theme width:260 change:^(NSInteger index) {
    SettingsWindowController *strong = weak; if (!strong) return; [strong->_host settingsModel].state.theme = C(themes[index]); [strong changed]; }];
  themeControl.accessibilityLabel = @"Theme";
  [self row:@"Theme" detail:ThemeDetail(themes[theme]) control:themeControl];
  NSArray *sizes = @[@"small",@"normal",@"large"]; NSInteger size = [sizes indexOfObject:S(model.state.controlSize)];
  [self row:@"Interface size" detail:@"Scales the sidebar, rail and Space home together. The toolbar stays the same size."
    control:[self segments:@[@"Small",@"Normal",@"Large"] selected:size==NSNotFound ? 0 : size width:222 change:^(NSInteger index) {
      SettingsWindowController *strong = weak; if (!strong) return; [strong->_host settingsModel].state.controlSize = C(sizes[index]); [strong changed]; }]];
  NSArray *styles = @[@"off",@"subtle",@"full"]; NSInteger style = [styles indexOfObject:S(model.state.sidebarAnimation)]; if (style == NSNotFound) style = 2;
  NSArray *effects = @[@"It hides and shows at once.",@"A quick slide that fades, 0.14 s.",@"The rail and sidebar slide out over 0.22 s and the page follows."];
  [self row:@"Sidebar animation" detail:[NSString stringWithFormat:@"How the sidebar and rail leave and return with ⌘ S. %@",effects[style]]
    control:[self segments:@[@"Off",@"Subtle",@"Full"] selected:style width:222 change:^(NSInteger index) {
      SettingsWindowController *strong = weak; if (!strong) return; [strong->_host settingsModel].state.sidebarAnimation = C(styles[index]); [strong changed]; }]];
  [self endBox];
  if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) [self note:@"Reduce motion is on in macOS, so the sidebar doesn't animate whatever you choose here." symbol:@"info.circle"];
}
- (void)buildSearch {
  rail::BrowserModel &model = [_host settingsModel]; __weak SettingsWindowController *weak = self;
  [self intro:@"Choose the engine for searches typed in the address bar, including new tabs and Space home. Website addresses still open directly."];
  [self beginBox];
  NSPopUpButton *engine = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,150,26) pullsDown:NO];
  engine.accessibilityLabel = @"Search engine";
  for (const auto &option : rail::SearchEngines) {
    [engine addItemWithTitle:@(option.name)]; engine.lastItem.representedObject = @(option.id);
    if (model.state.searchEngine == option.id) [engine selectItem:engine.lastItem];
  }
  [self bind:engine to:^(NSPopUpButton *sender) { SettingsWindowController *strong = weak; if (!strong) return;
    [strong->_host settingsSetSearchEngine:C(sender.selectedItem.representedObject)]; [strong reloadSoon]; }];
  [self row:@"Search engine" detail:@"Applies to new searches in every Space. Existing tabs and saved searches stay as they are." control:engine];
  [self endBox];
}
- (void)buildTabs {
  rail::BrowserModel &model = [_host settingsModel]; __weak SettingsWindowController *weak = self;
  [self intro:@"Pages you haven't looked at for a while unload to save memory. Their titles and addresses stay; opening one reloads it."];
  [self beginBox];
  NSPopUpButton *timeout = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,130,26) pullsDown:NO];
  for (NSNumber *minutes in @[@1,@5,@10,@15,@30,@60]) {
    [timeout addItemWithTitle:minutes.intValue==1 ? @"1 minute" : [NSString stringWithFormat:@"%@ minutes",minutes]]; timeout.lastItem.representedObject = minutes;
    if (minutes.doubleValue == model.state.idleMinutes) [timeout selectItem:timeout.lastItem];
  }
  [self bind:timeout to:^(NSPopUpButton *sender) { SettingsWindowController *strong = weak; if (!strong) return; [strong->_host settingsModel].state.idleMinutes = [sender.selectedItem.representedObject doubleValue]; [strong changed]; }];
  [self row:@"Unload idle tabs after" detail:@"Pinned tabs unload too. The selected tab always stays awake. Unsaved page state may be lost; isolated sessions keep their own saved logins." control:timeout];
  [self row:@"Reopen closed tabs" detail:@"⌘ Z right after closing a tab, or ⇧ ⌘ T any time while Rail is open." control:nil];
  [self endBox];
}
- (void)buildDeveloper {
  rail::BrowserModel &model = [_host settingsModel]; __weak SettingsWindowController *weak = self;
  [self intro:@"Chromium DevTools for the current page."];
  [self beginBox];
  [self row:@"DevTools placement" detail:@"Docked DevTools sit to the right of the page; drag the divider to resize them. ⌥ ⌘ I opens and closes them, ⇧ ⌘ D switches placement."
    control:[self segments:@[@"Beside the Page",@"In a Window"] selected:model.state.devToolsDocked ? 0 : 1 width:236 change:^(NSInteger index) {
      SettingsWindowController *strong = weak; if (!strong) return; [strong->_host settingsSetDevToolsDocked:index==0]; [strong reloadSoon]; }]];
  [self row:@"Inspect an element" detail:@"Right-click the page and choose Inspect Element." control:nil];
  [self endBox];
}
- (void)buildBrowser {
  __weak SettingsWindowController *weak = self;
  NSURL *handler = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:[NSURL URLWithString:@"https://example.com"]];
  BOOL isDefault = handler && [handler.URLByStandardizingPath.path isEqualToString:NSBundle.mainBundle.bundleURL.URLByStandardizingPath.path];
  NSString *other = handler ? [NSFileManager.defaultManager displayNameAtPath:handler.path].stringByDeletingPathExtension : @"another app";
  [self intro:@"Where links from other apps open, and where downloads go."];
  [self beginBox];
  NSButton *make = isDefault ? nil : [self button:@"Make Default…" width:0 press:^{ SettingsWindowController *strong = weak; if (!strong) return;
    [strong->_host makeDefaultBrowser:nil]; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [weak reloadSoon]; }); }];
  [self row:@"Default browser" detail:isDefault ? @"Rail opens links from other apps. Link rules decide which Space they open in." : [NSString stringWithFormat:@"Links from other apps open in %@. macOS asks you to confirm the change.",other] control:make];
  [self row:@"Downloads" detail:@"Files save straight to your Downloads folder without asking; a taken name gets a number. The last 20 stay listed in the toolbar."
    control:[self button:@"Show in Finder" width:0 press:^{ NSURL *folder = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject; if (folder) [NSWorkspace.sharedWorkspace openURL:folder]; }]];
  [self endBox];
}

#pragma mark Spaces

- (void)buildSpaces {
  rail::BrowserModel &model = [_host settingsModel]; __weak SettingsWindowController *weak = self;
  if (!model.space(_expandedSpace)) _expandedSpace = model.state.activeSpaceID;
  [self intro:@"Each Space has its own tabs, pins and home. New tabs use the Space's session; links that match its rules open there from anywhere."];
  [self beginBox];
  for (size_t index = 0; index < model.state.spaces.size(); index++) {
    const rail::Space &space = model.state.spaces[index]; std::string sid = space.id; BOOL open = sid == _expandedSpace;
    [self separator];
    size_t tabs = std::count_if(model.state.tabs.begin(),model.state.tabs.end(),[&](const rail::Tab &t) { return t.spaceID == sid; });
    size_t rules = model.rulesForSpace(sid).size();
    RailPanel *tile = [[RailPanel alloc] initWithFrame:NSMakeRect(12,_boxY+9,30,30)]; tile.wantsLayer = YES; tile.layer.cornerRadius = 8; tile.fill = open ? RailTint(RailRoleSpaceActive) : RailTint(RailRoleHover);
    NSImageView *glyph = [NSImageView imageViewWithImage:RailSymbol([_host symbolForSpace:space index:index],14)]; glyph.contentTintColor = open ? RailTint(RailRoleSpaceActiveInk) : RailMuted(); glyph.frame = tile.bounds; [tile addSubview:glyph]; [_box addSubview:tile];
    NSTextField *name = RailLabel(S(space.name),12.5,NSFontWeightSemibold,Ink()); name.frame = NSMakeRect(53,_boxY+15,110,18); [_box addSubview:name];
    [_box addSubview:[self marker:space.sessionID letter:[self letterFor:space.sessionID] at:NSMakePoint(170,_boxY+15)]];
    NSString *meta = [NSString stringWithFormat:@"%@ session    %@    %lu tab%@",[self sessionName:space.sessionID],rules==0 ? @"No link rules" : [NSString stringWithFormat:@"%lu link rule%@",(unsigned long)rules,rules==1 ? @"" : @"s"],(unsigned long)tabs,tabs==1 ? @"" : @"s"];
    NSTextField *info = RailLabel(meta,11,NSFontWeightRegular,Muted()); info.frame = NSMakeRect(193,_boxY+16,self.width-235,16); [_box addSubview:info];
    NSImageView *chevron = [NSImageView imageViewWithImage:RailSymbol(open ? @"chevron.down" : @"chevron.right",10)]; chevron.contentTintColor = RailTint(RailRoleFaint); chevron.frame = NSMakeRect(self.width-28,_boxY+16,14,16); [_box addSubview:chevron];
    RailButton *toggle = RailAction(@"",nil,open ? @"Collapse" : [NSString stringWithFormat:@"Edit %@",S(space.name)],^{ SettingsWindowController *strong = weak; if (!strong) return; strong->_expandedSpace = open ? "" : sid; [strong reload]; });
    toggle.hoverFill = RailTint(RailRoleContentHover); toggle.cornerRadius = 0; toggle.frame = NSMakeRect(0,_boxY,self.width,48);
    [_box addSubview:toggle positioned:NSWindowBelow relativeTo:nil];
    if (open) _expandedTop = NSMinY(_box.frame) + _boxY;
    _boxY += 48;
    if (open) [self buildSpaceDetail:sid index:index];
  }
  [self endBox];
  NSButton *add = [self button:@"New Space" width:0 press:^{
    SettingsWindowController *strong = weak; if (!strong) return; rail::BrowserModel &m = [strong->_host settingsModel];
    const auto *current = m.space(m.state.activeSpaceID); std::string id = m.addSpace("New Space",current ? current->sessionID : "work",Now());
    strong->_expandedSpace = id; [strong->_host settingsChanged]; strong->_focusSpaceName = YES; [strong reload]; }];
  add.image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil]; add.imagePosition = NSImageLeading; [add sizeToFit];
  add.frame = NSMakeRect(Inset,_y-2,add.frame.size.width+6,26); [_doc addSubview:add];
  NSTextField *order = RailLabel(@"Spaces appear in the rail in this order.",11,NSFontWeightRegular,Muted()); order.frame = NSMakeRect(NSMaxX(add.frame)+10,_y+3,300,16); [_doc addSubview:order];
  _y += 46;
  [self buildLinkTester];
}
- (void)buildSpaceDetail:(const std::string &)sid index:(size_t)index {
  rail::BrowserModel &model = [_host settingsModel]; __weak SettingsWindowController *weak = self; const rail::Space *space = model.space(sid);
  CGFloat labelX = 53, fieldX = 205, y = _boxY + 2;
  auto label = ^(NSString *text, CGFloat top) { NSTextField *l = RailLabel(text,11.5,NSFontWeightRegular,Muted()); l.frame = NSMakeRect(labelX,top,140,16); [self->_box addSubview:l]; };

  label(@"Name",y+4);
  NSTextField *name = [self editField:S(space->name) width:220 commit:^(NSString *value) { SettingsWindowController *strong = weak; if (!strong) return; if (auto *s = [strong->_host settingsModel].space(sid)) { s->name = C(value); [strong->_host settingsChanged]; } }];
  name.frame = NSMakeRect(fieldX,y,220,24); name.accessibilityLabel = @"Space name"; [_box addSubview:name];
  if (_focusSpaceName) { _focusAfterReload = name; _focusSpaceName = NO; }
  y += 36;

  label(@"Icon",y+6);
  NSString *current = [_host symbolForSpace:*space index:index]; CGFloat x = fieldX;
  auto setIcon = ^(NSString *symbol) { SettingsWindowController *strong = weak; if (!strong) return; if (auto *s = [strong->_host settingsModel].space(sid)) { s->icon = C(symbol); [strong changed]; } };
  NSArray *quick = [RailSpaceSymbols() subarrayWithRange:NSMakeRange(0,9)];
  if (![quick containsObject:current]) quick = [[quick subarrayWithRange:NSMakeRange(0,8)] arrayByAddingObject:current];
  for (NSString *symbol in quick) {
    BOOL on = [symbol isEqualToString:current];
    RailButton *b = RailAction(@"",symbol,RailSymbolTitle(symbol),^{ setIcon(symbol); }); b.centered = YES; b.cornerRadius = 7;
    b.normalFill = on ? RailTint(RailRoleSpaceActive) : RailTint(RailRoleSunken); b.hoverFill = on ? RailTint(RailRoleSpaceActiveHover) : RailTint(RailRoleContentHover); b.ink = on ? RailTint(RailRoleSpaceActiveInk) : RailMuted();
    b.frame = NSMakeRect(x,y,28,28); b.accessibilityLabel = [NSString stringWithFormat:@"%@ icon",RailSymbolTitle(symbol)]; [_box addSubview:b]; x += 31;
  }
  __block RailButton *more = RailAction(@"",@"ellipsis",@"More icons",nil); more.centered = YES; more.cornerRadius = 7; more.normalFill = RailTint(RailRoleSunken); more.hoverFill = RailTint(RailRoleContentHover); more.ink = RailMuted(); more.frame = NSMakeRect(x,y,28,28);
  __weak RailButton *weakMore = more;
  more.handler = ^{
    SettingsWindowController *strong = weak; if (!strong) return; NSMenu *menu = [[NSMenu alloc] init];
    for (NSString *symbol in RailSpaceSymbols()) { NSMenuItem *item = [menu addItemWithTitle:RailSymbolTitle(symbol) action:@selector(run:) keyEquivalent:@""]; item.target = [strong action:^(id s) { (void)s; setIcon(symbol); }]; item.image = RailSymbol(symbol,13); if ([symbol isEqualToString:current]) item.state = NSControlStateValueOn; }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *other = [menu addItemWithTitle:@"Other SF Symbol…" action:@selector(run:) keyEquivalent:@""];
    other.target = [strong action:^(id s) { (void)s; [weak askSymbol:current then:setIcon]; }];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,30) inView:weakMore];
  };
  [_box addSubview:more]; y += 40;

  label(@"Session for new tabs",y+5);
  NSPopUpButton *session = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX-3,y,180,26) pullsDown:NO];
  for (const auto &s : model.state.sessions) { [session addItemWithTitle:S(s.name)]; session.lastItem.representedObject = S(s.id); if (s.id == space->sessionID) [session selectItem:session.lastItem]; }
  [self bind:session to:^(NSPopUpButton *sender) { SettingsWindowController *strong = weak; if (!strong) return; if (auto *s = [strong->_host settingsModel].space(sid)) { s->sessionID = C(sender.selectedItem.representedObject); [strong changed]; } }];
  [_box addSubview:session]; y += 38;

  label(@"Links that open here",y+5);
  _rules = [NSMutableArray array]; for (const auto &p : model.rulesForSpace(sid)) [_rules addObject:S(p)];
  CGFloat rows = MAX(3,(CGFloat)_rules.count), tableHeight = rows*24+2;
  NSScrollView *frame = [[NSScrollView alloc] initWithFrame:NSMakeRect(fieldX,y,330,tableHeight)]; frame.borderType = NSLineBorder; frame.hasVerticalScroller = NO;
  NSTableView *table = [[NSTableView alloc] initWithFrame:frame.bounds]; table.headerView = nil; table.rowHeight = 24; table.usesAlternatingRowBackgroundColors = YES; table.intercellSpacing = NSMakeSize(0,0);
  table.style = NSTableViewStylePlain; table.focusRingType = NSFocusRingTypeNone; table.accessibilityLabel = @"Address patterns";
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"pattern"]; column.width = 326; [table addTableColumn:column];
  // The table asks for its rows as soon as it has a data source, so it must already be the rules table.
  _rulesTable = table; table.dataSource = self; table.delegate = self; frame.documentView = table; [_box addSubview:frame]; [table reloadData];
  y += tableHeight;
  RailButton *plus = RailAction(@"",@"plus",@"Add a pattern",^{ [weak addRule]; }); plus.frame = NSMakeRect(fieldX,y+4,24,22); plus.centered = YES; plus.cornerRadius = 5; plus.ink = RailMuted(); plus.hoverFill = RailTint(RailRoleContentHover); [_box addSubview:plus];
  RailButton *minus = RailAction(@"",@"minus",@"Remove the selected pattern",^{ [weak removeRule]; }); minus.frame = NSMakeRect(fieldX+26,y+4,24,22); minus.centered = YES; minus.cornerRadius = 5; minus.ink = RailMuted(); minus.hoverFill = RailTint(RailRoleContentHover); [_box addSubview:minus];
  y += 32;
  NSTextField *hint = Wrapped(@"One pattern per row, such as dev.azure.com/contoso/**. * matches within a path segment, ** anything below. The most specific pattern wins.",10.5,Muted(),fieldX,y,330);
  [_box addSubview:hint]; y = NSMaxY(hint.frame) + 16;
  _boxY = y;
}
- (void)askSymbol:(NSString *)current then:(void (^)(NSString *symbol))then {
  NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Use another SF Symbol"; alert.informativeText = @"Type a symbol name, for example leaf or hammer.";
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,260,24)]; field.stringValue = current ?: @""; alert.accessoryView = field;
  [alert addButtonWithTitle:@"Use Symbol"]; [alert addButtonWithTitle:@"Cancel"];
  [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) {
    if (result != NSAlertFirstButtonReturn) return; NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (name.length && [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]) then(name); else NSBeep();
  }];
  [alert.window makeFirstResponder:field];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return table == _rulesTable ? (NSInteger)_rules.count : 0; }
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
  (void)column; NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,326,24)];
  NSTextField *field = [NSTextField textFieldWithString:_rules[row]]; field.bordered = NO; field.drawsBackground = NO; field.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  field.frame = NSMakeRect(6,4,314,16); field.tag = row; field.delegate = self; field.target = self; field.action = @selector(ruleEdited:); ((NSTextFieldCell *)field.cell).sendsActionOnEndEditing = YES;
  field.cell.scrollable = YES; field.placeholderString = @"example.com/path/**"; field.accessibilityLabel = @"Address pattern";
  [cell addSubview:field]; cell.textField = field; (void)table; return cell;
}
- (void)saveRules {
  std::vector<std::string> patterns; for (NSString *p in _rules) patterns.push_back(C(p));
  rail::BrowserModel &model = [_host settingsModel]; model.setSpaceRules(_expandedSpace,patterns); [_host settingsChanged];
}
- (void)ruleEdited:(NSTextField *)sender {
  NSInteger row = sender.tag; if (row < 0 || row >= (NSInteger)_rules.count) return;
  NSString *value = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!value.length) [_rules removeObjectAtIndex:row]; else _rules[row] = value;
  [self saveRules]; [self reloadSoon];
}
- (void)addRule {
  [_rules addObject:@""]; [_rulesTable reloadData];
  // Extra rows push the table taller on the next rebuild; for now the new row is edited in place.
  NSInteger row = _rules.count-1; [_rulesTable scrollRowToVisible:row]; [_rulesTable editColumn:0 row:row withEvent:nil select:YES];
}
- (void)removeRule {
  NSInteger row = _rulesTable.selectedRow; if (row < 0) row = _rulesTable.clickedRow; if (row < 0 || row >= (NSInteger)_rules.count) { NSBeep(); return; }
  [_window makeFirstResponder:nil]; [_rules removeObjectAtIndex:row]; [self saveRules]; [self reloadSoon];
}

#pragma mark Sessions

- (void)buildSessions {
  rail::BrowserModel &model = [_host settingsModel]; __weak SettingsWindowController *weak = self;
  [self intro:@"Tabs in the same session share cookies and logins, even across Spaces. Changing a tab's session reloads its page in that profile."];
  [self beginBox];
  for (const auto &session : model.state.sessions) {
    std::string id = session.id; [self separator];
    size_t tabs = std::count_if(model.state.tabs.begin(),model.state.tabs.end(),[&](const rail::Tab &t) { return t.sessionID == id; });
    NSMutableArray *spaces = [NSMutableArray array]; for (const auto &s : model.state.spaces) if (s.sessionID == id) [spaces addObject:S(s.name)];
    [_box addSubview:[self marker:id letter:[self letterFor:id] at:NSMakePoint(14,_boxY+16)]];
    NSTextField *name = [self editField:S(session.name) width:190 commit:^(NSString *value) {
      SettingsWindowController *strong = weak; if (!strong) return; rail::BrowserModel &m = [strong->_host settingsModel];
      for (auto &s : m.state.sessions) if (s.id == id) s.name = C(value); [strong->_host settingsChanged]; }];
    name.frame = NSMakeRect(42,_boxY+12,190,24); name.accessibilityLabel = @"Session name"; [_box addSubview:name];
    if (_focusSession == id) { _focusAfterReload = name; _focusSession.clear(); }
    NSString *uses = spaces.count ? [NSString stringWithFormat:@"New tabs in %@",[spaces componentsJoinedByString:@", "]] : @"Not a Space default";
    NSTextField *meta = RailLabel([NSString stringWithFormat:@"%lu tab%@  ·  %@",(unsigned long)tabs,tabs==1 ? @"" : @"s",uses],11,NSFontWeightRegular,Muted());
    meta.frame = NSMakeRect(246,_boxY+16,self.width-260,16); [_box addSubview:meta];
    _boxY += 48;
  }
  [self separator];
  size_t isolated = std::count_if(model.state.tabs.begin(),model.state.tabs.end(),[](const rail::Tab &t) { return rail::BrowserModel::isIsolatedSession(t.sessionID); });
  [_box addSubview:[self marker:rail::BrowserModel::isolatedSessionID("settings") letter:@"I" at:NSMakePoint(14,_boxY+15)]];
  NSTextField *iso = RailLabel(@"Isolated",12.5,NSFontWeightSemibold,Ink()); iso.frame = NSMakeRect(45,_boxY+14,150,18); [_box addSubview:iso];
  NSTextField *isoMeta = Wrapped([NSString stringWithFormat:@"A separate saved profile for one tab, not an incognito mode. %lu tab%@ use%@ one. Choose it from a tab's session badge.",(unsigned long)isolated,isolated==1 ? @"" : @"s",isolated==1 ? @"s" : @""],11,Muted(),246,_boxY+14,self.width-260);
  [_box addSubview:isoMeta]; _boxY = MAX(_boxY+46,NSMaxY(isoMeta.frame)+14);
  [self endBox];
  NSButton *add = [self button:@"New Session" width:0 press:^{
    SettingsWindowController *strong = weak; if (!strong) return; std::string id = [strong->_host settingsModel].addSession("New session");
    strong->_focusSession = id; [strong->_host settingsChanged]; [strong reload]; }];
  add.image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil]; add.imagePosition = NSImageLeading; [add sizeToFit];
  add.frame = NSMakeRect(Inset,_y-2,add.frame.size.width+6,26); [_doc addSubview:add]; _y += 34;
}

#pragma mark Link Rules

// Links from other apps, links that open a new tab, and addresses typed into a new tab follow the Spaces' rules.
- (void)buildLinkTester {
  [self heading:@"Test a link"];
  [self intro:@"Links from other apps, links that open a new tab, and addresses typed into a new tab open in the Space whose pattern matches. The most specific pattern wins."];
  [self beginBox];
  _tryField = [NSTextField textFieldWithString:_tryText ?: @""]; _tryField.placeholderString = @"Paste or type an address"; _tryField.delegate = self;
  _tryField.frame = NSMakeRect(14,12,self.width-28,24); _tryField.accessibilityLabel = @"Address to test"; [_box addSubview:_tryField];
  _tryResult = RailLabel(@"",11.5,NSFontWeightRegular,Muted()); _tryResult.frame = NSMakeRect(15,44,self.width-30,16); [_box addSubview:_tryResult];
  _boxY = 72; [self endBox]; [self updateTry];
}
- (void)updateTry {
  if (!_tryResult) return; rail::BrowserModel &model = [_host settingsModel];
  NSString *text = [_tryField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!text.length) { _tryResult.textColor = Muted(); _tryResult.stringValue = @"Type an address to see where it opens."; return; }
  if (![text containsString:@"://"]) text = [@"https://" stringByAppendingString:text];
  std::string url = C(text), space = model.spaceForURL(url);
  if (space.empty()) { _tryResult.textColor = Muted(); _tryResult.stringValue = @"No rule matches. It opens in the current Space."; return; }
  std::string best; for (const auto &p : model.rulesForSpace(space)) if (rail::BrowserModel::ruleMatches(p,url) && p.size() > best.size()) best = p;
  const auto *target = model.space(space);
  _tryResult.textColor = RailTint(RailRoleAccent);
  _tryResult.stringValue = [NSString stringWithFormat:@"Opens in %@, matching %@",target ? S(target->name) : @"another Space",S(best)];
}

#pragma mark Projects and Connections

- (void)buildProjects {
  rail::BrowserModel &model = [_host settingsModel]; rail::Projects &projects = [_host settingsProjects]; __weak SettingsWindowController *weak = self;
  [self intro:@"Projects are cards on their Space's home, with buttons for every environment. Add them from a Space home or with File › Add Project…"];
  if (projects.state.projects.empty()) {
    [self beginBox];
    [self row:@"No projects yet" detail:@"Open a Space home to add one, or import repositories from GitHub or Azure DevOps there."
      control:[self button:@"Open Space Home" width:0 press:^{ SettingsWindowController *strong = weak; if (strong) [strong->_host settingsShowSpaceHome:[strong->_host settingsModel].state.activeSpaceID]; }]];
    [self endBox]; return;
  }
  for (const auto &space : model.state.spaces) {
    auto list = projects.inSpace(space.id); if (list.empty()) continue; std::string sid = space.id;
    NSTextField *title = RailLabel(S(space.name),13,NSFontWeightSemibold,Ink()); title.frame = NSMakeRect(Inset+2,_y,300,18); [_doc addSubview:title];
    NSButton *home = [self button:@"Open Home" width:0 press:^{ SettingsWindowController *strong = weak; if (strong) [strong->_host settingsShowSpaceHome:sid]; }];
    home.controlSize = NSControlSizeSmall; home.font = [NSFont systemFontOfSize:11]; [home sizeToFit]; home.frame = NSMakeRect(Inset+self.width-home.frame.size.width,_y-3,home.frame.size.width,22); [_doc addSubview:home];
    _y += 26; [self beginBox];
    for (const auto *project : list) {
      std::string pid = project->id; [self separator];
      NSTextField *name = [self editField:S(project->name) width:180 commit:^(NSString *value) { SettingsWindowController *strong = weak; if (!strong) return; if ([strong->_host settingsProjects].renameProject(pid,C(value))) [strong->_host settingsProjectsChanged]; }];
      name.frame = NSMakeRect(12,_boxY+11,220,24); name.accessibilityLabel = @"Project name"; [_box addSubview:name];
      NSString *source = project->sources.empty() ? @"No repository" : S(project->sources.front().resource);
      size_t envs = project->environments.size();
      NSTextField *meta = RailLabel([NSString stringWithFormat:@"%@  ·  %lu environment%@",source,(unsigned long)envs,envs==1 ? @"" : @"s"],11,NSFontWeightRegular,Muted());
      // The repository and environments sit under the name, so long repository names stay readable.
      meta.frame = NSMakeRect(15,_boxY+40,self.width-225,16); [_box addSubview:meta];
      NSPopUpButton *move = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(self.width-190,_boxY+20,140,26) pullsDown:NO];
      for (const auto &s : model.state.spaces) { [move addItemWithTitle:S(s.name)]; move.lastItem.representedObject = S(s.id); if (s.id == sid) [move selectItem:move.lastItem]; }
      move.toolTip = @"Space whose home shows this project"; move.accessibilityLabel = @"Project Space";
      [self bind:move to:^(NSPopUpButton *sender) { SettingsWindowController *strong = weak; if (!strong) return; if ([strong->_host settingsProjects].moveProject(pid,C(sender.selectedItem.representedObject))) [strong->_host settingsProjectsChanged]; [strong reloadSoon]; }];
      [_box addSubview:move];
      RailButton *remove = RailAction(@"",@"trash",@"Remove project",^{ [weak confirmRemoveProject:pid]; }); remove.centered = YES; remove.cornerRadius = 6; remove.ink = Muted(); remove.hoverFill = RailTint(RailRoleContentHover); remove.frame = NSMakeRect(self.width-42,_boxY+20,28,26); [_box addSubview:remove];
      _boxY += 66;
    }
    [self endBox];
  }
}
- (void)confirmRemoveProject:(std::string)projectID {
  const auto *project = [_host settingsProjects].project(projectID); if (!project) return; __weak SettingsWindowController *weak = self;
  NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = [NSString stringWithFormat:@"Remove %@?",S(project->name)];
  alert.informativeText = @"Its card and environment buttons go away. Open tabs, sessions and connections stay.";
  [alert addButtonWithTitle:@"Remove"]; [alert addButtonWithTitle:@"Cancel"]; alert.buttons.firstObject.hasDestructiveAction = YES;
  [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) {
    SettingsWindowController *strong = weak; if (!strong || result != NSAlertFirstButtonReturn) return;
    if ([strong->_host settingsProjects].removeProject(projectID)) [strong->_host settingsProjectsChanged]; [strong reload];
  }];
}
- (void)buildConnections {
  rail::Projects &projects = [_host settingsProjects]; const rail::StatusSnapshot &status = [_host settingsStatus]; __weak SettingsWindowController *weak = self;
  [self beginBox];
  [self row:@"1Password" detail:@"Fill logins and generate passwords using the 1Password app on this Mac." control:[self button:@"Connect…" width:0 press:^{ SettingsWindowController *s=weak; if (s) [s->_host showPasswords:nil]; }]];
  [self endBox];
  [self intro:@"Accounts that project cards read pipelines and pull requests with. Azure DevOps uses a session's own login; GitHub signs in with a device code, and its token stays in your Keychain."];
  [self beginBox];
  if (projects.state.connections.empty())
    [self row:@"No connections yet" detail:@"They're added when you import projects from GitHub or Azure DevOps on a Space home." control:nil];
  for (const auto &connection : projects.state.connections) {
    std::string cid = connection.id; BOOL github = connection.provider == "github";
    auto found = status.connections.find(cid); rail::Access access = found != status.connections.end() ? found->second.access : rail::Access::unknown;
    NSString *state = access == rail::Access::signedIn ? @"Signed in" : access == rail::Access::signedOut ? @"Signed out" : access == rail::Access::rejected ? @"Access denied"
      : access == rail::Access::notCovered ? @"The GitHub app can't see these repositories" : @"Not checked yet";
    size_t used = 0; for (const auto &p : projects.state.projects) for (const auto &s : p.sources) if (s.connectionID == cid) { used++; break; }
    NSString *account = connection.account.empty() ? (github ? @"Not signed in yet" : @"Organization unknown") : S(connection.account);
    NSString *detail = [NSString stringWithFormat:@"%@  ·  %@ session  ·  %@  ·  %lu project%@",account,[self sessionName:connection.sessionID],state,(unsigned long)used,used==1 ? @"" : @"s"];
    NSButton *signIn = access == rail::Access::signedIn ? nil : [self button:@"Sign In…" width:0 press:^{ SettingsWindowController *strong = weak; if (strong) [strong->_host settingsSignIn:cid]; }];
    [self row:github ? @"GitHub" : @"Azure DevOps" detail:detail control:signIn];
  }
  [self endBox];
}
@end
