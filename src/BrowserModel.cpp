#include "BrowserModel.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cctype>
#include <cstdint>
#include <iomanip>
#include <random>
#include <sstream>
#include <unordered_map>
#include <unordered_set>

namespace rail {

namespace {

std::string uniqueID(const char* kind) {
    static std::atomic<std::uint64_t> sequence{0};
    static thread_local std::mt19937_64 random{std::random_device{}()};
    std::ostringstream value;
    value << kind << '-' << std::hex << std::setfill('0')
          << std::setw(16) << random() << std::setw(16) << (random() ^ ++sequence);
    return value.str();
}

template <typename Records>
auto findRecord(Records& records, const std::string& id) -> decltype(&records.front()) {
    const auto found = std::find_if(records.begin(), records.end(), [&](const auto& record) {
        return record.id == id;
    });
    return found == records.end() ? nullptr : &*found;
}

double timestamp(double now) {
    return std::isfinite(now) && now >= 0 ? now : 0;
}

std::string trimmed(const std::string& value) {
    const auto begin = std::find_if_not(value.begin(), value.end(), [](unsigned char c) { return std::isspace(c); });
    const auto end = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char c) { return std::isspace(c); }).base();
    return begin < end ? std::string(begin, end) : std::string{};
}

std::string nameOr(const std::string& value, const char* fallback) {
    const auto name = trimmed(value);
    return name.empty() ? fallback : name;
}

bool safeID(const std::string& id) {
    return !id.empty() && id.size() <= 128 && std::all_of(id.begin(), id.end(), [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '-' || c == '_';
    });
}

using IDMap = std::unordered_map<std::string, std::string>;

template <typename Records>
IDMap repairIDs(Records& records, const char* kind, bool namedSessions = false) {
    const auto allowed = [&](const std::string& id) {
        return safeID(id) && (!namedSessions || id.compare(0, 9, "isolated-") != 0);
    };
    std::unordered_set<std::string> reserved;
    std::unordered_set<std::string> used;
    IDMap repaired;
    for (const auto& record : records) {
        if (allowed(record.id)) reserved.insert(record.id);
    }
    for (auto& record : records) {
        const auto original = record.id;
        if (!allowed(original) || used.count(original)) {
            do { record.id = uniqueID(kind); } while (used.count(record.id) || reserved.count(record.id));
        }
        used.insert(record.id);
        // Duplicate imported IDs are ambiguous; existing references keep the first record.
        repaired.emplace(original, record.id);
    }
    return repaired;
}

std::string remapped(const IDMap& ids, const std::string& id) {
    const auto found = ids.find(id);
    return found == ids.end() ? id : found->second;
}

} // namespace

BrowserModel::BrowserModel() {
    state.sessions = {{"work", "Work"}, {"personal", "Personal"}};
    state.spaces = {{"work", "Work", "work", ""},
                    {"personal", "Personal", "personal", ""},
                    {"research", "Research", "work", ""}};
    for (auto& current : state.spaces) {
        current.selectedTabID = uniqueID("tab");
        state.tabs.push_back({current.selectedTabID, current.id, current.sessionID,
                              "New Tab", "about:blank", false, 0});
    }
    state.activeSpaceID = state.spaces.front().id;
    state.activeTabID = state.spaces.front().selectedTabID;
}

Tab* BrowserModel::tab(const std::string& id) { return findRecord(state.tabs, id); }
const Tab* BrowserModel::tab(const std::string& id) const { return findRecord(state.tabs, id); }
Space* BrowserModel::space(const std::string& id) { return findRecord(state.spaces, id); }
const Space* BrowserModel::space(const std::string& id) const { return findRecord(state.spaces, id); }
const Session* BrowserModel::session(const std::string& id) const { return findRecord(state.sessions, id); }
std::string BrowserModel::addTab(const std::string& spaceID, const std::string& url,
                                 double now, const std::string& sessionID) {
    const auto* owner = space(spaceID);
    if (!owner) return {};
    const auto identity = session(sessionID) ? sessionID : owner->sessionID;
    std::string id;
    do { id = uniqueID("tab"); } while (tab(id));
    state.tabs.push_back({id, owner->id, identity, "New Tab", nameOr(url, "about:blank"), false, timestamp(now)});
    selectTab(id, now);
    return id;
}
bool BrowserModel::selectTab(const std::string& id, double now) {
    auto* selected = tab(id);
    if (!selected) return false;
    auto* owner = space(selected->spaceID);
    if (!owner) return false;
    now = timestamp(now);
    if (auto* previous = tab(state.activeTabID)) previous->lastUsed = now;
    selected->lastUsed = now;
    owner->selectedTabID = selected->id;
    state.activeSpaceID = selected->spaceID;
    state.activeTabID = selected->id;
    return true;
}

bool BrowserModel::selectSpace(const std::string& id, double now) {
    const auto* owner = space(id);
    if (!owner) return false;
    const auto* selected = tab(owner->selectedTabID);
    if (selected && selected->spaceID == id) return selectTab(selected->id, now);
    const auto found = std::find_if(state.tabs.begin(), state.tabs.end(), [&](const Tab& current) {
        return current.spaceID == id;
    });
    return found != state.tabs.end() && selectTab(found->id, now);
}
std::string BrowserModel::ensureSpaceTab(const std::string& spaceID, double now) {
    auto* owner = space(spaceID);
    if (!owner) return {};
    const auto* remembered = tab(owner->selectedTabID);
    if (remembered && remembered->spaceID == owner->id) return remembered->id;
    const auto found = std::find_if(state.tabs.begin(), state.tabs.end(), [&](const Tab& current) {
        return current.spaceID == owner->id;
    });
    if (found != state.tabs.end()) {
        owner->selectedTabID = found->id;
    } else {
        std::string id;
        do { id = uniqueID("tab"); } while (tab(id));
        state.tabs.push_back({id, owner->id, owner->sessionID, "New Tab", "about:blank", false, timestamp(now)});
        owner->selectedTabID = id;
    }
    return owner->selectedTabID;
}

bool BrowserModel::closeTab(const std::string& id, double now) {
    const auto* current = tab(id);
    if (!current) return false;
    const auto ownerID = current->spaceID;
    const auto closedID = current->id;
    const bool wasActive = state.activeTabID == closedID;
    state.tabs.erase(std::remove_if(state.tabs.begin(), state.tabs.end(), [&](const Tab& candidate) {
        return candidate.id == closedID;
    }), state.tabs.end());
    const auto replacement = ensureSpaceTab(ownerID, now);
    if (wasActive) selectTab(replacement, now);
    return true;
}
bool BrowserModel::setSession(const std::string& tabID, const std::string& sessionID) {
    auto* current = tab(tabID);
    if (!current || (!session(sessionID) && sessionID != isolatedSessionID(current->id))) return false;
    current->sessionID = sessionID;
    return true;
}

bool BrowserModel::setIsolated(const std::string& tabID) {
    return setSession(tabID, isolatedSessionID(tabID));
}
bool BrowserModel::togglePin(const std::string& id) {
    auto* current = tab(id);
    if (!current) return false;
    current->pinned = !current->pinned;
    return true;
}
bool BrowserModel::moveTab(const std::string& tabID, const std::string& targetSpaceID, double now) {
    auto* current = tab(tabID);
    if (!current || !space(targetSpaceID)) return false;
    if (current->spaceID == targetSpaceID) return true;
    const auto movedID = current->id;
    const auto sourceID = current->spaceID;
    const auto targetID = targetSpaceID;
    const bool wasActive = state.activeTabID == movedID;
    current->spaceID = targetID;
    ensureSpaceTab(sourceID, now);
    ensureSpaceTab(targetID, now);
    if (wasActive) selectTab(movedID, now);
    return true;
}
std::string BrowserModel::addSpace(const std::string& name, const std::string& sessionID, double now) {
    if (state.sessions.empty()) return {};
    const auto identity = session(sessionID) ? sessionID : state.sessions.front().id;
    std::string id;
    do { id = uniqueID("space"); } while (space(id));
    const auto displayName = nameOr(name, "Space");
    state.spaces.push_back({id, displayName, identity, ""});
    addTab(id, "about:blank", now);
    return id;
}

std::string BrowserModel::addSession(const std::string& name) {
    std::string id;
    do { id = uniqueID("session"); } while (session(id));
    const auto displayName = nameOr(name, "Session");
    state.sessions.push_back({id, displayName});
    return id;
}
std::vector<std::string> BrowserModel::idleTabs(double now) const {
    std::vector<std::string> result;
    if (!std::isfinite(now) || !std::isfinite(state.idleMinutes) || state.idleMinutes <= 0) return result;
    for (const auto& current : state.tabs) {
        if (current.id != state.activeTabID && std::isfinite(current.lastUsed)
            && now - current.lastUsed > state.idleMinutes * 60) {
            result.push_back(current.id);
        }
    }
    return result;
}
void BrowserModel::sanitize(double now) {
    now = timestamp(now);
    if (!std::isfinite(state.idleMinutes * 60) || state.idleMinutes <= 0) state.idleMinutes = 10;

    if (state.sessions.empty()) state.sessions = {{"work", "Work"}, {"personal", "Personal"}};
    const auto sessionIDs = repairIDs(state.sessions, "session", true);
    for (auto& current : state.sessions) current.name = nameOr(current.name, "Session");

    if (state.spaces.empty()) {
        const auto work = session("work") ? "work" : state.sessions.front().id;
        const auto personal = session("personal") ? "personal" : work;
        state.spaces = {{"work", "Work", work, ""}, {"personal", "Personal", personal, ""},
                        {"research", "Research", work, ""}};
    }
    const auto spaceIDs = repairIDs(state.spaces, "space");
    for (auto& current : state.spaces) {
        current.name = nameOr(current.name, "Space");
        current.sessionID = remapped(sessionIDs, current.sessionID);
        if (!session(current.sessionID)) current.sessionID = state.sessions.front().id;
    }

    const auto tabIDs = repairIDs(state.tabs, "tab");
    for (auto& current : state.tabs) {
        current.spaceID = remapped(spaceIDs, current.spaceID);
        const auto* owner = space(current.spaceID);
        if (!owner) {
            owner = &state.spaces.front();
            current.spaceID = owner->id;
        }
        current.sessionID = remapped(sessionIDs, current.sessionID);
        if (!session(current.sessionID)) {
            current.sessionID = current.sessionID.compare(0, 9, "isolated-") == 0
                ? isolatedSessionID(current.id) : owner->sessionID;
        }
        current.url = nameOr(current.url, "about:blank");
        current.title = nameOr(current.title, "New Tab");
        if (!std::isfinite(current.lastUsed) || current.lastUsed < 0 || current.lastUsed > now) {
            current.lastUsed = now;
        }
    }

    for (auto& current : state.spaces) {
        current.selectedTabID = remapped(tabIDs, current.selectedTabID);
        ensureSpaceTab(current.id, now);
    }
    state.activeTabID = remapped(tabIDs, state.activeTabID);
    state.activeSpaceID = remapped(spaceIDs, state.activeSpaceID);
    if (const auto* active = tab(state.activeTabID)) {
        state.activeSpaceID = active->spaceID;
        space(active->spaceID)->selectedTabID = active->id;
    } else {
        if (!space(state.activeSpaceID)) state.activeSpaceID = state.spaces.front().id;
        state.activeTabID = space(state.activeSpaceID)->selectedTabID;
    }
}
bool BrowserModel::isIsolatedSession(const std::string& id) {
    constexpr auto prefix = "isolated-";
    return id.compare(0, 9, prefix) == 0 && safeID(id.substr(9));
}

std::string BrowserModel::isolatedSessionID(const std::string& tabID) {
    return "isolated-" + tabID;
}

} // namespace rail
