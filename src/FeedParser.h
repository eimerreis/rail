#import <Foundation/Foundation.h>
#include "Reading.h"

namespace rail {
struct ParsedFeed {
  bool valid = false;
  std::string title;
  std::vector<FeedEntry> entries;
};
// Reads RSS 2.0, RSS 1.0 (RDF) and Atom. Relative links resolve against base.
ParsedFeed ParseFeed(NSData *data, NSString *base);
// The feed an HTML page advertises with <link rel="alternate">, or nil.
NSString *DiscoverFeedURL(NSData *html, NSString *base);
}
