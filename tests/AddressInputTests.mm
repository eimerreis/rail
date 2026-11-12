#import "AddressInput.h"
#include "SearchEngine.h"
#include <iostream>
#include <stdexcept>

namespace {
void Check(bool condition, const char *message) {
  if (!condition) throw std::runtime_error(message);
}
void CheckURL(NSString *input, NSString *expected, const std::string &engineID) {
  BOOL search = YES;
  NSString *url = rail::NormalizedAddress(input,engineID,&search);
  Check([url isEqualToString:expected], "URL normalization changed with the selected engine");
  Check(!search, "a URL must not be classified as a search");
}
}

int main() {
  @autoreleasepool {
    for (const auto &engine : rail::SearchEngines) {
      BOOL search = NO;
      NSString *url = rail::NormalizedAddress(@" \n hello world \t",engine.id,&search);
      NSString *expected = [@(engine.url) stringByAppendingString:@"?q=hello%20world"];
      Check(search && [url isEqualToString:expected], "a query should use the chosen engine and preserve space encoding");
      // Keep Foundation's query encoding, including literal percent signs, plus signs and Unicode.
      // These must stay a single q item, never a second parameter or a URL fragment.
      for (NSString *query in @[@"café 日本語", @"a&b=c#d%20 + /?", @"what is example.com?", @"duckduckgo versus google and bing"]) {
        url = rail::NormalizedAddress(query,engine.id,&search);
        NSURLComponents *parts = [NSURLComponents componentsWithString:url];
        Check(search && parts.queryItems.count == 1, "search text must stay one query item");
        Check([parts.queryItems[0].name isEqualToString:@"q"] && [parts.queryItems[0].value isEqualToString:query], "search text should round-trip without double encoding or parameter injection");
        Check(parts.fragment == nil, "a query must not add a fragment");
      }
      CheckURL(@" https://example.com/a%20b?q=a%26b#notes\n",@"https://example.com/a%20b?q=a%26b#notes",engine.id);
      CheckURL(@"example.com/path?q=kept#notes",@"https://example.com/path?q=kept#notes",engine.id);
      CheckURL(@"localhost:3000/path",@"http://localhost:3000/path",engine.id);
      CheckURL(@"127.0.0.1:8080/",@"http://127.0.0.1:8080/",engine.id);
      CheckURL(@"[::1]:8080/",@"http://[::1]:8080/",engine.id);
      CheckURL(@"about:blank",@"about:blank",engine.id);
      CheckURL(@"/tmp/Rail note%?#.txt",@"file:///tmp/Rail%20note%25%3F%23.txt",engine.id);
      CheckURL(@"file:///tmp/Rail note%20.txt",@"file:///tmp/Rail%20note%20.txt",engine.id);
      CheckURL(@"file://localhost/tmp/Rail note.txt",@"file://localhost/tmp/Rail%20note.txt",engine.id);
      NSString *home = [NSHomeDirectory() stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
      CheckURL(@"~/Rail note.txt",[NSString stringWithFormat:@"file://%@/Rail%%20note.txt",home],engine.id);
      // Never infer "search" from a URL's host or prefix. Explicit engine URLs remain URLs
      // in address suggestions and project/environment forms, regardless of the preference.
      for (const auto &explicitEngine : rail::SearchEngines) {
        NSString *explicitURL = [@(explicitEngine.url) stringByAppendingString:@"?q=saved%20search"];
        CheckURL(explicitURL,explicitURL,engine.id);
      }
      for (NSString *invalid in @[@"", @" \n\t", @"javascript:alert(1)", @"data:text/plain,hello", @"ftp://example.com/file", @"https://", @"file://remote.example/tmp/test", @"file:relative.txt"]) {
        search = YES;
        Check(rail::NormalizedAddress(invalid,engine.id,&search) == nil && !search, "invalid and remote file URLs should still be rejected, not searched");
      }
    }
    BOOL search = NO;
    Check([rail::NormalizedAddress(@"hello world","unrecognized",&search) isEqualToString:@"https://duckduckgo.com/?q=hello%20world"] && search,
          "invalid choices should use the existing search endpoint");
    std::cout << "PASS address input, engines, query encoding, explicit URLs, local paths and rejected schemes\n";
  }
}
