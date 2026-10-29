#pragma once

#include <string>
#include <vector>

namespace rail {

struct HistoryEntry {
    std::string url;
    std::string title;
    int visits = 0;
    int typed = 0;
    double lastVisit = 0;
};

struct Suggestion {
    const HistoryEntry* entry = nullptr;
    // Text to show inline after what the user typed, e.g. "hub.com" for "git".
    std::string completion;
    // Where the suggestion leads; the site root when only the host was completed.
    std::string url;
};

class History {
public:
    std::vector<HistoryEntry> entries;

    void recordVisit(const std::string& url, double now);
    void recordTyped(const std::string& url, double now);
    void setTitle(const std::string& url, const std::string& title);
    // Best match first. Only the first suggestion can carry an inline completion.
    std::vector<Suggestion> suggest(const std::string& query, double now, size_t limit) const;
    void prune(size_t maxEntries, double now);
    // "https://www.github.com/" -> "github.com", the form users type and recognize.
    static std::string displayURL(const std::string& url);
    static bool recordable(const std::string& url);

private:
    HistoryEntry* find(const std::string& url);
    double frecency(const HistoryEntry& entry, double now) const;
};

} // namespace rail
