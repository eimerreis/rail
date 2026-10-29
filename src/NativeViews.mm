#import "NativeViews.h"

NSColor *RailColor(unsigned int h) {
  return [NSColor colorWithSRGBRed:((h >> 16) & 255) / 255.0 green:((h >> 8) & 255) / 255.0 blue:(h & 255) / 255.0 alpha:1];
}
NSImage *RailSymbol(NSString *name, CGFloat size) {
  NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  return [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightRegular]];
}
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
@end

@implementation RailButton {
  BOOL _hovered;
  NSTrackingArea *_hoverArea;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.bordered = NO; self.bezelStyle = NSBezelStyleRegularSquare;
    self.font = [NSFont systemFontOfSize:12]; self.ink = RailColor(0x273445);
    self.cornerRadius = 6; self.hoverFill = RailColor(0xe2e8ef);
    self.target = self; self.action = @selector(invoke:);
    self.focusRingType = NSFocusRingTypeExterior;
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)invoke:(id)sender { (void)sender; if (self.handler) self.handler(); }
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
  CGFloat imageSize = self.image ? 15 : 0;
  CGFloat textWidth = self.title.length ? [self.title sizeWithAttributes:attrs].width : 0;
  CGFloat gap = (imageSize && textWidth) ? 7 : 0;
  CGFloat start = self.centered ? MAX(1, (bounds.size.width - imageSize - gap - textWidth) / 2) : 9;
  if (self.image) {
    NSImage *image = [self.image copy];
    NSImageSymbolConfiguration *color = [NSImageSymbolConfiguration configurationWithPaletteColors:@[ink]];
    image = [image imageWithSymbolConfiguration:color] ?: image;
    [image drawInRect:NSMakeRect(start, (bounds.size.height - imageSize) / 2, imageSize, imageSize) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:self.enabled ? 1 : .4 respectFlipped:YES hints:nil];
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
