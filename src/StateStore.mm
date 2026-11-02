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
    if (error && !*error) *error = [NSError errorWithDomain:@"Rail" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The saved layout is not a supported Rail state file."}];
    return false;
  }
  State state;
  for (id item in Array(value[@"sessions"])) if ([item isKindOfClass:NSDictionary.class]) state.sessions.push_back({Text(item[@"id"]),Text(item[@"name"])});
  for (id item in Array(value[@"spaces"])) if ([item isKindOfClass:NSDictionary.class]) state.spaces.push_back({Text(item[@"id"]),Text(item[@"name"]),Text(item[@"sessionID"]),Text(item[@"selectedTabID"]),Text(item[@"icon"])});
  for (id item in Array(value[@"tabs"])) if ([item isKindOfClass:NSDictionary.class]) state.tabs.push_back({Text(item[@"id"]),Text(item[@"spaceID"]),Text(item[@"sessionID"]),Text(item[@"title"]),Text(item[@"url"]),ReadBoolean(item[@"pinned"],false),0,Text(item[@"pinnedURL"]),Text(item[@"pinnedTitle"]),Text(item[@"customTitle"])});
  for (id item in Array(value[@"spaceRules"])) if ([item isKindOfClass:NSDictionary.class]) state.spaceRules.push_back({Text(item[@"pattern"]),Text(item[@"spaceID"])});
  state.activeSpaceID = Text(value[@"activeSpaceID"]); state.activeTabID = Text(value[@"activeTabID"]);
  state.idleMinutes = Number(value[@"idleMinutes"],10); state.sidebarVisible = ReadBoolean(value[@"sidebarVisible"],true);
  state.sidebarWidth = Number(value[@"sidebarWidth"],210); state.controlSize = Text(value[@"controlSize"]);
  state.sidebarAnimation = Text(value[@"sidebarAnimation"]); state.theme = Text(value[@"theme"]);
  state.devToolsDocked = ReadBoolean(value[@"devToolsDocked"],true); state.devToolsWidth = Number(value[@"devToolsWidth"],480);
  model.state = std::move(state); model.sanitize(NSDate.date.timeIntervalSince1970);
  return true;
}
bool SaveState(NSString *directory, const BrowserModel &model, NSError **error) {
  if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return false;
  NSMutableArray *sessions = [NSMutableArray array], *spaces = [NSMutableArray array], *tabs = [NSMutableArray array], *rules = [NSMutableArray array];
  for (const auto &s : model.state.sessions) [sessions addObject:@{@"id":S(s.id),@"name":S(s.name)}];
  for (const auto &s : model.state.spaces) [spaces addObject:@{@"id":S(s.id),@"name":S(s.name),@"sessionID":S(s.sessionID),@"selectedTabID":S(s.selectedTabID),@"icon":S(s.icon)}];
  for (const auto &t : model.state.tabs) [tabs addObject:@{@"id":S(t.id),@"spaceID":S(t.spaceID),@"sessionID":S(t.sessionID),@"title":S(t.title),@"url":S(t.url),@"pinned":@(t.pinned),@"pinnedURL":S(t.pinnedURL),@"pinnedTitle":S(t.pinnedTitle),@"customTitle":S(t.customTitle)}];
  for (const auto &r : model.state.spaceRules) [rules addObject:@{@"pattern":S(r.pattern),@"spaceID":S(r.spaceID)}];
  NSDictionary *state = @{@"version":@1,@"sessions":sessions,@"spaces":spaces,@"tabs":tabs,@"spaceRules":rules,@"activeSpaceID":S(model.state.activeSpaceID),@"activeTabID":S(model.state.activeTabID),@"idleMinutes":@(model.state.idleMinutes),@"sidebarVisible":@(model.state.sidebarVisible),@"sidebarWidth":@(model.state.sidebarWidth),@"controlSize":S(model.state.controlSize),@"sidebarAnimation":S(model.state.sidebarAnimation),@"theme":S(model.state.theme),@"devToolsDocked":@(model.state.devToolsDocked),@"devToolsWidth":@(model.state.devToolsWidth)};
  NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:error];
  if (!data) return false;
  return [data writeToFile:[directory stringByAppendingPathComponent:@"state.json"] options:NSDataWritingAtomic error:error];
}
bool LoadHistory(NSString *directory, History &history) {
  NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"history.json"]];
  id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![value isKindOfClass:NSDictionary.class] || Number(value[@"version"],0) != 1) return false;
  history.entries.clear();
  for (id item in Array(value[@"entries"])) {
    if (![item isKindOfClass:NSDictionary.class] || !History::recordable(Text(item[@"url"]))) continue;
    history.entries.push_back({Text(item[@"url"]),Text(item[@"title"]),(int)Number(item[@"visits"],0),(int)Number(item[@"typed"],0),Number(item[@"lastVisit"],0)});
  }
  return true;
}
bool SaveHistory(NSString *directory, const History &history, NSError **error) {
  if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return false;
  NSMutableArray *entries = [NSMutableArray array];
  for (const auto &e : history.entries) [entries addObject:@{@"url":S(e.url),@"title":S(e.title),@"visits":@(e.visits),@"typed":@(e.typed),@"lastVisit":@(e.lastVisit)}];
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"entries":entries} options:0 error:error];
  if (!data) return false;
  return [data writeToFile:[directory stringByAppendingPathComponent:@"history.json"] options:NSDataWritingAtomic error:error];
}
bool LoadProjects(NSString *directory, Projects &projects, NSError **error) {
  NSString *path = [directory stringByAppendingPathComponent:@"projects.json"];
  if (![NSFileManager.defaultManager fileExistsAtPath:path]) { projects.state = {}; return true; }
  NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
  if (!data) return false;
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
  if (![value isKindOfClass:NSDictionary.class] || Number(value[@"version"],0) != 1) {
    if (error && !*error) *error = [NSError errorWithDomain:@"Rail" code:2 userInfo:@{NSLocalizedDescriptionKey:@"The saved projects are not a supported Rail projects file."}];
    return false;
  }
  ProjectsState state;
  for (id c in Array(value[@"connections"])) if ([c isKindOfClass:NSDictionary.class]) state.connections.push_back({Text(c[@"id"]),Text(c[@"provider"]),Text(c[@"account"]),Text(c[@"auth"]),Text(c[@"sessionID"])});
  for (id p in Array(value[@"projects"])) {
    if (![p isKindOfClass:NSDictionary.class]) continue;
    Project project{Text(p[@"id"]),Text(p[@"name"]),Text(p[@"spaceID"]),(int)Number(p[@"order"],0),{},{},{}};
    for (id e in Array(p[@"environments"])) if ([e isKindOfClass:NSDictionary.class]) project.environments.push_back({Text(e[@"id"]),Text(e[@"name"]),Text(e[@"url"]),Text(e[@"healthPath"]),Text(e[@"sessionID"])});
    for (id l in Array(p[@"links"])) if ([l isKindOfClass:NSDictionary.class]) project.links.push_back({Text(l[@"id"]),Text(l[@"kind"]),Text(l[@"label"]),Text(l[@"url"]),Text(l[@"sessionID"]),Text(l[@"environmentID"])});
    for (id b in Array(p[@"sources"])) if ([b isKindOfClass:NSDictionary.class]) project.sources.push_back({Text(b[@"connectionID"]),Text(b[@"resource"])});
    state.projects.push_back(project);
  }
  projects.state = std::move(state);
  return true;
}
bool SaveProjects(NSString *directory, const Projects &projects, NSError **error) {
  if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return false;
  NSMutableArray *connections = [NSMutableArray array], *list = [NSMutableArray array];
  for (const auto &c : projects.state.connections) [connections addObject:@{@"id":S(c.id),@"provider":S(c.provider),@"account":S(c.account),@"auth":S(c.auth),@"sessionID":S(c.sessionID)}];
  for (const auto &p : projects.state.projects) {
    NSMutableArray *environments = [NSMutableArray array], *links = [NSMutableArray array], *sources = [NSMutableArray array];
    for (const auto &e : p.environments) [environments addObject:@{@"id":S(e.id),@"name":S(e.name),@"url":S(e.url),@"healthPath":S(e.healthPath),@"sessionID":S(e.sessionID)}];
    for (const auto &l : p.links) [links addObject:@{@"id":S(l.id),@"kind":S(l.kind),@"label":S(l.label),@"url":S(l.url),@"sessionID":S(l.sessionID),@"environmentID":S(l.environmentID)}];
    for (const auto &b : p.sources) [sources addObject:@{@"connectionID":S(b.connectionID),@"resource":S(b.resource)}];
    [list addObject:@{@"id":S(p.id),@"name":S(p.name),@"spaceID":S(p.spaceID),@"order":@(p.order),@"environments":environments,@"links":links,@"sources":sources}];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"connections":connections,@"projects":list} options:NSJSONWritingPrettyPrinted error:error];
  if (!data) return false;
  return [data writeToFile:[directory stringByAppendingPathComponent:@"projects.json"] options:NSDataWritingAtomic error:error];
}
bool LoadReading(NSString *directory, ReadingList &reading, NSError **error) {
  NSString *path = [directory stringByAppendingPathComponent:@"reading.json"];
  if (![NSFileManager.defaultManager fileExistsAtPath:path]) { reading.state = {}; return true; }
  NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
  if (!data) return false;
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
  if (![value isKindOfClass:NSDictionary.class] || Number(value[@"version"],0) != 1) {
    if (error && !*error) *error = [NSError errorWithDomain:@"Rail" code:3 userInfo:@{NSLocalizedDescriptionKey:@"The saved reading list is not a supported Rail file."}];
    return false;
  }
  ReadingState state;
  for (id f in Array(value[@"feeds"])) {
    if (![f isKindOfClass:NSDictionary.class]) continue;
    Feed feed; feed.id = Text(f[@"id"]); feed.url = Text(f[@"url"]); feed.title = Text(f[@"title"]); feed.lastSuccess = Number(f[@"lastSuccess"],0); feed.error = Text(f[@"error"]); feed.fetched = ReadBoolean(f[@"fetched"],false);
    for (id seen in Array(f[@"seen"])) if ([seen isKindOfClass:NSString.class]) feed.seen.push_back(Text(seen));
    state.feeds.push_back(feed);
  }
  for (id i in Array(value[@"items"])) {
    if (![i isKindOfClass:NSDictionary.class]) continue;
    ReadingItem item; item.id = Text(i[@"id"]); item.url = Text(i[@"url"]); item.title = Text(i[@"title"]); item.site = Text(i[@"site"]); item.feedID = Text(i[@"feedID"]); item.sessionID = Text(i[@"sessionID"]);
    item.added = Number(i[@"added"],0); item.readAt = Number(i[@"readAt"],0); item.minutes = (int)Number(i[@"minutes"],0); item.progress = Number(i[@"progress"],0); item.reader = readerStatusFromName(Text(i[@"reader"]));
    state.items.push_back(item);
  }
  reading.state = std::move(state); reading.sanitize();
  return true;
}
bool SaveReading(NSString *directory, const ReadingList &reading, NSError **error) {
  if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return false;
  NSMutableArray *feeds = [NSMutableArray array], *items = [NSMutableArray array];
  for (const auto &f : reading.state.feeds) {
    NSMutableArray *seen = [NSMutableArray array]; for (const auto &key : f.seen) [seen addObject:S(key)];
    [feeds addObject:@{@"id":S(f.id),@"url":S(f.url),@"title":S(f.title),@"lastSuccess":@(f.lastSuccess),@"error":S(f.error),@"fetched":@(f.fetched),@"seen":seen}];
  }
  for (const auto &i : reading.state.items) [items addObject:@{@"id":S(i.id),@"url":S(i.url),@"title":S(i.title),@"site":S(i.site),@"feedID":S(i.feedID),@"sessionID":S(i.sessionID),@"added":@(i.added),@"readAt":@(i.readAt),@"minutes":@(i.minutes),@"progress":@(i.progress),@"reader":@(readerStatusName(i.reader))}];
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"feeds":feeds,@"items":items} options:NSJSONWritingPrettyPrinted error:error];
  if (!data) return false;
  return [data writeToFile:[directory stringByAppendingPathComponent:@"reading.json"] options:NSDataWritingAtomic error:error];
}
}
