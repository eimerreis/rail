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
      original.state.sidebarWidth = 300; original.state.controlSize = "large";
      original.setSpaceRules("personal", {"dev.azure.com/contoso/**"});
      original.space("research")->icon = "leaf";
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
      Check(restored.state.controlSize == "large", "control size lost");
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
      std::cout << "PASS state round-trip, Unicode, preferences, Space rules, corruption, future schema\n";
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
      std::cout << "PASS projects round-trip, corruption, future schema, missing file\n";
    } @finally {
      [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }
  }
}
