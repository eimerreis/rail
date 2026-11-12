#import <Cocoa/Cocoa.h>
#include <string>
#include "BrowserModel.h"
#include "Projects.h"

// What the Settings window reads and changes. The browser controller owns the state;
// the window edits it in place and reports each change so the browser can refresh and save.
@protocol SettingsHost <NSObject>
- (rail::BrowserModel &)settingsModel;
- (rail::Projects &)settingsProjects;
- (const rail::StatusSnapshot &)settingsStatus;
- (NSString *)symbolForSpace:(const rail::Space &)space index:(size_t)index;
// Layout, tabs, Spaces or sessions changed.
- (void)settingsChanged;
- (void)settingsProjectsChanged;
- (void)settingsSetDevToolsDocked:(BOOL)docked;
- (void)settingsSetSearchEngine:(const std::string &)engineID;
- (void)makeDefaultBrowser:(id)sender;
- (void)settingsSignIn:(const std::string &)connectionID;
- (void)showPasswords:(id)sender;
- (void)settingsShowSpaceHome:(const std::string &)spaceID;
@end

@interface SettingsWindowController : NSObject <NSWindowDelegate>
- (instancetype)initWithHost:(id<SettingsHost>)host;
@property(nonatomic, readonly) NSWindow *window;
// Shows the window, on pane when given: appearance, tabs, developer, browser, spaces, sessions, projects, connections.
- (void)showPane:(NSString *)pane;
// Shows Spaces with one Space opened for editing.
- (void)showSpace:(NSString *)spaceID;
// Rebuilds the visible pane from the current state, e.g. after the browser changed something.
- (void)reload;
@property(nonatomic, readonly) NSString *pane;
@end
