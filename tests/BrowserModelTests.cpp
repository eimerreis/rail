#include "BrowserModel.h"

#include <algorithm>
#include <cmath>
#include <functional>
#include <iostream>
#include <limits>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

void startupHasSpacesWithBlankTabs() {
    rail::BrowserModel model;
    require(model.state.sessions.size() == 2, "startup should have two named sessions");
    require(model.state.sessions[0].name == "Work", "first session should be Work");
    require(model.state.sessions[1].name == "Personal", "second session should be Personal");
    require(model.state.spaces.size() == 3, "startup should have three Spaces");
    require(model.state.spaces[0].name == "Work", "first Space should be Work");
    require(model.state.spaces[1].name == "Personal", "second Space should be Personal");
    require(model.state.spaces[2].name == "Research", "third Space should be Research");
    require(model.state.tabs.size() == 3, "each initial Space should have a tab");
    for (const auto& space : model.state.spaces) {
        unsigned count = 0;
        for (const auto& tab : model.state.tabs) {
            if (tab.spaceID != space.id) continue;
            ++count;
            require(tab.url == "about:blank", "initial tabs should be blank");
            require(tab.title == "New Tab", "initial tab title should be New Tab");
            require(tab.sessionID == space.sessionID, "initial tab should use Space default session");
            require(space.selectedTabID == tab.id, "each Space should remember its blank tab");
        }
        require(count == 1, "each initial Space should have exactly one tab");
    }
    require(model.state.activeSpaceID == model.state.spaces[0].id, "Work should be active");
    require(model.state.activeTabID == model.state.spaces[0].selectedTabID, "Work blank tab should be selected");
    require(model.state.idleMinutes == 10, "default idle interval should be ten minutes");
    require(model.state.sidebarVisible, "sidebar should start visible");
}

void lookupReturnsMatchingRecords() {
    rail::BrowserModel model;
    const auto tabID = model.state.tabs.front().id;
    require(model.tab(tabID) == &model.state.tabs.front(), "mutable tab lookup should return matching record");
    require(model.space("work") == &model.state.spaces.front(), "mutable Space lookup should return matching record");
    const auto& readonly = model;
    require(readonly.tab(tabID) == &model.state.tabs.front(), "const tab lookup should return matching record");
    require(readonly.space("work") == &model.state.spaces.front(), "const Space lookup should return matching record");
    require(readonly.session("work") == &model.state.sessions.front(), "session lookup should return matching record");
    require(!model.tab("missing") && !readonly.tab("missing"), "missing tab should return null");
    require(!model.space("missing") && !readonly.space("missing"), "missing Space should return null");
    require(!readonly.session("missing"), "missing session should return null");
}

void selectionRemembersEachSpace() {
    rail::BrowserModel model;
    const auto original = model.state.activeTabID;
    model.state.tabs.push_back({"work-second", "work", "personal", "Other", "https://example.com", false, 0});
    require(model.selectTab("work-second", 42), "existing tab should be selectable");
    require(model.state.activeTabID == "work-second", "selected tab should become active");
    require(model.tab(original)->lastUsed == 42, "leaving a tab should start its idle interval now");
    require(model.tab("work-second")->lastUsed == 42, "selected tab should record current time");
    require(model.space("work")->selectedTabID == "work-second", "Space should remember selection");
    require(model.selectSpace("personal", 60), "existing Space should be selectable");
    require(model.state.activeSpaceID == "personal", "Space selection should change active Space");
    require(model.tab(model.state.activeTabID)->spaceID == "personal", "Space should activate one of its tabs");
    require(model.tab("work-second")->lastUsed == 60, "Space switch should timestamp the old tab");
    require(model.selectSpace("work", 90), "prior Space should be selectable");
    require(model.state.activeTabID == "work-second", "Space should restore its previous selection");
    require(model.tab("work-second")->sessionID == "personal", "Space switch should preserve independent identity");
    require(!model.selectTab("missing", 100), "unknown tab should be rejected");
    require(!model.selectSpace("missing", 100), "unknown Space should be rejected");
    require(model.state.activeTabID == "work-second", "invalid selection should preserve active tab");
    model.space("personal")->selectedTabID = "missing";
    require(model.selectSpace("personal", 110), "Space with missing remembered tab should recover");
    require(model.tab(model.state.activeTabID)->spaceID == "personal", "fallback should belong to selected Space");
}

void idleTimeoutUsesStrictBoundary() {
    rail::BrowserModel model;
    model.state.idleMinutes = 2;
    for (auto& tab : model.state.tabs) tab.lastUsed = 10;
    const auto inactive = model.space("personal")->selectedTabID;
    const auto pinned = model.space("research")->selectedTabID;
    model.tab(pinned)->pinned = true;
    require(model.idleTabs(130).empty(), "tabs exactly at timeout should remain loaded");
    const auto expired = model.idleTabs(130.001);
    require(expired.size() == 2, "both inactive tabs should expire after the boundary");
    require(std::find(expired.begin(), expired.end(), inactive) != expired.end(), "ordinary inactive tab should expire");
    require(std::find(expired.begin(), expired.end(), pinned) != expired.end(), "pinned inactive tab should expire");
    require(std::find(expired.begin(), expired.end(), model.state.activeTabID) == expired.end(), "active tab must never expire");
    const auto previous = model.state.activeTabID;
    require(model.selectTab(inactive, 1000), "long-active tab should allow switching");
    const auto afterSwitch = model.idleTabs(1100);
    require(std::find(afterSwitch.begin(), afterSwitch.end(), previous) == afterSwitch.end(), "old active tab should get a fresh idle interval");
    require(model.idleTabs(0).empty(), "clock moving backward should not expire tabs");
}

void pinningTogglesOnlyTheRequestedTab() {
    rail::BrowserModel model;
    const auto id = model.state.activeTabID;
    require(model.togglePin(id), "existing tab should be pinnable");
    require(model.tab(id)->pinned, "tab should now be pinned");
    require(model.togglePin(id), "pinned tab should be unpinnable");
    require(!model.tab(id)->pinned, "tab should now be unpinned");
    require(!model.togglePin("missing"), "missing tab should be rejected");
}

void switchingNamedSessionPreservesSpace() {
    rail::BrowserModel model;
    const auto first = model.state.activeTabID;
    const auto second = model.space("research")->selectedTabID;
    require(model.setSession(first, "personal"), "existing named session should be assignable");
    require(model.setSession(second, "personal"), "same session should be assignable to another tab");
    require(model.tab(first)->sessionID == model.tab(second)->sessionID, "named sessions should share identity");
    require(model.tab(first)->spaceID == "work", "session change should preserve first Space");
    require(model.tab(second)->spaceID == "research", "session change should preserve second Space");
    require(model.state.activeSpaceID == "work" && model.state.activeTabID == first, "session change should preserve selection");
    require(!model.setSession(first, "missing"), "unknown session should be rejected");
    require(!model.setSession("missing", "work"), "unknown tab should be rejected");
    require(model.tab(first)->sessionID == "personal", "rejected session change should preserve identity");
}

void isolatedSessionsAreStableAndUnique() {
    rail::BrowserModel model;
    const auto first = model.state.tabs[0].id;
    const auto second = model.state.tabs[1].id;
    require(model.setIsolated(first), "first tab should support isolated session");
    require(model.setIsolated(second), "second tab should support isolated session");
    require(model.tab(first)->sessionID == "isolated-" + first, "isolated ID should be derived from stable tab ID");
    require(model.tab(first)->sessionID != model.tab(second)->sessionID, "isolated tabs should never share identity");
    require(rail::BrowserModel::isolatedSessionID(first) == model.tab(first)->sessionID, "helper should use canonical isolated ID");
    require(rail::BrowserModel::isIsolatedSession(model.tab(first)->sessionID), "isolated identifier should be recognized");
    require(!rail::BrowserModel::isIsolatedSession("work"), "named identifier is not isolated");
    require(!rail::BrowserModel::isIsolatedSession("isolated-"), "empty isolated identifier should be rejected");
    require(!rail::BrowserModel::isIsolatedSession("isolated-../unsafe"), "unsafe profile path should be rejected");
    require(model.state.sessions.size() == 2, "isolated identities should not create named sessions");
    require(model.setSession(first, "work"), "isolated tab should return to a named session");
    require(model.setIsolated(first), "tab should return to its isolated identity");
    require(model.tab(first)->sessionID == "isolated-" + first, "isolated identity should survive repeated switches");
    require(!model.setSession(first, model.tab(second)->sessionID), "tab should reject another tab's isolated identity");
    require(!model.setIsolated("missing"), "missing tab should reject isolation");
}

void tabsUseSpaceDefaultOrValidOverride() {
    rail::BrowserModel model;
    const auto previous = model.state.activeTabID;
    const auto first = model.addTab("personal", "https://example.com", 50);
    require(!first.empty(), "new tab should receive an ID");
    require(model.tab(first)->spaceID == "personal", "new tab should belong to requested Space");
    require(model.tab(first)->sessionID == "personal", "new tab should use Space default identity");
    require(model.tab(first)->url == "https://example.com", "new tab should keep requested URL");
    require(model.tab(first)->lastUsed == 50, "new tab should record current time");
    require(model.tab(previous)->lastUsed == 50, "creating selected tab should timestamp old selection");
    require(model.state.activeTabID == first && model.state.activeSpaceID == "personal", "new tab should be selected");
    const auto overridden = model.addTab("work", "  \n ", 60, "personal");
    require(overridden != first, "new tab IDs should be unique");
    require(model.tab(overridden)->sessionID == "personal", "valid explicit identity should override Space default");
    require(model.tab(overridden)->url == "about:blank", "blank URL should open native empty state");
    require(model.tab(overridden)->title == "New Tab", "blank tab should have New Tab title");
    const auto fallback = model.addTab("work", "about:blank", 70, "unknown");
    require(model.tab(fallback)->sessionID == "work", "invalid explicit identity should use Space default");
    require(model.addTab("missing", "about:blank", 80).empty(), "unknown Space should reject new tab");
}

void namedSessionsCanBeCreated() {
    rail::BrowserModel model;
    const auto first = model.addSession("  Client One  ");
    require(!first.empty(), "named session should receive an ID");
    require(model.session(first)->name == "Client One", "session name should be trimmed");
    const auto second = model.addSession("Client One");
    require(second != first, "same session name should still receive a different identity");
    require(!rail::BrowserModel::isIsolatedSession(first), "generated named identity should not be isolated");
    const auto unnamed = model.addSession("  ");
    require(!model.session(unnamed)->name.empty(), "empty session name should receive a fallback");
}

void spacesCanBeCreatedWithInitialTabs() {
    rail::BrowserModel model;
    const auto id = model.addSpace("  Client Space  ", "personal", 45);
    require(!id.empty(), "Space should receive an ID");
    require(model.space(id)->name == "Client Space", "Space name should be trimmed");
    require(model.space(id)->sessionID == "personal", "Space should retain chosen default session");
    require(model.state.activeSpaceID == id, "new Space should become selected");
    require(model.tab(model.state.activeTabID)->spaceID == id, "new Space should have selected tab");
    require(model.tab(model.state.activeTabID)->sessionID == "personal", "initial tab should use chosen session");
    require(model.tab(model.state.activeTabID)->url == "about:blank", "initial tab should be blank");
    require(model.tab(model.state.activeTabID)->lastUsed == 45, "initial tab should record creation time");
    const auto fallback = model.addSpace("  ", "missing", 50);
    require(!model.space(fallback)->name.empty(), "empty Space name should have a fallback");
    require(model.session(model.space(fallback)->sessionID), "invalid default should recover to a named session");
}

void closingLastTabCreatesSelectedBlank() {
    rail::BrowserModel model;
    const auto old = model.state.activeTabID;
    model.setIsolated(old);
    model.togglePin(old);
    require(model.closeTab(old, 99), "last tab should close even when pinned");
    require(!model.tab(old), "closed tab metadata should be removed");
    require(model.state.tabs.size() == 3, "last tab should be replaced with a blank tab");
    require(model.state.activeTabID != old, "replacement should have a fresh ID");
    const auto* replacement = model.tab(model.state.activeTabID);
    require(replacement && replacement->spaceID == "work", "replacement should be selected in same Space");
    require(replacement->url == "about:blank" && replacement->title == "New Tab", "replacement should be blank");
    require(replacement->sessionID == "work", "replacement should use Space default identity");
    require(!replacement->pinned && replacement->lastUsed == 99, "replacement should be fresh and active");
    require(model.space("work")->selectedTabID == replacement->id, "Space should remember replacement");
    require(!model.closeTab("missing", 100), "unknown tab should not close anything");
}

void closingBackgroundTabPreservesSelection() {
    rail::BrowserModel model;
    const auto active = model.state.activeTabID;
    const auto background = model.space("personal")->selectedTabID;
    require(model.closeTab(background, 10), "background tab should close");
    require(model.state.activeTabID == active && model.state.activeSpaceID == "work", "background close should preserve active selection");
    require(model.tab(model.space("personal")->selectedTabID)->spaceID == "personal", "background Space should remember its fresh blank tab");
    const auto second = model.addTab("work", "https://example.com", 20);
    require(model.closeTab(second, 30), "selected tab should close when others remain");
    require(model.state.activeTabID == active, "remaining tab should become selected");
    require(model.tab(active)->lastUsed == 30, "remaining tab should receive selection timestamp");
}

void movingTabsPreservesIdentity() {
    rail::BrowserModel model;
    const auto moved = model.state.activeTabID;
    model.setIsolated(moved);
    model.togglePin(moved);
    const auto identity = model.tab(moved)->sessionID;
    require(model.moveTab(moved, "personal", 25), "selected tab should move to another Space");
    require(model.tab(moved)->spaceID == "personal", "moved tab should belong to target Space");
    require(model.tab(moved)->sessionID == identity, "move should preserve isolated identity");
    require(model.tab(moved)->pinned, "move should preserve pin state");
    require(model.state.activeTabID == moved && model.state.activeSpaceID == "personal", "selection should follow moved active tab");
    require(model.space("personal")->selectedTabID == moved, "target Space should remember moved selection");
    const auto replacement = model.space("work")->selectedTabID;
    require(replacement != moved && model.tab(replacement)->spaceID == "work", "source Space should get a fresh tab if emptied");
    require(model.moveTab(replacement, "research", 30), "background tab should move");
    require(model.state.activeTabID == moved && model.state.activeSpaceID == "personal", "background move should preserve active selection");
    require(model.tab(replacement)->sessionID == "work", "background move should preserve named identity");
    require(!model.moveTab(moved, "missing", 35), "unknown target Space should be rejected");
    require(!model.moveTab("missing", "work", 35), "unknown source tab should be rejected");
    require(model.moveTab(moved, "personal", 35), "moving within current Space should be harmless");
}

bool isSafeIdentifier(const std::string& id) {
    return !id.empty() && id.size() <= 128 && std::all_of(id.begin(), id.end(), [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '-' || c == '_';
    });
}

void requireValidState(const rail::BrowserModel& model, double now) {
    require(!model.state.sessions.empty() && !model.state.spaces.empty() && !model.state.tabs.empty(), "state should contain sessions, Spaces, and tabs");
    std::set<std::string> sessionIDs;
    std::set<std::string> spaceIDs;
    std::set<std::string> tabIDs;
    for (const auto& session : model.state.sessions) {
        require(isSafeIdentifier(session.id), "named session ID should be a safe path component");
        require(session.id.compare(0, 9, "isolated-") != 0, "named session should not use isolated prefix");
        require(sessionIDs.insert(session.id).second, "named session IDs should be unique");
        require(!session.name.empty(), "session should have a display name");
    }
    for (const auto& space : model.state.spaces) {
        require(isSafeIdentifier(space.id), "Space ID should be safe");
        require(spaceIDs.insert(space.id).second, "Space IDs should be unique");
        require(!space.name.empty(), "Space should have a display name");
        require(model.session(space.sessionID), "Space should have valid named default session");
        const auto* selected = model.tab(space.selectedTabID);
        require(selected && selected->spaceID == space.id, "Space should remember an existing tab it owns");
    }
    for (const auto& tab : model.state.tabs) {
        require(isSafeIdentifier(tab.id), "tab ID should be safe");
        require(tabIDs.insert(tab.id).second, "tab IDs should be unique");
        require(model.space(tab.spaceID), "tab should belong to existing Space");
        require(model.session(tab.sessionID) || tab.sessionID == "isolated-" + tab.id, "tab should have valid named or own isolated identity");
        require(!tab.title.empty() && !tab.url.empty(), "tab should have nonempty title and URL");
        require(std::isfinite(tab.lastUsed) && tab.lastUsed >= 0 && tab.lastUsed <= now, "tab timestamp should be finite and within current clock");
    }
    const auto* active = model.tab(model.state.activeTabID);
    require(active && active->spaceID == model.state.activeSpaceID, "active tab should belong to active Space");
    require(model.space(model.state.activeSpaceID)->selectedTabID == active->id, "active Space should remember active tab");
    require(std::isfinite(model.state.idleMinutes * 60) && model.state.idleMinutes > 0, "idle interval should be finite and positive");
}

void sanitizeRecoversEmptyState() {
    rail::BrowserModel model;
    model.state = {};
    model.state.idleMinutes = -5;
    model.state.sidebarVisible = false;
    model.sanitize(100);
    requireValidState(model, 100);
    require(model.state.sessions.size() == 2, "empty imported state should recover default sessions");
    require(model.state.spaces.size() == 3, "empty imported state should recover default Spaces");
    require(model.state.tabs.size() == 3, "empty imported state should recover blank tabs");
    require(model.state.idleMinutes == 10, "invalid timeout should recover default");
    require(!model.state.sidebarVisible, "sanitizing should preserve sidebar preference");
}

void sanitizeRepairsMalformedReferences() {
    rail::BrowserModel model;
    model.state.sessions = {{"../shared", "  "}, {"../shared", "Duplicate"}, {"isolated-reserved", "Reserved"}, {"named", " Named "}};
    model.state.spaces = {{"../desk", " ", "../shared", "../tab"},
                          {"../desk", "Duplicate", "missing", "../tab"},
                          {"space", "Space", "isolated-reserved", "missing"},
                          {"empty", "Empty", "named", ""}};
    model.state.tabs = {{"../tab", "../desk", "../shared", " ", " \n ", false, std::numeric_limits<double>::quiet_NaN()},
                        {"../tab", "../desk", "isolated-../tab", " ", "https://a.example", true, std::numeric_limits<double>::infinity()},
                        {"valid", "space", "isolated-other", "Title", "https://b.example", false, -1},
                        {"orphan", "missing", "missing", "", "https://c.example", false, 9999}};
    model.state.activeSpaceID = "../desk";
    model.state.activeTabID = "../tab";
    model.state.idleMinutes = std::numeric_limits<double>::infinity();
    model.sanitize(100);
    requireValidState(model, 100);
    require(model.state.tabs[0].sessionID == model.state.sessions[0].id, "repaired named session should keep its tab references");
    require(model.state.spaces[0].sessionID == model.state.sessions[0].id, "repaired named session should keep its Space references");
    require(model.state.tabs[0].spaceID == model.state.spaces[0].id, "repaired Space should keep its tab references");
    require(model.state.activeTabID == model.state.tabs[0].id, "repaired tab ID should retain active selection");
    require(model.state.tabs[0].url == "about:blank" && model.state.tabs[0].title == "New Tab", "blank imported URL should recover empty state");
    require(model.state.tabs[1].sessionID == "isolated-" + model.state.tabs[1].id, "duplicate isolated tab should get its own repaired identity");
    require(model.state.tabs[1].pinned, "repair should preserve pinned state");
    require(model.tab("valid")->sessionID == "isolated-valid", "incorrect isolated identity should be bound to its own tab");
    require(model.tab("orphan")->spaceID == model.state.spaces[0].id, "orphan tab should recover into first Space");
    require(model.tab("orphan")->lastUsed == 100, "future timestamp should clamp to current time");
    require(model.state.idleMinutes == 10, "nonfinite timeout should reset");
    const auto firstID = model.state.tabs[0].id;
    const auto secondID = model.state.tabs[1].id;
    model.sanitize(100);
    requireValidState(model, 100);
    require(model.state.tabs[0].id == firstID && model.state.tabs[1].id == secondID, "repair should be idempotent");
}

void sanitizePreservesValidState() {
    rail::BrowserModel model;
    model.setIsolated(model.state.activeTabID);
    const auto isolated = model.state.activeTabID;
    model.selectSpace("personal", 5);
    model.state.idleMinutes = 0.5;
    model.state.sidebarVisible = false;
    const auto active = model.state.activeTabID;
    model.sanitize(100);
    requireValidState(model, 100);
    require(model.tab(isolated)->sessionID == "isolated-" + isolated, "valid isolated identity should persist");
    require(model.tab(isolated)->lastUsed == 5, "sanitizing should not extend inactive timeout");
    require(model.state.activeTabID == active && model.state.activeSpaceID == "personal", "valid active selection should persist");
    require(model.state.idleMinutes == 0.5 && !model.state.sidebarVisible, "valid preferences should persist");
    model.state.activeSpaceID = "work";
    model.state.activeTabID = "missing";
    model.sanitize(100);
    require(model.state.activeTabID == isolated, "missing active tab should recover remembered tab in active Space");
    model.state.activeSpaceID = "missing";
    model.state.activeTabID = active;
    model.sanitize(100);
    require(model.state.activeSpaceID == "personal", "valid active tab should restore its owning Space");
}

using Test = std::pair<std::string, std::function<void()>>;

} // namespace

int main(int argc, char** argv) {
    const std::vector<Test> tests = {
        {"startup", startupHasSpacesWithBlankTabs},
        {"lookup", lookupReturnsMatchingRecords},
        {"selection", selectionRemembersEachSpace},
        {"idle", idleTimeoutUsesStrictBoundary},
        {"pinning", pinningTogglesOnlyTheRequestedTab},
        {"named-session-switch", switchingNamedSessionPreservesSpace},
        {"isolation", isolatedSessionsAreStableAndUnique},
        {"add-tab", tabsUseSpaceDefaultOrValidOverride},
        {"add-session", namedSessionsCanBeCreated},
        {"add-space", spacesCanBeCreatedWithInitialTabs},
        {"close-last", closingLastTabCreatesSelectedBlank},
        {"close-background", closingBackgroundTabPreservesSelection},
        {"move", movingTabsPreservesIdentity},
        {"sanitize-empty", sanitizeRecoversEmptyState},
        {"sanitize-malformed", sanitizeRepairsMalformedReferences},
        {"sanitize-valid", sanitizePreservesValidState},
    };
    unsigned passed = 0;
    unsigned failed = 0;
    for (const auto& test : tests) {
        if (argc > 1 && test.first != argv[1]) continue;
        try {
            test.second();
            ++passed;
            std::cout << "PASS " << test.first << '\n';
        } catch (const std::exception& error) {
            ++failed;
            std::cerr << "FAIL " << test.first << ": " << error.what() << '\n';
        }
    }
    if (passed + failed == 0) {
        std::cerr << "No matching tests\n";
        return 2;
    }
    std::cout << passed << " passed, " << failed << " failed\n";
    return failed ? 1 : 0;
}
