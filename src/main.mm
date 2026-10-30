#import <Cocoa/Cocoa.h>
#import "BrowserController.h"
#import "CEFBridge.h"
#include "include/cef_application_mac.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include <fcntl.h>
#include <limits.h>
#include <unistd.h>

@interface EimerrailApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@property(nonatomic, weak) BrowserController *browserController;
@end
@implementation EimerrailApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent scope;
  if ((event.type==NSEventTypeKeyDown || event.type==NSEventTypeFlagsChanged) && [self.browserController handleShortcut:event]) return;
  [super sendEvent:event];
}
- (void)terminate:(id)sender { [self.browserController quit:sender]; }
@end

@interface EimerrailDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) BrowserController *controller;
@end
@implementation EimerrailDelegate
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)flag {
  (void)application; (void)flag; [self.controller.window makeKeyAndOrderFront:nil]; return YES;
}
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls { (void)application; [self.controller openExternalURLs:urls]; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { (void)app; return YES; }
@end

int main(int argc, char *argv[]) {
  CefScopedLibraryLoader library;
  if (!library.LoadInMain()) return 1;
  @autoreleasepool {
    [EimerrailApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    CefRefPtr<CefCommandLine> command=CefCommandLine::CreateCommandLine(); command->InitFromArgv(argc,argv);
    NSString *directory;
    if (command->HasSwitch("data-dir")) directory=[NSString stringWithUTF8String:command->GetSwitchValue("data-dir").ToString().c_str()];
    else directory=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Eimerrail"];
    NSError *error=nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
      NSLog(@"Eimerrail cannot create its data folder: %@",error.localizedDescription); return 1;
    }
    // Chromium compares profile parent paths byte-for-byte. F_GETPATH resolves
    // the actual casing on macOS's normally case-insensitive filesystem.
    int descriptor=open(directory.fileSystemRepresentation,O_RDONLY);
    char canonical[PATH_MAX];
    if (descriptor<0 || fcntl(descriptor,F_GETPATH,canonical)<0) {
      if (descriptor>=0) close(descriptor);
      NSLog(@"Eimerrail cannot resolve its data folder."); return 1;
    }
    close(descriptor); directory=[NSFileManager.defaultManager stringWithFileSystemRepresentation:canonical length:strlen(canonical)];
    // Keep the reason for an uncaught exception; macOS crash reports lose it when AppKit rethrows.
    static NSString *crashLog=nil; crashLog=[[directory stringByAppendingPathComponent:@"crash.log"] copy];
    NSSetUncaughtExceptionHandler([](NSException *exception) {
      NSString *text=[NSString stringWithFormat:@"%@\n%@: %@\n%@\n",NSDate.date,exception.name,exception.reason,[exception.callStackSymbols componentsJoinedByString:@"\n"]];
      [text writeToFile:crashLog atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
    BrowserController *controller=[[BrowserController alloc] initWithDataDirectory:directory automation:command->HasSwitch("automation")];
    EimerrailDelegate *delegate=[[EimerrailDelegate alloc] init]; delegate.controller=controller;
    NSApp.delegate=delegate; ((EimerrailApplication *)NSApp).browserController=controller;
    CefSettings settings;
    // CEF dynamically loads its signed framework. The helper initializes Chromium's sandbox.
    settings.no_sandbox=false;
    CefString(&settings.keychain_service_name)="Eimerrail Safe Storage";
    CefString(&settings.keychain_account_name)="Eimerrail";
    CefString(&settings.root_cache_path)=[directory stringByAppendingPathComponent:@"Chromium"].UTF8String;
    CefString(&settings.cache_path)=[directory stringByAppendingPathComponent:@"Chromium/default"].UTF8String;
    CefString(&settings.log_file)=[directory stringByAppendingPathComponent:@"cef.log"].UTF8String;
    settings.log_severity=LOGSEVERITY_WARNING;
    if (command->HasSwitch("automation") && command->HasSwitch("debug-port")) {
      int port=std::atoi(command->GetSwitchValue("debug-port").ToString().c_str());
      if (port>=1024 && port<=65535) settings.remote_debugging_port=port;
    }
    CefMainArgs args(argc,argv); CefRefPtr<CefApp> app=MakeRailApp(controller);
    if (!CefInitialize(args,settings,app,nullptr)) return CefGetExitCode();
    CefRunMessageLoop();
    delegate.controller=nil; ((EimerrailApplication *)NSApp).browserController=nil; controller=nil;
    CefShutdown(); NSApp.delegate=nil;
  }
  return 0;
}
