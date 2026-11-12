#import "StateStore.h"
#include <iostream>
#include <stdexcept>

static void Check(bool value, const char *message) {
  if (!value) throw std::runtime_error(message);
}
int main() {
  @autoreleasepool {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    @try {
      rail::BrowserModel original;
      auto tabID = original.state.activeTabID;
      original.tab(tabID)->url = "https://example.com/a?q=hello";
      original.tab(tabID)->title = "Notes — 日本語";
      original.togglePin(tabID);
      original.renameTab(tabID,"My notes");
      original.tab(tabID)->url = "https://example.com/elsewhere";
      original.setIsolated(tabID);
      original.state.idleMinutes = 30;
      original.state.sidebarVisible = false;
      original.state.sidebarWidth = 300; original.state.controlSize = "large"; original.state.sidebarAnimation = "subtle"; original.state.devToolsDocked = false;
      original.setSpaceRules("personal", {"dev.azure.com/contoso/**"});
      original.space("research")->icon = "leaf";
      auto snoozedID = original.addTab(original.state.activeSpaceID,"https://example.com/later",1);
      Check(original.tab(snoozedID)->originTabID == tabID, "new tab source missing");
      original.selectTab(tabID,1);
      double snoozedUntil = round(NSDate.date.timeIntervalSince1970)+3600;
      Check(original.snoozeTabs({snoozedID},snoozedUntil,1), "snooze failed");
      NSError *error = nil;
      Check(rail::SaveState(directory,original,&error), "save failed");
      rail::BrowserModel restored;
      Check(rail::LoadState(directory,restored,&error), "load failed");
      Check(restored.state.activeTabID == tabID, "selected tab changed");
      Check(restored.space(restored.state.activeSpaceID)->selectedTabID == tabID, "Space selection lost");
      Check(restored.tab(tabID)->url == original.tab(tabID)->url, "URL lost");
      Check(restored.tab(tabID)->pinnedURL == "https://example.com/a?q=hello", "pinned URL lost");
      Check(restored.tab(tabID)->title == original.tab(tabID)->title, "Unicode title lost");
      Check(restored.tab(tabID)->customTitle == "My notes", "pinned tab name lost");
      Check(restored.tab(tabID)->sessionID == rail::BrowserModel::isolatedSessionID(tabID), "isolated session lost");
      Check(restored.spaceForURL("https://dev.azure.com/contoso/x") == "personal", "Space rules lost");
      Check(restored.space("research")->icon == "leaf", "Space icon lost");
      Check(restored.tab(snoozedID) && restored.tab(snoozedID)->snoozedUntil == snoozedUntil, "snooze time lost");
      Check(restored.tab(snoozedID)->originTabID.empty(), "runtime tab source should not change the saved state schema");
      Check(restored.state.controlSize == "large", "control size lost");
      Check(restored.state.sidebarAnimation == "subtle" && !restored.state.devToolsDocked, "sidebar animation or DevTools placement lost");
      Check(restored.tab(tabID)->pinned && !restored.state.sidebarVisible && restored.state.idleMinutes == 30 && restored.state.sidebarWidth == 300, "preferences lost");
      rail::History history; history.recordVisit("https://example.com/",5); history.setTitle("https://example.com/","Example");
      Check(rail::SaveHistory(directory,history,&error), "history save failed");
      rail::History loadedHistory;
      Check(rail::LoadHistory(directory,loadedHistory) && loadedHistory.entries.size() == 1 && loadedHistory.entries[0].title == "Example" && loadedHistory.entries[0].visits == 1, "history lost");
      NSString *path = [directory stringByAppendingPathComponent:@"state.json"];
      [@"{broken" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      error = nil;
      Check(!rail::LoadState(directory,restored,&error) && error, "corrupt JSON accepted");
      Check(restored.state.activeTabID == tabID, "failed load mutated model");
      [@"{\"version\":99}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      error = nil;
      Check(!rail::LoadState(directory,restored,&error), "future schema accepted");
      Check(restored.state.activeTabID == tabID, "unknown schema mutated model");
      // Theme: every theme survives a save; a missing or unknown one falls back to Porcelain
      // and the rest of the layout is kept.
      for (const char *theme : {"porcelain", "nightline", "daylight"}) {
        rail::BrowserModel themed = original; themed.state.theme = theme;
        Check(rail::SaveState(directory,themed,&error), "themed save failed");
        rail::BrowserModel loaded;
        Check(rail::LoadState(directory,loaded,&error) && loaded.state.theme == theme, "theme lost");
      }
      for (NSString *stored in @[@"", @"\"theme\":\"midnight\",", @"\"theme\":42,"]) {
        // A state file from before themes, or with a value Rail doesn't know.
        NSString *legacy = [NSString stringWithFormat:@"{\"version\":1,%@\"idleMinutes\":30,\"sidebarWidth\":300,\"controlSize\":\"large\",\"sessions\":[{\"id\":\"work\",\"name\":\"Work\"}],\"spaces\":[{\"id\":\"work\",\"name\":\"Work\",\"sessionID\":\"work\",\"selectedTabID\":\"t1\"}],\"tabs\":[{\"id\":\"t1\",\"spaceID\":\"work\",\"sessionID\":\"work\",\"title\":\"Kept\",\"url\":\"https://example.com/kept\"}],\"activeSpaceID\":\"work\",\"activeTabID\":\"t1\"}",stored];
        [legacy writeToFile:[directory stringByAppendingPathComponent:@"state.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        rail::BrowserModel loaded; loaded.state.theme = "nightline";
        Check(rail::LoadState(directory,loaded,&error), "state without a valid theme should still load");
        Check(loaded.state.theme == "porcelain", "missing or unknown theme should fall back to Porcelain");
        Check(loaded.state.activeTabID == "t1" && loaded.tab("t1") && loaded.tab("t1")->url == "https://example.com/kept" && loaded.state.idleMinutes == 30 && loaded.state.sidebarWidth == 300 && loaded.state.controlSize == "large", "theme fallback lost other state");
      }
      Check(rail::SaveState(directory,original,&error), "save failed");
      std::cout << "PASS state round-trip, Unicode, preferences, Space rules, corruption, future schema, theme persistence and fallback\n";
      rail::Projects projects;
      auto projectID = projects.addProject("Billing — 請求", "work", "https://dev.azure.com/contoso/Billing/_git/billing-api", "work");
      auto envID = projects.addEnvironment(projectID, "PROD", "https://billing.contoso.com", "__isolated__", "/healthz");
      projects.addLink(projectID, "custom", "LaunchDarkly", "https://app.launchdarkly.com/x", "work", envID);
      Check(rail::SaveProjects(directory,projects,&error), "projects save failed");
      rail::Projects loaded;
      Check(rail::LoadProjects(directory,loaded,&error), "projects load failed");
      const auto *project = loaded.project(projectID);
      Check(project && project->name == "Billing — 請求" && project->environments.size() == 1 && project->links.size() == 3 && project->sources.size() == 1, "projects lost");
      Check(project->environments[0].sessionID == "isolated-" + envID && project->environments[0].healthPath == "/healthz", "environment lost");
      Check(project->links[2].environmentID == envID && loaded.state.connections.size() == 1 && loaded.state.connections[0].auth == "session", "links or connections lost");
      NSString *projectsPath = [directory stringByAppendingPathComponent:@"projects.json"];
      [@"{broken" writeToFile:projectsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
      error = nil;
      Check(!rail::LoadProjects(directory,loaded,&error) && error && loaded.project(projectID), "corrupt projects accepted or model mutated");
      [@"{\"version\":2}" writeToFile:projectsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
      Check(!rail::LoadProjects(directory,loaded,&error), "future projects schema accepted");
      [NSFileManager.defaultManager removeItemAtPath:projectsPath error:nil];
      Check(rail::LoadProjects(directory,loaded,&error) && loaded.state.projects.empty(), "missing projects file should be empty");
      rail::TrackedRuns tracked; rail::TrackedRuns untouched; untouched.runs.push_back({});
      Check(!rail::LoadTrackedRuns(directory,untouched) && untouched.runs.size() == 1, "missing tracked runs should change nothing");
      rail::TrackedRun run; run.key = "run:release"; run.sourceKey = "c|a/b"; run.kind = "pipeline"; run.revision = "41"; run.title = "release"; run.project = "App"; run.spaceID = "work"; run.sessionID = "work"; run.number = "12"; run.url = "https://example.com/run"; run.pageURL = "https://example.com/pr"; run.state = rail::RunState::failed; run.startedAt = 5; run.changedAt = 6; run.acknowledged = true; run.passedSeen = true; run.cleared = true;
      tracked.runs.push_back(run);
      Check(rail::SaveTrackedRuns(directory,tracked,&error), "tracked runs should save");
      rail::TrackedRuns reloaded;
      Check(rail::LoadTrackedRuns(directory,reloaded) && reloaded.runs.size() == 1, "tracked runs should load");
      const auto &back = reloaded.runs[0];
      Check(back.key == run.key && back.revision == "41" && back.state == rail::RunState::failed && back.acknowledged && back.passedSeen && back.cleared && back.changedAt == 6 && back.pageURL == run.pageURL, "tracked runs should survive a restart");
      std::cout << "PASS projects round-trip, corruption, future schema, missing file\n";
    } @finally {
      [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }
  }
}
