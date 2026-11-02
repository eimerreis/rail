#include "Reading.h"

#include "Projects.h"

#include <algorithm>
#include <cmath>
#include <unordered_set>

namespace rail {

ReadingItem* ReadingList::item(const std::string& id) {
    for (auto& entry : state.items) if (entry.id == id) return &entry;
    return nullptr;
}
const ReadingItem* ReadingList::item(const std::string& id) const {
    return const_cast<ReadingList*>(this)->item(id);
}
Feed* ReadingList::feed(const std::string& id) {
    for (auto& entry : state.feeds) if (entry.id == id) return &entry;
    return nullptr;
}
const Feed* ReadingList::feed(const std::string& id) const {
    return const_cast<ReadingList*>(this)->feed(id);
}

std::string ReadingList::newID(const char* prefix, double now) {
    for (;;) {
        std::string id = prefix + std::to_string(static_cast<long long>(now * 1000)) + "-" + std::to_string(++nextID_);
        if (!item(id) && !feed(id)) return id;
    }
}

std::string ReadingList::siteOf(const std::string& url) {
    const auto scheme = url.find("://");
    auto host = scheme == std::string::npos ? url : url.substr(scheme + 3);
    host = host.substr(0, host.find_first_of("/?#"));
    if (const auto at = host.rfind('@'); at != std::string::npos) host = host.substr(at + 1);
    if (host.rfind("www.", 0) == 0) host = host.substr(4);
    return host;
}

std::string ReadingList::add(const std::string& url, const std::string& sessionID, double now, bool* created) {
    if (created) *created = false;
    if (!isWebURL(url)) return "";
    for (auto& entry : state.items) {
        if (entry.url != url) continue;
        entry.readAt = 0; entry.added = now;
        return entry.id;
    }
    ReadingItem entry;
    entry.id = newID("r", now);
    entry.url = url;
    entry.site = siteOf(url);
    entry.sessionID = sessionID;
    entry.added = now;
    state.items.push_back(entry);
    if (created) *created = true;
    return entry.id;
}

bool ReadingList::markRead(const std::string& id, double now) {
    auto* entry = item(id);
    if (!entry || entry->readAt > 0) return false;
    entry->readAt = now;
    return true;
}

bool ReadingList::markUnread(const std::string& id) {
    auto* entry = item(id);
    if (!entry || entry->readAt <= 0) return false;
    entry->readAt = 0;
    return true;
}

bool ReadingList::remove(const std::string& id) {
    const auto before = state.items.size();
    state.items.erase(std::remove_if(state.items.begin(), state.items.end(), [&](const ReadingItem& entry) { return entry.id == id; }), state.items.end());
    return state.items.size() != before;
}

bool ReadingList::setProgress(const std::string& id, double progress) {
    auto* entry = item(id);
    if (!entry) return false;
    entry->progress = std::clamp(progress, 0.0, 1.0);
    return true;
}

std::string ReadingList::addFeed(const std::string& url, const std::string& title, bool* created) {
    if (created) *created = false;
    if (!isWebURL(url)) return "";
    for (const auto& entry : state.feeds) if (entry.url == url) return entry.id;
    Feed entry;
    entry.id = newID("f", static_cast<double>(state.feeds.size()));
    entry.url = url;
    entry.title = title.empty() ? siteOf(url) : title;
    state.feeds.push_back(entry);
    if (created) *created = true;
    return entry.id;
}

std::vector<std::string> ReadingList::removeFeed(const std::string& id) {
    std::vector<std::string> removed;
    for (const auto& entry : state.items) if (entry.feedID == id) removed.push_back(entry.id);
    for (const auto& itemID : removed) remove(itemID);
    state.feeds.erase(std::remove_if(state.feeds.begin(), state.feeds.end(), [&](const Feed& entry) { return entry.id == id; }), state.feeds.end());
    return removed;
}

size_t ReadingList::mergeFeed(const std::string& feedID, const std::vector<FeedEntry>& entries,
                              const std::function<std::string(const std::string&)>& sessionForURL,
                              double now, std::vector<std::string>* removed) {
    auto* source = feed(feedID);
    if (!source) return 0;
    std::vector<FeedEntry> sorted = entries;
    std::stable_sort(sorted.begin(), sorted.end(), [](const FeedEntry& a, const FeedEntry& b) { return a.published > b.published; });
    std::unordered_set<std::string> seen(source->seen.begin(), source->seen.end());
    size_t added = 0, considered = 0;
    const bool first = !source->fetched;
    std::vector<std::string> newlySeen;
    for (const auto& entry : sorted) {
        const auto key = entry.guid.empty() ? entry.url : entry.guid;
        if (key.empty() || !seen.insert(key).second) continue;
        newlySeen.push_back(key);
        if (!isWebURL(entry.url) || (first && considered >= firstFetchLimit)) continue;
        ++considered;
        // A link the user saved themselves stays as it is, read or not.
        bool known = false;
        for (const auto& existing : state.items) if (existing.url == entry.url) { known = true; break; }
        if (known) continue;
        ReadingItem added_item;
        added_item.id = newID("r", now);
        added_item.url = entry.url;
        added_item.title = entry.title;
        added_item.site = source->title;
        added_item.feedID = feedID;
        added_item.sessionID = sessionForURL ? sessionForURL(entry.url) : "";
        added_item.added = entry.published > 0 && entry.published < now ? entry.published : now;
        state.items.push_back(added_item);
        ++added;
    }
    // Newest last, so trimming from the front forgets the oldest.
    source->seen.insert(source->seen.end(), newlySeen.rbegin(), newlySeen.rend());
    if (source->seen.size() > seenPerFeed) source->seen.erase(source->seen.begin(), source->seen.end() - seenPerFeed);
    source->fetched = true;

    // Over the limit, read items go first, oldest first; unread ones only if there are too many of those.
    std::vector<const ReadingItem*> own;
    for (const auto& entry : state.items) if (entry.feedID == feedID) own.push_back(&entry);
    if (own.size() > itemsPerFeed) {
        std::stable_sort(own.begin(), own.end(), [](const ReadingItem* a, const ReadingItem* b) {
            if ((a->readAt > 0) != (b->readAt > 0)) return a->readAt > 0;
            return a->added < b->added;
        });
        std::vector<std::string> prune;
        for (size_t i = 0; i < own.size() - itemsPerFeed; ++i) prune.push_back(own[i]->id);
        for (const auto& id : prune) { remove(id); if (removed) removed->push_back(id); }
    }
    return added;
}

std::vector<const ReadingItem*> ReadingList::shown(bool read, const std::string& feedID) const {
    std::vector<const ReadingItem*> result;
    for (const auto& entry : state.items) {
        if ((entry.readAt > 0) != read) continue;
        if (!feedID.empty() && entry.feedID != feedID) continue;
        result.push_back(&entry);
    }
    std::stable_sort(result.begin(), result.end(), [read](const ReadingItem* a, const ReadingItem* b) {
        return read ? a->readAt > b->readAt : a->added > b->added;
    });
    return result;
}

size_t ReadingList::unreadCount(const std::string& feedID) const {
    return shown(false, feedID).size();
}

int ReadingList::minutesLeft(const ReadingItem& item) {
    if (item.minutes <= 0) return 0;
    return std::max(1, static_cast<int>(std::ceil(item.minutes * (1 - item.progress))));
}

void ReadingList::sanitize() {
    state.items.erase(std::remove_if(state.items.begin(), state.items.end(), [](const ReadingItem& entry) { return entry.id.empty() || !isWebURL(entry.url); }), state.items.end());
    state.feeds.erase(std::remove_if(state.feeds.begin(), state.feeds.end(), [](const Feed& entry) { return entry.id.empty() || !isWebURL(entry.url); }), state.feeds.end());
    for (auto& entry : state.items) {
        entry.progress = std::clamp(entry.progress, 0.0, 1.0);
        if (entry.site.empty()) entry.site = siteOf(entry.url);
        // Items whose feed is gone become ordinary saved links.
        if (!entry.feedID.empty() && !feed(entry.feedID)) entry.feedID.clear();
    }
}

const char* readerStatusName(ReaderStatus status) {
    switch (status) {
        case ReaderStatus::Ready: return "ready";
        case ReaderStatus::NeedsLogin: return "login";
        case ReaderStatus::Unavailable: return "unavailable";
        case ReaderStatus::Pending: break;
    }
    return "pending";
}

ReaderStatus readerStatusFromName(const std::string& name) {
    if (name == "ready") return ReaderStatus::Ready;
    if (name == "login") return ReaderStatus::NeedsLogin;
    if (name == "unavailable") return ReaderStatus::Unavailable;
    return ReaderStatus::Pending;
}

} // namespace rail
