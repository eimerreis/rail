#include "BrowserModel.h"
#include "Projects.h"
#include "SearchEngine.h"

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

std::string lowered(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return std::tolower(c); });
    return value;
}

// Canonical web origin and case-sensitive path, without query, fragment or trailing slashes.
std::string pinAddress(const std::string& url) {
    auto origin = originOf(url);
    if (origin.empty()) return {};
    const std::string defaultPort = origin.compare(0, 8, "https://") == 0 ? ":443" : ":80";
    if (origin.size() >= defaultPort.size() && origin.compare(origin.size() - defaultPort.size(), defaultPort.size(), defaultPort) == 0)
        origin.resize(origin.size() - defaultPort.size());
    const auto start = url.find_first_of("/?#", url.find("://") + 3);
    auto path = start != std::string::npos && url[start] == '/' ? url.substr(start) : std::string{};
    path = path.substr(0, path.find_first_of("?#"));
    while (!path.empty() && path.back() == '/') path.pop_back();
    return origin + path;
}

// Host (with port) and path, lowercased, without scheme, credentials, query, fragment or "www.".
std::string ruleAddress(const std::string& url) {
    auto text = trimmed(url);
    if (const auto scheme = text.find("://"); scheme != std::string::npos) text.erase(0, scheme + 3);
    text = text.substr(0, text.find_first_of("?#"));
    const auto slash = text.find('/');
    auto host = text.substr(0, slash);
    auto path = slash == std::string::npos ? std::string{} : text.substr(slash);
    if (const auto at = host.rfind('@'); at != std::string::npos) host.erase(0, at + 1);
    host = lowered(host);
    if (host.compare(0, 4, "www.") == 0) host.erase(0, 4);
    if (path == "/") path.clear();
    return host + lowered(path);
}

// "*" matches within one path segment, "**" across segments; "/**" may also match nothing.
bool globMatch(const char* pattern, const char* text) {
    while (*pattern) {
        if (pattern[0] == '/' && pattern[1] == '*' && pattern[2] == '*' && (!pattern[3] || pattern[3] == '/')
            && globMatch(pattern + 3, text)) return true;
        if (pattern[0] == '*') {
            const bool crossesSegments = pattern[1] == '*';
            pattern += crossesSegments ? 2 : 1;
            for (const char* rest = text;; ++rest) {
                if (globMatch(pattern, rest)) return true;
                if (!*rest || (!crossesSegments && *rest == '/')) return false;
            }
        }
        if (*pattern != *text) return false;
        ++pattern;
        ++text;
    }
    return !*text;
}

size_t specificity(const std::string& pattern) {
    return static_cast<size_t>(std::count_if(pattern.begin(), pattern.end(), [](char c) { return c != '*'; }));
}

std::string remapped(const IDMap& ids, const std::string& id) {
    const auto found = ids.find(id);
    return found == ids.end() ? id : found->second;
}

} // namespace

BrowserModel::BrowserModel() {
    state.sessions = {{"work", "Work"}, {"personal", "Personal"}};
    state.spaces = {{"work", "Work", "work", "", "briefcase"},
                    {"personal", "Personal", "personal", "", "house"},
                    {"research", "Research", "work", "", "book"}};
    for (auto& current : state.spaces) {
        current.selectedTabID = uniqueID("tab");
        state.tabs.push_back({current.selectedTabID, current.id, current.sessionID,
                              "New Tab", "about:blank", false, 0});
    }
    state.activeSpaceID = state.spaces.front().id;
    state.activeTabID = state.spaces.front().selectedTabID;
    rememberSelection(state.activeTabID);
}

Tab* BrowserModel::tab(const std::string& id) { return findRecord(state.tabs, id); }
const Tab* BrowserModel::tab(const std::string& id) const { return findRecord(state.tabs, id); }
Space* BrowserModel::space(const std::string& id) { return findRecord(state.spaces, id); }
const Space* BrowserModel::space(const std::string& id) const { return findRecord(state.spaces, id); }
const Session* BrowserModel::session(const std::string& id) const { return findRecord(state.sessions, id); }
std::string BrowserModel::addTab(const std::string& spaceID, const std::string& url,
                                 double now, const std::string& sessionID,
                                 const std::string& originTabID, bool background) {
    auto* owner = space(spaceID);
    if (!owner) return {};
    std::string id;
    do { id = uniqueID("tab"); } while (tab(id));
    const auto identity = sessionAllowed(id, sessionID) ? sessionID : owner->sessionID;
    const auto origin = originTabID.empty() ? state.activeTabID : originTabID;
    const auto source = tab(origin) ? origin : std::string{};
    state.tabs.push_back({id, owner->id, identity, "New Tab", nameOr(url, "about:blank"), false, timestamp(now)});
    state.tabs.back().originTabID = source;
    if (!background) selectTab(id, now);
    else if (owner->id != state.activeSpaceID) owner->selectedTabID = id;
    else ensureSpaceTab(spaceID, now);
    return id;
}
void BrowserModel::rememberSelection(const std::string& id) {
    const auto selectedID = id;
    recentTabIDs.erase(std::remove_if(recentTabIDs.begin(), recentTabIDs.end(), [&](const std::string& recent) {
        return recent == selectedID || !tab(recent);
    }), recentTabIDs.end());
    recentTabIDs.push_back(selectedID);
}
bool BrowserModel::selectTab(const std::string& id, double now) {
    auto* selected = tab(id);
    if (!selected) return false;
    auto* owner = space(selected->spaceID);
    if (!owner) return false;
    now = timestamp(now);
    if (auto* previous = tab(state.activeTabID)) previous->lastUsed = now;
    selected->lastUsed = now;
    selected->snoozedUntil = 0;
    owner->selectedTabID = selected->id;
    state.activeSpaceID = selected->spaceID;
    state.activeTabID = selected->id;
    rememberSelection(selected->id);
    return true;
}

bool BrowserModel::selectSpace(const std::string& id, double now) {
    const auto* owner = space(id);
    if (!owner) return false;
    const auto* selected = tab(owner->selectedTabID);
    if (selected && selected->spaceID == id && !selected->snoozed()) return selectTab(selected->id, now);
    const auto found = std::find_if(state.tabs.begin(), state.tabs.end(), [&](const Tab& current) {
        return current.spaceID == id && !current.snoozed();
    });
    return found != state.tabs.end() && selectTab(found->id, now);
}
std::string BrowserModel::ensureSpaceTab(const std::string& spaceID, double now) {
    auto* owner = space(spaceID);
    if (!owner) return {};
    const auto* remembered = tab(owner->selectedTabID);
    if (remembered && remembered->spaceID == owner->id && !remembered->snoozed()) return remembered->id;
    const auto found = std::find_if(state.tabs.begin(), state.tabs.end(), [&](const Tab& current) {
        return current.spaceID == owner->id && !current.snoozed();
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

std::string BrowserModel::tabAfterClose(const Tab& closed, const std::vector<std::string>& closingTabIDs) const {
    const auto eligible = [&](const Tab* candidate) {
        return candidate && candidate->spaceID == closed.spaceID && candidate->id != closed.id && !candidate->snoozed()
            && std::find(closingTabIDs.begin(), closingTabIDs.end(), candidate->id) == closingTabIDs.end();
    };
    // Pinned close keeps its existing recently-used behavior, rather than following an old origin.
    if (!closed.pinned && eligible(tab(closed.originTabID))) return closed.originTabID;
    for (auto recent = recentTabIDs.rbegin(); recent != recentTabIDs.rend(); ++recent) {
        if (eligible(tab(*recent))) return *recent;
    }
    // Tabs with no selection history (including restored layouts) use timestamps,
    // then stable sidebar order for ties. Never wake a tab or leave this Space.
    const Tab* next = nullptr;
    for (const auto& candidate : state.tabs) {
        if (eligible(&candidate) && (!next || candidate.lastUsed > next->lastUsed)) next = &candidate;
    }
    return next ? next->id : std::string{};
}
bool BrowserModel::closeTab(const std::string& id, double now, const std::vector<std::string>& closingTabIDs) {
    const auto* current = tab(id);
    if (!current) return false;
    const auto ownerID = current->spaceID;
    const auto closedID = current->id;
    const bool wasActive = state.activeTabID == closedID;
    ClosedTab record{*current, static_cast<size_t>(current - state.tabs.data()), current->pinned, ""};
    // Keep the undo stack short; it only covers recent mistakes.
    auto remember = [&] {
        closedTabs.push_back(record);
        if (closedTabs.size() > 25) closedTabs.erase(closedTabs.begin());
    };
    if (current->pinned) {
        // Closing a pinned tab keeps it pinned and puts it back to its pinned page.
        auto* pinned = tab(closedID);
        pinned->url = nameOr(pinned->pinnedURL, "about:blank");
        pinned->title = nameOr(pinned->pinnedTitle, "New Tab");
        if (!wasActive) { remember(); return true; }
    } else {
        state.tabs.erase(std::remove_if(state.tabs.begin(), state.tabs.end(), [&](const Tab& candidate) {
            return candidate.id == closedID;
        }), state.tabs.end());
        recentTabIDs.erase(std::remove(recentTabIDs.begin(), recentTabIDs.end(), closedID), recentTabIDs.end());
    }
    auto* owner = space(ownerID);
    const auto* remembered = owner ? tab(owner->selectedTabID) : nullptr;
    if (wasActive || !remembered || remembered->spaceID != ownerID || remembered->snoozed()) {
        auto replacement = tabAfterClose(record.tab, closingTabIDs);
        if (replacement.empty()) {
            replacement = addTab(ownerID, "about:blank", now, "", "", true);
            record.replacementID = replacement;
        }
        if (owner) owner->selectedTabID = replacement;
        if (wasActive) selectTab(replacement, now);
    }
    remember();
    return true;
}
std::string BrowserModel::reopenClosedTab(double now) {
    while (!closedTabs.empty()) {
        ClosedTab record = closedTabs.back();
        closedTabs.pop_back();
        Tab restored = record.tab;
        if (!space(restored.spaceID)) restored.spaceID = state.activeSpaceID;
        if (!space(restored.spaceID) || !sessionAllowed(restored.id, restored.sessionID)) {
            restored.sessionID = space(restored.spaceID) ? space(restored.spaceID)->sessionID : "";
        }
        if (!space(restored.spaceID)) continue;
        if (record.pinnedReset) {
            // The pinned tab is still there; give it back the page it was on.
            auto* pinned = tab(restored.id);
            if (!pinned) continue;
            pinned->url = restored.url;
            pinned->title = restored.title;
        } else {
            if (tab(restored.id)) continue;
            state.tabs.insert(state.tabs.begin() + static_cast<std::ptrdiff_t>(std::min(record.index, state.tabs.size())), restored);
        }
        // Drop the blank tab that only existed because this one was closed.
        if (const auto* blank = tab(record.replacementID); blank && blank->url == "about:blank" && !blank->pinned) {
            const auto blankID = blank->id;
            state.tabs.erase(std::remove_if(state.tabs.begin(), state.tabs.end(), [&](const Tab& t) { return t.id == blankID; }), state.tabs.end());
        }
        selectTab(restored.id, now);
        return restored.id;
    }
    return {};
}
bool BrowserModel::setSession(const std::string& tabID, const std::string& sessionID) {
    auto* current = tab(tabID);
    if (!current || !sessionAllowed(tabID, sessionID)) return false;
    current->sessionID = sessionID;
    return true;
}

bool BrowserModel::setIsolated(const std::string& tabID) {
    return setSession(tabID, isolatedSessionID(tabID));
}
double BrowserModel::controlScale(const std::string& controlSize) {
    if (controlSize == "large") return 1.3;
    if (controlSize == "normal") return 1.15;
    return 1;
}
bool BrowserModel::togglePin(const std::string& id) {
    const auto* current = tab(id);
    return current && setPinned(id, !current->pinned);
}
bool BrowserModel::setPinned(const std::string& id, bool pinned) {
    auto* current = tab(id);
    if (!current) return false;
    if (pinned && !current->pinned) { current->pinnedURL = current->url; current->pinnedTitle = current->title; }
    if (!pinned) { current->pinnedURL.clear(); current->pinnedTitle.clear(); current->customTitle.clear(); }
    current->pinned = pinned;
    return true;
}
bool BrowserModel::reorderPinnedTab(const std::string& id, const std::string& beforeID) {
    const auto* current = tab(id);
    if (!current || !current->pinned || !space(current->spaceID)) return false;
    if (!beforeID.empty()) {
        const auto* before = tab(beforeID);
        if (!before || !before->pinned || before->spaceID != current->spaceID) return false;
    }
    std::vector<size_t> slots;
    size_t from = 0, to = 0;
    for (size_t i = 0; i < state.tabs.size(); ++i) {
        const auto& candidate = state.tabs[i];
        if (!candidate.pinned || candidate.spaceID != current->spaceID) continue;
        if (candidate.id == id) from = slots.size();
        if (candidate.id == beforeID) to = slots.size();
        slots.push_back(i);
    }
    if (beforeID.empty()) to = slots.size();
    if (to > from) --to;
    // Rotate only pins, not intervening regular/snoozed tabs or another Space's tabs.
    while (from < to) { std::swap(state.tabs[slots[from]], state.tabs[slots[from + 1]]); ++from; }
    while (from > to) { std::swap(state.tabs[slots[from]], state.tabs[slots[from - 1]]); --from; }
    return true;
}
std::vector<std::string> BrowserModel::pinnedTabs(const std::string& spaceID) const {
    std::vector<std::string> pins;
    for (const auto& current : state.tabs) {
        if (current.spaceID == spaceID && current.pinned) pins.push_back(current.id);
    }
    return pins;
}
bool BrowserModel::renameTab(const std::string& id, const std::string& name) {
    auto* current = tab(id);
    if (!current || !current->pinned) return false;
    const auto first = name.find_first_not_of(" \t\r\n");
    current->customTitle = first == std::string::npos ? "" : name.substr(first, name.find_last_not_of(" \t\r\n") - first + 1);
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
bool BrowserModel::snoozeTabs(const std::vector<std::string>& ids, double until, double now) {
    if (!std::isfinite(until) || until <= timestamp(now)) return false;
    std::vector<std::string> spaces;
    for (const auto& id : ids) {
        auto* current = tab(id);
        if (!current || current->pinned) continue;
        current->snoozedUntil = until;
        spaces.push_back(current->spaceID);
    }
    if (spaces.empty()) return false;
    const auto* active = tab(state.activeTabID);
    const bool activeSnoozed = active && active->snoozed();
    const auto activeSpace = state.activeSpaceID;
    // Every Space keeps a visible tab, even if that means a new blank one.
    for (const auto& spaceID : spaces) ensureSpaceTab(spaceID, now);
    if (activeSnoozed) selectTab(ensureSpaceTab(activeSpace, now), now);
    return true;
}
bool BrowserModel::wakeTab(const std::string& id, double now) {
    auto* current = tab(id);
    if (!current || !current->snoozed()) return false;
    current->snoozedUntil = 0;
    current->lastUsed = timestamp(now);
    return true;
}
std::vector<std::string> BrowserModel::wakeDueTabs(double now) {
    std::vector<std::string> woken;
    for (auto& current : state.tabs) {
        if (current.snoozed() && current.snoozedUntil <= now) woken.push_back(current.id);
    }
    for (const auto& id : woken) wakeTab(id, now);
    return woken;
}
std::vector<std::string> BrowserModel::listedTabs(const std::string& spaceID) const {
    std::vector<std::string> listed;
    for (const auto& current : state.tabs) {
        if (current.spaceID == spaceID && !current.pinned && !current.snoozed()) listed.push_back(current.id);
    }
    return listed;
}
std::vector<std::string> BrowserModel::tabRange(const std::string& spaceID, const std::string& from, const std::string& to) const {
    const auto listed = listedTabs(spaceID);
    const auto end = std::find(listed.begin(), listed.end(), to);
    if (end == listed.end()) return {};
    const auto start = std::find(listed.begin(), listed.end(), from);
    if (start == listed.end()) return {to};
    return start < end ? std::vector<std::string>(start, end + 1) : std::vector<std::string>(end, start + 1);
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
std::string BrowserModel::normalizedRulePattern(const std::string& pattern) {
    auto normalized = ruleAddress(pattern);
    while (normalized.size() > 1 && normalized.back() == '/') normalized.pop_back();
    return normalized;
}
bool BrowserModel::ruleMatches(const std::string& pattern, const std::string& url) {
    const auto normalized = normalizedRulePattern(pattern);
    const auto address = ruleAddress(url);
    return !normalized.empty() && !address.empty() && globMatch(normalized.c_str(), address.c_str());
}
std::string BrowserModel::spaceForURL(const std::string& url) const {
    const SpaceRule* best = nullptr;
    for (const auto& rule : state.spaceRules) {
        if (!space(rule.spaceID) || !ruleMatches(rule.pattern, url)) continue;
        if (!best || specificity(rule.pattern) > specificity(best->pattern)) best = &rule;
    }
    return best ? best->spaceID : std::string{};
}
std::string BrowserModel::pinnedTabForURL(const std::string& url) const {
    const auto address = pinAddress(url);
    if (address.empty()) return {};
    const auto ruledSpace = spaceForURL(url);
    const Tab* best = nullptr;
    size_t bestLength = 0;
    for (const auto& candidate : state.tabs) {
        if (!candidate.pinned || !space(candidate.spaceID) || (!ruledSpace.empty() && candidate.spaceID != ruledSpace)) continue;
        const auto pinned = pinAddress(candidate.pinnedURL.empty() ? candidate.url : candidate.pinnedURL);
        if (pinned.empty() || address.compare(0, pinned.size(), pinned) != 0) continue;
        if (address.size() > pinned.size() && address[pinned.size()] != '/') continue;
        const bool inCurrentSpace = candidate.spaceID == state.activeSpaceID;
        const bool bestInCurrentSpace = best && best->spaceID == state.activeSpaceID;
        const bool preferred = best && (inCurrentSpace != bestInCurrentSpace ? inCurrentSpace
            : candidate.lastUsed != best->lastUsed ? candidate.lastUsed > best->lastUsed : candidate.id == state.activeTabID);
        if (!best || pinned.size() > bestLength || (pinned.size() == bestLength
            && preferred)) {
            best = &candidate;
            bestLength = pinned.size();
        }
    }
    return best ? best->id : std::string{};
}
std::vector<std::string> BrowserModel::rulesForSpace(const std::string& spaceID) const {
    std::vector<std::string> patterns;
    for (const auto& rule : state.spaceRules) if (rule.spaceID == spaceID) patterns.push_back(rule.pattern);
    return patterns;
}
bool BrowserModel::setSpaceRules(const std::string& spaceID, const std::vector<std::string>& patterns) {
    if (!space(spaceID)) return false;
    std::unordered_set<std::string> claimed;
    for (const auto& pattern : patterns) claimed.insert(normalizedRulePattern(pattern));
    // Saving a pattern here takes it away from any other Space.
    state.spaceRules.erase(std::remove_if(state.spaceRules.begin(), state.spaceRules.end(), [&](const SpaceRule& rule) {
        return rule.spaceID == spaceID || claimed.count(normalizedRulePattern(rule.pattern));
    }), state.spaceRules.end());
    for (const auto& pattern : patterns) state.spaceRules.push_back({pattern, spaceID});
    sanitizeRules();
    return true;
}
void BrowserModel::sanitizeRules() {
    std::unordered_set<std::string> seen;
    std::vector<SpaceRule> kept;
    for (auto rule : state.spaceRules) {
        rule.pattern = normalizedRulePattern(rule.pattern);
        // One pattern belongs to one Space; the first claim keeps it.
        if (rule.pattern.empty() || !space(rule.spaceID) || !seen.insert(rule.pattern).second) continue;
        kept.push_back(std::move(rule));
    }
    state.spaceRules = std::move(kept);
}
void BrowserModel::sanitize(double now) {
    now = timestamp(now);
    if (!std::isfinite(state.idleMinutes * 60) || state.idleMinutes <= 0) state.idleMinutes = 10;
    state.sidebarWidth = std::isfinite(state.sidebarWidth) ? std::clamp(state.sidebarWidth, 180.0, 420.0) : 210;
    if (state.controlSize != "normal" && state.controlSize != "large") state.controlSize = "small";
    if (state.sidebarAnimation != "off" && state.sidebarAnimation != "subtle") state.sidebarAnimation = "full";
    if (state.theme != "nightline" && state.theme != "daylight") state.theme = "porcelain";
    state.searchEngine = searchEngineForID(state.searchEngine).id;
    state.devToolsWidth = std::isfinite(state.devToolsWidth) ? std::clamp(state.devToolsWidth, 240.0, 1600.0) : 480;

    if (state.sessions.empty()) state.sessions = {{"work", "Work"}, {"personal", "Personal"}};
    const auto sessionIDs = repairIDs(state.sessions, "session", true);
    for (auto& current : state.sessions) current.name = nameOr(current.name, "Session");

    if (state.spaces.empty()) {
        const auto work = session("work") ? "work" : state.sessions.front().id;
        const auto personal = session("personal") ? "personal" : work;
        state.spaces = {{"work", "Work", work, "", "briefcase"}, {"personal", "Personal", personal, "", "house"},
                        {"research", "Research", work, "", "book"}};
    }
    const auto spaceIDs = repairIDs(state.spaces, "space");
    for (auto& current : state.spaces) {
        current.name = nameOr(current.name, "Space");
        current.sessionID = remapped(sessionIDs, current.sessionID);
        if (!session(current.sessionID)) current.sessionID = state.sessions.front().id;
    }

    const auto tabIDs = repairIDs(state.tabs, "tab");
    for (auto& current : state.tabs) {
        if (!current.originTabID.empty()) current.originTabID = remapped(tabIDs, current.originTabID);
        if (current.originTabID == current.id || !tab(current.originTabID)) current.originTabID.clear();
        current.spaceID = remapped(spaceIDs, current.spaceID);
        const auto* owner = space(current.spaceID);
        if (!owner) {
            owner = &state.spaces.front();
            current.spaceID = owner->id;
        }
        current.sessionID = remapped(sessionIDs, current.sessionID);
        if (!sessionAllowed(current.id, current.sessionID)) {
            current.sessionID = current.sessionID.compare(0, 9, "isolated-") == 0
                ? isolatedSessionID(current.id) : owner->sessionID;
        }
        current.url = nameOr(current.url, "about:blank");
        current.title = nameOr(current.title, "New Tab");
        if (!std::isfinite(current.lastUsed) || current.lastUsed < 0 || current.lastUsed > now) {
            current.lastUsed = now;
        }
        if (!current.pinned) { current.pinnedURL.clear(); current.pinnedTitle.clear(); current.customTitle.clear(); }
        else if (current.pinnedURL.empty()) { current.pinnedURL = current.url; current.pinnedTitle = current.title; }
        // A tab whose time passed while Rail was closed is simply back.
        if (current.pinned || !std::isfinite(current.snoozedUntil) || current.snoozedUntil <= now) current.snoozedUntil = 0;
    }
    if (auto* active = tab(remapped(tabIDs, state.activeTabID))) active->snoozedUntil = 0;

    for (auto& rule : state.spaceRules) rule.spaceID = remapped(spaceIDs, rule.spaceID);
    sanitizeRules();

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
    for (auto& recent : recentTabIDs) recent = remapped(tabIDs, recent);
    rememberSelection(state.activeTabID);
}
bool BrowserModel::sessionAllowed(const std::string& tabID, const std::string& sessionID) const {
    if (session(sessionID) || sessionID == isolatedSessionID(tabID)) return true;
    return isIsolatedSession(sessionID)
        && std::find(projectProfiles.begin(), projectProfiles.end(), sessionID) != projectProfiles.end();
}

bool BrowserModel::isIsolatedSession(const std::string& id) {
    constexpr auto prefix = "isolated-";
    return id.compare(0, 9, prefix) == 0 && safeID(id.substr(9));
}

std::string BrowserModel::isolatedSessionID(const std::string& tabID) {
    return "isolated-" + tabID;
}

} // namespace rail
