#import <Cocoa/Cocoa.h>
#import "BrowserController.h"
#import "CEFBridge.h"
#import "Keychain.h"
#import "Theme.h"
#include "include/cef_application_mac.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include <fcntl.h>
#include <limits.h>
#include <unistd.h>

@interface RailApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@property(nonatomic, weak) BrowserController *browserController;
@end
@implementation RailApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent scope;
  if ((event.type==NSEventTypeKeyDown || event.type==NSEventTypeFlagsChanged) && [self.browserController handleShortcut:event]) return;
  [super sendEvent:event];
}
- (void)terminate:(id)sender { [self.browserController quit:sender]; }
@end

@interface RailDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) BrowserController *controller;
@end
@implementation RailDelegate
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)flag {
  (void)application; (void)flag; [self.controller.window makeKeyAndOrderFront:nil]; return YES;
}
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls { (void)application; [self.controller openExternalURLs:urls]; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { (void)app; return YES; }
@end

// The app was called Eimerrail before. On the first launch after the rename, take over its data
// folder, the key Chromium encrypts cookies with, saved connections and preferences.
static void MigrateEimerrailData(NSString *directory) {
  NSFileManager *files=NSFileManager.defaultManager;
  NSString *legacy=[directory.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Eimerrail"];
  if ([files fileExistsAtPath:directory] || ![files fileExistsAtPath:legacy]) return;
  if ([NSRunningApplication runningApplicationsWithBundleIdentifier:@"de.eimerreis.eimerrail"].count) {
    NSAlert *alert=[[NSAlert alloc] init];
    alert.messageText=@"Quit Eimerrail to move your data to Rail";
    alert.informativeText=@"Rail takes over the tabs, logins and connections of Eimerrail on its first launch. Quit Eimerrail, then open Rail again.";
    [alert runModal]; exit(0);
  }
  NSError *error=nil;
  if (![files moveItemAtPath:legacy toPath:directory error:&error]) {
    NSLog(@"Rail cannot move the Eimerrail data folder: %@",error.localizedDescription); return;
  }
  KeychainRenameItems(@"Eimerrail Safe Storage",@"Eimerrail",@"Rail Safe Storage",@"Rail",@"Rail Safe Storage");
  KeychainRenameItems(@"Eimerrail Connections",nil,@"Rail Connections",nil,@"Rail connection");
  NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
  [[defaults persistentDomainForName:@"de.eimerreis.eimerrail"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
    (void)stop; [defaults setObject:value forKey:[key stringByReplacingOccurrencesOfString:@"Eimerrail" withString:@"Rail"]];
  }];
  [defaults removePersistentDomainForName:@"de.eimerreis.eimerrail"];
}

int main(int argc, char *argv[]) {
  CefScopedLibraryLoader library;
  if (!library.LoadInMain()) return 1;
  @autoreleasepool {
    [RailApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    CefRefPtr<CefCommandLine> command=CefCommandLine::CreateCommandLine(); command->InitFromArgv(argc,argv);
    BOOL automation=command->HasSwitch("automation");
    if (automation && (!command->HasSwitch("data-dir") || command->GetSwitchValue("data-dir").empty())) {
      NSLog(@"Automation requires an explicit disposable --data-dir."); return 1;
    }
    NSString *defaultDirectory=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Rail"];
    NSString *directory;
    if (command->HasSwitch("data-dir")) directory=[NSString stringWithUTF8String:command->GetSwitchValue("data-dir").ToString().c_str()];
    else {
      directory=defaultDirectory;
      MigrateEimerrailData(directory);
    }
    NSError *error=nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
      NSLog(@"Rail cannot create its data folder: %@",error.localizedDescription); return 1;
    }
    // Chromium compares profile parent paths byte-for-byte. F_GETPATH resolves
    // the actual casing on macOS's normally case-insensitive filesystem.
    int descriptor=open(directory.fileSystemRepresentation,O_RDONLY);
    char canonical[PATH_MAX];
    if (descriptor<0 || fcntl(descriptor,F_GETPATH,canonical)<0) {
      if (descriptor>=0) close(descriptor);
      NSLog(@"Rail cannot resolve its data folder."); return 1;
    }
    close(descriptor); directory=[NSFileManager.defaultManager stringWithFileSystemRepresentation:canonical length:strlen(canonical)];
    if (automation && [directory isEqualToString:defaultDirectory.stringByResolvingSymlinksInPath]) {
      NSLog(@"Automation cannot use the normal Rail profile. Supply a disposable --data-dir."); return 1;
    }
    // Keep the reason for an uncaught exception; macOS crash reports lose it when AppKit rethrows.
    static NSString *crashLog=nil; crashLog=[[directory stringByAppendingPathComponent:@"crash.log"] copy];
    NSSetUncaughtExceptionHandler([](NSException *exception) {
      NSString *text=[NSString stringWithFormat:@"%@\n%@: %@\n%@\n",NSDate.date,exception.name,exception.reason,[exception.callStackSymbols componentsJoinedByString:@"\n"]];
      [text writeToFile:crashLog atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
    // Rail's typeface is bundled; register it before any view measures text.
    RailRegisterFonts();
    BrowserController *controller=[[BrowserController alloc] initWithDataDirectory:directory automation:automation];
    RailDelegate *delegate=[[RailDelegate alloc] init]; delegate.controller=controller;
    NSApp.delegate=delegate; ((RailApplication *)NSApp).browserController=controller;
    CefSettings settings;
    // CEF dynamically loads its signed framework. The helper initializes Chromium's sandbox.
    settings.no_sandbox=false;
    // Tests still exercise real cookie encryption, with one reusable test-only
    // Keychain item instead of requesting access to the everyday browser's key.
    CefString(&settings.keychain_service_name)=automation ? "Rail Test Safe Storage" : "Rail Safe Storage";
    CefString(&settings.keychain_account_name)="Rail";
    CefString(&settings.root_cache_path)=[directory stringByAppendingPathComponent:@"Chromium"].UTF8String;
    CefString(&settings.cache_path)=[directory stringByAppendingPathComponent:@"Chromium/default"].UTF8String;
    CefString(&settings.log_file)=[directory stringByAppendingPathComponent:@"cef.log"].UTF8String;
    settings.log_severity=LOGSEVERITY_WARNING;
    if (automation && command->HasSwitch("debug-port")) {
      int port=std::atoi(command->GetSwitchValue("debug-port").ToString().c_str());
      if (port>=1024 && port<=65535) settings.remote_debugging_port=port;
    }
    CefMainArgs args(argc,argv); CefRefPtr<CefApp> app=MakeRailApp(controller);
    if (!CefInitialize(args,settings,app,nullptr)) return CefGetExitCode();
    CefRunMessageLoop();
    delegate.controller=nil; ((RailApplication *)NSApp).browserController=nil; controller=nil;
    CefShutdown(); NSApp.delegate=nil;
  }
  return 0;
}
