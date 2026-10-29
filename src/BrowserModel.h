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
};

struct Tab {
    std::string id;
    std::string spaceID;
    std::string sessionID;
    std::string title;
    std::string url;
    bool pinned = false;
    double lastUsed = 0;
};

struct State {
    std::vector<Session> sessions;
    std::vector<Space> spaces;
    std::vector<Tab> tabs;
    std::string activeSpaceID;
    std::string activeTabID;
    double idleMinutes = 10;
    bool sidebarVisible = true;
};

class BrowserModel {
public:
    State state;

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
    bool setSession(const std::string& tabID, const std::string& sessionID);
    bool setIsolated(const std::string& tabID);
    bool togglePin(const std::string& id);
    bool moveTab(const std::string& tabID, const std::string& targetSpaceID, double now);
    std::string addSpace(const std::string& name, const std::string& sessionID, double now);
    std::string addSession(const std::string& name);
    std::vector<std::string> idleTabs(double now) const;
    void sanitize(double now);
    static bool isIsolatedSession(const std::string& id);
    static std::string isolatedSessionID(const std::string& tabID);

private:
    std::string ensureSpaceTab(const std::string& spaceID, double now);
};

} // namespace rail
