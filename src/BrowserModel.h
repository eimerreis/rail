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
    // When a snoozed tab comes back; 0 for a tab that isn't snoozed. Snoozed tabs stay
    // in their Space and position but are left out of its visible tabs until then.
    double snoozedUntil = 0;
    // Close returns here when the source is still visible in this Space. Runtime
    // only, like selection history; unrelated to Chromium's window.opener/session.
    std::string originTabID;
    bool snoozed() const { return snoozedUntil > 0; }
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
    // How hiding and showing the sidebar animates: off, subtle or full.
    std::string sidebarAnimation = "full";
    // Shell theme for every window: porcelain, nightline or daylight.
    std::string theme = "porcelain";
    // Address-bar and new-tab searches: duckduckgo (the existing default), google or bing.
    std::string searchEngine = "duckduckgo";
    // DevTools open beside the page, as in Chrome, or in their own window.
    bool devToolsDocked = true;
    double devToolsWidth = 480;
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
    // An empty origin uses the active tab. Background creation never changes the
    // active tab/Space; a routed tab is remembered in its destination Space.
    std::string addTab(const std::string& spaceID, const std::string& url,
                       double now, const std::string& sessionID = "",
                       const std::string& originTabID = "", bool background = false);
    bool selectTab(const std::string& id, double now);
    bool selectSpace(const std::string& id, double now);
    // Pending asynchronous closes are not eligible return destinations.
    bool closeTab(const std::string& id, double now, const std::vector<std::string>& closingTabIDs = {});
    // Restores the most recently closed tab and selects it; returns its ID or "".
    std::string reopenClosedTab(double now);
    bool setSession(const std::string& tabID, const std::string& sessionID);
    bool setIsolated(const std::string& tabID);
    bool togglePin(const std::string& id);
    bool setPinned(const std::string& id, bool pinned);
    // Names a pinned tab; a blank name goes back to the page title.
    bool renameTab(const std::string& id, const std::string& name);
    bool moveTab(const std::string& tabID, const std::string& targetSpaceID, double now);
    // Hides tabs until the given time and moves off the active tab if it is one of them.
    // Pinned tabs and unknown IDs are skipped; false when nothing was snoozed.
    bool snoozeTabs(const std::vector<std::string>& ids, double until, double now);
    // Puts a snoozed tab back in its Space without selecting it. Selecting a tab also wakes it.
    bool wakeTab(const std::string& id, double now);
    // Wakes the tabs whose time has come and returns their IDs.
    std::vector<std::string> wakeDueTabs(double now);
    // The Space's sidebar list, top to bottom: tabs that are neither pinned nor snoozed.
    std::vector<std::string> listedTabs(const std::string& spaceID) const;
    // The listed tabs from one tab to another inclusive, in either direction.
    // Just the destination when the starting tab isn't listed; empty when the destination isn't.
    std::vector<std::string> tabRange(const std::string& spaceID, const std::string& from, const std::string& to) const;
    std::string addSpace(const std::string& name, const std::string& sessionID, double now);
    std::string addSession(const std::string& name);
    std::vector<std::string> idleTabs(double now) const;
    // The Space a rule sends url to, or "" when no rule matches.
    std::string spaceForURL(const std::string& url) const;
    // A pin for this page or a parent path, respecting Space rules; "" if none matches.
    std::string pinnedTabForURL(const std::string& url) const;
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
    // Actual selection order, independent of lastUsed (also used for idle timing).
    std::vector<std::string> recentTabIDs;
    void rememberSelection(const std::string& id);
    std::string tabAfterClose(const Tab& closed, const std::vector<std::string>& closingTabIDs) const;
    std::string ensureSpaceTab(const std::string& spaceID, double now);
    void sanitizeRules();
};

} // namespace rail
