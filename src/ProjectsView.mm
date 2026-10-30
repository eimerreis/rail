#import "ProjectsView.h"

@implementation ProjectPill
@end
@implementation ProjectRow
@end
@implementation ProjectChip
@end
@implementation ProjectCard
@end

namespace {
NSColor *Ink() { return RailColor(0x273445); }
NSColor *Sub() { return RailColor(0x596879); }
NSColor *Line() { return RailColor(0xd4dde5); }
NSColor *ToneText(ProjectTone tone) {
  switch (tone) {
    case ProjectToneCritical: return RailColor(0xb03a2c);
    case ProjectToneWarn: case ProjectToneBusy: return RailColor(0x8a5a0c);
    case ProjectToneOK: return RailColor(0x2c7347);
    case ProjectToneInfo: case ProjectToneRunning: return RailColor(0x245b96);
    default: return Sub();
  }
}
NSColor *ToneFill(ProjectTone tone) {
  switch (tone) {
    case ProjectToneCritical: return RailColor(0xfbe6e2);
    case ProjectToneWarn: case ProjectToneBusy: return RailColor(0xfbf0d8);
    case ProjectToneOK: return RailColor(0xe3f1e7);
    case ProjectToneInfo: case ProjectToneRunning: return RailColor(0xd8e7f7);
    default: return RailColor(0xedf1f5);
  }
}
// Status dots: filled for a known state, a ring for stopped or in progress.
void DrawDot(NSRect frame, ProjectTone tone) {
  NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:frame];
  switch (tone) {
    case ProjectToneCritical:
      [[RailColor(0xd9533f) colorWithAlphaComponent:.2] setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(frame,-2.5,-2.5)] fill];
      [RailColor(0xd9533f) setFill]; [dot fill]; break;
    case ProjectToneWarn: [RailColor(0xd1912a) setFill]; [dot fill]; break;
    case ProjectToneOK: [RailColor(0x3f9a5f) setFill]; [dot fill]; break;
    case ProjectToneRunning: case ProjectToneInfo: [RailColor(0x3a72b5) setFill]; [dot fill]; break;
    case ProjectToneStopped: { NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(frame,.75,.75)]; ring.lineWidth = 1.5; [RailColor(0xa3afbc) setStroke]; [ring stroke]; break; }
    case ProjectToneBusy: {
      NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(frame,.75,.75)]; ring.lineWidth = 1.5; [RailColor(0xd1912a) setStroke]; [ring stroke];
      NSBezierPath *half = [NSBezierPath bezierPath]; NSPoint c = NSMakePoint(NSMidX(frame),NSMidY(frame));
      [half moveToPoint:c]; [half appendBezierPathWithArcWithCenter:c radius:NSWidth(frame)/2-2 startAngle:-90 endAngle:90 clockwise:NO]; [half closePath];
      [RailColor(0xd1912a) setFill]; [half fill]; break;
    }
    case ProjectToneUnknown: [RailColor(0xc8d1db) setFill]; [dot fill]; break;
    default: break;
  }
}
void DrawMark(NSRect frame, NSString *mark, NSInteger style) {
  unsigned fills[] = {0xdae6f4, 0xdeebdf, 0xeee2d5}, inks[] = {0x3c5f88, 0x476d4e, 0x7a5838};
  NSInteger i = MAX(0, MIN(2, style));
  [RailColor(fills[i]) setFill]; [[NSBezierPath bezierPathWithRoundedRect:frame xRadius:4 yRadius:4] fill];
  NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:9 weight:NSFontWeightSemibold], NSForegroundColorAttributeName:RailColor(inks[i])};
  NSSize size = [mark sizeWithAttributes:attrs];
  [mark drawAtPoint:NSMakePoint(NSMidX(frame)-size.width/2, NSMidY(frame)-size.height/2) withAttributes:attrs];
}
CGFloat TextWidth(NSString *text, NSFont *font) { return ceil([text ?: @"" sizeWithAttributes:@{NSFontAttributeName:font}].width); }
NSTextField *Wrapping(NSString *text, CGFloat size, NSColor *color, CGFloat width, CGFloat *height) {
  NSTextField *field = RailLabel(text, size, NSFontWeightRegular, color);
  field.lineBreakMode = NSLineBreakByWordWrapping; field.maximumNumberOfLines = 4; field.preferredMaxLayoutWidth = width;
  field.cell.wraps = YES; field.cell.truncatesLastVisibleLine = YES;
  NSSize fit = [field.cell cellSizeForBounds:NSMakeRect(0,0,width,200)];
  *height = ceil(fit.height); return field;
}
}

// A button in the card's stack: icon, label, status dot and value, session marker.
@interface ProjectRowButton : NSButton
@property(nonatomic, strong) ProjectRow *row;
@end
@implementation ProjectRowButton {
  BOOL _hovered;
  NSTrackingArea *_area;
}
- (instancetype)initWithRow:(ProjectRow *)row {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _row = row; self.bordered = NO; self.title = @""; self.target = self; self.action = @selector(invoke:);
    self.toolTip = row.help; self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", row.label, row.value ?: @""]; self.menu = row.menu;
    self.focusRingType = NSFocusRingTypeExterior;
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)invoke:(id)sender { (void)sender; if (_row.handler) _row.handler(); }
- (void)updateTrackingAreas {
  [super updateTrackingAreas]; if (_area) [self removeTrackingArea:_area];
  _area = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
  [self addTrackingArea:_area];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
  (void)dirty;
  NSRect bounds = NSInsetRect(self.bounds,.5,.5);
  NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:7 yRadius:7];
  [(_hovered ? RailColor(0xf1f5f9) : NSColor.whiteColor) setFill]; [shape fill];
  [(_hovered ? RailColor(0xbfccd9) : Line()) setStroke]; shape.lineWidth = 1; [shape stroke];
  if (self.window.firstResponder == self) { [RailColor(0x3976be) setStroke]; shape.lineWidth = 2; [shape stroke]; }
  CGFloat h = NSHeight(self.bounds), x = 10;
  if (_row.symbol.length) {
    NSImage *icon = [RailSymbol(_row.symbol,12) imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[Sub()]]];
    NSSize size = icon.size; [icon drawInRect:NSMakeRect(x+(15-size.width)/2,(h-size.height)/2,size.width,size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
  }
  x += 24;
  NSFont *labelFont = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
  NSMutableParagraphStyle *clip = [[NSMutableParagraphStyle alloc] init]; clip.lineBreakMode = NSLineBreakByTruncatingTail;
  [_row.label drawInRect:NSMakeRect(x,(h-15)/2,64,15) withAttributes:@{NSFontAttributeName:labelFont,NSForegroundColorAttributeName:Ink(),NSParagraphStyleAttributeName:clip}];
  x += 70;
  CGFloat right = NSWidth(self.bounds) - (_row.mark.length ? 33 : 10);
  if (_row.tone != ProjectToneNeutral) { DrawDot(NSMakeRect(x,(h-8)/2,8,8),_row.tone); x += 15; }
  BOOL strong = _row.tone == ProjectToneCritical || _row.tone == ProjectToneWarn;
  NSFont *valueFont = [NSFont monospacedDigitSystemFontOfSize:11 weight:strong ? NSFontWeightMedium : NSFontWeightRegular];
  [_row.value ?: @"" drawInRect:NSMakeRect(x,(h-15)/2,MAX(0,right-x),15) withAttributes:@{NSFontAttributeName:valueFont,NSForegroundColorAttributeName:strong ? ToneText(_row.tone) : Sub(),NSParagraphStyleAttributeName:clip}];
  if (_row.mark.length) DrawMark(NSMakeRect(NSWidth(self.bounds)-27,(h-17)/2,17,17),_row.mark,_row.markStyle);
}
@end

@implementation ProjectsHomeView {
  NSScrollView *_scroll;
  RailPanel *_document;
  NSSegmentedControl *_filterControl;
  CGFloat _laidOutWidth;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.fill = NSColor.whiteColor;
    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds]; _scroll.drawsBackground = NO; _scroll.hasVerticalScroller = YES; _scroll.autohidesScrollers = YES;
    _scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; _scroll.horizontalScrollElasticity = NSScrollElasticityNone;
    _document = [[RailPanel alloc] init]; _document.fill = NSColor.whiteColor; _scroll.documentView = _document; [self addSubview:_scroll];
    _filterControl = [NSSegmentedControl segmentedControlWithLabels:@[@"All",@"Needs attention",@"Running locally"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(filterChanged:)];
    _filterControl.segmentStyle = NSSegmentStyleRounded; _filterControl.controlSize = NSControlSizeRegular; _filterControl.font = [NSFont systemFontOfSize:11];
  }
  return self;
}
- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size]; _scroll.frame = self.bounds;
  if (fabs(NSWidth(self.bounds)-_laidOutWidth) > .5) [self reload];
}
- (void)filterChanged:(NSSegmentedControl *)sender { _filter = sender.selectedSegment; if (self.onFilter) self.onFilter(_filter); [self reload]; }
- (void)showAddMenu:(NSView *)anchor { [self.addMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(anchor.bounds)+4) inView:anchor]; }

- (NSArray<ProjectCard *> *)visibleCards {
  if (_filter == 0) return self.cards;
  NSMutableArray *out = [NSMutableArray array];
  for (ProjectCard *card in self.cards) if (_filter == 1 ? card.needsAttention : card.runsLocally) [out addObject:card];
  return out;
}

- (void)reload {
  CGFloat width = NSWidth(self.bounds); _laidOutWidth = width;
  NSPoint offset = _scroll.contentView.bounds.origin;
  for (NSView *v in [_document.subviews copy]) [v removeFromSuperview];
  CGFloat margin = width > 900 ? 40 : 24, content = MAX(320, width - margin*2), y = 30;
  __weak ProjectsHomeView *weak = self;

  NSTextField *title = RailLabel(@"Projects",22,NSFontWeightSemibold,Ink()); title.frame = NSMakeRect(margin,y,300,30); [_document addSubview:title];
  NSTextField *summary = RailLabel(self.summary,12,NSFontWeightRegular,Sub()); summary.frame = NSMakeRect(margin,y+33,MAX(100,content-430),18); [_document addSubview:summary];
  RailButton *add = RailAction(@"Add project",@"plus",@"Add a project or import repositories",nil);
  __weak RailButton *weakAdd = add; add.handler = ^{ [weak showAddMenu:weakAdd]; };
  add.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium]; add.stroke = Line(); add.normalFill = NSColor.whiteColor; add.cornerRadius = 7;
  add.frame = NSMakeRect(margin+content-122,y+20,122,30); [_document addSubview:add];
  if (self.checking) {
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(margin+content-152,y+27,16,16)]; spinner.style = NSProgressIndicatorStyleSpinning; spinner.controlSize = NSControlSizeSmall;
    [spinner startAnimation:nil]; [_document addSubview:spinner];
  } else {
    RailButton *check = RailAction(@"",@"arrow.clockwise",@"Check now",^{ if (weak.onCheckNow) weak.onCheckNow(); }); check.centered = YES; check.ink = Sub();
    check.frame = NSMakeRect(margin+content-160,y+20,30,30); [_document addSubview:check];
  }
  [_filterControl sizeToFit]; _filterControl.selectedSegment = _filter;
  if (content > 640) { _filterControl.frame = NSMakeRect(margin+content-172-NSWidth(_filterControl.frame),y+22,NSWidth(_filterControl.frame),26); [_document addSubview:_filterControl]; }
  y += 78;

  NSArray<ProjectCard *> *cards = [self visibleCards];
  if (!self.cards.count) y = [self emptyStateAt:y margin:margin width:content];
  else if (!cards.count) {
    NSTextField *none = RailLabel(_filter == 1 ? @"Nothing needs attention right now." : @"No local server is running.",13,NSFontWeightRegular,Sub());
    none.frame = NSMakeRect(margin,y+10,content,20); [_document addSubview:none]; y += 50;
  } else {
    // Two columns once each card still has room for its status; a single card stays at a readable width.
    NSInteger columns = content >= 1060 ? 2 : 1; CGFloat gap = 16, cardWidth = MIN(columns == 1 ? 820 : CGFLOAT_MAX, floor((content - gap*(columns-1))/columns));
    for (NSUInteger i = 0; i < cards.count; i += columns) {
      CGFloat rowHeight = 0; NSMutableArray<NSView *> *row = [NSMutableArray array];
      for (NSInteger c = 0; c < columns && i+c < cards.count; c++) {
        NSView *card = [self cardView:cards[i+c] width:cardWidth];
        card.frame = NSMakeRect(margin + c*(cardWidth+gap), y, cardWidth, NSHeight(card.frame));
        rowHeight = MAX(rowHeight, NSHeight(card.frame)); [row addObject:card]; [_document addSubview:card];
      }
      for (NSView *card in row) card.frame = NSMakeRect(NSMinX(card.frame), y, cardWidth, rowHeight);
      y += rowHeight + gap;
    }
    y += 24;
  }
  _document.frame = NSMakeRect(0,0,width,MAX(y,floor(NSHeight(_scroll.contentView.bounds))));
  [_scroll.contentView scrollToPoint:NSMakePoint(0,MIN(offset.y,MAX(0,y-NSHeight(self.bounds))))];
  [_scroll reflectScrolledClipView:_scroll.contentView];
}

- (CGFloat)emptyStateAt:(CGFloat)y margin:(CGFloat)margin width:(CGFloat)width {
  __weak ProjectsHomeView *weak = self;
  RailPanel *box = [[RailPanel alloc] initWithFrame:NSMakeRect(margin,y,width,220)]; box.fill = RailColor(0xf7f9fb);
  box.wantsLayer = YES; box.layer.cornerRadius = 12; box.layer.borderWidth = 1; box.layer.borderColor = RailColor(0xe7ecf1).CGColor;
  NSTextField *heading = RailLabel([NSString stringWithFormat:@"No projects in %@ yet",self.spaceName ?: @"this Space"],17,NSFontWeightSemibold,Ink()); heading.frame = NSMakeRect(28,30,width-56,24); [box addSubview:heading];
  CGFloat h = 0;
  NSTextField *copy = Wrapping(@"A project groups a repository, its pipelines, and the places it runs: a local server, INT, PROD. Add one from a repository URL, import repositories, or right-click a tab and choose Add to Project.",12.5,Sub(),MIN(560,width-56),&h);
  copy.frame = NSMakeRect(28,62,MIN(560,width-56),h); [box addSubview:copy];
  CGFloat x = 28;
  NSArray *actions = @[@[@"Add project",@"plus",@0],@[@"Import from Azure DevOps",@"square.and.arrow.down",@1],@[@"Import from GitHub",@"square.and.arrow.down",@2]];
  for (NSArray *entry in actions) {
    NSInteger kind = [entry[2] integerValue];
    RailButton *button = RailAction(entry[0],entry[1],entry[0],^{ ProjectsHomeView *strong = weak; if (!strong) return; void (^h)(void) = kind == 0 ? strong.onAddProject : kind == 1 ? strong.onImportAzure : strong.onImportGitHub; if (h) h(); });
    button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; button.cornerRadius = 7;
    if (kind == 0) { button.normalFill = RailColor(0xd8e7f7); button.hoverFill = RailColor(0xcbdff4); button.ink = RailColor(0x245b96); }
    else { button.normalFill = NSColor.whiteColor; button.stroke = Line(); }
    CGFloat w = TextWidth(entry[0],button.font) + 44; button.frame = NSMakeRect(x,80+h,w,32); [box addSubview:button]; x += w + 8;
  }
  box.frame = NSMakeRect(margin,y,width,80+h+32+30); [_document addSubview:box];
  return y + NSHeight(box.frame) + 30;
}

- (NSView *)cardView:(ProjectCard *)card width:(CGFloat)width {
  // The layer paints the rounded card so a soft shadow can sit outside it.
  RailPanel *view = [[RailPanel alloc] initWithFrame:NSMakeRect(0,0,width,100)]; view.menu = card.menu;
  view.wantsLayer = YES; view.layer.backgroundColor = NSColor.whiteColor.CGColor; view.layer.cornerRadius = 12; view.layer.borderWidth = 1;
  view.layer.borderColor = (card.needsAttention ? RailColor(0xecc4bc) : Line()).CGColor;
  if (card.needsAttention) { view.layer.shadowColor = RailColor(0xb03a2c).CGColor; view.layer.shadowOpacity = .14; view.layer.shadowRadius = 10; view.layer.shadowOffset = CGSizeMake(0,-4); }
  CGFloat left = 20, y = 16, stackWidth = MIN(262, floor((width-left-16)*.5)), leftWidth = width - left - 16 - stackWidth - 20;
  if (card.provider) {
    RailPanel *badge = [[RailPanel alloc] initWithFrame:NSMakeRect(left,y+2,18,18)]; badge.fill = card.provider == 2 ? RailColor(0x2d3b4d) : RailColor(0x2f6fb8);
    badge.wantsLayer = YES; badge.layer.cornerRadius = 5; badge.layer.masksToBounds = YES;
    NSImageView *icon = [NSImageView imageViewWithImage:RailSymbol(card.provider == 2 ? @"chevron.left.forwardslash.chevron.right" : @"infinity",9)]; icon.contentTintColor = NSColor.whiteColor; icon.frame = NSMakeRect(2,2,14,14); [badge addSubview:icon];
    [view addSubview:badge];
  }
  CGFloat nameX = card.provider ? left+27 : left;
  NSTextField *name = RailLabel(card.name,15,NSFontWeightSemibold,Ink()); name.frame = NSMakeRect(nameX,y,width-nameX-50,22); [view addSubview:name];
  if (card.menu) {
    RailButton *more = RailAction(@"",@"ellipsis",@"Project options",nil); more.centered = YES; more.ink = Sub();
    NSMenu *menu = card.menu; __weak RailButton *weakMore = more; more.handler = ^{ [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(weakMore.bounds)+4) inView:weakMore]; };
    more.frame = NSMakeRect(width-42,y-2,28,28); [view addSubview:more];
  }
  y += 24;
  NSTextField *meta = RailLabel(card.meta,11,NSFontWeightRegular,Sub()); meta.frame = NSMakeRect(nameX,y,width-nameX-20,16); [view addSubview:meta];
  y += 30;
  CGFloat top = y, ly = y;
  // Left column: status pills, a short explanation, custom links.
  CGFloat px = left;
  for (ProjectPill *pill in card.pills) {
    NSFont *font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    CGFloat w = MIN(leftWidth, TextWidth(pill.title,font) + (pill.symbol ? 44 : 22));
    if (px > left && px + w > left + leftWidth) { px = left; ly += 28; }
    RailButton *button = RailAction(pill.title,pill.symbol,pill.help ?: pill.title,pill.handler);
    button.font = font; button.cornerRadius = 5; button.normalFill = ToneFill(pill.tone); button.ink = ToneText(pill.tone);
    button.hoverFill = pill.handler ? [ToneFill(pill.tone) blendedColorWithFraction:.18 ofColor:ToneText(pill.tone)] : ToneFill(pill.tone);
    if (pill.symbol) button.image = RailSymbol(pill.symbol,11);
    button.enabled = YES; button.frame = NSMakeRect(px,ly,w,23); [view addSubview:button]; px += w + 6;
  }
  if (card.pills.count) ly += 33;
  if (card.detail.length) {
    CGFloat h = 0; NSTextField *detail = Wrapping(card.detail,11.5,Sub(),leftWidth,&h);
    detail.frame = NSMakeRect(left,ly,leftWidth,h); [view addSubview:detail]; ly += h + 12;
  }
  if (card.chips.count) {
    CGFloat cx = left; NSUInteger shown = 0;
    for (ProjectChip *chip in card.chips) {
      if (shown == 4) break;
      NSFont *font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
      CGFloat w = MIN(leftWidth, TextWidth(chip.title,font) + 46);
      if (cx > left && cx + w > left + leftWidth) { cx = left; ly += 32; }
      RailButton *button = RailAction(chip.title,nil,chip.help ?: chip.title,chip.handler);
      button.image = chip.icon ?: RailSymbol(@"link",12); button.keepsImageColors = chip.iconKeepsColors; button.ink = Ink(); button.font = font;
      button.stroke = Line(); button.normalFill = NSColor.whiteColor; button.hoverFill = RailColor(0xf1f5f9); button.cornerRadius = 7; button.menu = chip.menu;
      button.frame = NSMakeRect(cx,ly,w,28); [view addSubview:button]; cx += w + 6; shown++;
    }
    if (card.chips.count > 4) {
      NSMenu *overflow = [[NSMenu alloc] init];
      for (NSUInteger i = 4; i < card.chips.count; i++) {
        ProjectChip *chip = card.chips[i]; NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:chip.title action:@selector(runBlock:) keyEquivalent:@""];
        item.target = self; item.representedObject = chip.handler; item.image = chip.icon; [overflow addItem:item];
      }
      RailButton *more = RailAction([NSString stringWithFormat:@"+%lu",(unsigned long)(card.chips.count-4)],nil,@"More links",nil);
      __weak RailButton *weakMore = more; more.handler = ^{ [overflow popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(weakMore.bounds)+4) inView:weakMore]; };
      more.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium]; more.stroke = Line(); more.normalFill = NSColor.whiteColor; more.cornerRadius = 7; more.centered = YES;
      if (cx + 40 > left + leftWidth) { cx = left; ly += 32; }
      more.frame = NSMakeRect(cx,ly,40,28); [view addSubview:more];
    }
    ly += 36;
  }
  // Right column: Repo, Pipelines, environments.
  CGFloat ry = top, sx = width - 16 - stackWidth;
  for (ProjectRow *row in card.rows) {
    ProjectRowButton *button = [[ProjectRowButton alloc] initWithRow:row]; button.frame = NSMakeRect(sx,ry,stackWidth,34); [view addSubview:button]; ry += 40;
  }
  if (!card.rows.count) {
    NSTextField *hint = RailLabel(@"No environments yet",11,NSFontWeightRegular,Sub()); hint.frame = NSMakeRect(sx,ry+8,stackWidth,16); [view addSubview:hint]; ry += 34;
  }
  view.frame = NSMakeRect(0,0,width,MAX(ly,ry) + 12);
  return view;
}
- (void)runBlock:(NSMenuItem *)item { void (^handler)(void) = item.representedObject; if (handler) handler(); }
@end
