#import <Cocoa/Cocoa.h>

NSColor *RailColor(unsigned int hex);
NSTextField *RailLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color);
NSImage *RailSymbol(NSString *name, CGFloat size);
extern NSPasteboardType const RailTabPasteboardType;

@interface RailPanel : NSView
@property(nonatomic, strong) NSColor *fill;
@property(nonatomic, copy) void (^onResize)(void);
// Drop target for dragged tabs; points are in this panel's coordinates.
@property(nonatomic, copy) NSDragOperation (^onTabDragOver)(NSString *tabID, NSPoint point);
@property(nonatomic, copy) BOOL (^onTabDrop)(NSString *tabID, NSPoint point);
@property(nonatomic, copy) void (^onTabDragEnd)(void);
@end

@interface RailButton : NSButton <NSDraggingSource>
// Set to make the button draggable; a click still performs its action.
@property(nonatomic, copy) NSString *dragTabID;
@property(nonatomic, weak) NSView *dragView;
@property(nonatomic, copy) void (^handler)(void);
@property(nonatomic, strong) NSColor *normalFill;
@property(nonatomic, strong) NSColor *hoverFill;
@property(nonatomic, strong) NSColor *ink;
@property(nonatomic, strong) NSColor *stroke;
@property(nonatomic) BOOL centered;
@property(nonatomic) CGFloat cornerRadius;
// Bitmap images such as favicons keep their own colors instead of taking the ink color.
@property(nonatomic) BOOL keepsImageColors;
@property(nonatomic) CGFloat imageOpacity;
@end

RailButton *RailAction(NSString *title, NSString *symbol, NSString *help, void (^handler)(void));

@interface RailResizeHandle : NSView
@property(nonatomic, copy) void (^onBegin)(void);
// Distance from where the drag started, so limits applied by the owner do not drift the cursor.
@property(nonatomic, copy) void (^onDrag)(CGFloat deltaX);
@property(nonatomic, copy) void (^onEnd)(void);
@end

@interface RailSuggestion : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic) BOOL iconKeepsColors;
@end

@interface RailSuggestionList : NSView
@property(nonatomic, copy) NSArray<RailSuggestion *> *suggestions;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, copy) void (^onChoose)(NSInteger index);
+ (CGFloat)heightForCount:(NSUInteger)count;
@end

@interface RailAddressBar : NSView
@property(nonatomic, readonly) NSTextField *field;
@property(nonatomic, copy) NSString *symbolName;
@property(nonatomic, copy) void (^onFocusChange)(BOOL focused);
@end
