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
      original.tab(tabID)->url = "https://example.com/elsewhere";
      original.setIsolated(tabID);
      original.state.idleMinutes = 30;
      original.state.sidebarVisible = false;
      original.state.sidebarWidth = 300;
      original.setSpaceRules("personal", {"dev.azure.com/contoso/**"});
      NSError *error = nil;
      Check(rail::SaveState(directory,original,&error), "save failed");
      rail::BrowserModel restored;
      Check(rail::LoadState(directory,restored,&error), "load failed");
      Check(restored.state.activeTabID == tabID, "selected tab changed");
      Check(restored.space(restored.state.activeSpaceID)->selectedTabID == tabID, "Space selection lost");
      Check(restored.tab(tabID)->url == original.tab(tabID)->url, "URL lost");
      Check(restored.tab(tabID)->pinnedURL == "https://example.com/a?q=hello", "pinned URL lost");
      Check(restored.tab(tabID)->title == original.tab(tabID)->title, "Unicode title lost");
      Check(restored.tab(tabID)->sessionID == rail::BrowserModel::isolatedSessionID(tabID), "isolated session lost");
      Check(restored.spaceForURL("https://dev.azure.com/contoso/x") == "personal", "Space rules lost");
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
    } @finally {
      [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }
  }
}
