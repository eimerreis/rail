#import "NativeViews.h"

typedef NS_ENUM(NSInteger, ProjectTone) {
  ProjectToneNeutral, ProjectToneInfo, ProjectToneOK, ProjectToneWarn, ProjectToneCritical,
  ProjectToneRunning, ProjectToneStopped, ProjectToneBusy, ProjectToneUnknown
};

// Shared drawing for project and activity views.
NSColor *ProjectToneText(ProjectTone tone);
NSColor *ProjectToneFill(ProjectTone tone);
void ProjectDrawDot(NSRect frame, ProjectTone tone);
void ProjectDrawMark(NSRect frame, NSString *mark, NSInteger style);
NSImage *ProjectStateSymbol(ProjectTone tone, CGFloat size);

// A coloured status label on a card. Clickable when it has a handler.
@interface ProjectPill : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *symbol;
@property(nonatomic) ProjectTone tone;
@property(nonatomic, copy) NSString *help;
@property(nonatomic, copy) void (^handler)(void);
@end

// One step on a project's path: Local, Repo, Pipelines, or an environment.
@interface ProjectRow : NSObject
@property(nonatomic) BOOL local;                // drawn apart from the promotion path
@property(nonatomic, copy) NSString *symbol;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *value;
@property(nonatomic) ProjectTone tone;          // dot and value colour; Neutral draws no dot
@property(nonatomic, copy) NSString *mark;      // session initial: W, P, I; nil when it's the Space's own session
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
@property(nonatomic) BOOL moving;               // a pipeline or deployment is under way
@property(nonatomic) ProjectTone changedTone;   // tints the lane just after one of the user's runs changed; Neutral for none
@property(nonatomic, strong) NSMenu *menu;
@end

// The Space's Projects page: a header with filters and one lane per project, grouped by state.
// Each lane reads left to right: what runs locally, then repo → pipeline → each environment.
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
