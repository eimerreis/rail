#import "AppUpdater.h"

@implementation AppUpdater {
  __weak NSWindow *_window;
  NSTask *_worker;
  NSTimer *_readyTimer;
  NSString *_log;
}
- (instancetype)initWithWindow:(NSWindow *)window {
  if ((self=[super init])) _window=window;
  return self;
}
- (BOOL)running { return _worker!=nil; }
- (void)failed:(NSString *)message {
  if (self.onStatus) self.onStatus(@"Reinstall failed. Your current app is still installed.");
  NSAlert *alert=[[NSAlert alloc] init];
  alert.messageText=@"Could not reinstall latest main";
  alert.informativeText=message;
  [alert addButtonWithTitle:@"OK"];
  if (_log) [alert addButtonWithTitle:@"Show Log"];
  NSString *log=_log;
  [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) {
    if (result==NSAlertSecondButtonReturn && log) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:log]];
  }];
}
- (void)start {
  if (self.running) return;
  NSFileManager *files=NSFileManager.defaultManager;
  NSString *cache=[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"de.eimerreis.eimerrail/updater"];
  NSString *run=[cache stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSString *script=[run stringByAppendingPathComponent:@"reinstall-main.sh"];
  NSString *bundled=[NSBundle.mainBundle pathForResource:@"reinstall-main" ofType:@"sh"];
  NSError *error=nil;
  _log=nil;
  if (![files createDirectoryAtPath:run withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error] ||
      !bundled || ![files copyItemAtPath:bundled toPath:script error:&error]) {
    [self failed:error.localizedDescription ?: @"The reinstall worker is missing. Rebuild Eimerrail first."]; return;
  }
  _log=[run stringByAppendingPathComponent:@"update.log"];
  if (![files createFileAtPath:_log contents:nil attributes:@{NSFilePosixPermissions:@0600}]) {
    _log=nil; [self failed:@"Could not create the reinstall log."]; return;
  }
  NSFileHandle *output=[NSFileHandle fileHandleForWritingAtPath:_log];
  _worker=[[NSTask alloc] init];
  _worker.executableURL=[NSURL fileURLWithPath:@"/bin/bash"];
  NSDictionary *info=NSBundle.mainBundle.infoDictionary;
  NSMutableArray *arguments=[NSMutableArray arrayWithArray:@[script,cache,run,NSBundle.mainBundle.bundlePath.stringByResolvingSymlinksInPath,
    [NSString stringWithFormat:@"%d",NSProcessInfo.processInfo.processIdentifier],info[@"EimerrailSigningIdentity"] ?: @"AUTO",info[@"EimerrailGitHubClientID"] ?: @""]];
  NSArray *launchArguments=NSProcessInfo.processInfo.arguments;
  if (launchArguments.count>1) [arguments addObjectsFromArray:[launchArguments subarrayWithRange:NSMakeRange(1,launchArguments.count-1)]];
  _worker.arguments=arguments;
  _worker.standardInput=NSFileHandle.fileHandleWithNullDevice;
  _worker.standardOutput=output; _worker.standardError=output;
  __weak AppUpdater *weak=self;
  _worker.terminationHandler=^(NSTask *task) {
    dispatch_async(dispatch_get_main_queue(), ^{
      AppUpdater *strong=weak; if (!strong) return;
      [strong->_readyTimer invalidate]; strong->_readyTimer=nil; strong->_worker=nil;
      if (task.terminationStatus!=0) [strong failed:@"The download, build, or installation failed. Show Log for details. Building requires Xcode Command Line Tools and uv; the app folder must be writable."];
    });
  };
  if (![_worker launchAndReturnError:&error]) {
    _worker=nil; [output closeFile]; [self failed:error.localizedDescription]; return;
  }
  [output closeFile];
  if (self.onStatus) self.onStatus(@"Building latest main… Eimerrail will restart when ready.");
  _readyTimer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
    if (![files fileExistsAtPath:[run stringByAppendingPathComponent:@"ready"]]) return;
    [timer invalidate];
    AppUpdater *strong=weak; if (!strong) return;
    strong->_readyTimer=nil;
    if (strong.onStatus) strong.onStatus(@"Restarting to install latest main…");
    if (strong.onReady) strong.onReady();
  }];
}
- (void)dealloc { [_readyTimer invalidate]; }
@end
