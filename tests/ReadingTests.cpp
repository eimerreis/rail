#include "Reading.h"

#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

std::string work(const std::string&) { return "work"; }

void savedLinksStartUnread() {
    rail::ReadingList list;
    bool created = false;
    const auto id = list.add("https://www.example.com/a?b=1", "work", 100, &created);
    require(created && !id.empty(), "a new link should be saved");
    require(list.item(id)->site == "example.com", "site should drop www and path");
    require(list.unreadCount() == 1 && list.shown(true).empty(), "a saved link is unread");
    require(list.add("javascript:alert(1)", "work", 100).empty(), "only web pages can be saved");
    require(list.add("file:///etc/passwd", "work", 100).empty(), "local files cannot be saved");
}

void savingAgainReturnsTheItemToTheInbox() {
    rail::ReadingList list;
    const auto id = list.add("https://example.com/a", "work", 100);
    list.add("https://example.com/b", "work", 200);
    list.markRead(id, 300);
    bool created = true;
    require(list.add("https://example.com/a", "personal", 400, &created) == id, "the same address keeps its item");
    require(!created && list.state.items.size() == 2, "no duplicate should be created");
    require(list.item(id)->readAt == 0, "saving again makes it unread");
    require(list.item(id)->sessionID == "work", "saving again keeps the session");
    require(list.shown(false).front()->id == id, "saving again moves it to the top");
}

void onlyMarkingChangesReadState() {
    rail::ReadingList list;
    const auto id = list.add("https://example.com/a", "work", 100);
    list.setProgress(id, 1);
    require(list.item(id)->readAt == 0, "reading to the end does not mark an item read");
    require(list.markRead(id, 200) && !list.markRead(id, 300), "marking read twice changes nothing");
    require(list.item(id)->readAt == 200 && list.unreadCount() == 0, "marked read");
    require(list.markUnread(id) && list.unreadCount() == 1, "marked unread");
}

void listsAreOrdered() {
    rail::ReadingList list;
    const auto a = list.add("https://example.com/a", "work", 100);
    const auto b = list.add("https://example.com/b", "work", 200);
    const auto c = list.add("https://example.com/c", "work", 300);
    require(list.shown(false)[0]->id == c && list.shown(false)[2]->id == a, "inbox is newest first");
    list.markRead(c, 400); list.markRead(a, 500);
    require(list.shown(true)[0]->id == a && list.shown(true)[1]->id == c, "read is most recently read first");
    require(list.shown(false).size() == 1 && list.shown(false)[0]->id == b, "read items leave the inbox");
}

void minutesLeftFollowProgress() {
    rail::ReadingItem item;
    require(rail::ReadingList::minutesLeft(item) == 0, "unknown length has no time left");
    item.minutes = 10; item.progress = .62;
    require(rail::ReadingList::minutesLeft(item) == 4, "rounds up");
    item.progress = 1;
    require(rail::ReadingList::minutesLeft(item) == 1, "never says zero for a known length");
}

void aNewFeedBringsOnlyItsNewestEntries() {
    rail::ReadingList list;
    const auto feed = list.addFeed("https://example.com/feed", "Example");
    std::vector<rail::FeedEntry> entries;
    for (int i = 1; i <= 8; ++i) entries.push_back({"g" + std::to_string(i), "https://example.com/" + std::to_string(i), "Post", static_cast<double>(i)});
    require(list.mergeFeed(feed, entries, work, 1000) == rail::ReadingList::firstFetchLimit, "first fetch is limited");
    require(list.shown(false).front()->url == "https://example.com/8", "newest entry comes first");
    require(list.mergeFeed(feed, entries, work, 2000) == 0, "skipped entries do not return on the next fetch");
    entries.push_back({"g9", "https://example.com/9", "Post", 9});
    require(list.mergeFeed(feed, entries, work, 3000) == 1, "later entries are all added");
    require(list.item(list.shown(false).front()->id)->sessionID == "work", "session comes from the caller");
}

void feedsDoNotRepeatSavedLinksOrReadItems() {
    rail::ReadingList list;
    const auto feed = list.addFeed("https://example.com/feed", "Example");
    const auto saved = list.add("https://example.com/1", "work", 50);
    list.markRead(saved, 60);
    require(list.mergeFeed(feed, {{"g1", "https://example.com/1", "One", 10}}, work, 100) == 0, "a saved link is not repeated");
    require(list.item(saved)->readAt == 60 && list.item(saved)->feedID.empty(), "the saved item stays untouched");
    list.mergeFeed(feed, {{"g2", "https://example.com/2", "Two", 20}}, work, 200);
    const auto id = list.shown(false).front()->id;
    list.markRead(id, 300);
    require(list.mergeFeed(feed, {{"g2", "https://example.com/2", "Two", 20}}, work, 400) == 0, "a read entry stays read");
    require(list.unreadCount() == 0, "nothing is new");
}

void feedDatesCannotJumpAhead() {
    rail::ReadingList list;
    const auto feed = list.addFeed("https://example.com/feed", "Example");
    list.mergeFeed(feed, {{"g", "https://example.com/1", "One", 99999}}, work, 100);
    require(list.state.items[0].added == 100, "a date in the future counts as now");
}

void feedsArePruned() {
    rail::ReadingList list;
    const auto feed = list.addFeed("https://example.com/feed", "Example");
    list.mergeFeed(feed, {}, work, 1);
    std::vector<rail::FeedEntry> entries;
    for (size_t i = 0; i < rail::ReadingList::itemsPerFeed; ++i) entries.push_back({"g" + std::to_string(i), "https://example.com/" + std::to_string(i), "Post", static_cast<double>(i + 1)});
    list.mergeFeed(feed, entries, work, 10000);
    const auto oldest = list.shown(false).back()->id;
    const auto read = list.shown(false).front()->id;
    list.markRead(read, 10001);
    std::vector<std::string> removed;
    list.mergeFeed(feed, {{"new", "https://example.com/new", "New", 9000}}, work, 10002, &removed);
    require(removed.size() == 1 && removed[0] == read, "read items are pruned first");
    require(list.item(oldest) != nullptr, "unread items stay while read ones can go");
    require(list.state.items.size() == rail::ReadingList::itemsPerFeed, "the limit holds");
}

void removingAFeedRemovesItsItems() {
    rail::ReadingList list;
    const auto feed = list.addFeed("https://example.com/feed", "Example");
    const auto saved = list.add("https://example.com/saved", "work", 50);
    list.mergeFeed(feed, {{"g", "https://example.com/1", "One", 10}}, work, 100);
    const auto removed = list.removeFeed(feed);
    require(removed.size() == 1 && list.state.items.size() == 1 && list.item(saved), "saved links stay");
    require(list.state.feeds.empty(), "the feed is gone");
}

void feedFilterAndCounts() {
    rail::ReadingList list;
    const auto a = list.addFeed("https://a.example/feed", "A");
    const auto b = list.addFeed("https://b.example/feed", "B");
    bool created = true;
    require(list.addFeed("https://a.example/feed", "Again", &created) == a && !created, "feeds are unique by address");
    list.mergeFeed(a, {{"1", "https://a.example/1", "", 1}, {"2", "https://a.example/2", "", 2}}, work, 100);
    list.mergeFeed(b, {{"3", "https://b.example/3", "", 3}}, work, 100);
    list.add("https://saved.example/", "work", 100);
    require(list.unreadCount() == 4 && list.unreadCount(a) == 2 && list.unreadCount(b) == 1, "counts per feed");
    require(list.shown(false, b).size() == 1 && list.shown(false, b)[0]->site == "B", "filter by feed");
}

void sanitizeRepairsLoadedData() {
    rail::ReadingList list;
    rail::ReadingItem bad; bad.id = "bad"; bad.url = "javascript:alert(1)";
    rail::ReadingItem orphan; orphan.id = "orphan"; orphan.url = "https://example.com/a"; orphan.feedID = "gone"; orphan.progress = 7;
    list.state.items = {bad, orphan};
    list.sanitize();
    require(list.state.items.size() == 1 && list.state.items[0].id == "orphan", "non-web items are dropped");
    require(list.state.items[0].feedID.empty() && list.state.items[0].progress == 1 && list.state.items[0].site == "example.com", "items are repaired");
}

} // namespace

int main() {
    try {
        savedLinksStartUnread();
        savingAgainReturnsTheItemToTheInbox();
        onlyMarkingChangesReadState();
        listsAreOrdered();
        minutesLeftFollowProgress();
        aNewFeedBringsOnlyItsNewestEntries();
        feedsDoNotRepeatSavedLinksOrReadItems();
        feedDatesCannotJumpAhead();
        feedsArePruned();
        removingAFeedRemovesItsItems();
        feedFilterAndCounts();
        sanitizeRepairsLoadedData();
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
    std::cout << "Reading tests passed\n";
    return 0;
}
