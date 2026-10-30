#pragma once

#include <string>
#include <vector>

namespace rail {

struct Session {
    std::string id;
    std::string name;
};

struct Space {
    std::string id;
    std::string name;
    std::string sessionID;
    std::string selectedTabID;
    // SF Symbol shown in the rail; empty falls back to one picked by position.
    std::string icon;
};

struct Tab {
    std::string id;
    std::string spaceID;
    std::string sessionID;
    std::string title;
    std::string url;
    bool pinned = false;
    double lastUsed = 0;
    // The page a pinned tab returns to when it is closed, as in Arc.
    std::string pinnedURL;
    std::string pinnedTitle;
    // A name the user gave a pinned tab; it replaces the page title until the tab is unpinned.
    std::string customTitle;
    const std::string& shownTitle() const { return customTitle.empty() ? title : customTitle; }
};

// Links whose address matches pattern open in spaceID. Patterns are globs over
// host and path, e.g. dev.azure.com/contoso/**; the most specific match wins.
struct SpaceRule {
    std::string pattern;
    std::string spaceID;
};

struct State {
    std::vector<Session> sessions;
    std::vector<Space> spaces;
    std::vector<Tab> tabs;
    std::vector<SpaceRule> spaceRules;
    std::string activeSpaceID;
    std::string activeTabID;
    double idleMinutes = 10;
    bool sidebarVisible = true;
    double sidebarWidth = 210;
    // Size of the sidebar, Spaces rail and Space home: small, normal or large.
    std::string controlSize = "small";
};

// What closing a tab changed, so it can be undone. Kept only for this run of the app.
struct ClosedTab {
    Tab tab;
    size_t index = 0;
    bool pinnedReset = false;
    std::string replacementID;
};

class BrowserModel {
public:
    State state;
    std::vector<ClosedTab> closedTabs;
    // Isolated profiles owned by project environments and links. Tabs opened from a
    // project may use them; set before sanitize so those tabs keep their profile.
    std::vector<std::string> projectProfiles;

    BrowserModel();
    Tab* tab(const std::string& id);
    const Tab* tab(const std::string& id) const;
    Space* space(const std::string& id);
    const Space* space(const std::string& id) const;
    const Session* session(const std::string& id) const;
    std::string addTab(const std::string& spaceID, const std::string& url,
                       double now, const std::string& sessionID = "");
    bool selectTab(const std::string& id, double now);
    bool selectSpace(const std::string& id, double now);
    bool closeTab(const std::string& id, double now);
    // Restores the most recently closed tab and selects it; returns its ID or "".
    std::string reopenClosedTab(double now);
    bool setSession(const std::string& tabID, const std::string& sessionID);
    bool setIsolated(const std::string& tabID);
    bool togglePin(const std::string& id);
    bool setPinned(const std::string& id, bool pinned);
    // Names a pinned tab; a blank name goes back to the page title.
    bool renameTab(const std::string& id, const std::string& name);
    bool moveTab(const std::string& tabID, const std::string& targetSpaceID, double now);
    std::string addSpace(const std::string& name, const std::string& sessionID, double now);
    std::string addSession(const std::string& name);
    std::vector<std::string> idleTabs(double now) const;
    // The Space a rule sends url to, or "" when no rule matches.
    std::string spaceForURL(const std::string& url) const;
    std::vector<std::string> rulesForSpace(const std::string& spaceID) const;
    // Replaces the rules of one Space; blank and duplicate patterns are dropped.
    bool setSpaceRules(const std::string& spaceID, const std::vector<std::string>& patterns);
    static std::string normalizedRulePattern(const std::string& pattern);
    static bool ruleMatches(const std::string& pattern, const std::string& url);
    void sanitize(double now);
    // A named session, the tab's own isolated profile, or a project-owned profile.
    bool sessionAllowed(const std::string& tabID, const std::string& sessionID) const;
    static bool isIsolatedSession(const std::string& id);
    // How much larger than small the sidebar and Space home are drawn.
    static double controlScale(const std::string& controlSize);
    static std::string isolatedSessionID(const std::string& tabID);

private:
    std::string ensureSpaceTab(const std::string& spaceID, double now);
    void sanitizeRules();
};

} // namespace rail
