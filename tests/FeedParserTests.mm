#import "FeedParser.h"
#import "StateStore.h"
#include <iostream>
#include <stdexcept>

static void Check(bool value, const char *message) {
  if (!value) throw std::runtime_error(message);
}
static NSData *D(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
int main() {
  @autoreleasepool {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    try {
      auto rss = rail::ParseFeed(D(@"<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Rivet &amp; Notes</title><image><title>Logo</title><url>https://x/y.png</url></image><link>https://rivet.example/</link>"
        "<item><title><![CDATA[Retry <em>budgets</em>]]></title><link>/retry</link><guid>g-1</guid><pubDate>Fri, 30 Oct 2026 09:00:00 +0100</pubDate></item>"
        "<item><title>No link</title></item>"
        "<item><title>Guid link</title><guid>https://rivet.example/guid</guid><pubDate>Thu, 29 Oct 2026 08:00:00 GMT</pubDate></item></channel></rss>"),@"https://rivet.example/feed.xml");
      Check(rss.valid && rss.title == "Rivet & Notes", "RSS title; a channel image title must not win");
      Check(rss.entries.size() == 2, "entries without any link are skipped");
      Check(rss.entries[0].url == "https://rivet.example/retry", "relative links resolve");
      Check(rss.entries[0].title == "Retry budgets" && rss.entries[0].guid == "g-1", "CDATA titles lose their markup");
      Check(rss.entries[0].published == 1793347200, "RFC 822 date");
      Check(rss.entries[1].url == "https://rivet.example/guid" && rss.entries[1].published > 0, "a guid can be the link");

      auto atom = rail::ParseFeed(D(@"<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Atom</title><link href=\"https://a.example/\"/><author><name>Someone</name></author>"
        "<entry><title type=\"html\">One &amp;amp; two</title><id>tag:1</id><link rel=\"self\" href=\"https://a.example/self\"/><link rel=\"alternate\" href=\"https://a.example/one\"/><updated>2026-10-30T10:00:00Z</updated></entry>"
        "<entry><title>Fraction</title><id>tag:2</id><link href=\"two\"/><published>2026-10-30T10:00:00.500Z</published></entry></feed>"),@"https://a.example/feed");
      Check(atom.valid && atom.title == "Atom" && atom.entries.size() == 2, "Atom feed");
      Check(atom.entries[0].url == "https://a.example/one", "alternate link wins over self");
      Check(atom.entries[0].title == "One & two", "escaped titles are decoded");
      Check(atom.entries[0].published == 1793354400, "ISO date");
      Check(atom.entries[1].url == "https://a.example/two" && atom.entries[1].published > 0, "fractional seconds");

      auto rdf = rail::ParseFeed(D(@"<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\" xmlns=\"http://purl.org/rss/1.0/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><channel><title>RDF</title></channel><item><title>A</title><link>https://r.example/a</link><dc:date>2026-10-30T10:00:00Z</dc:date></item></rdf:RDF>"),@"");
      Check(rdf.valid && rdf.title == "RDF" && rdf.entries.size() == 1 && rdf.entries[0].published > 0, "RDF feed");

      Check(!rail::ParseFeed(D(@"<html><body>Not a feed</body></html>"),@"").valid, "HTML is not a feed");
      Check(!rail::ParseFeed(D(@"plain text"),@"").valid, "text is not a feed");
      Check(rail::ParseFeed(D(@"<rss><channel><item><link>https://x.example/1</link></item><item><link>https://x"),@"").valid, "a truncated feed keeps finished entries");

      NSString *found = rail::DiscoverFeedURL(D(@"<head><link rel=\"stylesheet\" href=\"a.css\"><link type='application/atom+xml' rel='alternate' href='/atom.xml?a=1&amp;b=2'></head>"),@"https://s.example/blog/");
      Check([found isEqual:@"https://s.example/atom.xml?a=1&b=2"], "feed discovery");
      Check(rail::DiscoverFeedURL(D(@"<link rel=\"stylesheet\" href=\"a.css\">"),@"https://s.example/") == nil, "no feed advertised");

      rail::ReadingList list;
      auto feed = list.addFeed("https://rivet.example/feed.xml","Rivet — 日本語");
      list.mergeFeed(feed,{{"g","https://rivet.example/1","Post",10}},[](const std::string &) { return std::string("personal"); },100);
      auto saved = list.add("https://example.com/a","work",200);
      list.item(saved)->minutes = 12; list.item(saved)->progress = .5; list.item(saved)->reader = rail::ReaderStatus::NeedsLogin; list.markRead(saved,300);
      list.feed(feed)->error = "Unreachable"; list.feed(feed)->lastSuccess = 50;
      NSError *error = nil;
      Check(rail::SaveReading(directory,list,&error), "save failed");
      rail::ReadingList restored;
      Check(rail::LoadReading(directory,restored,&error), "load failed");
      Check(restored.state.items.size() == 2 && restored.state.feeds.size() == 1, "counts survive");
      const auto *item = restored.item(saved);
      Check(item && item->minutes == 12 && item->progress == .5 && item->readAt == 300 && item->reader == rail::ReaderStatus::NeedsLogin && item->sessionID == "work", "item fields survive");
      Check(restored.feed(feed)->title == "Rivet — 日本語" && restored.feed(feed)->seen.size() == 1 && restored.feed(feed)->fetched && restored.feed(feed)->error == "Unreachable", "feed fields survive");
      Check(restored.mergeFeed(feed,{{"g","https://rivet.example/1","Post",10}},nullptr,400) == 0, "seen entries survive a restart");

      NSString *path = [directory stringByAppendingPathComponent:@"reading.json"];
      [@"{broken" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      rail::ReadingList broken; broken.add("https://keep.example/","work",1);
      Check(!rail::LoadReading(directory,broken,&error), "a damaged file is reported");
      Check(broken.state.items.size() == 1, "a damaged file does not clear the list");
    } catch (const std::exception &failure) {
      [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
      std::cerr << failure.what() << '\n'; return 1;
    }
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    std::cout << "Feed parser tests passed\n";
  }
  return 0;
}
