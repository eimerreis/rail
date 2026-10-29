#include "History.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <sstream>

namespace rail {
namespace {

std::string lower(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return text;
}

bool startsWith(const std::string& text, const std::string& prefix) {
    return text.size() >= prefix.size() && text.compare(0, prefix.size(), prefix) == 0;
}

// Tokens match at word starts, so "hub" does not find "github" but "git" and "pull" do.
bool matchesWordStart(const std::string& haystack, const std::string& token) {
    for (size_t at = haystack.find(token); at != std::string::npos; at = haystack.find(token, at + 1)) {
        if (at == 0 || !std::isalnum(static_cast<unsigned char>(haystack[at - 1]))) return true;
    }
    return false;
}

std::string hostOf(const std::string& display) {
    const auto end = display.find_first_of("/?#");
    return end == std::string::npos ? display : display.substr(0, end);
}

} // namespace

std::string History::displayURL(const std::string& url) {
    std::string text = url;
    const auto scheme = text.find("://");
    if (scheme != std::string::npos) text = text.substr(scheme + 3);
    if (startsWith(lower(text), "www.")) text = text.substr(4);
    if (!text.empty() && text.back() == '/' && text.find('/') == text.size() - 1) text.pop_back();
    return text;
}

bool History::recordable(const std::string& url) {
    const auto value = lower(url);
    return startsWith(value, "http://") || startsWith(value, "https://");
}

HistoryEntry* History::find(const std::string& url) {
    for (auto& entry : entries) if (entry.url == url) return &entry;
    return nullptr;
}

void History::recordVisit(const std::string& url, double now) {
    if (!recordable(url)) return;
    auto* entry = find(url);
    if (!entry) { entries.push_back({url, "", 0, 0, now}); entry = &entries.back(); }
    entry->visits++;
    entry->lastVisit = now;
}

void History::recordTyped(const std::string& url, double now) {
    if (!recordable(url)) return;
    auto* entry = find(url);
    if (!entry) { entries.push_back({url, "", 0, 0, now}); entry = &entries.back(); }
    entry->typed++;
    entry->lastVisit = now;
}

void History::setTitle(const std::string& url, const std::string& title) {
    if (auto* entry = find(url); entry && !title.empty()) entry->title = title;
}

double History::frecency(const HistoryEntry& entry, double now) const {
    const double days = std::max(0.0, now - entry.lastVisit) / 86400;
    return (entry.visits + entry.typed * 4.0 + 1) / (1 + days / 7);
}

std::vector<Suggestion> History::suggest(const std::string& query, double now, size_t limit) const {
    std::vector<Suggestion> result;
    const std::string needle = lower(query);
    std::vector<std::string> tokens;
    std::istringstream words(needle);
    for (std::string word; words >> word;) tokens.push_back(word);
    if (tokens.empty() || limit == 0) return result;

    struct Scored { const HistoryEntry* entry; double score; bool prefix; };
    std::vector<Scored> scored;
    for (const auto& entry : entries) {
        const auto display = lower(displayURL(entry.url));
        const auto title = lower(entry.title);
        const bool prefix = startsWith(display, needle);
        bool all = true;
        for (const auto& token : tokens) {
            if (!matchesWordStart(display, token) && !matchesWordStart(title, token)) { all = false; break; }
        }
        if (!prefix && !all) continue;
        // Prefer pages users typed, return to often, and short addresses such as a site root.
        double score = frecency(entry, now) / (1 + display.size() / 40.0);
        if (prefix) score *= 4;
        scored.push_back({&entry, score, prefix});
    }
    std::stable_sort(scored.begin(), scored.end(), [](const Scored& a, const Scored& b) { return a.score > b.score; });

    // Like Chrome, inline-complete only an address the user is typing from its start.
    const bool addressLike = needle.find(' ') == std::string::npos;
    for (const auto& item : scored) {
        if (result.size() >= limit) break;
        Suggestion suggestion{item.entry, "", item.entry->url};
        if (result.empty() && addressLike && item.prefix) {
            const auto display = displayURL(item.entry->url);
            const auto host = hostOf(display);
            // Complete the site first; once the user types past it, complete the full page.
            const auto target = needle.size() < host.size() ? host : display;
            suggestion.completion = target.substr(needle.size());
            if (target != display) {
                const auto scheme = item.entry->url.find("://");
                const auto path = item.entry->url.find('/', scheme + 3);
                suggestion.url = item.entry->url.substr(0, path) + "/";
            }
        }
        result.push_back(suggestion);
    }
    return result;
}

void History::prune(size_t maxEntries, double now) {
    if (entries.size() <= maxEntries) return;
    std::stable_sort(entries.begin(), entries.end(), [&](const HistoryEntry& a, const HistoryEntry& b) { return frecency(a, now) > frecency(b, now); });
    entries.resize(maxEntries);
}

} // namespace rail
