#import "NativeViews.h"

NSColor *RailColor(unsigned int h) {
  return [NSColor colorWithSRGBRed:((h >> 16) & 255) / 255.0 green:((h >> 8) & 255) / 255.0 blue:(h & 255) / 255.0 alpha:1];
}
NSImage *RailSymbol(NSString *name, CGFloat size) {
  NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  return [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightRegular]];
}
NSPasteboardType const RailTabPasteboardType = @"de.eimerreis.eimerrail.tab";
NSTextField *RailLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
  NSTextField *field = [NSTextField labelWithString:text ?: @""];
  field.font = [NSFont systemFontOfSize:size weight:weight];
  field.textColor = color;
  field.lineBreakMode = NSLineBreakByTruncatingTail;
  return field;
}
@implementation RailPanel
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)rect { [(self.fill ?: NSColor.clearColor) setFill]; NSRectFill(NSIntersectionRect(rect,self.bounds)); }
- (void)setFill:(NSColor *)fill { _fill = fill; self.needsDisplay = YES; }
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize { [super resizeSubviewsWithOldSize:oldSize]; if (self.onResize) self.onResize(); }
- (NSString *)draggedTab:(id<NSDraggingInfo>)info { return [info.draggingPasteboard stringForType:RailTabPasteboardType]; }
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [self draggingUpdated:info]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
  NSString *tabID = [self draggedTab:info];
  return tabID && self.onTabDragOver ? self.onTabDragOver(tabID,[self convertPoint:info.draggingLocation fromView:nil]) : NSDragOperationNone;
}
- (void)draggingExited:(id<NSDraggingInfo>)info { (void)info; if (self.onTabDragEnd) self.onTabDragEnd(); }
- (void)draggingEnded:(id<NSDraggingInfo>)info { (void)info; if (self.onTabDragEnd) self.onTabDragEnd(); }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
  NSString *tabID = [self draggedTab:info];
  return tabID && self.onTabDrop && self.onTabDrop(tabID,[self convertPoint:info.draggingLocation fromView:nil]);
}
@end

@implementation RailButton {
  BOOL _hovered;
  NSTrackingArea *_hoverArea;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.bordered = NO; self.bezelStyle = NSBezelStyleRegularSquare;
    self.font = [NSFont systemFontOfSize:12]; self.ink = RailColor(0x273445);
    self.cornerRadius = 6; self.hoverFill = RailColor(0xe2e8ef); self.imageOpacity = 1;
    self.target = self; self.action = @selector(invoke:);
    self.focusRingType = NSFocusRingTypeExterior;
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)invoke:(id)sender { (void)sender; if (self.handler) self.handler(); }
- (void)mouseDown:(NSEvent *)event {
  if (!self.dragTabID.length) { [super mouseDown:event]; return; }
  // Decide between a click and a drag before handing the gesture to AppKit.
  NSPoint start = event.locationInWindow;
  while (YES) {
    NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
    if (next.type == NSEventTypeLeftMouseUp) { if (self.enabled) [self sendAction:self.action to:self.target]; return; }
    if (hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) < 4) continue;
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init]; [item setString:self.dragTabID forType:RailTabPasteboardType];
    NSView *shown = self.dragView ?: self;
    NSBitmapImageRep *snapshot = [shown bitmapImageRepForCachingDisplayInRect:shown.bounds]; [shown cacheDisplayInRect:shown.bounds toBitmapImageRep:snapshot];
    NSImage *image = [[NSImage alloc] initWithSize:shown.bounds.size]; [image addRepresentation:snapshot];
    NSDraggingItem *drag = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
    [drag setDraggingFrame:[self convertRect:shown.bounds fromView:shown] contents:image];
    _hovered = NO; self.needsDisplay = YES;
    [self beginDraggingSessionWithItems:@[drag] event:event source:self];
    return;
  }
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  (void)session; return context == NSDraggingContextWithinApplication ? NSDragOperationMove : NSDragOperationNone;
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_hoverArea) [self removeTrackingArea:_hoverArea];
  _hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
  [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSRect bounds = NSInsetRect(self.bounds, .5, .5);
  NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:self.cornerRadius yRadius:self.cornerRadius];
  NSColor *fill = (_hovered && self.enabled) ? (self.hoverFill ?: self.normalFill) : self.normalFill;
  if (fill) { [fill setFill]; [shape fill]; }
  if (self.stroke) { [self.stroke setStroke]; shape.lineWidth = 1; [shape stroke]; }
  if (self.window.firstResponder == self) { [RailColor(0x3976be) setStroke]; shape.lineWidth = 2; [shape stroke]; }
  NSColor *ink = self.enabled ? self.ink : [self.ink colorWithAlphaComponent:.4];
  NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
  style.lineBreakMode = NSLineBreakByTruncatingTail;
  NSDictionary *attrs = @{NSFontAttributeName:self.font, NSForegroundColorAttributeName:ink, NSParagraphStyleAttributeName:style};
  CGFloat imageSize = self.image ? 16 : 0;
  CGFloat textWidth = self.title.length ? [self.title sizeWithAttributes:attrs].width : 0;
  CGFloat gap = (imageSize && textWidth) ? 7 : 0;
  CGFloat start = self.centered ? MAX(1, (bounds.size.width - imageSize - gap - textWidth) / 2) : 9;
  if (self.image) {
    NSImage *image = self.image;
    if (!self.keepsImageColors) image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[ink]]] ?: image;
    // Draw at the image's own proportions; symbols such as house or book are not square.
    NSSize size = image.size;
    CGFloat scale = MIN(1, MIN(18 / MAX(size.width, 1), 18 / MAX(size.height, 1)));
    size = NSMakeSize(size.width * scale, size.height * scale);
    NSRect frame = NSMakeRect(start + (imageSize - size.width) / 2, (bounds.size.height - size.height) / 2, size.width, size.height);
    [image drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:self.imageOpacity * (self.enabled ? 1 : .4) respectFlipped:YES hints:nil];
  }
  if (textWidth) {
    CGFloat h = self.font.ascender - self.font.descender + 2;
    [self.title drawInRect:NSMakeRect(start + imageSize + gap, (bounds.size.height-h)/2, MAX(0,bounds.size.width-start-imageSize-gap-(self.centered ? 1 : 6)), h) withAttributes:attrs];
  }
}
@end
RailButton *RailAction(NSString *title, NSString *symbol, NSString *help, void (^handler)(void)) {
  RailButton *button = [[RailButton alloc] initWithFrame:NSZeroRect];
  button.title = title ?: @""; button.image = symbol.length ? RailSymbol(symbol,15) : nil;
  button.toolTip = help; button.accessibilityLabel = help ?: title; button.handler = handler;
  return button;
}

@implementation RailResizeHandle {
  CGFloat _startX;
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.resizeLeftRightCursor]; }
- (void)mouseDown:(NSEvent *)event { (void)event; _startX = [NSEvent mouseLocation].x; if (self.onBegin) self.onBegin(); }
- (void)mouseDragged:(NSEvent *)event { (void)event; if (self.onDrag) self.onDrag([NSEvent mouseLocation].x - _startX); }
- (void)mouseUp:(NSEvent *)event { (void)event; if (self.onEnd) self.onEnd(); }
@end

@implementation RailSuggestion
@end

static const CGFloat RailSuggestionRow = 34, RailSuggestionInset = 6;

@implementation RailSuggestionList {
  NSTrackingArea *_hoverArea;
}
+ (CGFloat)heightForCount:(NSUInteger)count { return count * RailSuggestionRow + RailSuggestionInset * 2; }
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;
    self.layer.shadowColor = [NSColor colorWithWhite:0 alpha:1].CGColor; self.layer.shadowOpacity = .14;
    self.layer.shadowRadius = 10; self.layer.shadowOffset = CGSizeMake(0,-4);
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)setSuggestions:(NSArray<RailSuggestion *> *)suggestions { _suggestions = [suggestions copy]; self.needsDisplay = YES; }
- (void)setSelectedIndex:(NSInteger)selectedIndex { _selectedIndex = selectedIndex; self.needsDisplay = YES; }
- (NSInteger)rowAt:(NSPoint)point {
  NSInteger row = (NSInteger)floor((point.y - RailSuggestionInset) / RailSuggestionRow);
  return row >= 0 && row < (NSInteger)self.suggestions.count ? row : -1;
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_hoverArea) [self removeTrackingArea:_hoverArea];
  _hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
  [self addTrackingArea:_hoverArea];
}
- (void)mouseMoved:(NSEvent *)event {
  NSInteger row = [self rowAt:[self convertPoint:event.locationInWindow fromView:nil]];
  if (row >= 0 && row != self.selectedIndex) self.selectedIndex = row;
}
- (void)mouseDown:(NSEvent *)event {
  NSInteger row = [self rowAt:[self convertPoint:event.locationInWindow fromView:nil]];
  if (row >= 0 && self.onChoose) self.onChoose(row);
}
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSBezierPath *panel = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:10 yRadius:10];
  [NSColor.whiteColor setFill]; [panel fill];
  [RailColor(0xd4dde5) setStroke]; panel.lineWidth = 1; [panel stroke];
  CGFloat width = self.bounds.size.width;
  NSDictionary *titleAttrs = @{NSFontAttributeName:[NSFont systemFontOfSize:13], NSForegroundColorAttributeName:RailColor(0x273445)};
  NSDictionary *detailAttrs = @{NSFontAttributeName:[NSFont systemFontOfSize:12], NSForegroundColorAttributeName:RailColor(0x596879)};
  NSDictionary *selectedDetailAttrs = @{NSFontAttributeName:[NSFont systemFontOfSize:12], NSForegroundColorAttributeName:RailColor(0x245b96)};
  for (NSUInteger i = 0; i < self.suggestions.count; i++) {
    RailSuggestion *item = self.suggestions[i];
    NSRect row = NSMakeRect(RailSuggestionInset, RailSuggestionInset + i * RailSuggestionRow, width - RailSuggestionInset * 2, RailSuggestionRow);
    BOOL selected = (NSInteger)i == self.selectedIndex;
    if (selected) { [RailColor(0xd8e7f7) setFill]; [[NSBezierPath bezierPathWithRoundedRect:row xRadius:6 yRadius:6] fill]; }
    NSImage *icon = item.icon;
    if (icon && !item.iconKeepsColors) icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[RailColor(selected ? 0x245b96 : 0x596879)]]] ?: icon;
    if (icon) {
      NSSize size = icon.size; CGFloat scale = MIN(1, MIN(16 / MAX(size.width,1), 16 / MAX(size.height,1)));
      size = NSMakeSize(size.width * scale, size.height * scale);
      [icon drawInRect:NSMakeRect(NSMinX(row) + 10 + (16 - size.width) / 2, NSMidY(row) - size.height / 2, size.width, size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    // Title first, then the address in a quieter color, sharing one line like Chrome's omnibox.
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] initWithString:item.title ?: @"" attributes:titleAttrs];
    if (item.detail.length) {
      if (line.length) [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"  –  " attributes:detailAttrs]];
      [line appendAttributedString:[[NSAttributedString alloc] initWithString:item.detail attributes:selected ? selectedDetailAttrs : detailAttrs]];
    }
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init]; style.lineBreakMode = NSLineBreakByTruncatingTail;
    [line addAttribute:NSParagraphStyleAttributeName value:style range:NSMakeRange(0, line.length)];
    CGFloat h = 17;
    [line drawWithRect:NSMakeRect(NSMinX(row) + 36, NSMidY(row) - h / 2, NSWidth(row) - 46, h) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
  }
}
@end

@interface RailAddressField : NSTextField
@property(nonatomic, weak) RailAddressBar *bar;
@end
@interface RailAddressBar ()
- (void)syncFocusSoon;
@end

@implementation RailAddressField
- (BOOL)becomeFirstResponder { BOOL became = [super becomeFirstResponder]; [self.bar syncFocusSoon]; return became; }
- (void)mouseDown:(NSEvent *)event {
  // Like a browser: the first click selects the whole address, later clicks place the caret.
  BOOL wasEditing = self.currentEditor != nil;
  [super mouseDown:event];
  if (!wasEditing && self.currentEditor) [self.currentEditor selectAll:nil];
}
- (void)textDidEndEditing:(NSNotification *)notification {
  [super textDidEndEditing:notification];
  [self.bar syncFocusSoon];
}
@end

@implementation RailAddressBar {
  RailAddressField *_field;
  NSImageView *_icon;
  BOOL _hovered, _focused;
  NSTrackingArea *_hoverArea;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _icon = [[NSImageView alloc] init]; _icon.contentTintColor = RailColor(0x596879); [self addSubview:_icon];
    _field = [[RailAddressField alloc] init]; _field.bar = self;
    _field.font = [NSFont systemFontOfSize:13]; _field.textColor = RailColor(0x273445);
    _field.bordered = NO; _field.bezeled = NO; _field.drawsBackground = NO; _field.focusRingType = NSFocusRingTypeNone;
    _field.usesSingleLineMode = YES; _field.cell.scrollable = YES; _field.cell.wraps = NO; _field.lineBreakMode = NSLineBreakByClipping;
    [self addSubview:_field];
    self.symbolName = @"magnifyingglass";
  }
  return self;
}
- (NSTextField *)field { return _field; }
- (BOOL)isFlipped { return YES; }
- (void)setSymbolName:(NSString *)symbolName {
  if ([_symbolName isEqualToString:symbolName]) return;
  _symbolName = [symbolName copy]; _icon.image = RailSymbol(symbolName,12);
}
- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  CGFloat textHeight = _field.intrinsicContentSize.height;
  _icon.frame = NSMakeRect(10,(size.height-16)/2,16,16);
  _field.frame = NSMakeRect(31,floor((size.height-textHeight)/2),MAX(0,size.width-41),textHeight);
}
// Editing restarts briefly end and re-begin the field editor, so focus is read back after the event settles.
- (void)syncFocusSoon {
  __weak RailAddressBar *weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{ [weak syncFocus]; });
}
- (void)syncFocus {
  NSResponder *responder = self.window.firstResponder;
  BOOL focused = responder == _field || (_field.currentEditor && responder == _field.currentEditor);
  if (focused == _focused) return;
  _focused = focused; self.needsDisplay = YES;
  if (self.onFocusChange) self.onFocusChange(focused);
  if (focused) [_field.currentEditor selectAll:nil];
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_hoverArea) [self removeTrackingArea:_hoverArea];
  _hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect | NSTrackingCursorUpdate owner:self userInfo:nil];
  [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }
- (void)cursorUpdate:(NSEvent *)event { (void)event; [NSCursor.IBeamCursor set]; }
- (void)mouseDown:(NSEvent *)event { (void)event; [self.window makeFirstResponder:_field]; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSRect bounds = NSInsetRect(self.bounds, 1, 1);
  NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:8 yRadius:8];
  if (_focused) {
    [NSColor.whiteColor setFill]; [shape fill];
    [RailColor(0x3976be) setStroke]; shape.lineWidth = 2; [shape stroke];
  } else {
    [(_hovered ? RailColor(0xe2e8ef) : RailColor(0xe9eef3)) setFill]; [shape fill];
  }
}
@end
