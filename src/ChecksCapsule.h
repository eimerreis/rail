#import "ProjectsView.h"

// One line in the Capsule's list.
@interface ChecksEntry : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *age;
@property(nonatomic) ProjectTone tone;
@property(nonatomic) NSInteger section;          // 0 failed, 1 waiting for approval, 2 running, 3 finished
@property(nonatomic, copy) void (^open)(void);
@property(nonatomic, copy) void (^showInActivity)(void);
@property(nonatomic, copy) void (^dismiss)(void);
@end

// The toolbar control that carries every Tracked Run: counts by state, or an Announcement while
// something has just happened. See GLOSSARY.md.
@interface ChecksCapsule : NSButton
@property(nonatomic) NSInteger running, waiting, failed, passed;
@property(nonatomic) BOOL warning;
@property(nonatomic, copy) NSString *announceTitle;   // nil shows the counts
@property(nonatomic, copy) NSString *announceDetail;
@property(nonatomic) ProjectTone announceTone;
@property(nonatomic) BOOL listOpen;
@property(nonatomic, copy) void (^onToggle)(void);
@property(nonatomic, copy) void (^onOpenAnnounced)(void);
@property(nonatomic, copy) void (^onDismissAnnounced)(void);  // nil when there is nothing to dismiss
- (void)reload;
- (CGFloat)preferredWidth;
@end

// The list behind the Capsule, shown in a popover.
@interface ChecksListView : RailPanel
@property(nonatomic, copy) NSArray<NSString *> *warnings;
@property(nonatomic, copy) void (^onWarning)(NSInteger index);
@property(nonatomic, copy) NSArray<ChecksEntry *> *entries;
@property(nonatomic, copy) void (^onClear)(void);     // nil when nothing is finished
// Lays out the list and returns the size it would like.
- (NSSize)reload;
@end
