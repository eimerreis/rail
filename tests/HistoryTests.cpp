#include "History.h"

#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

constexpr double day = 86400;

void visitsAreCountedPerURL() {
    rail::History history;
    history.recordVisit("https://github.com/", 10);
    history.recordVisit("https://github.com/", 20);
    history.recordVisit("about:blank", 20);
    history.setTitle("https://github.com/", "GitHub");
    require(history.entries.size() == 1, "only web pages should be recorded once each");
    require(history.entries[0].visits == 2 && history.entries[0].lastVisit == 20, "visits should accumulate");
    require(history.entries[0].title == "GitHub", "title should be stored");
}

void displayURLDropsSchemeAndWWW() {
    require(rail::History::displayURL("https://www.github.com/") == "github.com", "root display");
    require(rail::History::displayURL("https://github.com/a/b/") == "github.com/a/b/", "path display keeps slash");
    require(rail::History::displayURL("http://localhost:3000/") == "localhost:3000", "port display");
}

void hostPrefixCompletesInline() {
    rail::History history;
    history.recordVisit("https://github.com/", 0);
    history.recordVisit("https://gitlab.com/", 0);
    history.recordTyped("https://github.com/", 0);
    auto results = history.suggest("git", 0, 5);
    require(results.size() == 2, "both prefix matches should be suggested");
    require(results[0].entry->url == "https://github.com/", "typed site should rank first");
    require(results[0].completion == "hub.com", "first suggestion should complete inline");
    require(results[1].completion.empty(), "only the first suggestion completes inline");
}

void deepPagesCompleteToTheirSiteFirst() {
    rail::History history;
    history.recordVisit("https://www.example.com/docs/start", 0);
    auto results = history.suggest("exa", 0, 5);
    require(results.size() == 1 && results[0].completion == "mple.com", "host should complete first");
    require(results[0].url == "https://www.example.com/", "host completion should open the site root");
    results = history.suggest("example.com/d", 0, 5);
    require(results[0].completion == "ocs/start", "typing past the host should complete the page");
    require(results[0].url == "https://www.example.com/docs/start", "page completion should open the page");
}

void titlesMatchAtWordStarts() {
    rail::History history;
    history.recordVisit("https://news.example.org/a1", 0);
    history.setTitle("https://news.example.org/a1", "Weekly Rust Digest");
    require(history.suggest("rust", 0, 5).size() == 1, "title word should match");
    require(history.suggest("weekly dig", 0, 5).size() == 1, "every word should match");
    require(history.suggest("ust", 0, 5).empty(), "mid-word text should not match");
    require(history.suggest("rust", 0, 5)[0].completion.empty(), "title matches should not complete inline");
}

void recentPagesOutrankStaleOnes() {
    rail::History history;
    for (int i = 0; i < 3; ++i) history.recordVisit("https://docs.old.dev/", 0);
    history.recordVisit("https://docs.new.dev/", 60 * day);
    auto results = history.suggest("docs", 60 * day, 5);
    require(results[0].entry->url == "https://docs.new.dev/", "recent visit should win over stale visits");
}

void pruneKeepsMostRelevant() {
    rail::History history;
    history.recordVisit("https://a.dev/", 0);
    history.recordTyped("https://b.dev/", 0);
    history.prune(1, 0);
    require(history.entries.size() == 1 && history.entries[0].url == "https://b.dev/", "typed entry should survive");
}

} // namespace

int main(int argc, char** argv) {
    const std::vector<std::pair<std::string, std::function<void()>>> tests = {
        {"visits", visitsAreCountedPerURL},
        {"display", displayURLDropsSchemeAndWWW},
        {"inline", hostPrefixCompletesInline},
        {"deep-pages", deepPagesCompleteToTheirSiteFirst},
        {"titles", titlesMatchAtWordStarts},
        {"recency", recentPagesOutrankStaleOnes},
        {"prune", pruneKeepsMostRelevant},
    };
    unsigned failed = 0;
    for (const auto& test : tests) {
        if (argc > 1 && test.first != argv[1]) continue;
        try { test.second(); std::cout << "PASS " << test.first << '\n'; }
        catch (const std::exception& error) { ++failed; std::cerr << "FAIL " << test.first << ": " << error.what() << '\n'; }
    }
    return failed ? 1 : 0;
}
