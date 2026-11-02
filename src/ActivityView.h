#import "ProjectsView.h"

// One line in a pull request's detail: a check, a policy, or a reviewer.
@interface ActivityStep : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic) ProjectTone tone;
@property(nonatomic, copy) NSString *initials;   // reviewers draw an avatar instead of a state symbol
@property(nonatomic, copy) NSString *help;
@property(nonatomic, copy) void (^handler)(void);
@end

// One of the user's own open pull requests.
@interface ActivityItem : NSObject
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *project;
@property(nonatomic, copy) NSString *number;     // "!1187" or "#214"
@property(nonatomic, copy) NSString *branches;   // "seat-transfer → release/2.14"
@property(nonatomic, copy) NSString *age;        // "3 d"
@property(nonatomic, copy) NSString *opened;     // "opened 3 days ago"
@property(nonatomic, copy) NSString *reason;
@property(nonatomic) ProjectTone reasonTone;
@property(nonatomic) ProjectTone checksTone;     // the list glyph
@property(nonatomic) NSInteger stage;            // 0 needs you, 1 waiting on others, 2 ready to merge
@property(nonatomic) NSInteger provider;         // 1 Azure DevOps, 2 GitHub
@property(nonatomic, copy) NSString *openTitle;  // "Open in Azure DevOps"
@property(nonatomic, copy) NSString *mark;
@property(nonatomic) NSInteger markStyle;
@property(nonatomic, copy) NSArray<ProjectPill *> *pills;
@property(nonatomic, copy) NSArray<ActivityStep *> *checks;
@property(nonatomic, copy) NSArray<ActivityStep *> *policies;
@property(nonatomic, copy) NSArray<ActivityStep *> *reviewers;
@property(nonatomic, copy) void (^open)(void);
@end

// The Space's Activity page: the user's own pull requests on the left, grouped by who has to act,
// and the selected one's checks, policies and reviewers on the right.
@interface ActivityView : RailPanel
@property(nonatomic, copy) NSString *summary;
@property(nonatomic, copy) NSArray<ActivityItem *> *items;
@property(nonatomic, copy) NSString *selectedKey;
@property(nonatomic) BOOL checking;
@property(nonatomic, copy) NSString *emptyTitle;
@property(nonatomic, copy) NSString *emptyDetail;
@property(nonatomic, copy) void (^onCheckNow)(void);
@property(nonatomic, copy) void (^onSelect)(NSString *key);
- (void)reload;
@end
