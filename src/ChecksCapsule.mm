#import "ChecksCapsule.h"

namespace {
const CGFloat ListWidth = 392, MaxListHeight = 540;
NSColor *Ink() { return RailTint(RailRoleInk); }
NSColor *Sub() { return RailTint(RailRoleMuted); }
NSMutableParagraphStyle *Clip() { NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init]; style.lineBreakMode = NSLineBreakByTruncatingTail; return style; }
void DrawSymbol(NSImage *image, NSRect frame) {
  [image drawInRect:NSMakeRect(NSMidX(frame)-image.size.width/2,NSMidY(frame)-image.size.height/2,image.size.width,image.size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}
CGFloat TextWidth(NSString *text, NSFont *font) { return ceil([text ?: @"" sizeWithAttributes:@{NSFontAttributeName:font}].width); }
RailButton *SmallAction(NSString *title, BOOL primary, void (^handler)(void)) {
  RailButton *button = RailAction(title,nil,title,handler); button.font = RailFont(11,NSFontWeightSemibold); button.centered = YES; button.cornerRadius = 7;
  if (primary) { button.normalFill = RailTint(RailRoleSelected); button.hoverFill = RailTint(RailRoleSelectedHover); button.ink = RailTint(RailRoleSelectedInk); }
  else { button.normalFill = RailTint(RailRoleRaised); button.hoverFill = RailTint(RailRoleContentHover); button.stroke = RailTint(RailRoleLineStrong); }
  return button;
}
RailButton *DismissAction(void (^handler)(void), NSColor *ink) {
  RailButton *button = RailAction(@"",@"xmark",@"Dismiss",handler); button.centered = YES; button.ink = ink; button.cornerRadius = 6;
  return button;
}
}

@implementation ChecksEntry
@end

@implementation ChecksCapsule {
  BOOL _hovered;
  NSTrackingArea *_area;
  RailButton *_openButton, *_dismissButton;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.bordered = NO; self.title = @""; self.target = self; self.action = @selector(invoke:); self.focusRingType = NSFocusRingTypeExterior;
    self.toolTip = @"Checks (⌘ ⇧ K)"; self.clipsToBounds = YES;
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)invoke:(id)sender { (void)sender; if (_onToggle) _onToggle(); }
- (void)updateTrackingAreas {
  [super updateTrackingAreas]; if (_area) [self removeTrackingArea:_area];
  _area = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
  [self addTrackingArea:_area];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }
- (NSArray *)segments {
  NSMutableArray *segments = [NSMutableArray array];
  if (_running) [segments addObject:@[@(ProjectToneRunning),@(_running)]];
  if (_waiting) [segments addObject:@[@(ProjectToneWarn),@(_waiting)]];
  // An announced failure already says so itself; only further ones need counting.
  NSInteger failed = _announceTitle && _announceTone == ProjectToneCritical ? _failed - 1 : _failed;
  if (failed > 0) [segments addObject:@[@(ProjectToneCritical),@(failed)]];
  if (_passed) [segments addObject:@[@(ProjectToneOK),@(_passed)]];
  return segments;
}
- (CGFloat)segmentsWidth {
  CGFloat width = 0; NSFont *font = RailDigitsFont(11.5,NSFontWeightSemibold);
  for (NSArray *segment in [self segments]) width += 18 + TextWidth([segment[1] stringValue],font) + 8;
  return width;
}
- (CGFloat)announceTextWidth {
  return TextWidth(_announceTitle,RailFont(11.5,NSFontWeightSemibold)) + (_announceDetail.length ? 6 + TextWidth(_announceDetail,RailFont(11.5,NSFontWeightRegular)) : 0);
}
- (CGFloat)buttonsWidth { return (_onOpenAnnounced ? 72 : 0) + (_onDismissAnnounced ? 24 : 0); }
- (CGFloat)preferredWidth {
  CGFloat warning = _warning ? 22 : 0, segments = [self segmentsWidth];
  if (_announceTitle) return ceil(10 + 20 + [self announceTextWidth] + 8 + [self buttonsWidth] + segments + warning + 8);
  return ceil(MAX(30, 10 + warning + segments + (segments || warning ? 2 : 10)));
}
- (void)reload {
  [_openButton removeFromSuperview]; [_dismissButton removeFromSuperview]; _openButton = nil; _dismissButton = nil;
  __weak ChecksCapsule *weak = self;
  if (_announceTitle && _onOpenAnnounced) { _openButton = RailAction(@"Open run",nil,@"Open run",^{ ChecksCapsule *strong = weak; if (strong.onOpenAnnounced) strong.onOpenAnnounced(); }); _openButton.font = RailFont(11,NSFontWeightSemibold); _openButton.centered = YES; _openButton.cornerRadius = 11; _openButton.normalFill = RailTint(RailRoleRaised); _openButton.hoverFill = RailTint(RailRoleContentHover); [self addSubview:_openButton]; }
  if (_announceTitle && _onDismissAnnounced) { _dismissButton = DismissAction(^{ ChecksCapsule *strong = weak; if (strong.onDismissAnnounced) strong.onDismissAnnounced(); },ProjectToneText(_announceTone)); [self addSubview:_dismissButton]; }
  NSMutableArray *words = [NSMutableArray array];
  if (_running) [words addObject:[NSString stringWithFormat:@"%ld running",(long)_running]];
  if (_waiting) [words addObject:[NSString stringWithFormat:@"%ld waiting for approval",(long)_waiting]];
  if (_failed) [words addObject:[NSString stringWithFormat:@"%ld failed",(long)_failed]];
  if (_passed) [words addObject:[NSString stringWithFormat:@"%ld passed",(long)_passed]];
  if (_warning) [words addObject:@"may be out of date"];
  self.accessibilityLabel = _announceTitle ? [NSString stringWithFormat:@"%@ %@",_announceTitle,_announceDetail ?: @""] : words.count ? [@"Checks: " stringByAppendingString:[words componentsJoinedByString:@", "]] : @"Checks";
  [self layoutButtons]; self.needsDisplay = YES;
}
- (void)layoutButtons {
  CGFloat x = NSWidth(self.bounds) - [self segmentsWidth] - 4 - (_warning ? 22 : 0), h = NSHeight(self.bounds);
  if (_dismissButton) { x -= 24; _dismissButton.frame = NSMakeRect(x,(h-22)/2,22,22); }
  if (_openButton) { x -= 68; _openButton.frame = NSMakeRect(x,(h-22)/2,64,22); }
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self layoutButtons]; }
- (void)drawRect:(NSRect)dirty {
  (void)dirty;
  CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
  NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:(h-1)/2 yRadius:(h-1)/2];
  NSColor *fill = _announceTitle ? ProjectToneFill(_announceTone) : _listOpen ? RailTint(RailRoleSelected) : RailTint(RailRoleField);
  if (_hovered && !_listOpen) fill = [fill blendedColorWithFraction:.06 ofColor:Ink()];
  [fill setFill]; [shape fill];
  if (!_announceTitle) { [(_listOpen ? RailTint(RailRoleAccent) : RailTint(RailRoleLine)) setStroke]; shape.lineWidth = 1; [shape stroke]; }
  if (self.window.firstResponder == self) { [RailTint(RailRoleFocus) setStroke]; shape.lineWidth = 2; [shape stroke]; }
  CGFloat x = 10;
  if (_announceTitle) {
    DrawSymbol(ProjectStateSymbol(_announceTone,13), NSMakeRect(x,(h-16)/2,16,16)); x += 20;
    CGFloat room = w - x - 8 - [self buttonsWidth] - [self segmentsWidth] - (_warning ? 22 : 0);
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] initWithString:_announceTitle attributes:@{NSFontAttributeName:RailFont(11.5,NSFontWeightSemibold),NSForegroundColorAttributeName:ProjectToneText(_announceTone),NSParagraphStyleAttributeName:Clip()}];
    if (_announceDetail.length) [line appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:_announceDetail] attributes:@{NSFontAttributeName:RailFont(11.5,NSFontWeightRegular),NSForegroundColorAttributeName:Ink(),NSParagraphStyleAttributeName:Clip()}]];
    [line drawInRect:NSMakeRect(x,(h-16)/2,MAX(0,room),16)];
    x = w - [self segmentsWidth] - (_warning ? 22 : 0) - 4;
  }
  if (_warning) {
    NSImage *symbol = [RailSymbol(@"exclamationmark.triangle.fill",12) imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[RailTint(RailRoleWarnDot)]]];
    DrawSymbol(symbol, NSMakeRect(x,(h-16)/2,18,16)); x += 22;
  }
  NSDictionary *digits = @{NSFontAttributeName:RailDigitsFont(11.5,NSFontWeightSemibold),NSForegroundColorAttributeName:Ink()};
  NSArray *segments = [self segments];
  for (NSArray *segment in segments) {
    DrawSymbol(ProjectStateSymbol((ProjectTone)[segment[0] integerValue],13), NSMakeRect(x,(h-16)/2,16,16)); x += 18;
    NSString *count = [segment[1] stringValue]; [count drawAtPoint:NSMakePoint(x,(h-15)/2) withAttributes:digits]; x += TextWidth(count,digits[NSFontAttributeName]) + 8;
  }
  // Only finished runs left to look through.
  if (!_announceTitle && !segments.count && !_warning) {
    NSImage *symbol = [RailSymbol(@"checklist",12) imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[Sub()]]];
    DrawSymbol(symbol, self.bounds);
  }
}
@end

// One run in the list. Clicking it opens the run.
@interface ChecksRow : NSButton
- (instancetype)initWithEntry:(ChecksEntry *)entry;
@end
@implementation ChecksRow {
  ChecksEntry *_entry;
  BOOL _hovered;
  NSTrackingArea *_area;
}
- (instancetype)initWithEntry:(ChecksEntry *)entry {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _entry = entry; self.bordered = NO; self.title = @""; self.target = self; self.action = @selector(invoke:); self.focusRingType = NSFocusRingTypeExterior;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@",entry.title,entry.detail,entry.age];
    if (entry.section == 0 || entry.section == 1) {
      __weak ChecksEntry *weak = entry;
      RailButton *open = SmallAction(@"Open run",YES,^{ if (weak.open) weak.open(); }); open.frame = NSMakeRect(38,50,70,26); [self addSubview:open];
      if (entry.showInActivity) { RailButton *show = SmallAction(@"Show in Activity",NO,^{ if (weak.showInActivity) weak.showInActivity(); }); show.frame = NSMakeRect(114,50,114,26); [self addSubview:show]; }
      if (entry.dismiss) { RailButton *dismiss = DismissAction(^{ if (weak.dismiss) weak.dismiss(); },Sub()); dismiss.frame = NSMakeRect(ListWidth-40,50,26,26); [self addSubview:dismiss]; }
    }
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)invoke:(id)sender { (void)sender; if (_entry.open) _entry.open(); }
- (void)updateTrackingAreas {
  [super updateTrackingAreas]; if (_area) [self removeTrackingArea:_area];
  _area = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
  [self addTrackingArea:_area];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
  (void)dirty;
  CGFloat w = NSWidth(self.bounds);
  BOOL urgent = _entry.section == 0 || _entry.section == 1;
  if (urgent) { [ProjectToneFill(_entry.tone) setFill]; NSRectFill(self.bounds); }
  if (_hovered) { [[Ink() colorWithAlphaComponent:.05] setFill]; NSRectFillUsingOperation(self.bounds,NSCompositingOperationSourceOver); }
  if (self.window.firstResponder == self) { [RailTint(RailRoleFocus) setStroke]; NSBezierPath *ring = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds,1,1)]; ring.lineWidth = 2; [ring stroke]; }
  DrawSymbol(ProjectStateSymbol(_entry.tone,14), NSMakeRect(14,8,16,16));
  NSDictionary *age = @{NSFontAttributeName:RailDigitsFont(11,NSFontWeightRegular),NSForegroundColorAttributeName:Sub()};
  CGFloat ageWidth = ceil([_entry.age ?: @"" sizeWithAttributes:age].width);
  [_entry.age ?: @"" drawAtPoint:NSMakePoint(w-14-ageWidth,9) withAttributes:age];
  [_entry.title drawInRect:NSMakeRect(38,8,MAX(0,w-38-ageWidth-22),17) withAttributes:@{NSFontAttributeName:RailFont(12,NSFontWeightSemibold),NSForegroundColorAttributeName:urgent ? ProjectToneText(_entry.tone) : Ink(),NSParagraphStyleAttributeName:Clip()}];
  [_entry.detail drawInRect:NSMakeRect(38,26,MAX(0,w-52),15) withAttributes:@{NSFontAttributeName:RailFont(11,NSFontWeightRegular),NSForegroundColorAttributeName:Sub(),NSParagraphStyleAttributeName:Clip()}];
}
@end

@implementation ChecksListView {
  NSScrollView *_scroll;
  RailPanel *_document;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.fill = RailTint(RailRoleRaised);
    _scroll = [[NSScrollView alloc] init]; _scroll.drawsBackground = NO; _scroll.hasVerticalScroller = YES; _scroll.autohidesScrollers = YES; _scroll.horizontalScrollElasticity = NSScrollElasticityNone;
    _document = [[RailPanel alloc] init]; _scroll.documentView = _document; [self addSubview:_scroll];
  }
  return self;
}
- (NSSize)reload {
  self.fill = RailTint(RailRoleRaised); _document.fill = RailTint(RailRoleRaised); self.needsDisplay = YES;
  NSPoint offset = _scroll.contentView.bounds.origin;
  for (NSView *v in [_document.subviews copy]) [v removeFromSuperview];
  CGFloat y = 12; __weak ChecksListView *weak = self;
  NSTextField *heading = RailLabel(@"Checks",13,NSFontWeightBold,Ink()); heading.frame = NSMakeRect(14,y,200,18); [_document addSubview:heading]; y += 26;
  for (NSUInteger i = 0; i < _warnings.count; i++) {
    RailButton *warning = RailAction(_warnings[i],@"exclamationmark.triangle.fill",_warnings[i],^{ ChecksListView *strong = weak; if (strong.onWarning) strong.onWarning(i); });
    warning.font = RailFont(11.5,NSFontWeightMedium); warning.ink = ProjectToneText(ProjectToneWarn); warning.normalFill = ProjectToneFill(ProjectToneWarn); warning.hoverFill = [ProjectToneFill(ProjectToneWarn) blendedColorWithFraction:.06 ofColor:Ink()]; warning.cornerRadius = 8;
    warning.frame = NSMakeRect(10,y,ListWidth-20,32); [_document addSubview:warning]; y += 38;
  }
  NSArray *titles = @[@"Failed",@"Waiting for approval",@"Running",@"Finished"];
  for (NSInteger section = 0; section < 4; section++) {
    NSMutableArray<ChecksEntry *> *members = [NSMutableArray array];
    for (ChecksEntry *entry in _entries) if (entry.section == section) [members addObject:entry];
    if (!members.count) continue;
    NSTextField *title = RailLabel(section == 0 ? titles[section] : [NSString stringWithFormat:@"%@  %lu",titles[section],(unsigned long)members.count],10.5,NSFontWeightSemibold,Sub());
    title.frame = NSMakeRect(14,y+4,240,15); [_document addSubview:title];
    if (section == 3 && _onClear) {
      RailButton *clear = RailAction(@"Clear",nil,@"Remove finished runs from this list",^{ ChecksListView *strong = weak; if (strong.onClear) strong.onClear(); });
      clear.font = RailFont(11,NSFontWeightMedium); clear.ink = RailTint(RailRoleAccent); clear.hoverFill = RailTint(RailRoleContentHover); clear.centered = YES; clear.frame = NSMakeRect(ListWidth-60,y,50,22); [_document addSubview:clear];
    }
    y += 24;
    for (ChecksEntry *entry in members) {
      ChecksRow *row = [[ChecksRow alloc] initWithEntry:entry];
      CGFloat h = section <= 1 ? 86 : 48; row.frame = NSMakeRect(0,y,ListWidth,h); [_document addSubview:row]; y += h;
    }
    y += 6;
  }
  if (!_entries.count && !_warnings.count) {
    NSTextField *none = RailLabel(@"Nothing to follow right now.",11.5,NSFontWeightRegular,Sub()); none.frame = NSMakeRect(14,y,ListWidth-28,16); [_document addSubview:none]; y += 24;
  }
  y += 6;
  CGFloat height = MIN(y,MaxListHeight);
  _document.frame = NSMakeRect(0,0,ListWidth,y);
  // Size only: the popover owns this view's origin, and resetting it pushes the list out of place.
  [self setFrameSize:NSMakeSize(ListWidth,height)]; _scroll.frame = self.bounds;
  [_scroll.contentView scrollToPoint:NSMakePoint(0,MIN(offset.y,MAX(0,y-height)))]; [_scroll reflectScrolledClipView:_scroll.contentView];
  return NSMakeSize(ListWidth,height);
}
@end
