#import "ActivityView.h"
#import "Theme.h"

@implementation ActivityStep
@end
@implementation ActivityItem
@end

namespace {
NSColor *Ink() { return RailInk(); }
NSColor *Sub() { return RailMuted(); }
NSColor *Line() { return RailLine(); }
NSColor *Soft() { return RailTint(RailRoleLineSoft); }
NSColor *Accent() { return RailTint(RailRoleSelectedInk); }
NSMutableParagraphStyle *Clip() { NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init]; style.lineBreakMode = NSLineBreakByTruncatingTail; return style; }
void DrawSymbol(NSImage *image, NSRect frame) {
  NSSize size = image.size;
  [image drawInRect:NSMakeRect(NSMidX(frame)-size.width/2,NSMidY(frame)-size.height/2,size.width,size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}
// Reviewers: initials on a muted disc, with a small state badge. The disc colours identify
// people, so they stay the same in every theme.
void DrawAvatar(NSRect frame, NSString *initials, ProjectTone tone) {
  unsigned fills[] = {0x587089, 0x476d4e, 0x7a5838, 0x6b4fa6, 0x35618e};
  NSUInteger hash = 0; for (NSUInteger i = 0; i < initials.length; i++) hash = hash*31 + [initials characterAtIndex:i];
  [RailColor(fills[hash % 5]) setFill]; [[NSBezierPath bezierPathWithOvalInRect:frame] fill];
  NSDictionary *attrs = @{NSFontAttributeName:RailFont(8.5,NSFontWeightBold),NSForegroundColorAttributeName:NSColor.whiteColor};
  NSSize size = [initials sizeWithAttributes:attrs];
  [initials drawAtPoint:NSMakePoint(NSMidX(frame)-size.width/2,NSMidY(frame)-size.height/2) withAttributes:attrs];
  if (tone == ProjectToneNeutral || tone == ProjectToneUnknown) return;
  NSRect badge = NSMakeRect(NSMaxX(frame)-8,NSMaxY(frame)-8,11,11);
  [RailTint(RailRoleRaised) setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(badge,-1.5,-1.5)] fill];
  DrawSymbol(ProjectStateSymbol(tone,10), badge);
}
NSString *StageTitle(NSInteger stage) { return stage == 0 ? @"Needs you" : stage == 1 ? @"Waiting on others" : @"Ready to merge"; }
}

// A pull request in the list: state symbol, title, age, and project · number · reason.
@interface ActivityRowButton : NSButton
@property(nonatomic, strong) ActivityItem *item;
@property(nonatomic) BOOL selectedRow;
@property(nonatomic, copy) void (^handler)(void);
@end
@implementation ActivityRowButton {
  BOOL _hovered;
  NSTrackingArea *_area;
}
- (instancetype)initWithItem:(ActivityItem *)item {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _item = item; self.bordered = NO; self.title = @""; self.target = self; self.action = @selector(invoke:);
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@", item.title, item.project, item.reason];
    self.focusRingType = NSFocusRingTypeExterior;
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)invoke:(id)sender { (void)sender; if (_handler) _handler(); }
- (void)updateTrackingAreas {
  [super updateTrackingAreas]; if (_area) [self removeTrackingArea:_area];
  _area = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
  [self addTrackingArea:_area];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
  (void)dirty;
  NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8];
  if (_selectedRow) { [RailTint(RailRoleSelected) setFill]; [shape fill]; }
  else if (_hovered) { [RailTint(RailRoleContentHover) setFill]; [shape fill]; }
  if (self.window.firstResponder == self) { [RailTint(RailRoleFocus) setStroke]; NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:7 yRadius:7]; ring.lineWidth = 2; [ring stroke]; }
  CGFloat w = NSWidth(self.bounds);
  DrawSymbol(ProjectStateSymbol(_item.checksTone,13), NSMakeRect(9,9,16,16));
  NSDictionary *ageAttrs = @{NSFontAttributeName:RailDigitsFont(10,NSFontWeightRegular),NSForegroundColorAttributeName:_selectedRow ? Accent() : Sub()};
  CGFloat ageWidth = ceil([_item.age ?: @"" sizeWithAttributes:ageAttrs].width);
  [_item.age ?: @"" drawAtPoint:NSMakePoint(w-10-ageWidth,11) withAttributes:ageAttrs];
  [_item.title drawInRect:NSMakeRect(32,8,MAX(0,w-32-ageWidth-18),17) withAttributes:@{NSFontAttributeName:RailFont(12,NSFontWeightSemibold),NSForegroundColorAttributeName:_selectedRow ? Accent() : Ink(),NSParagraphStyleAttributeName:Clip()}];
  NSDictionary *plain = @{NSFontAttributeName:RailFont(11,NSFontWeightRegular),NSForegroundColorAttributeName:_selectedRow ? Accent() : Sub()};
  NSMutableAttributedString *line = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ · %@ · ",_item.project,_item.number] attributes:plain];
  BOOL strong = _item.reasonTone != ProjectToneNeutral && _item.reasonTone != ProjectToneUnknown;
  [line appendAttributedString:[[NSAttributedString alloc] initWithString:_item.reason ?: @"" attributes:@{NSFontAttributeName:RailFont(11,strong ? NSFontWeightMedium : NSFontWeightRegular),NSForegroundColorAttributeName:strong ? ProjectToneText(_item.reasonTone) : plain[NSForegroundColorAttributeName]}]];
  [line addAttribute:NSParagraphStyleAttributeName value:Clip() range:NSMakeRange(0,line.length)];
  [line drawInRect:NSMakeRect(32,28,MAX(0,w-42),16)];
}
@end

// A row in a detail list: state symbol or avatar, title, detail, and a chevron when it opens something.
@interface ActivityStepButton : NSButton
@property(nonatomic, strong) ActivityStep *step;
@property(nonatomic) BOOL divider;
@end
@implementation ActivityStepButton {
  BOOL _hovered;
  NSTrackingArea *_area;
}
- (instancetype)initWithStep:(ActivityStep *)step {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _step = step; self.bordered = NO; self.title = @""; self.target = self; self.action = @selector(invoke:);
    self.toolTip = step.help; self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", step.title, step.detail ?: @""];
    self.enabled = step.handler != nil; self.focusRingType = NSFocusRingTypeExterior;
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)invoke:(id)sender { (void)sender; if (_step.handler) _step.handler(); }
- (void)updateTrackingAreas {
  [super updateTrackingAreas]; if (_area) [self removeTrackingArea:_area];
  _area = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
  [self addTrackingArea:_area];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
  (void)dirty;
  CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
  if (_hovered && _step.handler) { [RailTint(RailRoleContentHover) setFill]; NSRectFill(self.bounds); }
  if (_divider) { [Soft() setFill]; NSRectFill(NSMakeRect(0,0,w,1)); }
  if (self.window.firstResponder == self) { [RailTint(RailRoleFocus) setStroke]; NSBezierPath *ring = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds,1,1)]; ring.lineWidth = 2; [ring stroke]; }
  if (_step.initials.length) DrawAvatar(NSMakeRect(13,(h-20)/2,20,20), _step.initials, _step.tone);
  else DrawSymbol(ProjectStateSymbol(_step.tone,13), NSMakeRect(14,(h-16)/2,16,16));
  CGFloat right = w - (_step.handler ? 34 : 14);
  NSDictionary *detailAttrs = @{NSFontAttributeName:RailDigitsFont(10.5,NSFontWeightRegular),NSForegroundColorAttributeName:Sub(),NSParagraphStyleAttributeName:Clip()};
  CGFloat detailWidth = MIN(MAX(0,(right-44)*.45), ceil([_step.detail ?: @"" sizeWithAttributes:detailAttrs].width)+2);
  NSMutableParagraphStyle *alignRight = Clip(); alignRight.alignment = NSTextAlignmentRight;
  [_step.detail ?: @"" drawInRect:NSMakeRect(right-detailWidth,(h-15)/2+1,detailWidth,15) withAttributes:@{NSFontAttributeName:detailAttrs[NSFontAttributeName],NSForegroundColorAttributeName:Sub(),NSParagraphStyleAttributeName:alignRight}];
  BOOL problem = _step.tone == ProjectToneCritical;
  [_step.title drawInRect:NSMakeRect(44,(h-16)/2,MAX(0,right-detailWidth-56),16) withAttributes:@{NSFontAttributeName:RailFont(11.5,NSFontWeightSemibold),NSForegroundColorAttributeName:problem ? ProjectToneText(ProjectToneCritical) : Ink(),NSParagraphStyleAttributeName:Clip()}];
  if (_step.handler) {
    NSImage *chevron = [RailSymbol(@"chevron.right",9) imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[Sub()]]];
    DrawSymbol(chevron, NSMakeRect(w-26,(h-14)/2,14,14));
  }
}
@end

@implementation ActivityView {
  NSScrollView *_listScroll, *_detailScroll;
  RailPanel *_listDocument, *_detailDocument, *_divider;
  NSMutableArray<ActivityRowButton *> *_rows;
  CGFloat _laidOutWidth;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.fill = RailTint(RailRoleContent); _rows = [NSMutableArray array];
    _listScroll = [self scrollWithDocument:&_listDocument fill:RailTint(RailRoleSunken)];
    _detailScroll = [self scrollWithDocument:&_detailDocument fill:RailTint(RailRoleContent)];
    _divider = [[RailPanel alloc] init]; _divider.fill = Line(); [self addSubview:_divider];
    // Boxes copy colours into their layers, so a new theme rebuilds the page.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:RailThemeDidChangeNotification object:nil];
  }
  return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (NSScrollView *)scrollWithDocument:(RailPanel *__strong *)document fill:(NSColor *)fill {
  NSScrollView *scroll = [[NSScrollView alloc] init]; scroll.drawsBackground = YES; scroll.backgroundColor = fill;
  scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES; scroll.horizontalScrollElasticity = NSScrollElasticityNone;
  *document = [[RailPanel alloc] init]; (*document).fill = fill; scroll.documentView = *document; [self addSubview:scroll];
  return scroll;
}
- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  if (fabs(NSWidth(self.bounds)-_laidOutWidth) > .5 || NSHeight(_listScroll.frame) != size.height) [self reload];
}
- (BOOL)acceptsFirstResponder { return YES; }
// Up and down move through the list from anywhere in the view.
- (void)keyDown:(NSEvent *)event {
  if (event.keyCode != 125 && event.keyCode != 126) { [super keyDown:event]; return; }
  NSArray<ActivityItem *> *ordered = [self orderedItems]; if (!ordered.count) return;
  NSInteger index = [ordered indexOfObjectPassingTest:^BOOL(ActivityItem *item, NSUInteger i, BOOL *stop) { (void)i; (void)stop; return [item.key isEqualToString:self.selectedKey]; }];
  index = index == NSNotFound ? 0 : MAX(0, MIN((NSInteger)ordered.count-1, index + (event.keyCode == 125 ? 1 : -1)));
  [self select:ordered[index].key];
  for (ActivityRowButton *row in _rows) if ([row.item.key isEqualToString:self.selectedKey]) { [row scrollRectToVisible:row.bounds]; [self.window makeFirstResponder:row]; }
}
- (NSArray<ActivityItem *> *)orderedItems {
  NSMutableArray *out = [NSMutableArray array];
  for (NSInteger stage = 0; stage < 3; stage++) for (ActivityItem *item in self.items) if (item.stage == stage) [out addObject:item];
  return out;
}
- (void)select:(NSString *)key {
  self.selectedKey = key; if (self.onSelect) self.onSelect(key);
  for (ActivityRowButton *row in _rows) { row.selectedRow = [row.item.key isEqualToString:key]; row.needsDisplay = YES; }
  [self layoutDetail];
}
- (ActivityItem *)selectedItem {
  for (ActivityItem *item in self.items) if ([item.key isEqualToString:self.selectedKey]) return item;
  return [self orderedItems].firstObject;
}

- (void)reload {
  CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds); _laidOutWidth = width;
  BOOL empty = !self.items.count;
  CGFloat listWidth = empty ? 0 : width >= 980 ? 372 : MAX(280, floor(width*.38));
  _listScroll.hidden = empty; _divider.hidden = empty;
  _listScroll.frame = NSMakeRect(0,0,listWidth,height); _divider.frame = NSMakeRect(listWidth,0,1,height);
  _detailScroll.frame = NSMakeRect(empty ? 0 : listWidth+1,0,width-(empty ? 0 : listWidth+1),height);
  NSUInteger selected = [self.items indexOfObjectPassingTest:^BOOL(ActivityItem *item, NSUInteger i, BOOL *stop) { (void)i; (void)stop; return [item.key isEqualToString:self.selectedKey]; }];
  if (!empty && selected == NSNotFound) self.selectedKey = [self orderedItems].firstObject.key;
  [self layoutList:listWidth];
  [self layoutDetail];
}

- (CGFloat)headerIn:(RailPanel *)document x:(CGFloat)x width:(CGFloat)width {
  __weak ActivityView *weak = self;
  NSTextField *title = RailLabel(@"Activity",19,NSFontWeightBold,Ink()); title.frame = NSMakeRect(x,20,200,26); [document addSubview:title];
  if (self.checking) {
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(x+width-22,25,16,16)]; spinner.style = NSProgressIndicatorStyleSpinning; spinner.controlSize = NSControlSizeSmall;
    [spinner startAnimation:nil]; [document addSubview:spinner];
  } else {
    RailButton *check = RailAction(@"",@"arrow.clockwise",@"Check now",^{ if (weak.onCheckNow) weak.onCheckNow(); }); check.centered = YES; check.ink = Sub();
    check.frame = NSMakeRect(x+width-28,19,28,28); [document addSubview:check];
  }
  NSTextField *summary = RailLabel(self.summary,11,NSFontWeightRegular,Sub()); summary.lineBreakMode = NSLineBreakByTruncatingTail;
  summary.frame = NSMakeRect(x,50,width,16); [document addSubview:summary];
  return 82;
}

- (void)layoutList:(CGFloat)width {
  NSPoint offset = _listScroll.contentView.bounds.origin;
  for (NSView *v in [_listDocument.subviews copy]) [v removeFromSuperview];
  [_rows removeAllObjects];
  if (!self.items.count) return;
  CGFloat y = [self headerIn:_listDocument x:18 width:width-36];
  __weak ActivityView *weak = self;
  for (NSInteger stage = 0; stage < 3; stage++) {
    NSMutableArray<ActivityItem *> *members = [NSMutableArray array];
    for (ActivityItem *item in self.items) if (item.stage == stage) [members addObject:item];
    if (!members.count) continue;
    NSTextField *heading = RailLabel([NSString stringWithFormat:@"%@  %lu",StageTitle(stage),(unsigned long)members.count],10.5,NSFontWeightSemibold,Sub());
    heading.frame = NSMakeRect(18,y,width-36,15); [_listDocument addSubview:heading]; y += 21;
    for (ActivityItem *item in members) {
      ActivityRowButton *row = [[ActivityRowButton alloc] initWithItem:item]; row.selectedRow = [item.key isEqualToString:self.selectedKey];
      NSString *key = item.key; row.handler = ^{ [weak select:key]; };
      row.frame = NSMakeRect(8,y,width-16,52); [_listDocument addSubview:row]; [_rows addObject:row]; y += 54;
    }
    y += 12;
  }
  _listDocument.frame = NSMakeRect(0,0,width,MAX(y+12,NSHeight(_listScroll.contentView.bounds)));
  [_listScroll.contentView scrollToPoint:NSMakePoint(0,MIN(offset.y,MAX(0,y-NSHeight(_listScroll.bounds))))];
  [_listScroll reflectScrolledClipView:_listScroll.contentView];
}

- (CGFloat)section:(NSString *)title caption:(NSString *)caption steps:(NSArray<ActivityStep *> *)steps empty:(NSString *)empty x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
  NSTextField *heading = RailLabel(title,11,NSFontWeightSemibold,Ink()); [heading sizeToFit]; heading.frame = NSMakeRect(x,y,NSWidth(heading.frame),16); [_detailDocument addSubview:heading];
  if (caption.length) { NSTextField *sub = RailLabel(caption,11,NSFontWeightRegular,Sub()); sub.frame = NSMakeRect(x+NSWidth(heading.frame)+8,y,width-NSWidth(heading.frame)-8,16); sub.lineBreakMode = NSLineBreakByTruncatingTail; [_detailDocument addSubview:sub]; }
  y += 24;
  RailPanel *box = [[RailPanel alloc] initWithFrame:NSMakeRect(x,y,width,40)]; box.fill = RailTint(RailRoleRaised);
  box.wantsLayer = YES; box.layer.cornerRadius = 10; box.layer.borderWidth = 1; box.layer.borderColor = Line().CGColor; box.layer.masksToBounds = YES;
  CGFloat by = 0;
  if (!steps.count) {
    NSTextField *none = RailLabel(empty,11.5,NSFontWeightRegular,Sub()); none.frame = NSMakeRect(14,12,width-28,16); [box addSubview:none]; by = 40;
  }
  for (NSUInteger i = 0; i < steps.count; i++) {
    ActivityStepButton *row = [[ActivityStepButton alloc] initWithStep:steps[i]]; row.divider = i > 0;
    row.frame = NSMakeRect(0,by,width,40); [box addSubview:row]; by += 40;
  }
  box.frame = NSMakeRect(x,y,width,by); [_detailDocument addSubview:box];
  return y + by + 26;
}

- (void)layoutDetail {
  for (NSView *v in [_detailDocument.subviews copy]) [v removeFromSuperview];
  CGFloat width = NSWidth(_detailScroll.frame), margin = width > 700 ? 34 : 22, content = MAX(240, width-margin*2);
  ActivityItem *item = [self selectedItem];
  if (!item) { [self layoutEmpty:width]; return; }
  CGFloat y = 24, x = margin;
  RailPanel *badge = [[RailPanel alloc] initWithFrame:NSMakeRect(x,y+2,26,26)]; badge.fill = item.provider == 2 ? RailColor(0x2d3b4d) : RailColor(0x2f6fb8);
  badge.wantsLayer = YES; badge.layer.cornerRadius = 7; badge.layer.masksToBounds = YES;
  NSImageView *icon = [NSImageView imageViewWithImage:RailSymbol(item.provider == 2 ? @"chevron.left.forwardslash.chevron.right" : @"infinity",12)]; icon.contentTintColor = NSColor.whiteColor; icon.frame = NSMakeRect(4,4,18,18); [badge addSubview:icon];
  [_detailDocument addSubview:badge];
  CGFloat textX = x + 38;
  RailButton *open = nil;
  if (item.open) {
    open = RailAction(item.openTitle ?: @"Open",nil,item.openTitle,item.open);
    open.font = RailFont(11.5,NSFontWeightMedium); open.stroke = Line(); open.normalFill = RailTint(RailRoleRaised); open.hoverFill = RailTint(RailRoleContentHover); open.cornerRadius = 7; open.centered = YES;
    CGFloat w = ceil([open.title sizeWithAttributes:@{NSFontAttributeName:open.font}].width) + 28;
    open.frame = NSMakeRect(x+content-w,y+1,w,30); [_detailDocument addSubview:open];
  }
  CGFloat titleWidth = content - 38 - (open ? NSWidth(open.frame)+16 : 0);
  NSTextField *title = RailLabel(item.title,19,NSFontWeightBold,Ink());
  title.lineBreakMode = NSLineBreakByWordWrapping; title.maximumNumberOfLines = 2; title.cell.wraps = YES; title.cell.truncatesLastVisibleLine = YES; title.preferredMaxLayoutWidth = titleWidth;
  CGFloat titleHeight = ceil([title.cell cellSizeForBounds:NSMakeRect(0,0,titleWidth,100)].height);
  title.frame = NSMakeRect(textX,y,titleWidth,titleHeight); [_detailDocument addSubview:title];
  y += titleHeight + 4;
  NSString *meta = [@[item.project, item.number, item.branches ?: @"", item.opened ?: @""] componentsJoinedByString:@" · "];
  NSTextField *metaField = RailLabel(meta,11,NSFontWeightRegular,Sub()); metaField.lineBreakMode = NSLineBreakByTruncatingTail; metaField.toolTip = meta;
  metaField.frame = NSMakeRect(textX,y,content-38,16); [_detailDocument addSubview:metaField];
  y += 32;
  CGFloat px = x;
  for (ProjectPill *pill in item.pills) {
    NSFont *font = RailFont(11,NSFontWeightSemibold);
    CGFloat w = ceil([pill.title sizeWithAttributes:@{NSFontAttributeName:font}].width) + (pill.symbol ? 40 : 20);
    if (px > x && px + w > x + content) break;
    RailButton *button = RailAction(pill.title,pill.symbol,pill.help ?: pill.title,pill.handler);
    button.font = font; button.cornerRadius = 5; button.normalFill = ProjectToneFill(pill.tone); button.ink = ProjectToneText(pill.tone); button.hoverFill = ProjectToneFill(pill.tone);
    if (pill.symbol) button.image = RailSymbol(pill.symbol,11);
    button.frame = NSMakeRect(px,y,w,23); [_detailDocument addSubview:button]; px += w + 6;
  }
  if (item.pills.count) y += 41;
  y = [self section:@"Checks" caption:nil steps:item.checks empty:@"No checks reported for this pull request." x:x y:y width:content];
  if (item.policies.count) y = [self section:@"Policies" caption:nil steps:item.policies empty:@"" x:x y:y width:content];
  y = [self section:@"Reviewers" caption:nil steps:item.reviewers empty:@"No reviewers yet." x:x y:y width:content];
  _detailDocument.frame = NSMakeRect(0,0,width,MAX(y,NSHeight(_detailScroll.contentView.bounds)));
  [_detailScroll.contentView scrollToPoint:NSZeroPoint]; [_detailScroll reflectScrolledClipView:_detailScroll.contentView];
}

- (void)layoutEmpty:(CGFloat)width {
  CGFloat margin = width > 900 ? 40 : 24, content = MAX(320, width-margin*2);
  CGFloat y = [self headerIn:_detailDocument x:margin width:content];
  RailPanel *box = [[RailPanel alloc] initWithFrame:NSMakeRect(margin,y+8,content,100)]; box.fill = RailTint(RailRoleSunken);
  box.wantsLayer = YES; box.layer.cornerRadius = 12; box.layer.borderWidth = 1; box.layer.borderColor = Soft().CGColor;
  NSTextField *heading = RailLabel(self.emptyTitle ?: @"No open pull requests of yours",15,NSFontWeightBold,Ink()); heading.frame = NSMakeRect(24,24,content-48,22); [box addSubview:heading];
  NSTextField *copy = RailLabel(self.emptyDetail ?: @"",12,NSFontWeightRegular,Sub());
  copy.lineBreakMode = NSLineBreakByWordWrapping; copy.maximumNumberOfLines = 4; copy.cell.wraps = YES; CGFloat copyWidth = MIN(560,content-48); copy.preferredMaxLayoutWidth = copyWidth;
  CGFloat h = ceil([copy.cell cellSizeForBounds:NSMakeRect(0,0,copyWidth,200)].height);
  copy.frame = NSMakeRect(24,52,copyWidth,h); [box addSubview:copy];
  box.frame = NSMakeRect(margin,y+8,content,52+h+24); [_detailDocument addSubview:box];
  _detailDocument.frame = NSMakeRect(0,0,width,MAX(NSMaxY(box.frame)+30,NSHeight(_detailScroll.contentView.bounds)));
}
@end
