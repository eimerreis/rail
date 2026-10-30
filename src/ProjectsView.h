#import "NativeViews.h"

typedef NS_ENUM(NSInteger, ProjectTone) {
  ProjectToneNeutral, ProjectToneInfo, ProjectToneOK, ProjectToneWarn, ProjectToneCritical,
  ProjectToneRunning, ProjectToneStopped, ProjectToneBusy, ProjectToneUnknown
};

// A coloured status label on a card. Clickable when it has a handler.
@interface ProjectPill : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *symbol;
@property(nonatomic) ProjectTone tone;
@property(nonatomic, copy) NSString *help;
@property(nonatomic, copy) void (^handler)(void);
@end

// One row in the card's button stack: Repo, Pipelines, or an environment.
@interface ProjectRow : NSObject
@property(nonatomic, copy) NSString *symbol;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *value;
@property(nonatomic) ProjectTone tone;          // dot and value colour; Neutral draws no dot
@property(nonatomic, copy) NSString *mark;      // session initial: W, P, I
@property(nonatomic) NSInteger markStyle;       // 0 work, 1 personal, 2 isolated
@property(nonatomic, copy) NSString *help;
@property(nonatomic, copy) void (^handler)(void);
@property(nonatomic, strong) NSMenu *menu;
@end

// A custom link under the status area.
@interface ProjectChip : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic) BOOL iconKeepsColors;
@property(nonatomic, copy) NSString *help;
@property(nonatomic, copy) void (^handler)(void);
@property(nonatomic, strong) NSMenu *menu;
@end

@interface ProjectCard : NSObject
@property(nonatomic, copy) NSString *projectID;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *meta;
@property(nonatomic, copy) NSString *providerSymbol;
@property(nonatomic) NSInteger provider;        // 0 none, 1 Azure DevOps, 2 GitHub
@property(nonatomic, copy) NSArray<ProjectPill *> *pills;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSArray<ProjectRow *> *rows;
@property(nonatomic, copy) NSArray<ProjectChip *> *chips;
@property(nonatomic) BOOL needsAttention;
@property(nonatomic) BOOL runsLocally;
@property(nonatomic, strong) NSMenu *menu;
@end

// The Space home: a header with filters and a grid of project cards.
@interface ProjectsHomeView : RailPanel
@property(nonatomic, copy) NSString *spaceName;
@property(nonatomic, copy) NSString *summary;
@property(nonatomic, copy) NSArray<ProjectCard *> *cards;
@property(nonatomic) NSInteger filter;          // 0 all, 1 needs attention, 2 running locally
@property(nonatomic) BOOL checking;
@property(nonatomic, strong) NSMenu *addMenu;
@property(nonatomic, copy) void (^onAddProject)(void);
@property(nonatomic, copy) void (^onImportAzure)(void);
@property(nonatomic, copy) void (^onImportGitHub)(void);
@property(nonatomic, copy) void (^onCheckNow)(void);
@property(nonatomic, copy) void (^onFilter)(NSInteger filter);
- (void)reload;
@end
