#import <Cocoa/Cocoa.h>

NSColor *RailColor(unsigned int hex);
NSTextField *RailLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color);
NSImage *RailSymbol(NSString *name, CGFloat size);

@interface RailPanel : NSView
@property(nonatomic, strong) NSColor *fill;
@property(nonatomic, copy) void (^onResize)(void);
@end

@interface RailButton : NSButton
@property(nonatomic, copy) void (^handler)(void);
@property(nonatomic, strong) NSColor *normalFill;
@property(nonatomic, strong) NSColor *hoverFill;
@property(nonatomic, strong) NSColor *ink;
@property(nonatomic, strong) NSColor *stroke;
@property(nonatomic) BOOL centered;
@property(nonatomic) CGFloat cornerRadius;
@end

RailButton *RailAction(NSString *title, NSString *symbol, NSString *help, void (^handler)(void));
