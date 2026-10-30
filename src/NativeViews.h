#import <Cocoa/Cocoa.h>

NSColor *RailColor(unsigned int hex);
NSTextField *RailLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color);
NSImage *RailSymbol(NSString *name, CGFloat size);
extern NSPasteboardType const RailTabPasteboardType;
// Zooms or minimizes the window as System Settings › Desktop & Dock asks for a title bar double-click.
void RailTitlebarDoubleClick(NSWindow *window);

@interface RailPanel : NSView
@property(nonatomic, strong) NSColor *fill;
@property(nonatomic, copy) void (^onResize)(void);
// Double-clicking the top titlebarHeight points acts like double-clicking a window title bar.
@property(nonatomic) CGFloat titlebarHeight;
// Called when the pointer enters or leaves the panel, including when it is rebuilt under the pointer.
@property(nonatomic, copy) void (^onHoverChange)(BOOL hovered);
// Draws the contents this much larger: subviews are laid out in bounds that are frame / contentScale.
@property(nonatomic) CGFloat contentScale;
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
// Runs on a double-click, after the first click has performed the action.
@property(nonatomic, copy) void (^onDoubleClick)(void);
@property(nonatomic, strong) NSColor *normalFill;
@property(nonatomic, strong) NSColor *hoverFill;
@property(nonatomic, strong) NSColor *ink;
@property(nonatomic, strong) NSColor *stroke;
@property(nonatomic) BOOL centered;
@property(nonatomic) CGFloat cornerRadius;
// Bitmap images such as favicons keep their own colors instead of taking the ink color.
@property(nonatomic) BOOL keepsImageColors;
@property(nonatomic) CGFloat imageOpacity;
// A ring around the button showing progress from 0 to 1; negative hides it.
@property(nonatomic) CGFloat progress;
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

@interface RailDownloadRow : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, strong) NSImage *icon;
// 0–1 while downloading, negative otherwise.
@property(nonatomic) CGFloat progress;
// SF Symbol at the end of the row, e.g. reveal in Finder or cancel; nil for none.
@property(nonatomic, copy) NSString *accessorySymbol;
@property(nonatomic, copy) NSString *accessoryHelp;
@end

@interface RailDownloadList : NSView
@property(nonatomic, copy) NSArray<RailDownloadRow *> *rows;
// accessory is YES when the symbol at the end of the row was clicked.
@property(nonatomic, copy) void (^onChoose)(NSInteger index, BOOL accessory);
@property(nonatomic, copy) NSMenu *(^menuForRow)(NSInteger index);
+ (CGFloat)heightForCount:(NSUInteger)count;
@end
