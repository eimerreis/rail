#import <Cocoa/Cocoa.h>

// Rail's three shell themes and its typeface. Colours are semantic and dynamic: each one
// resolves against the current theme whenever it is drawn, so switching themes needs only a
// redraw, plus a rebuild of views that copied a colour into a layer (CGColor) or an image.

typedef NS_ENUM(NSInteger, RailRole) {
  // Surfaces
  RailRoleRail, RailRoleShell, RailRoleSidebar, RailRoleContent, RailRoleRaised, RailRoleSunken,
  // Text
  RailRoleInk, RailRoleMuted, RailRoleFaint, RailRoleOnAccent,
  // Lines
  RailRoleLine, RailRoleLineSoft, RailRoleLineStrong,
  // Interaction on chrome (rail, sidebar, toolbar) and on content (pages, cards, popovers)
  RailRoleHover, RailRolePressed, RailRoleContentHover,
  RailRoleSelected, RailRoleSelectedHover, RailRoleSelectedInk, RailRoleAccent, RailRoleFocus,
  RailRoleField, RailRoleFieldHover,
  // The selected Space's tile in the rail
  RailRoleSpaceActive, RailRoleSpaceActiveHover, RailRoleSpaceActiveInk,
  RailRolePin,
  // Project and pull request states
  RailRoleCriticalInk, RailRoleCriticalFill, RailRoleCriticalDot,
  RailRoleWarnInk, RailRoleWarnFill, RailRoleWarnDot,
  RailRoleOKInk, RailRoleOKFill, RailRoleOKDot,
  RailRoleInfoInk, RailRoleInfoFill, RailRoleInfoDot,
  RailRoleNeutralFill, RailRoleStoppedDot, RailRoleUnknownDot,
  // Session markers: W, P, I
  RailRoleWorkFill, RailRoleWorkInk, RailRolePersonalFill, RailRolePersonalInk, RailRoleIsolatedFill, RailRoleIsolatedInk,
  RailRoleCount
};

// Stable IDs, as saved in state.json, and their display names.
NSArray<NSString *> *RailThemeIDs(void);
NSString *RailThemeName(NSString *themeID);
NSString *RailCurrentTheme(void);
// Switches the theme for every Rail window; unknown IDs fall back to Porcelain.
// Posts RailThemeDidChangeNotification when the theme actually changed.
void RailSetTheme(NSString *themeID);
extern NSNotificationName const RailThemeDidChangeNotification;
// The native look for Rail's windows and popovers: dark Aqua for Nightline, Aqua otherwise.
NSAppearance *RailThemeAppearance(void);
BOOL RailThemeIsDark(void);

NSColor *RailTint(RailRole role);
// Shorthands for the most used roles.
static inline NSColor *RailInk(void) { return RailTint(RailRoleInk); }
static inline NSColor *RailMuted(void) { return RailTint(RailRoleMuted); }
static inline NSColor *RailLine(void) { return RailTint(RailRoleLine); }
// Session marker colours for a session ID: work and other named sessions, personal, isolated.
NSColor *RailSessionFill(NSInteger style);
NSColor *RailSessionInk(NSInteger style);
// Marks every view in Rail's windows for redrawing, so dynamic colours resolve again.
void RailRedrawAllWindows(void);

// Manrope, bundled with the app; the system font when it isn't available.
// Weights map to Manrope 450 (regular), 530 (medium), 600 (semibold) and 700 (bold).
void RailRegisterFonts(void);
NSFont *RailFont(CGFloat size, NSFontWeight weight);
// Manrope with tabular figures, for counts, ages and sizes that line up.
NSFont *RailDigitsFont(CGFloat size, NSFontWeight weight);

// The approved rounded R on its near-black tile, drawn crisply at any size.
NSImage *RailMarkImage(void);
