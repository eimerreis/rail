#include "BrowserModel.h"
#include "SearchEngine.h"

#include <iostream>
#include <set>
#include <stdexcept>

namespace {
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
}

int main() {
    rail::BrowserModel model;
    require(model.state.searchEngine == "duckduckgo", "new profiles should keep the existing engine");
    const auto tabID = model.state.activeTabID;
    const auto spaceID = model.state.activeSpaceID;
    model.tab(tabID)->url = "http://localhost:3000/notes?q=kept";
    model.setIsolated(tabID);
    model.setPinned(tabID, true);
    model.renameTab(tabID, "My notes");
    const auto tabCount = model.state.tabs.size();
    std::set<std::string> ids;
    for (const auto& engine : rail::SearchEngines) {
        require(ids.insert(engine.id).second, "engine IDs should be unique");
        require(*engine.name, "every engine needs a Settings and suggestion label");
        const std::string url = engine.url;
        require(url.compare(0, 8, "https://") == 0, "search endpoints should use HTTPS");
        require(url.find_first_of("?#") == std::string::npos, "endpoints should leave the query to NSURLComponents");
        require(&rail::searchEngineForID(engine.id) == &engine, "known IDs should select their engine");
        model.state.searchEngine = engine.id;
        model.sanitize(100);
        require(model.state.searchEngine == engine.id, "sanitize should preserve a supported choice");
    }
    require(ids.count("google") && ids.count("bing") && ids.count("duckduckgo"), "all three engines should be available");
    require(std::string(rail::searchEngineForID("google").url) == "https://www.google.com/search", "Google endpoint should be correct");
    require(std::string(rail::searchEngineForID("bing").url) == "https://www.bing.com/search", "Bing endpoint should be correct");
    require(std::string(rail::searchEngineForID("duckduckgo").url) == "https://duckduckgo.com/", "the existing endpoint should not change");
    for (const char* invalid : {"", "unknown", "Google", " google ", "https://attacker.example/search"}) {
        require(std::string(rail::searchEngineForID(invalid).id) == "duckduckgo", "invalid IDs should use the existing default");
        model.state.searchEngine = invalid;
        model.sanitize(100);
        require(model.state.searchEngine == "duckduckgo", "sanitize should repair missing and invalid choices");
    }
    require(model.state.activeTabID == tabID && model.state.activeSpaceID == spaceID && model.state.tabs.size() == tabCount,
            "choice validation should preserve the layout");
    const auto* tab = model.tab(tabID);
    require(tab && tab->url == "http://localhost:3000/notes?q=kept" && tab->pinnedURL == tab->url && tab->customTitle == "My notes"
                && tab->sessionID == rail::BrowserModel::isolatedSessionID(tabID),
            "choice validation should preserve URLs, pins, names and sessions");
    std::cout << "PASS search engine defaults, choices, endpoints, validation and layout preservation\n";
}
