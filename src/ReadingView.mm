#import "ReadingView.h"
#include <cmath>

@implementation ReadingRow
@end
@implementation ReadingFeedRow
@end

namespace {
NSColor *Ink() { return RailColor(0x273445); }
NSColor *Sub() { return RailColor(0x596879); }
NSColor *Accent() { return RailColor(0x245b96); }
constexpr CGFloat ArticleWidth = 636;
NSString *const RailImageSource = @"RailImageSource";

// Sites without a known icon get a letter on one of the session marker tints.
NSView *LetterTile(NSString *key, NSImage *favicon, CGFloat size) {
  RailPanel *tile = [[RailPanel alloc] initWithFrame:NSMakeRect(0,0,size,size)]; tile.wantsLayer = YES;
  if (favicon) {
    NSImageView *icon = [[NSImageView alloc] initWithFrame:tile.bounds]; icon.image = favicon; icon.imageScaling = NSImageScaleProportionallyUpOrDown; [tile addSubview:icon];
    return tile;
  }
  static const unsigned tints[][2] = {{0xdae6f4,0x3c5f88},{0xdeebdf,0x476d4e},{0xeee2d5,0x7a5838},{0xe9e4f4,0x5b4590},{0xe6ebf0,0x4a5b6d}};
  NSUInteger hash = 0; for (NSUInteger i=0;i<key.length;i++) hash = hash*31+[key characterAtIndex:i];
  const unsigned *tint = tints[hash%5];
  tile.wantsLayer = YES; tile.layer.cornerRadius = 4; tile.fill = RailColor(tint[0]);
  NSString *letter = key.length ? [[key substringToIndex:1] uppercaseString] : @"•";
  NSTextField *label = RailLabel(letter,size*.56,NSFontWeightSemibold,RailColor(tint[1])); label.alignment = NSTextAlignmentCenter;
  CGFloat height = ceil(label.intrinsicContentSize.height); label.frame = NSMakeRect(0,floor((size-height)/2),size,height); [tile addSubview:label];
  return tile;
}
NSImageView *MetaIcon(NSString *symbol, NSColor *ink) {
  NSImageView *icon = [[NSImageView alloc] init]; icon.image = RailSymbol(symbol,9); icon.contentTintColor = ink; return icon;
}
}

// A row that acts as one button and keeps its contents out of hit testing.
@interface ReadingRowView : RailPanel
@property(nonatomic, copy) void (^handler)(void);
@property(nonatomic, strong) NSColor *restFill, *hoverColor;
@property(nonatomic) BOOL selected;
@property(nonatomic, copy) void (^onRemove)(void);
@property(nonatomic, copy) void (^onKey)(NSString *key);
@end
@implementation ReadingRowView
// A click leaves focus in the reader, so E, J and K keep working; only the keyboard lands on a row.
- (BOOL)acceptsFirstResponder { return NSApp.currentEvent.type != NSEventTypeLeftMouseDown; }
- (BOOL)canBecomeKeyView { return YES; }
- (NSFocusRingType)focusRingType { return NSFocusRingTypeExterior; }
- (void)drawFocusRingMask { NSRectFill(self.bounds); }
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (BOOL)isAccessibilitySelected { return self.selected; }
- (void)keyDown:(NSEvent *)event {
  NSString *key = event.charactersIgnoringModifiers;
  if ([key isEqual:@" "] || [key isEqual:@"\r"]) { if (self.handler) self.handler(); return; }
  if ((event.modifierFlags & NSEventModifierFlagCommand) && event.keyCode == 51 && self.onRemove) { self.onRemove(); return; }
  if (self.onKey && !(event.modifierFlags & NSEventModifierFlagCommand) && [@[@"e",@"j",@"k"] containsObject:key.lowercaseString]) { self.onKey(key.lowercaseString); return; }
  [super keyDown:event];
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES; self.layer.cornerRadius = 7; self.layer.masksToBounds = YES; self.hoverColor = RailColor(0xe2e8ef); self.restFill = RailColor(0xedf1f5); self.fill = self.restFill;
    __weak ReadingRowView *weak = self;
    self.onHoverChange = ^(BOOL hovered) { ReadingRowView *strong = weak; if (strong) strong.fill = hovered && !strong.selected ? strong.hoverColor : strong.restFill; };
    self.accessibilityElement = YES; self.accessibilityRole = NSAccessibilityButtonRole;
  }
  return self;
}
- (NSView *)hitTest:(NSPoint)point {
  NSView *hit = [super hitTest:point];
  return [hit isKindOfClass:NSButton.class] ? hit : hit ? self : nil;
}
- (void)mouseUp:(NSEvent *)event {
  if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil],self.bounds) && self.handler) self.handler();
}
- (void)mouseDown:(NSEvent *)event { (void)event; }
- (BOOL)accessibilityPerformPress { if (self.handler) self.handler(); return YES; }
@end

@implementation ReadingSidebarView {
  NSTextField *_title, *_kbd, *_empty, *_feedsHeading;
  RailAddressBar *_capture;
  RailPanel *_segments, *_listDocument, *_feedsDocument, *_divider;
  RailButton *_inbox, *_read, *_manage;
  NSScrollView *_list, *_feeds;
  NSArray<NSString *> *_shownRowIDs;
  CGFloat _feedsHeight;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.fill = RailColor(0xedf1f5);
    __weak ReadingSidebarView *weak = self;
    _title = RailLabel(@"Reading",14,NSFontWeightSemibold,Ink()); [self addSubview:_title];
    _capture = [[RailAddressBar alloc] init]; _capture.symbolName = @"link"; _capture.restingFill = NSColor.whiteColor; _capture.restingStroke = RailColor(0xd4dde5); [self addSubview:_capture];
    _capture.field.font = [NSFont systemFontOfSize:12]; _capture.field.placeholderString = @"Paste a link to read later"; _capture.field.accessibilityLabel = @"Paste a link to read later";
    _capture.field.target = self; _capture.field.action = @selector(submit:);
    _kbd = RailLabel(@"⌘V",10,NSFontWeightMedium,Sub()); _kbd.alignment = NSTextAlignmentCenter; _kbd.wantsLayer = YES; _kbd.layer.cornerRadius = 4; _kbd.layer.borderWidth = 1; _kbd.layer.borderColor = RailColor(0xd4dde5).CGColor; [_capture addSubview:_kbd];
    _segments = [[RailPanel alloc] init]; _segments.fill = RailColor(0xe2e8ef); _segments.wantsLayer = YES; _segments.layer.cornerRadius = 8; [self addSubview:_segments];
    _inbox = RailAction(@"Inbox",nil,@"Items you haven't marked read",^{ ReadingSidebarView *strong = weak; if (strong.onShowRead) strong.onShowRead(NO); });
    _read = RailAction(@"Read",nil,@"Items you marked read",^{ ReadingSidebarView *strong = weak; if (strong.onShowRead) strong.onShowRead(YES); });
    for (RailButton *button in @[_inbox,_read]) { button.centered = YES; button.font = [NSFont systemFontOfSize:12]; [_segments addSubview:button]; }
    _list = [[NSScrollView alloc] init]; _list.drawsBackground = NO; _list.hasVerticalScroller = YES; _list.autohidesScrollers = YES; _list.horizontalScrollElasticity = NSScrollElasticityNone;
    _listDocument = [[RailPanel alloc] init]; _listDocument.fill = RailColor(0xedf1f5); _list.documentView = _listDocument; [self addSubview:_list];
    _empty = RailLabel(@"",12,NSFontWeightRegular,Sub()); _empty.alignment = NSTextAlignmentCenter; _empty.maximumNumberOfLines = 3; _empty.lineBreakMode = NSLineBreakByWordWrapping; [self addSubview:_empty];
    _divider = [[RailPanel alloc] init]; _divider.fill = RailColor(0xd4dde5); [self addSubview:_divider];
    _feedsHeading = RailLabel(@"Feeds",10,NSFontWeightMedium,Sub()); [self addSubview:_feedsHeading];
    _manage = RailAction(@"Manage",nil,@"Add or check feeds",nil); __weak RailButton *weakManage = _manage;
    _manage.handler = ^{ ReadingSidebarView *strong = weak; if (strong.onManageFeeds) strong.onManageFeeds(weakManage); };
    _manage.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium]; _manage.ink = Accent(); _manage.centered = YES; [self addSubview:_manage];
    _feeds = [[NSScrollView alloc] init]; _feeds.drawsBackground = NO; _feeds.hasVerticalScroller = YES; _feeds.autohidesScrollers = YES; _feeds.horizontalScrollElasticity = NSScrollElasticityNone;
    _feedsDocument = [[RailPanel alloc] init]; _feedsDocument.fill = RailColor(0xedf1f5); _feeds.documentView = _feedsDocument; [self addSubview:_feeds];
  }
  return self;
}
- (NSTextField *)captureField { return _capture.field; }
- (void)submit:(id)sender {
  (void)sender; NSString *text = _capture.field.stringValue;
  if (text.length && self.onSubmit) self.onSubmit(text);
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self layoutContents]; }
- (void)layoutContents {
  CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
  _title.frame = NSMakeRect(15,2,w-30,20);
  _capture.frame = NSMakeRect(12,28,w-24,32); _kbd.frame = NSMakeRect(w-24-34,8,26,16);
  // Long addresses stop before the shortcut hint instead of running under it.
  NSRect field = _capture.field.frame; field.size.width = MAX(0,NSMinX(_kbd.frame)-6-field.origin.x); _capture.field.frame = field;
  _segments.frame = NSMakeRect(12,68,w-24,30);
  CGFloat half = floor((w-24-4)/2); _inbox.frame = NSMakeRect(2,2,half,26); _read.frame = NSMakeRect(2+half,2,half,26);
  CGFloat feedHeight = MIN(_feedsHeight,5*26+2)+(self.feedRows.count ? 6 : 4);
  CGFloat footer = 28+feedHeight, listTop = 104, listHeight = MAX(0,h-listTop-footer);
  _list.frame = NSMakeRect(0,listTop,w,listHeight);
  _empty.frame = NSMakeRect(24,listTop+36,w-48,54);
  _divider.frame = NSMakeRect(0,h-footer,w,1);
  _feedsHeading.frame = NSMakeRect(16,h-footer+9,120,14); _manage.frame = NSMakeRect(w-66,h-footer+6,54,20);
  _feeds.frame = NSMakeRect(0,h-feedHeight,w,feedHeight);
  [self layoutList];
}
- (void)reload {
  __weak ReadingSidebarView *weak = self;
  _inbox.title = [NSString stringWithFormat:@"Inbox  %lu",(unsigned long)self.inboxCount];
  _read.title = [NSString stringWithFormat:@"Read  %lu",(unsigned long)self.readCount];
  for (RailButton *button in @[_inbox,_read]) {
    BOOL on = (button==_read)==self.showingRead;
    button.normalFill = on ? NSColor.whiteColor : nil; button.hoverFill = on ? NSColor.whiteColor : RailColor(0xedf1f5);
    button.ink = on ? Ink() : Sub(); button.font = [NSFont systemFontOfSize:12 weight:on ? NSFontWeightMedium : NSFontWeightRegular];
    button.accessibilityValue = on ? @"selected" : nil;
  }
  // Rows are rebuilt, so keyboard focus has to be carried over to the new one.
  NSString *focusedID = nil; ReadingRowView *focusedRow = nil; NSInteger focusedFeed = -1;
  if ([self.window.firstResponder isKindOfClass:ReadingRowView.class] && [(NSView *)self.window.firstResponder isDescendantOf:_feedsDocument]) focusedFeed = (NSInteger)[_feedsDocument.subviews indexOfObject:(NSView *)self.window.firstResponder];
  void (^forwardKey)(NSString *) = ^(NSString *key) { ReadingSidebarView *strong = weak; if (strong.onKey) strong.onKey(key); };
  if ([self.window.firstResponder isKindOfClass:ReadingRowView.class] && [(NSView *)self.window.firstResponder isDescendantOf:_listDocument]) {
    NSUInteger index = [_listDocument.subviews indexOfObject:(NSView *)self.window.firstResponder];
    if (index < _shownRowIDs.count) focusedID = _shownRowIDs[index];
  }
  for (NSView *v in [_listDocument.subviews copy]) [v removeFromSuperview];
  _shownRowIDs = [self.rows valueForKey:@"itemID"];
  for (ReadingRow *row in self.rows) {
    ReadingRowView *view = [[ReadingRowView alloc] initWithFrame:NSZeroRect];
    NSString *itemID = row.itemID; view.handler = ^{ ReadingSidebarView *strong = weak; if (strong.onSelect) strong.onSelect(itemID); };
    view.selected = row.selected; if (row.selected) view.restFill = RailColor(0xd8e7f7); view.fill = view.restFill; view.menu = row.menu;
    view.accessibilityLabel = [NSString stringWithFormat:@"%@, %@",row.title,row.meta];
    view.identifier = @"reading-row"; view.onRemove = ^{ ReadingSidebarView *strong = weak; if (strong.onRemove) strong.onRemove(itemID); };
    view.onKey = forwardKey;
    if ([itemID isEqual:focusedID]) focusedRow = view;
    [view addSubview:LetterTile(row.tileKey,row.favicon,16)];
    NSTextField *title = RailLabel(row.title,12,row.pending ? NSFontWeightRegular : NSFontWeightMedium,row.selected ? Accent() : row.pending ? Sub() : Ink());
    title.maximumNumberOfLines = 2; title.lineBreakMode = NSLineBreakByTruncatingTail; title.cell.wraps = YES; title.cell.truncatesLastVisibleLine = YES; title.identifier = @"title"; [view addSubview:title];
    NSColor *metaInk = row.metaInk ?: (row.selected ? RailColor(0x44678e) : Sub());
    if (row.metaSymbol.length) { NSImageView *icon = MetaIcon(row.metaSymbol,row.metaInk ?: RailColor(0xa0641b)); icon.identifier = @"icon"; [view addSubview:icon]; }
    NSTextField *meta = RailLabel(row.meta,10.5,NSFontWeightRegular,metaInk); meta.identifier = @"meta"; [view addSubview:meta];
    if (row.progress > 0) {
      RailPanel *track = [[RailPanel alloc] init]; track.fill = RailColor(0xd4dde5); track.identifier = @"track"; [view addSubview:track];
      RailPanel *bar = [[RailPanel alloc] init]; bar.fill = RailColor(0x4173aa); [track addSubview:bar];
      track.toolTip = [NSString stringWithFormat:@"%.0f%% read",row.progress*100];
    }
    [_listDocument addSubview:view];
  }
  _empty.stringValue = self.emptyText ?: @""; _empty.hidden = self.rows.count>0;
  for (NSView *v in [_feedsDocument.subviews copy]) [v removeFromSuperview];
  CGFloat y = 2, w = self.bounds.size.width;
  for (ReadingFeedRow *feed in self.feedRows) {
    const CGFloat rowHeight = feed.problem.length ? 42 : 26;
    ReadingRowView *view = [[ReadingRowView alloc] initWithFrame:NSMakeRect(7,y,w-14,rowHeight)];
    NSString *feedID = feed.feedID; view.handler = ^{ ReadingSidebarView *strong = weak; if (strong.onFeed) strong.onFeed(feedID); };
    view.onKey = forwardKey; if ((NSInteger)_feedsDocument.subviews.count == focusedFeed) focusedRow = view;
    view.selected = feed.selected; if (feed.selected) view.restFill = RailColor(0xd8e7f7); view.fill = view.restFill; view.menu = feed.menu; view.toolTip = feed.problem;
    view.accessibilityLabel = [NSString stringWithFormat:@"%@, %lu unread%@",feed.title,(unsigned long)feed.unread,feed.problem.length ? [@", " stringByAppendingString:feed.problem] : @""];
    NSView *tile = LetterTile(feed.title,feed.favicon,14); tile.frame = NSMakeRect(9,6,14,14); [view addSubview:tile];
    NSTextField *title = RailLabel(feed.title,11,NSFontWeightRegular,feed.selected ? Accent() : Ink()); title.frame = NSMakeRect(30,5,w-14-30-34,16); [view addSubview:title];
    if (feed.problem.length) {
      RailPanel *dot = [[RailPanel alloc] initWithFrame:NSMakeRect(30,26,7,7)]; dot.wantsLayer = YES; dot.layer.cornerRadius = 3.5; dot.fill = RailColor(0xd1912a); [view addSubview:dot];
      NSTextField *why = RailLabel(feed.problem,10.5,NSFontWeightRegular,RailColor(0x8a5a0c)); why.frame = NSMakeRect(42,22,w-14-42-48,14); [view addSubview:why];
      RailButton *retry = RailAction(@"Retry",nil,@"Check this feed again",^{ ReadingSidebarView *strong = weak; if (strong.onFeedRetry) strong.onFeedRetry(feedID); });
      retry.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium]; retry.ink = Accent(); retry.centered = YES; retry.frame = NSMakeRect(w-14-46,19,40,20); [view addSubview:retry];
    }
    if (feed.unread) { NSTextField *count = RailLabel([NSString stringWithFormat:@"%lu",(unsigned long)feed.unread],10,NSFontWeightRegular,Sub()); count.alignment = NSTextAlignmentRight; count.frame = NSMakeRect(w-14-39,6,30,14); [view addSubview:count]; }
    [_feedsDocument addSubview:view]; y += rowHeight;
  }
  _feedsHeight = y;
  [self layoutContents];
  _feedsDocument.frame = NSMakeRect(0,0,w,MAX(y+4,_feeds.contentSize.height));
  // Tab runs from the paste field through the items and feeds.
  NSView *previous = _capture.field;
  for (NSView *view in [_listDocument.subviews arrayByAddingObjectsFromArray:_feedsDocument.subviews]) {
    previous.nextKeyView = view; previous = view;
    for (NSView *child in view.subviews) if ([child isKindOfClass:NSButton.class]) { previous.nextKeyView = child; previous = child; }
  }
  previous.nextKeyView = self.exitKeyView ?: _capture.field;
  if (focusedRow) [self.window makeFirstResponder:focusedRow];
}
- (BOOL)rowIsVisible:(NSString *)itemID {
  NSUInteger index = [_shownRowIDs indexOfObject:itemID]; if (index == NSNotFound || index >= _listDocument.subviews.count) return NO;
  return NSContainsRect(_listDocument.visibleRect,_listDocument.subviews[index].frame);
}
- (void)scrollRowIntoView:(NSString *)itemID {
  NSUInteger index = [_shownRowIDs indexOfObject:itemID]; if (index == NSNotFound || index >= _listDocument.subviews.count) return;
  [_listDocument scrollRectToVisible:NSInsetRect(_listDocument.subviews[index].frame,0,-6)];
}
- (void)layoutList {
  CGFloat w = self.bounds.size.width, rowWidth = w-14, y = 2;
  for (NSView *view in _listDocument.subviews) {
    if (![view isKindOfClass:ReadingRowView.class]) continue;
    NSTextField *title = nil, *meta = nil; NSImageView *icon = nil; NSView *track = nil, *tile = view.subviews.firstObject;
    for (NSView *child in view.subviews) {
      if ([child.identifier isEqual:@"title"]) title = (NSTextField *)child;
      else if ([child.identifier isEqual:@"meta"]) meta = (NSTextField *)child;
      else if ([child.identifier isEqual:@"icon"]) icon = (NSImageView *)child;
      else if ([child.identifier isEqual:@"track"]) track = child;
    }
    CGFloat textX = 34, textWidth = rowWidth-textX-10;
    tile.frame = NSMakeRect(9,9,16,16);
    CGFloat titleHeight = ceil([title.cell cellSizeForBounds:NSMakeRect(0,0,textWidth,60)].height);
    title.frame = NSMakeRect(textX,8,textWidth,titleHeight);
    CGFloat line = 8+titleHeight+2, metaX = textX;
    if (icon) { icon.frame = NSMakeRect(textX,line+1,12,12); metaX += 15; }
    meta.frame = NSMakeRect(metaX,line,textX+textWidth-metaX,14);
    CGFloat height = line+14+8;
    if (track) {
      track.frame = NSMakeRect(textX,height-2,textWidth,2);
      ReadingRow *row = nil; NSUInteger index = [_listDocument.subviews indexOfObject:view]; if (index < self.rows.count) row = self.rows[index];
      track.subviews.firstObject.frame = NSMakeRect(0,0,round(textWidth*row.progress),2);
      height += 6;
    }
    view.frame = NSMakeRect(7,y,rowWidth,height); y += height+2;
  }
  // Fill the visible area exactly, so an unneeded scroller doesn't narrow the rows.
  _listDocument.frame = NSMakeRect(0,0,w,MAX(y+6,floor(_list.contentSize.height)));
}
@end

@interface ReaderTextView : NSTextView
@property(nonatomic, copy) void (^onKey)(NSString *key);
@end
@implementation ReaderTextView
- (void)keyDown:(NSEvent *)event {
  NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption);
  NSString *key = event.charactersIgnoringModifiers.lowercaseString;
  if (!flags && self.onKey && [@[@"e",@"j",@"k"] containsObject:key]) { self.onKey(key); return; }
  if (flags==NSEventModifierFlagCommand && event.keyCode==51 && self.onKey) { self.onKey(@"remove"); return; }
  if (!flags && [key isEqual:@" "]) { if (event.modifierFlags & NSEventModifierFlagShift) [self scrollPageUp:nil]; else [self scrollPageDown:nil]; return; }
  [super keyDown:event];
}
@end

@interface ReaderView () <NSTextViewDelegate>
@end
@implementation ReaderView {
  RailPanel *_bar, *_barLine, *_tileHolder, *_messagePanel;
  NSTextField *_source, *_shortcut, *_messageTitle, *_messageDetail;
  RailButton *_open, *_mark, *_messageAction;
  NSProgressIndicator *_spinner;
  NSScrollView *_scroll;
  ReaderTextView *_text;
  NSURLSession *_images;
  NSUInteger _articleToken;
  BOOL _restoring, _hasBar;
  CGFloat _restoreProgress;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.fill = NSColor.whiteColor; __weak ReaderView *weak = self;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration; config.timeoutIntervalForRequest = 20;
    _images = [NSURLSession sessionWithConfiguration:config];
    _scroll = [[NSScrollView alloc] init]; _scroll.drawsBackground = NO; _scroll.hasVerticalScroller = YES; _scroll.autohidesScrollers = YES; _scroll.horizontalScrollElasticity = NSScrollElasticityNone;
    _text = [[ReaderTextView alloc] initWithFrame:NSZeroRect]; _text.editable = NO; _text.selectable = YES; _text.richText = YES; _text.drawsBackground = NO; _text.delegate = self; _text.usesFindBar = YES; _text.incrementalSearchingEnabled = YES;
    _text.verticallyResizable = YES; _text.horizontallyResizable = NO; _text.autoresizingMask = NSViewWidthSizable; _text.textContainer.widthTracksTextView = YES; _text.textContainer.heightTracksTextView = NO;
    _text.linkTextAttributes = @{NSForegroundColorAttributeName:Accent(),NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle),NSCursorAttributeName:NSCursor.pointingHandCursor};
    _text.selectedTextAttributes = @{NSBackgroundColorAttributeName:RailColor(0xc9dcf2)};
    _text.accessibilityLabel = @"Article";
    _text.onKey = ^(NSString *key) { ReaderView *strong = weak; if (strong.onKey) strong.onKey(key); };
    _scroll.documentView = _text; [self addSubview:_scroll];
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrolled:) name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    _bar = [[RailPanel alloc] init]; _bar.fill = NSColor.whiteColor; [self addSubview:_bar];
    _barLine = [[RailPanel alloc] init]; _barLine.fill = RailColor(0xd4dde5); [_bar addSubview:_barLine];
    _tileHolder = [[RailPanel alloc] init]; _tileHolder.fill = NSColor.whiteColor; [_bar addSubview:_tileHolder];
    _source = RailLabel(@"",12,NSFontWeightRegular,Sub()); [_bar addSubview:_source];
    _open = RailAction(@"Open original",@"arrow.up.forward.square",@"Open this page in a tab",^{ ReaderView *strong = weak; if (strong.onOpenOriginal) strong.onOpenOriginal(); }); _open.ink = Sub(); _open.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; [_bar addSubview:_open];
    _mark = RailAction(@"Mark read",@"checkmark",@"Mark read (E)",^{ ReaderView *strong = weak; if (strong.onToggleRead) strong.onToggleRead(); }); _mark.normalFill = RailColor(0xd8e7f7); _mark.hoverFill = RailColor(0xcbdff3); _mark.ink = Accent(); _mark.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; [_bar addSubview:_mark];
    _shortcut = RailLabel(@"E",10,NSFontWeightMedium,Sub()); _shortcut.alignment = NSTextAlignmentCenter; _shortcut.wantsLayer = YES; _shortcut.layer.cornerRadius = 4; _shortcut.layer.backgroundColor = NSColor.whiteColor.CGColor; [_mark addSubview:_shortcut];
    _messagePanel = [[RailPanel alloc] init]; _messagePanel.fill = NSColor.whiteColor; _messagePanel.hidden = YES; [self addSubview:_messagePanel];
    _messageTitle = RailLabel(@"",21,NSFontWeightMedium,Ink()); _messageTitle.alignment = NSTextAlignmentCenter; [_messagePanel addSubview:_messageTitle];
    _messageDetail = RailLabel(@"",13,NSFontWeightRegular,Sub()); _messageDetail.alignment = NSTextAlignmentCenter; _messageDetail.maximumNumberOfLines = 3; _messageDetail.lineBreakMode = NSLineBreakByWordWrapping; [_messagePanel addSubview:_messageDetail];
    _messageAction = RailAction(@"",nil,nil,^{ ReaderView *strong = weak; if (strong.onOpenOriginal) strong.onOpenOriginal(); }); _messageAction.normalFill = RailColor(0xd8e7f7); _messageAction.hoverFill = RailColor(0xcbdff3); _messageAction.ink = Accent(); _messageAction.centered = YES; _messageAction.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; [_messagePanel addSubview:_messageAction];
    _spinner = [[NSProgressIndicator alloc] init]; _spinner.style = NSProgressIndicatorStyleSpinning; _spinner.controlSize = NSControlSizeSmall; _spinner.displayedWhenStopped = NO; [_messagePanel addSubview:_spinner];
  }
  return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_images invalidateAndCancel]; }
- (BOOL)acceptsFirstResponder { return !_messagePanel.hidden; }
- (void)keyDown:(NSEvent *)event {
  NSString *key = event.charactersIgnoringModifiers.lowercaseString; const NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption);
  if (self.onKey && !flags && [@[@"e",@"j",@"k"] containsObject:key]) { self.onKey(key); return; }
  if (self.onKey && flags==NSEventModifierFlagCommand && event.keyCode==51) { self.onKey(@"remove"); return; }
  [super keyDown:event];
}
- (NSView *)keyTarget { return _scroll.hidden ? self : _text; }
- (void)setExitKeyView:(NSView *)view { _text.nextKeyView = view; self.nextKeyView = view; }
- (CGFloat)scrollOffset { return _scroll.hidden ? 0 : _scroll.contentView.bounds.origin.y; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self layoutContents]; }
- (void)layoutContents {
  CGFloat w = self.bounds.size.width, h = self.bounds.size.height, top = _hasBar ? 48 : 0;
  _bar.hidden = !_hasBar; _bar.frame = NSMakeRect(0,0,w,48); _barLine.frame = NSMakeRect(0,47,w,1);
  _tileHolder.frame = NSMakeRect(20,16,16,16); _source.frame = NSMakeRect(43,15,MAX(0,w-43-290),17);
  // One width for both titles, so Open original stays put when E toggles.
  const CGFloat mark = 146; _mark.frame = NSMakeRect(w-16-mark,10,mark,28); _shortcut.frame = NSMakeRect(mark-26,6,18,16); _open.frame = NSMakeRect(w-16-mark-8-118,10,118,28);
  _scroll.frame = NSMakeRect(0,top,w,h-top); _messagePanel.frame = NSMakeRect(0,top,w,h-top);
  // The article stays one readable column, centred in whatever width there is.
  CGFloat inset = MAX(24,floor((w-ArticleWidth)/2)); _text.textContainerInset = NSMakeSize(inset,34);
  CGFloat mw = _messagePanel.bounds.size.width, my = MAX(60,_messagePanel.bounds.size.height*.3);
  _messageTitle.frame = NSMakeRect(30,my,mw-60,30); _messageDetail.frame = NSMakeRect(MAX(30,(mw-460)/2),my+38,MIN(460,mw-60),54);
  _messageAction.frame = NSMakeRect((mw-170)/2,my+100,170,32); _spinner.frame = NSMakeRect((mw-16)/2,my+100,16,16);
}
- (void)setSource:(NSString *)source tileKey:(NSString *)tileKey favicon:(NSImage *)favicon read:(BOOL)read {
  _source.stringValue = source ?: @"";
  for (NSView *v in [_tileHolder.subviews copy]) [v removeFromSuperview];
  [_tileHolder addSubview:LetterTile(tileKey,favicon,16)];
  _mark.title = read ? @"Mark unread" : @"Mark read"; _mark.image = RailSymbol(read ? @"arrow.uturn.backward" : @"checkmark",13); _mark.toolTip = read ? @"Back to the inbox (E)" : @"Mark read (E)"; _mark.accessibilityLabel = _mark.title;
  _hasBar = YES; [self layoutContents];
}
- (void)showMessage:(NSString *)title detail:(NSString *)detail action:(NSString *)action busy:(BOOL)busy {
  _articleToken++; _hasBar = _hasBar && title != nil && busy+action.length>0;
  _scroll.hidden = YES; _messagePanel.hidden = NO;
  _messageTitle.stringValue = title ?: @"Nothing to read"; _messageDetail.stringValue = detail ?: @"";
  _messageAction.title = action ?: @""; _messageAction.hidden = !action.length;
  if (busy) [_spinner startAnimation:nil]; else [_spinner stopAnimation:nil];
  [self layoutContents];
}
- (void)showArticle:(NSDictionary *)article fallbackTitle:(NSString *)title progress:(CGFloat)progress {
  NSUInteger token = ++_articleToken; _messagePanel.hidden = YES; _scroll.hidden = NO; [_spinner stopAnimation:nil];
  NSAttributedString *text = ReadingAttributedArticle(article,title);
  _restoring = YES; _restoreProgress = progress;
  [_text.textStorage setAttributedString:text]; _text.selectedRange = NSMakeRange(0,0);
  [self layoutContents]; [self restoreScroll];
  [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0,text.length) options:0 usingBlock:^(id attachment, NSRange range, BOOL *stop) {
    (void)stop; if (attachment) [self loadImageAt:range token:token];
  }];
  // AppKit may lay out and scroll once more after this turn, so restore after that before listening again.
  dispatch_async(dispatch_get_main_queue(), ^{ if (token == self->_articleToken) [self restoreScroll]; self->_restoring = NO; });
}
- (void)restoreScroll {
  [_text.layoutManager ensureLayoutForTextContainer:_text.textContainer]; [_text sizeToFit];
  CGFloat max = MAX(0,_text.frame.size.height-_scroll.contentSize.height);
  [_scroll.contentView scrollToPoint:NSMakePoint(0,round(max*_restoreProgress))]; [_scroll reflectScrolledClipView:_scroll.contentView];
}
- (void)loadImageAt:(NSRange)range token:(NSUInteger)token {
  NSString *source = [_text.textStorage attribute:RailImageSource atIndex:range.location effectiveRange:nil];
  NSURL *url = source ? [NSURL URLWithString:source] : nil; if (!url) return;
  __weak ReaderView *weak = self;
  [[_images dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    (void)response; if (error || !data.length || data.length>12*1024*1024) return;
    NSImage *image = [[NSImage alloc] initWithData:data]; if (!image) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [weak placeImage:image at:range token:token]; });
  }] resume];
}
- (void)placeImage:(NSImage *)image at:(NSRange)range token:(NSUInteger)token {
  if (token != _articleToken || NSMaxRange(range) > _text.textStorage.length) return;
  NSTextAttachment *attachment = [_text.textStorage attribute:NSAttachmentAttributeName atIndex:range.location effectiveRange:nil]; if (!attachment) return;
  CGFloat scale = image.size.width > ArticleWidth ? ArticleWidth/image.size.width : 1;
  attachment.image = image; attachment.bounds = NSMakeRect(0,0,round(image.size.width*scale),round(image.size.height*scale));
  CGFloat y = _scroll.contentView.bounds.origin.y;
  [_text.layoutManager invalidateLayoutForCharacterRange:range actualCharacterRange:nil]; [_text.layoutManager invalidateDisplayForCharacterRange:range];
  [_text sizeToFit]; _restoring = YES; [_scroll.contentView scrollToPoint:NSMakePoint(0,y)]; _restoring = NO;
}
- (void)scrolled:(NSNotification *)note {
  (void)note; if (_restoring || _scroll.hidden || !self.onProgress) return;
  CGFloat max = _text.frame.size.height-_scroll.contentSize.height; if (max <= 0) return;
  self.onProgress(MIN(1,MAX(0,_scroll.contentView.bounds.origin.y/max)));
}
- (BOOL)textView:(NSTextView *)view clickedOnLink:(id)link atIndex:(NSUInteger)index {
  (void)view; (void)index; NSString *url = [link isKindOfClass:NSURL.class] ? ((NSURL *)link).absoluteString : [link isKindOfClass:NSString.class] ? link : nil;
  if (url && self.onLink) self.onLink(url);
  return YES;
}
- (void)focusArticle { [self.window makeFirstResponder:_scroll.hidden ? (NSResponder *)self : _text]; }
- (void)showFind {
  if (_scroll.hidden) return;
  NSMenuItem *item = [[NSMenuItem alloc] init]; item.tag = NSTextFinderActionShowFindInterface;
  [self.window makeFirstResponder:_text]; [_text performFindPanelAction:item];
}
@end

NSAttributedString *ReadingAttributedArticle(NSDictionary *article, NSString *fallbackTitle) {
  NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
  NSFont *body = [NSFont fontWithName:@"Georgia" size:17] ?: [NSFont systemFontOfSize:17];
  NSFont *mono = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
  NSColor *bodyInk = RailColor(0x2c3948);
  NSFontManager *fonts = NSFontManager.sharedFontManager;
  NSMutableParagraphStyle *(^style)(CGFloat line, CGFloat after) = ^(CGFloat line, CGFloat after) {
    NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init]; p.minimumLineHeight = line; p.maximumLineHeight = line; p.paragraphSpacing = after; return p;
  };
  void (^plain)(NSString *, NSDictionary *) = ^(NSString *text, NSDictionary *attributes) {
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:[text stringByAppendingString:@"\n"] attributes:attributes]];
  };
  void (^runs)(NSArray *, NSFont *, NSColor *, NSParagraphStyle *) = ^(NSArray *list, NSFont *font, NSColor *ink, NSParagraphStyle *paragraph) {
    if (![list isKindOfClass:NSArray.class]) return;
    for (NSDictionary *run in list) {
      if (![run isKindOfClass:NSDictionary.class] || ![run[@"text"] isKindOfClass:NSString.class]) continue;
      NSFont *shown = font;
      if ([run[@"code"] boolValue]) shown = [NSFont monospacedSystemFontOfSize:font.pointSize*.84 weight:NSFontWeightRegular];
      else {
        if ([run[@"strong"] boolValue]) shown = [fonts convertFont:shown toHaveTrait:NSBoldFontMask];
        if ([run[@"em"] boolValue]) shown = [fonts convertFont:shown toHaveTrait:NSItalicFontMask];
      }
      NSMutableDictionary *attributes = [@{NSFontAttributeName:shown,NSForegroundColorAttributeName:ink,NSParagraphStyleAttributeName:paragraph} mutableCopy];
      // Links come from the page, so only web addresses stay clickable.
      NSString *href = [run[@"href"] isKindOfClass:NSString.class] ? run[@"href"] : nil;
      if ([href hasPrefix:@"http://"] || [href hasPrefix:@"https://"]) if (NSURL *url = [NSURL URLWithString:href]) attributes[NSLinkAttributeName] = url;
      [out appendAttributedString:[[NSAttributedString alloc] initWithString:run[@"text"] attributes:attributes]];
    }
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:@{NSFontAttributeName:font,NSParagraphStyleAttributeName:paragraph}]];
  };
  NSString *title = [article[@"title"] isKindOfClass:NSString.class] && [article[@"title"] length] ? article[@"title"] : fallbackTitle ?: @"";
  NSMutableArray *byline = [NSMutableArray array];
  if ([article[@"byline"] isKindOfClass:NSString.class] && [article[@"byline"] length]) [byline addObject:article[@"byline"]];
  if ([article[@"published"] isKindOfClass:NSString.class] && [article[@"published"] length]) {
    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init]; NSDate *date = [iso dateFromString:article[@"published"]];
    if (!date) { iso.formatOptions = NSISO8601DateFormatWithFullDate; date = [iso dateFromString:[article[@"published"] substringToIndex:MIN((NSUInteger)10,[article[@"published"] length])]]; }
    if (date) { NSDateFormatter *shown = [[NSDateFormatter alloc] init]; shown.dateStyle = NSDateFormatterLongStyle; shown.timeStyle = NSDateFormatterNoStyle; [byline addObject:[NSString stringWithFormat:@"Published %@",[shown stringFromDate:date]]]; }
  }
  plain(title,@{NSFontAttributeName:[NSFont fontWithName:@"Georgia" size:36] ?: [NSFont systemFontOfSize:36],NSForegroundColorAttributeName:Ink(),NSKernAttributeName:@(-.8),NSParagraphStyleAttributeName:style(41,byline.count ? 10 : 24)});
  if (byline.count) plain([byline componentsJoinedByString:@" · "],@{NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:Sub(),NSParagraphStyleAttributeName:style(16,24)});
  NSUInteger images = 0;
  NSArray *blocks = [article[@"blocks"] isKindOfClass:NSArray.class] ? article[@"blocks"] : @[];
  for (NSDictionary *block in blocks) {
    if (![block isKindOfClass:NSDictionary.class] || ![block[@"t"] isKindOfClass:NSString.class]) continue;
    NSString *t = block[@"t"];
    if ([t isEqual:@"p"]) runs(block[@"runs"],body,bodyInk,style(27.5,18));
    else if ([t isEqual:@"h"]) {
      const int level = [block[@"l"] intValue]; const CGFloat size = level<=2 ? 22 : level==3 ? 19 : 17;
      NSMutableParagraphStyle *p = style(ceil(size*1.25),8); p.paragraphSpacingBefore = 16;
      runs(block[@"runs"],[NSFont fontWithName:level>=4 ? @"Georgia-Bold" : @"Georgia" size:size] ?: body,Ink(),p);
    }
    else if ([t isEqual:@"q"]) {
      NSMutableParagraphStyle *p = style(27.5,16); p.firstLineHeadIndent = p.headIndent = 22;
      runs(block[@"runs"],[fonts convertFont:body toHaveTrait:NSItalicFontMask],Sub(),p);
    }
    else if ([t isEqual:@"li"]) {
      NSMutableParagraphStyle *p = style(27.5,7); p.headIndent = 24; p.firstLineHeadIndent = 4; p.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:24 options:@{}]];
      NSString *marker = block[@"n"] ? [NSString stringWithFormat:@"%d.\t",[block[@"n"] intValue]] : @"•\t";
      [out appendAttributedString:[[NSAttributedString alloc] initWithString:marker attributes:@{NSFontAttributeName:body,NSForegroundColorAttributeName:Sub(),NSParagraphStyleAttributeName:p}]];
      runs(block[@"runs"],body,bodyInk,p);
    }
    else if ([t isEqual:@"pre"] && [block[@"text"] isKindOfClass:NSString.class]) {
      NSTextBlock *panel = [[NSTextBlock alloc] init]; panel.backgroundColor = RailColor(0xf4f6f8);
      [panel setWidth:12 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
      NSMutableParagraphStyle *p = style(21,18); p.textBlocks = @[panel]; p.lineBreakMode = NSLineBreakByCharWrapping;
      plain(block[@"text"],@{NSFontAttributeName:mono,NSForegroundColorAttributeName:Ink(),NSParagraphStyleAttributeName:p});
    }
    else if ([t isEqual:@"cap"]) runs(block[@"runs"],[NSFont systemFontOfSize:12],Sub(),style(17,20));
    else if ([t isEqual:@"img"] && [block[@"src"] isKindOfClass:NSString.class] && images < 30) {
      images++;
      NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
      const CGFloat w = [block[@"w"] doubleValue], h = [block[@"h"] doubleValue], scale = w > ArticleWidth ? ArticleWidth/w : 1;
      // Room is kept when the size is known, so the text doesn't jump when the image arrives.
      attachment.bounds = w>0 && h>0 ? NSMakeRect(0,0,round(w*scale),round(h*scale)) : NSMakeRect(0,0,1,1);
      attachment.image = [[NSImage alloc] initWithSize:attachment.bounds.size];
      NSMutableAttributedString *image = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
      NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init]; p.paragraphSpacing = 12;
      [image addAttributes:@{RailImageSource:block[@"src"],NSParagraphStyleAttributeName:p} range:NSMakeRange(0,image.length)];
      [out appendAttributedString:image];
      [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:@{NSParagraphStyleAttributeName:p}]];
    }
  }
  return out;
}
