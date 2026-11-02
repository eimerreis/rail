#import "Theme.h"
#import <CoreText/CoreText.h>

NSNotificationName const RailThemeDidChangeNotification = @"RailThemeDidChange";

namespace {
enum Theme { Porcelain, Nightline, Daylight, ThemeCount };
Theme current = Porcelain;

// One row per theme, in RailRole order. Starting values come from the theme handover
// (docs/handoff/rail-branding); the rest are derived from each mood and checked for contrast:
// text pairs reach 4.5:1, state dots and focus rings 3:1.
const unsigned Palettes[ThemeCount][RailRoleCount] = {
  { // Porcelain: warm limestone, putty and ivory with dark sage
    0xE3DDD2, 0xEEEAE2, 0xE8E3D9, 0xFAF8F2, 0xFFFDF9, 0xF3F0E9,
    0x292D29, 0x575B52, 0x86877C, 0xFBF7EE,
    0xD6CFC2, 0xE7E2D8, 0xBDB5A6,
    0xDDD7CB, 0xD2CBBD, 0xF1EEE6,
    0xDCE5D7, 0xCFDBC9, 0x3B5240, 0x526A54, 0x526A54,
    0xF7F4EE, 0xFBF9F4,
    0x526A54, 0x465C48, 0xF7F1E3,
    0xF2EEE6,
    0xA3372A, 0xF5E0D9, 0xC94F3B,
    0x7A5310, 0xF3E7CC, 0xC4881F,
    0x2E6640, 0xDDEBDB, 0x3E8A55,
    0x35617A, 0xDCE7EA, 0x4C7E98,
    0xEDE9E0, 0x8F8B7E, 0xCFCABF,
    0xDDE4E8, 0x3B5468, 0xDCE5D7, 0x43604A, 0xECDFCD, 0x6E4F2D,
  },
  { // Nightline: deep petrol with cream type and mint accents
    0x0F2427, 0x122A2D, 0x173237, 0x1D3A3D, 0x224344, 0x193538,
    0xF5EBD7, 0xA6BAB2, 0x7C9590, 0x10292B,
    0x365052, 0x2A4648, 0x5A7678,
    0x21403F, 0x2A4B4A, 0x264848,
    0x315950, 0x386559, 0xF5EBD7, 0xA8CABB, 0xA8CABB,
    0x1A3639, 0x1F3D40,
    0xF5EBD7, 0xE9DDC4, 0x173237,
    0x1B383B,
    0xF2A595, 0x4A2B29, 0xE46B56,
    0xE9C47E, 0x433820, 0xD9A441,
    0xA3D9B1, 0x1F4535, 0x5CBF7C,
    0xA6CEE2, 0x1F4050, 0x6CB0D3,
    0x21403F, 0x7C9590, 0x56716F,
    0x254659, 0xBBD5EA, 0x2B4B3B, 0xB6DABE, 0x4A3C27, 0xE6CC9C,
  },
  { // Daylight: pale sky and powder blue, ocean accent, coral for the active Space only
    0xD5E3EE, 0xE5EEF5, 0xDCE8F1, 0xFCFDFE, 0xFFFFFF, 0xF3F7FA,
    0x243B50, 0x4A6172, 0x788D9C, 0xFFFFFF,
    0xC8D7E2, 0xDFE8EF, 0xADC0CE,
    0xCEDDE9, 0xC2D4E3, 0xEEF3F8,
    0xCADFED, 0xBCD6E8, 0x1D5174, 0x2C6184, 0x2C6184,
    0xF5F9FC, 0xFAFCFE,
    0xC2654A, 0xB45A40, 0xFFF6EC,
    0xEBF2F8,
    0xA83A2B, 0xFAE3DE, 0xD2533E,
    0x7D5510, 0xFAEFD6, 0xC0821A,
    0x2A6B42, 0xDFF0E4, 0x3D965C,
    0x245B86, 0xD6E6F2, 0x3A76A8,
    0xE6EEF4, 0x8396A5, 0xC5D2DC,
    0xD6E5F3, 0x345A80, 0xDAEBDD, 0x426A4A, 0xF0E3D5, 0x74533A,
  },
};
NSString *const IDs[ThemeCount] = {@"porcelain", @"nightline", @"daylight"};
NSString *const Names[ThemeCount] = {@"Porcelain", @"Nightline", @"Daylight"};

Theme ThemeFor(NSString *themeID) {
  for (int i = 0; i < ThemeCount; i++) if ([IDs[i] isEqualToString:themeID]) return (Theme)i;
  return Porcelain;
}
NSColor *Resolved(Theme theme, RailRole role) {
  static NSColor *cache[ThemeCount][RailRoleCount];
  NSColor *__strong &color = cache[theme][role];
  if (!color) {
    unsigned h = Palettes[theme][role];
    color = [NSColor colorWithSRGBRed:((h >> 16) & 255) / 255.0 green:((h >> 8) & 255) / 255.0 blue:(h & 255) / 255.0 alpha:1];
  }
  return color;
}

NSString *ManropeName = nil;
}

NSArray<NSString *> *RailThemeIDs(void) { return @[IDs[Porcelain], IDs[Nightline], IDs[Daylight]]; }
NSString *RailThemeName(NSString *themeID) { return Names[ThemeFor(themeID)]; }
NSString *RailCurrentTheme(void) { return IDs[current]; }
BOOL RailThemeIsDark(void) { return current == Nightline; }
NSAppearance *RailThemeAppearance(void) { return [NSAppearance appearanceNamed:current == Nightline ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua]; }

void RailSetTheme(NSString *themeID) {
  Theme theme = ThemeFor(themeID);
  if (theme == current) return;
  current = theme;
  [NSNotificationCenter.defaultCenter postNotificationName:RailThemeDidChangeNotification object:nil];
}

NSColor *RailTint(RailRole role) {
  static NSColor *dynamic[RailRoleCount];
  if (role < 0 || role >= RailRoleCount) role = RailRoleInk;
  if (!dynamic[role]) {
    dynamic[role] = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) { (void)appearance; return Resolved(current, role); }];
  }
  return dynamic[role];
}
NSColor *RailSessionFill(NSInteger style) { return RailTint(style == 2 ? RailRoleIsolatedFill : style == 1 ? RailRolePersonalFill : RailRoleWorkFill); }
NSColor *RailSessionInk(NSInteger style) { return RailTint(style == 2 ? RailRoleIsolatedInk : style == 1 ? RailRolePersonalInk : RailRoleWorkInk); }

static void Redraw(NSView *view) {
  view.needsDisplay = YES;
  for (NSView *child in view.subviews) Redraw(child);
}
void RailRedrawAllWindows(void) {
  for (NSWindow *window in NSApp.windows) {
    // The frame view draws the window background and title bar.
    NSView *frame = window.contentView.superview ?: window.contentView;
    if (frame) Redraw(frame);
  }
}

#pragma mark Fonts

void RailRegisterFonts(void) {
  NSURL *url = [NSBundle.mainBundle URLForResource:@"Manrope-Variable" withExtension:@"ttf" subdirectory:@"Fonts"];
  if (!url) return;
  CFErrorRef error = NULL;
  if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
    // Already registered by an earlier call is fine; anything else leaves the system font in place.
    NSError *failure = CFBridgingRelease(error);
    if (failure.code != kCTFontManagerErrorAlreadyRegistered) { NSLog(@"Rail could not load Manrope: %@", failure.localizedDescription); return; }
  }
  if ([NSFont fontWithName:@"Manrope-Regular" size:12]) ManropeName = @"Manrope-Regular";
}

static CGFloat ManropeWeight(NSFontWeight weight) {
  if (weight >= NSFontWeightBold) return 700;
  if (weight >= NSFontWeightSemibold) return 600;
  if (weight >= NSFontWeightMedium) return 530;
  if (weight >= NSFontWeightRegular) return 450;
  return 380;
}

static NSFont *Make(CGFloat size, NSFontWeight weight, BOOL digits) {
  static NSMutableDictionary<NSString *, NSFont *> *cache;
  if (!cache) cache = [NSMutableDictionary dictionary];
  NSString *key = [NSString stringWithFormat:@"%.2f/%.3f/%d", size, weight, digits];
  NSFont *font = cache[key];
  if (font) return font;
  if (ManropeName) {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithObject:@{@(0x77676874 /* 'wght' */): @(ManropeWeight(weight))} forKey:(NSString *)kCTFontVariationAttribute];
    if (digits) attributes[NSFontFeatureSettingsAttribute] = @[@{NSFontFeatureTypeIdentifierKey: @(kNumberSpacingType), NSFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector)}];
    NSFontDescriptor *descriptor = [[NSFontDescriptor fontDescriptorWithName:ManropeName size:size] fontDescriptorByAddingAttributes:attributes];
    font = [NSFont fontWithDescriptor:descriptor size:size];
  }
  if (!font) font = digits ? [NSFont monospacedDigitSystemFontOfSize:size weight:weight] : [NSFont systemFontOfSize:size weight:weight];
  cache[key] = font;
  return font;
}
NSFont *RailFont(CGFloat size, NSFontWeight weight) { return Make(size, weight, NO); }
NSFont *RailDigitsFont(CGFloat size, NSFontWeight weight) { return Make(size, weight, YES); }

#pragma mark Mark

NSImage *RailMarkImage(void) {
  static NSImage *mark;
  if (mark) return mark;
  NSURL *url = [NSBundle.mainBundle URLForResource:@"RailMark" withExtension:@"pdf"];
  mark = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
  if (!mark) {
    // Without the bundled artwork: a cream R on the near-black tile, set in the brand face.
    mark = [NSImage imageWithSize:NSMakeSize(64, 64) flipped:NO drawingHandler:^BOOL(NSRect rect) {
      [[NSColor colorWithSRGBRed:.04 green:.04 blue:.04 alpha:1] setFill];
      [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:14 yRadius:14] fill];
      NSDictionary *attrs = @{NSFontAttributeName: RailFont(40, NSFontWeightBold), NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1 green:.94 blue:.84 alpha:1]};
      NSSize size = [@"R" sizeWithAttributes:attrs];
      [@"R" drawAtPoint:NSMakePoint(NSMidX(rect) - size.width / 2, NSMidY(rect) - size.height / 2) withAttributes:attrs];
      return YES;
    }];
  }
  mark.accessibilityDescription = @"Rail";
  return mark;
}
