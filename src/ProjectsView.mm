#import "ProjectsView.h"
#import "Theme.h"

@implementation ProjectPill
@end
@implementation ProjectRow
@end
@implementation ProjectChip
@end
@implementation ProjectCard
@end

namespace {
NSColor *Ink() { return RailInk(); }
NSColor *Sub() { return RailMuted(); }
NSColor *Line() { return RailLine(); }
NSColor *ToneText(ProjectTone tone) {
  switch (tone) {
    case ProjectToneCritical: return RailTint(RailRoleCriticalInk);
    case ProjectToneWarn: case ProjectToneBusy: return RailTint(RailRoleWarnInk);
    case ProjectToneOK: return RailTint(RailRoleOKInk);
    case ProjectToneInfo: case ProjectToneRunning: return RailTint(RailRoleInfoInk);
    default: return Sub();
  }
}
NSColor *ToneFill(ProjectTone tone) {
  switch (tone) {
    case ProjectToneCritical: return RailTint(RailRoleCriticalFill);
    case ProjectToneWarn: case ProjectToneBusy: return RailTint(RailRoleWarnFill);
    case ProjectToneOK: return RailTint(RailRoleOKFill);
    case ProjectToneInfo: case ProjectToneRunning: return RailTint(RailRoleInfoFill);
    default: return RailTint(RailRoleNeutralFill);
  }
}
// Status dots: filled for a known state, a ring for stopped or in progress.
void DrawDot(NSRect frame, ProjectTone tone) {
  NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:frame];
  switch (tone) {
    case ProjectToneCritical:
      [[RailTint(RailRoleCriticalDot) colorWithAlphaComponent:.2] setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(frame,-2.5,-2.5)] fill];
      [RailTint(RailRoleCriticalDot) setFill]; [dot fill]; break;
    case ProjectToneWarn: [RailTint(RailRoleWarnDot) setFill]; [dot fill]; break;
    case ProjectToneOK: [RailTint(RailRoleOKDot) setFill]; [dot fill]; break;
    case ProjectToneRunning: case ProjectToneInfo: [RailTint(RailRoleInfoDot) setFill]; [dot fill]; break;
    case ProjectToneStopped: { NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(frame,.75,.75)]; ring.lineWidth = 1.5; [RailTint(RailRoleStoppedDot) setStroke]; [ring stroke]; break; }
    case ProjectToneBusy: {
      NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(frame,.75,.75)]; ring.lineWidth = 1.5; [RailTint(RailRoleWarnDot) setStroke]; [ring stroke];
      NSBezierPath *half = [NSBezierPath bezierPath]; NSPoint c = NSMakePoint(NSMidX(frame),NSMidY(frame));
      [half moveToPoint:c]; [half appendBezierPathWithArcWithCenter:c radius:NSWidth(frame)/2-2 startAngle:-90 endAngle:90 clockwise:NO]; [half closePath];
      [RailTint(RailRoleWarnDot) setFill]; [half fill]; break;
    }
    case ProjectToneUnknown: [RailTint(RailRoleUnknownDot) setFill]; [dot fill]; break;
    default: break;
  }
}
void DrawMark(NSRect frame, NSString *mark, NSInteger style) {
  NSInteger i = MAX(0, MIN(2, style));
  [RailSessionFill(i) setFill]; [[NSBezierPath bezierPathWithRoundedRect:frame xRadius:4 yRadius:4] fill];
  NSDictionary *attrs = @{NSFontAttributeName:RailFont(9,NSFontWeightSemibold), NSForegroundColorAttributeName:RailSessionInk(i)};
  NSSize size = [mark sizeWithAttributes:attrs];
  [mark drawAtPoint:NSMakePoint(NSMidX(frame)-size.width/2, NSMidY(frame)-size.height/2) withAttributes:attrs];
}
NSColor *Soft() { return RailTint(RailRoleLineSoft); }
CGFloat TextWidth(NSString *text, NSFont *font) { return ceil([text ?: @"" sizeWithAttributes:@{NSFontAttributeName:font}].width); }
NSTextField *Wrapping(NSString *text, CGFloat size, NSColor *color, CGFloat width, CGFloat *height) {
  NSTextField *field = RailLabel(text, size, NSFontWeightRegular, color);
  field.lineBreakMode = NSLineBreakByWordWrapping; field.maximumNumberOfLines = 4; field.preferredMaxLayoutWidth = width;
  field.cell.wraps = YES; field.cell.truncatesLastVisibleLine = YES;
  NSSize fit = [field.cell cellSizeForBounds:NSMakeRect(0,0,width,200)];
  *height = ceil(fit.height); return field;
}
}

NSColor *ProjectToneText(ProjectTone tone) { return ToneText(tone); }
NSColor *ProjectToneFill(ProjectTone tone) { return ToneFill(tone); }
void ProjectDrawDot(NSRect frame, ProjectTone tone) { DrawDot(frame, tone); }
void ProjectDrawMark(NSRect frame, NSString *mark, NSInteger style) { DrawMark(frame, mark, style); }
// Check states as filled symbols, so shape carries the state alongside colour.
NSImage *ProjectStateSymbol(ProjectTone tone, CGFloat size) {
  NSString *name; NSColor *color;
  switch (tone) {
    case ProjectToneOK: name = @"checkmark.circle.fill"; color = RailTint(RailRoleOKDot); break;
    case ProjectToneCritical: name = @"xmark.circle.fill"; color = RailTint(RailRoleCriticalDot); break;
    case ProjectToneWarn: name = @"exclamationmark.circle.fill"; color = RailTint(RailRoleWarnDot); break;
    case ProjectToneRunning: case ProjectToneBusy: name = @"arrow.triangle.2.circlepath.circle.fill"; color = RailTint(RailRoleInfoDot); break;
    case ProjectToneStopped: name = @"minus.circle"; color = RailTint(RailRoleStoppedDot); break;
    default: name = @"circle.dotted"; color = RailTint(RailRoleFaint); break;
  }
  NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium] configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]];
  return [image imageWithSymbolConfiguration:config];
}

// A step on a project's path: caption, status dot and value. Problems tint the whole step.
@interface ProjectStepButton : NSButton
@property(nonatomic, strong) ProjectRow *row;
@end
@implementation ProjectStepButton {
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
  BOOL problem = _row.tone == ProjectToneCritical || _row.tone == ProjectToneWarn;
  BOOL quiet = _row.tone == ProjectToneStopped || (_row.tone == ProjectToneUnknown && !_row.value.length);
  NSRect bounds = NSInsetRect(self.bounds,.5,.5);
  NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:7 yRadius:7];
  NSColor *fill = problem ? ToneFill(_row.tone) : quiet ? RailTint(RailRoleRaised) : RailTint(RailRoleSunken);
  if (_hovered) fill = [fill blendedColorWithFraction:.06 ofColor:Ink()];
  [fill setFill]; [shape fill];
  [(problem ? [ToneFill(_row.tone) blendedColorWithFraction:.12 ofColor:ToneText(_row.tone)] : _hovered ? RailTint(RailRoleLineStrong) : Soft()) setStroke]; shape.lineWidth = 1; [shape stroke];
  if (self.window.firstResponder == self) { [RailTint(RailRoleFocus) setStroke]; shape.lineWidth = 2; [shape stroke]; }
  CGFloat h = NSHeight(self.bounds), x = 10, right = NSWidth(self.bounds) - (_row.mark.length ? 30 : 9);
  if (_row.tone != ProjectToneNeutral) { DrawDot(NSMakeRect(x,(h-8)/2,8,8),_row.tone); x += 15; }
  NSMutableParagraphStyle *clip = [[NSMutableParagraphStyle alloc] init]; clip.lineBreakMode = NSLineBreakByTruncatingTail;
  NSColor *ink = problem ? ToneText(_row.tone) : Ink();
  NSDictionary *caption = @{NSFontAttributeName:RailFont(9.5,NSFontWeightSemibold),NSForegroundColorAttributeName:problem ? ToneText(_row.tone) : Sub(),NSKernAttributeName:@.3,NSParagraphStyleAttributeName:clip};
  NSDictionary *value = @{NSFontAttributeName:RailDigitsFont(11,problem ? NSFontWeightMedium : NSFontWeightRegular),NSForegroundColorAttributeName:quiet ? Sub() : ink,NSParagraphStyleAttributeName:clip};
  if (h < 36) {
    NSString *label = _row.label.uppercaseString; CGFloat lw = MIN(MAX(0,right-x), TextWidth(label,caption[NSFontAttributeName])+2);
    [label drawInRect:NSMakeRect(x,(h-13)/2+.5,lw,13) withAttributes:caption];
    [_row.value ?: @"" drawInRect:NSMakeRect(x+lw+6,(h-15)/2,MAX(0,right-x-lw-6),15) withAttributes:value];
  } else {
    [_row.label.uppercaseString drawInRect:NSMakeRect(x,h/2-14,MAX(0,right-x),13) withAttributes:caption];
    [_row.value.length ? _row.value : @"—" drawInRect:NSMakeRect(x,h/2,MAX(0,right-x),15) withAttributes:value];
  }
  if (_row.mark.length) DrawMark(NSMakeRect(NSWidth(self.bounds)-25,(h-15)/2,15,15),_row.mark,_row.markStyle);
}
@end

@implementation ProjectsHomeView {
  NSScrollView *_scroll;
  RailPanel *_document;
  NSSegmentedControl *_filterControl;
  CGFloat _laidOutWidth;
  BOOL _stackLanes;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.fill = RailTint(RailRoleContent);
    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds]; _scroll.drawsBackground = NO; _scroll.hasVerticalScroller = YES; _scroll.autohidesScrollers = YES;
    _scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; _scroll.horizontalScrollElasticity = NSScrollElasticityNone;
    _document = [[RailPanel alloc] init]; _document.fill = RailTint(RailRoleContent); _scroll.documentView = _document; [self addSubview:_scroll];
    _filterControl = [NSSegmentedControl segmentedControlWithLabels:@[@"All",@"Needs attention",@"Running locally"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(filterChanged:)];
    _filterControl.segmentStyle = NSSegmentStyleRounded; _filterControl.controlSize = NSControlSizeRegular; _filterControl.font = [NSFont systemFontOfSize:11];
    // Lanes copy colours into their layers, so a new theme rebuilds the page.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:RailThemeDidChangeNotification object:nil];
  }
  return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
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

  NSTextField *title = RailLabel(@"Projects",22,NSFontWeightBold,Ink()); title.frame = NSMakeRect(margin,y,300,30); [_document addSubview:title];
  NSTextField *summary = RailLabel(self.summary,12,NSFontWeightRegular,Sub()); summary.frame = NSMakeRect(margin,y+33,MAX(100,content-430),18); [_document addSubview:summary];
  RailButton *add = RailAction(@"Add project",@"plus",@"Add a project or import repositories",nil);
  __weak RailButton *weakAdd = add; add.handler = ^{ [weak showAddMenu:weakAdd]; };
  add.font = RailFont(11.5,NSFontWeightMedium); add.stroke = Line(); add.normalFill = RailTint(RailRoleRaised); add.hoverFill = RailTint(RailRoleContentHover); add.cornerRadius = 7;
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
    // Every lane uses the same layout, so the paths line up down the page.
    CGFloat widest = 0; for (ProjectCard *card in cards) widest = MAX(widest, [self flowWidth:card]);
    _stackLanes = content - 58 - widest < 300;
    // Grouped by state so the calm projects stay out of the way.
    NSArray *titles = @[@"Needs attention",@"In progress",@"All clear"];
    for (NSInteger group = 0; group < 3; group++) {
      NSMutableArray<ProjectCard *> *members = [NSMutableArray array];
      for (ProjectCard *card in cards) if ((card.needsAttention ? 0 : card.moving ? 1 : 2) == group) [members addObject:card];
      if (!members.count) continue;
      NSTextField *heading = RailLabel(titles[group],11.5,NSFontWeightSemibold,Ink()); [heading sizeToFit];
      heading.frame = NSMakeRect(margin,y,NSWidth(heading.frame),16); [_document addSubview:heading];
      NSTextField *count = RailLabel([NSString stringWithFormat:@"%lu",(unsigned long)members.count],11.5,NSFontWeightRegular,Sub());
      count.frame = NSMakeRect(margin+NSWidth(heading.frame)+6,y,40,16); [_document addSubview:count];
      y += 24;
      for (ProjectCard *card in members) {
        NSView *lane = [self laneView:card width:content];
        lane.frame = NSMakeRect(margin,y,content,NSHeight(lane.frame)); [_document addSubview:lane];
        y += NSHeight(lane.frame) + 8;
      }
      y += 14;
    }
    y += 24;
  }
  _document.frame = NSMakeRect(0,0,width,MAX(y,floor(NSHeight(_scroll.contentView.bounds))));
  [_scroll.contentView scrollToPoint:NSMakePoint(0,MIN(offset.y,MAX(0,y-NSHeight(self.bounds))))];
  [_scroll reflectScrolledClipView:_scroll.contentView];
}

- (CGFloat)emptyStateAt:(CGFloat)y margin:(CGFloat)margin width:(CGFloat)width {
  __weak ProjectsHomeView *weak = self;
  RailPanel *box = [[RailPanel alloc] initWithFrame:NSMakeRect(margin,y,width,220)]; box.fill = RailTint(RailRoleSunken);
  box.wantsLayer = YES; box.layer.cornerRadius = 12; box.layer.borderWidth = 1; box.layer.borderColor = Soft().CGColor;
  NSTextField *heading = RailLabel([NSString stringWithFormat:@"No projects in %@ yet",self.spaceName ?: @"this Space"],17,NSFontWeightBold,Ink()); heading.frame = NSMakeRect(28,30,width-56,24); [box addSubview:heading];
  CGFloat h = 0;
  NSTextField *copy = Wrapping(@"A project groups a repository, its pipelines, and the places it runs: a local server, INT, PROD. Add one from a repository URL, import repositories, or right-click a tab and choose Add to Project.",12.5,Sub(),MIN(560,width-56),&h);
  copy.frame = NSMakeRect(28,62,MIN(560,width-56),h); [box addSubview:copy];
  CGFloat x = 28;
  NSArray *actions = @[@[@"Add project",@"plus",@0],@[@"Import from Azure DevOps",@"square.and.arrow.down",@1],@[@"Import from GitHub",@"square.and.arrow.down",@2]];
  for (NSArray *entry in actions) {
    NSInteger kind = [entry[2] integerValue];
    RailButton *button = RailAction(entry[0],entry[1],entry[0],^{ ProjectsHomeView *strong = weak; if (!strong) return; void (^h)(void) = kind == 0 ? strong.onAddProject : kind == 1 ? strong.onImportAzure : strong.onImportGitHub; if (h) h(); });
    button.font = RailFont(12,NSFontWeightMedium); button.cornerRadius = 7;
    if (kind == 0) { button.normalFill = RailTint(RailRoleSelected); button.hoverFill = RailTint(RailRoleSelectedHover); button.ink = RailTint(RailRoleSelectedInk); }
    else { button.normalFill = RailTint(RailRoleRaised); button.hoverFill = RailTint(RailRoleContentHover); button.stroke = Line(); }
    CGFloat w = TextWidth(entry[0],button.font) + 44; button.frame = NSMakeRect(x,80+h,w,32); [box addSubview:button]; x += w + 8;
  }
  box.frame = NSMakeRect(margin,y,width,80+h+32+30); [_document addSubview:box];
  return y + NSHeight(box.frame) + 30;
}

static CGFloat nameXOffset(ProjectCard *card) { return card.provider ? 27 : 0; }
- (CGFloat)flowWidth:(ProjectCard *)card {
  NSUInteger local = 0, path = 0; for (ProjectRow *row in card.rows) row.local ? local++ : path++;
  return local*128 + MAX(0,(CGFloat)local-1)*6 + (local ? 14 : 0) + path*136 + MAX(0,(CGFloat)path-1)*22;
}
- (NSView *)laneView:(ProjectCard *)card width:(CGFloat)width {
  // The layer paints the rounded lane so a soft shadow can sit outside it.
  RailPanel *view = [[RailPanel alloc] initWithFrame:NSMakeRect(0,0,width,60)]; view.menu = card.menu;
  view.wantsLayer = YES; view.layer.backgroundColor = RailTint(RailRoleRaised).CGColor; view.layer.cornerRadius = 10; view.layer.borderWidth = 1;
  view.layer.borderColor = (card.needsAttention ? [RailTint(RailRoleCriticalDot) colorWithAlphaComponent:.45] : Line()).CGColor;
  if (card.needsAttention) { view.layer.shadowColor = RailTint(RailRoleCriticalDot).CGColor; view.layer.shadowOpacity = .12; view.layer.shadowRadius = 9; view.layer.shadowOffset = CGSizeMake(0,-4); }

  // The path: local servers first and apart, then repo → pipeline → environments.
  NSMutableArray<ProjectRow *> *local = [NSMutableArray array], *path = [NSMutableArray array];
  for (ProjectRow *row in card.rows) [(row.local ? local : path) addObject:row];
  BOOL quiet = !card.pills.count && !card.detail.length && !card.chips.count;
  CGFloat stepHeight = quiet ? 32 : 40, localWidth = 128, stepWidth = 136, chevron = 22, localGap = local.count ? 14 : 0;
  CGFloat flow = local.count*localWidth + MAX(0,(CGFloat)local.count-1)*6 + localGap + path.count*stepWidth + MAX(0,(CGFloat)path.count-1)*chevron;
  CGFloat left = 14, moreWidth = card.menu ? 34 : 0, inner = width - left - 10 - moreWidth;
  // Beside the name when there's room, else on its own line under it.
  BOOL stacked = _stackLanes;
  if (stacked) {
    // Stacked paths get the full width: steps grow to show more, or shrink to fit.
    CGFloat fixed = local.count*localWidth + MAX(0,(CGFloat)local.count-1)*6 + localGap + MAX(0,(CGFloat)path.count-1)*chevron;
    stepWidth = path.count ? MAX(84, MIN(176, floor((inner - (nameXOffset(card)) - fixed)/path.count))) : stepWidth;
    flow = fixed + path.count*stepWidth;
  }
  CGFloat textWidth = stacked ? inner : inner - flow - 20;

  CGFloat y = quiet ? 0 : 12;
  CGFloat nameX = left;
  if (card.provider) {
    RailPanel *badge = [[RailPanel alloc] initWithFrame:NSMakeRect(left,(quiet ? 0 : y)+1,18,18)]; badge.fill = card.provider == 2 ? RailColor(0x2d3b4d) : RailColor(0x2f6fb8);
    badge.wantsLayer = YES; badge.layer.cornerRadius = 5; badge.layer.masksToBounds = YES;
    NSImageView *icon = [NSImageView imageViewWithImage:RailSymbol(card.provider == 2 ? @"chevron.left.forwardslash.chevron.right" : @"infinity",9)]; icon.contentTintColor = NSColor.whiteColor; icon.frame = NSMakeRect(2,2,14,14); [badge addSubview:icon];
    [view addSubview:badge]; nameX = left + 27;
  }
  NSFont *nameFont = RailFont(13,NSFontWeightSemibold);
  CGFloat nameWidth = MIN(TextWidth(card.name,nameFont)+4, MAX(60,textWidth-(nameX-left)));
  NSTextField *name = RailLabel(card.name,13,NSFontWeightSemibold,Ink()); name.frame = NSMakeRect(nameX,y,nameWidth,19); [view addSubview:name];
  NSTextField *meta = RailLabel(card.meta,11,NSFontWeightRegular,Sub()); meta.lineBreakMode = NSLineBreakByTruncatingTail;
  meta.frame = NSMakeRect(nameX+nameWidth+6,y+2,MAX(0,left+textWidth-(nameX+nameWidth+6)),16); [view addSubview:meta];
  CGFloat ly = y + 25;
  if (card.pills.count || card.detail.length) {
    CGFloat px = nameX, maxX = left + textWidth;
    for (ProjectPill *pill in card.pills) {
      NSFont *font = RailFont(10.5,NSFontWeightSemibold);
      CGFloat w = MIN(maxX-px, TextWidth(pill.title,font) + (pill.symbol ? 40 : 20));
      if (w < 60) break;
      RailButton *button = RailAction(pill.title,pill.symbol,pill.help ?: pill.title,pill.handler);
      button.font = font; button.cornerRadius = 5; button.normalFill = ToneFill(pill.tone); button.ink = ToneText(pill.tone);
      button.hoverFill = pill.handler ? [ToneFill(pill.tone) blendedColorWithFraction:.18 ofColor:ToneText(pill.tone)] : ToneFill(pill.tone);
      if (pill.symbol) button.image = RailSymbol(pill.symbol,10.5);
      button.frame = NSMakeRect(px,ly,w,21); [view addSubview:button]; px += w + 6;
    }
    if (card.detail.length && maxX - px > 80) {
      NSTextField *detail = RailLabel(card.detail,11,NSFontWeightRegular,Sub()); detail.lineBreakMode = NSLineBreakByTruncatingTail; detail.toolTip = card.detail;
      detail.frame = NSMakeRect(px+2,ly+3,maxX-px-2,16); [view addSubview:detail];
    }
    ly += 29;
  }
  if (card.chips.count) {
    CGFloat cx = nameX, maxX = left + textWidth;
    for (ProjectChip *chip in card.chips) {
      NSFont *font = RailFont(10.5,NSFontWeightMedium);
      CGFloat w = MIN(maxX-cx, TextWidth(chip.title,font) + 40);
      if (w < 70) break;
      RailButton *button = RailAction(chip.title,nil,chip.help ?: chip.title,chip.handler);
      button.image = chip.icon ?: RailSymbol(@"link",11); button.keepsImageColors = chip.iconKeepsColors; button.ink = Ink(); button.font = font;
      button.stroke = Line(); button.normalFill = RailTint(RailRoleRaised); button.hoverFill = RailTint(RailRoleContentHover); button.cornerRadius = 6; button.menu = chip.menu;
      button.frame = NSMakeRect(cx,ly,w,24); [view addSubview:button]; cx += w + 6;
    }
    ly += 30;
  }
  CGFloat textBottom = quiet ? 0 : ly - 4;

  CGFloat fx = stacked ? nameX : left + inner - flow, fy;
  CGFloat height;
  if (stacked) { fy = (quiet ? 36 : textBottom + 2); height = fy + stepHeight + 12; }
  else { height = MAX(quiet ? 48 : textBottom + 8, stepHeight + 20); fy = (height - stepHeight)/2; }
  if (quiet && !stacked) { name.frame = NSOffsetRect(name.frame,0,(height-19)/2); meta.frame = NSOffsetRect(meta.frame,0,(height-19)/2); for (NSView *v in view.subviews) if ([v isKindOfClass:RailPanel.class]) v.frame = NSOffsetRect(v.frame,0,(height-19)/2); }
  else if (quiet) { for (NSView *v in view.subviews) v.frame = NSOffsetRect(v.frame,0,9); }
  for (ProjectRow *row in local) {
    ProjectStepButton *step = [[ProjectStepButton alloc] initWithRow:row]; step.frame = NSMakeRect(fx,fy,localWidth,stepHeight); [view addSubview:step]; fx += localWidth + 6;
  }
  if (local.count) fx += localGap - 6;
  for (NSUInteger i = 0; i < path.count; i++) {
    if (i) {
      NSImageView *arrow = [NSImageView imageViewWithImage:RailSymbol(@"chevron.right",9)]; arrow.contentTintColor = RailTint(RailRoleFaint);
      arrow.frame = NSMakeRect(fx,fy+(stepHeight-12)/2,chevron,12); [view addSubview:arrow]; fx += chevron;
    }
    ProjectStepButton *step = [[ProjectStepButton alloc] initWithRow:path[i]]; step.frame = NSMakeRect(fx,fy,stepWidth,stepHeight); [view addSubview:step]; fx += stepWidth;
  }
  if (!card.rows.count) {
    NSTextField *hint = RailLabel(@"No environments yet",11,NSFontWeightRegular,Sub()); hint.frame = NSMakeRect(left+inner-140,fy+(stepHeight-16)/2,140,16); hint.alignment = NSTextAlignmentRight; [view addSubview:hint];
  }
  if (card.menu) {
    RailButton *more = RailAction(@"",@"ellipsis",@"Project options",nil); more.centered = YES; more.ink = Sub();
    NSMenu *menu = card.menu; __weak RailButton *weakMore = more; more.handler = ^{ [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(weakMore.bounds)+4) inView:weakMore]; };
    more.frame = NSMakeRect(width-38,stacked ? 10 : (height-28)/2,28,28); [view addSubview:more];
  }
  view.frame = NSMakeRect(0,0,width,height);
  return view;
}
- (void)runBlock:(NSMenuItem *)item { void (^handler)(void) = item.representedObject; if (handler) handler(); }
@end
