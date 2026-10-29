#import "StateStore.h"

namespace {
NSString *S(const std::string &s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
std::string Text(id value) { return [value isKindOfClass:NSString.class] ? std::string([value UTF8String] ?: "") : ""; }
NSArray *Array(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
bool ReadBoolean(id value, bool fallback) { return [value isKindOfClass:NSNumber.class] ? [value boolValue] : fallback; }
double Number(id value, double fallback) { return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : fallback; }
}
namespace rail {
bool LoadState(NSString *directory, BrowserModel &model, NSError **error) {
  NSString *path = [directory stringByAppendingPathComponent:@"state.json"];
  if (![NSFileManager.defaultManager fileExistsAtPath:path]) return true;
  NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
  if (!data) return false;
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
  if (![value isKindOfClass:NSDictionary.class] || Number(value[@"version"],0) != 1) {
    if (error && !*error) *error = [NSError errorWithDomain:@"Eimerrail" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The saved layout is not a supported Eimerrail state file."}];
    return false;
  }
  State state;
  for (id item in Array(value[@"sessions"])) if ([item isKindOfClass:NSDictionary.class]) state.sessions.push_back({Text(item[@"id"]),Text(item[@"name"])});
  for (id item in Array(value[@"spaces"])) if ([item isKindOfClass:NSDictionary.class]) state.spaces.push_back({Text(item[@"id"]),Text(item[@"name"]),Text(item[@"sessionID"]),Text(item[@"selectedTabID"])});
  for (id item in Array(value[@"tabs"])) if ([item isKindOfClass:NSDictionary.class]) state.tabs.push_back({Text(item[@"id"]),Text(item[@"spaceID"]),Text(item[@"sessionID"]),Text(item[@"title"]),Text(item[@"url"]),ReadBoolean(item[@"pinned"],false),0});
  state.activeSpaceID = Text(value[@"activeSpaceID"]); state.activeTabID = Text(value[@"activeTabID"]);
  state.idleMinutes = Number(value[@"idleMinutes"],10); state.sidebarVisible = ReadBoolean(value[@"sidebarVisible"],true);
  model.state = std::move(state); model.sanitize(NSDate.date.timeIntervalSince1970);
  return true;
}
bool SaveState(NSString *directory, const BrowserModel &model, NSError **error) {
  if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return false;
  NSMutableArray *sessions = [NSMutableArray array], *spaces = [NSMutableArray array], *tabs = [NSMutableArray array];
  for (const auto &s : model.state.sessions) [sessions addObject:@{@"id":S(s.id),@"name":S(s.name)}];
  for (const auto &s : model.state.spaces) [spaces addObject:@{@"id":S(s.id),@"name":S(s.name),@"sessionID":S(s.sessionID),@"selectedTabID":S(s.selectedTabID)}];
  for (const auto &t : model.state.tabs) [tabs addObject:@{@"id":S(t.id),@"spaceID":S(t.spaceID),@"sessionID":S(t.sessionID),@"title":S(t.title),@"url":S(t.url),@"pinned":@(t.pinned)}];
  NSDictionary *state = @{@"version":@1,@"sessions":sessions,@"spaces":spaces,@"tabs":tabs,@"activeSpaceID":S(model.state.activeSpaceID),@"activeTabID":S(model.state.activeTabID),@"idleMinutes":@(model.state.idleMinutes),@"sidebarVisible":@(model.state.sidebarVisible)};
  NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:error];
  if (!data) return false;
  return [data writeToFile:[directory stringByAppendingPathComponent:@"state.json"] options:NSDataWritingAtomic error:error];
}
}
