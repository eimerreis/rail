#pragma once

#include <functional>
#include <string>
#include <vector>

namespace rail {

// Whether an item can be shown in the reader. The article itself is cached in a separate file.
enum class ReaderStatus { Pending, Ready, NeedsLogin, Unavailable };

struct ReadingItem {
    std::string id;
    std::string url;
    std::string title;
    std::string site;
    // Empty for links the user saved.
    std::string feedID;
    // The session the page is read and opened in.
    std::string sessionID;
    double added = 0;
    // 0 while unread.
    double readAt = 0;
    int minutes = 0;
    // How far the reader was scrolled, 0 to 1.
    double progress = 0;
    ReaderStatus reader = ReaderStatus::Pending;
};

struct Feed {
    std::string id;
    std::string url;
    std::string title;
    double lastSuccess = 0;
    // Why the last check failed; empty when it worked.
    std::string error;
    bool fetched = false;
    // Entries already handled, oldest first, so skipped and pruned ones never come back as new.
    std::vector<std::string> seen;
};

struct FeedEntry {
    std::string guid;
    std::string url;
    std::string title;
    double published = 0;
};

struct ReadingState {
    std::vector<ReadingItem> items;
    std::vector<Feed> feeds;
};

class ReadingList {
public:
    ReadingState state;

    ReadingItem* item(const std::string& id);
    const ReadingItem* item(const std::string& id) const;
    Feed* feed(const std::string& id);
    const Feed* feed(const std::string& id) const;

    // Saves a link, or returns the item that already has this address, back in the inbox.
    // created tells the two apart. Returns "" for an address that is not a web page.
    std::string add(const std::string& url, const std::string& sessionID, double now, bool* created = nullptr);
    bool markRead(const std::string& id, double now);
    bool markUnread(const std::string& id);
    bool remove(const std::string& id);
    bool setProgress(const std::string& id, double progress);

    std::string addFeed(const std::string& url, const std::string& title, bool* created = nullptr);
    // Removes the feed and its items; returns the IDs of the removed items.
    std::vector<std::string> removeFeed(const std::string& id);
    // Adds entries not seen before as unread items and returns how many. A new feed brings
    // only its newest few, so adding one doesn't fill the inbox with its whole archive.
    // Pruned item IDs are appended to removed.
    size_t mergeFeed(const std::string& feedID, const std::vector<FeedEntry>& entries,
                     const std::function<std::string(const std::string&)>& sessionForURL,
                     double now, std::vector<std::string>* removed = nullptr);

    // Inbox items newest first, or read items most recently read first; feedID narrows to one feed.
    std::vector<const ReadingItem*> shown(bool read, const std::string& feedID = "") const;
    size_t unreadCount(const std::string& feedID = "") const;
    // Whole minutes left to read; 0 when the length is unknown.
    static int minutesLeft(const ReadingItem& item);
    // "https://www.example.com/a" -> "example.com".
    static std::string siteOf(const std::string& url);
    void sanitize();

    static constexpr size_t firstFetchLimit = 5;
    static constexpr size_t itemsPerFeed = 200;
    static constexpr size_t seenPerFeed = 1000;

private:
    std::string newID(const char* prefix, double now);
    size_t nextID_ = 0;
};

const char* readerStatusName(ReaderStatus status);
ReaderStatus readerStatusFromName(const std::string& name);

} // namespace rail
