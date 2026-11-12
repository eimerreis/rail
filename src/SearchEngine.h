#pragma once

#include <array>
#include <string>

namespace rail {

struct SearchEngine {
    const char* id;
    const char* name;
    const char* url;
};

inline constexpr std::array<SearchEngine, 3> SearchEngines = {{
    {"duckduckgo", "DuckDuckGo", "https://duckduckgo.com/"},
    {"google", "Google", "https://www.google.com/search"},
    {"bing", "Bing", "https://www.bing.com/search"},
}};

// Keep the pre-preference engine for old layouts and unrecognized values.
inline const SearchEngine& searchEngineForID(const std::string& id) {
    for (const auto& engine : SearchEngines) if (id == engine.id) return engine;
    return SearchEngines.front();
}

} // namespace rail
