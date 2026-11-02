#import "FeedParser.h"

namespace {
std::string C(NSString *s) { return std::string(s.UTF8String ?: ""); }
NSString *Trimmed(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @""; }
NSString *Resolved(NSString *link, NSString *base) {
  NSString *text = Trimmed(link); if (!text.length) return @"";
  return [NSURL URLWithString:text relativeToURL:base.length ? [NSURL URLWithString:base] : nil].absoluteString ?: @"";
}
// Feed titles are often escaped HTML.
NSString *PlainTitle(NSString *title) {
  NSString *text = [title stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0,title.length)];
  for (NSArray *pair in @[@[@"&lt;",@"<"],@[@"&gt;",@">"],@[@"&quot;",@"\""],@[@"&#39;",@"'"],@[@"&apos;",@"'"],@[@"&amp;",@"&"]]) text = [text stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
  return Trimmed([text stringByReplacingOccurrencesOfString:@"\\s+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0,text.length)]);
}
double ParsedDate(NSString *value) {
  NSString *text = Trimmed(value); if (!text.length) return 0;
  NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
  NSDate *date = [iso dateFromString:text];
  if (!date) { iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds; date = [iso dateFromString:text]; }
  if (date) return date.timeIntervalSince1970;
  NSDateFormatter *rfc = [[NSDateFormatter alloc] init]; rfc.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  for (NSString *format in @[@"EEE, dd MMM yyyy HH:mm:ss Z",@"EEE, dd MMM yyyy HH:mm:ss zzz",@"dd MMM yyyy HH:mm:ss Z",@"dd MMM yyyy HH:mm:ss zzz",@"EEE, dd MMM yyyy HH:mm Z",@"EEE, dd MMM yyyy HH:mm zzz",@"yyyy-MM-dd"]) {
    rfc.dateFormat = format; if ((date = [rfc dateFromString:text])) return date.timeIntervalSince1970;
  }
  return 0;
}
}

@interface RailFeedReader : NSObject <NSXMLParserDelegate>
@property(nonatomic, copy) NSString *base;
@property(nonatomic) BOOL validRoot;
@property(nonatomic, copy) NSString *feedTitle;
@end
@implementation RailFeedReader {
  @public std::vector<rail::FeedEntry> _entries;
  NSMutableString *_text;
  BOOL _inEntry;
  NSInteger _imageDepth, _depth;
  NSString *_title, *_link, *_atomLink, *_guid, *_date, *_updated;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *,NSString *> *)attributes {
  (void)parser; (void)uri; (void)qualified;
  if (++_depth == 1) self.validRoot = [@[@"rss",@"feed",@"rdf:RDF"] containsObject:name];
  _text = [NSMutableString string];
  if ([name isEqual:@"image"] || [name isEqual:@"author"] || [name isEqual:@"source"]) _imageDepth++;
  if ([name isEqual:@"item"] || [name isEqual:@"entry"]) { _inEntry = YES; _title = _link = _atomLink = _guid = _date = _updated = nil; }
  if ([name isEqual:@"link"] && attributes[@"href"] && _inEntry) {
    NSString *rel = attributes[@"rel"] ?: @"alternate";
    if ([rel isEqual:@"alternate"] && !_atomLink) _atomLink = attributes[@"href"];
  }
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string { (void)parser; [_text appendString:string]; }
- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)data {
  (void)parser; NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]; if (string) [_text appendString:string];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified {
  (void)parser; (void)uri; (void)qualified; _depth--;
  if ([name isEqual:@"image"] || [name isEqual:@"author"] || [name isEqual:@"source"]) { _imageDepth--; _text = [NSMutableString string]; return; }
  NSString *text = _text ?: @""; _text = [NSMutableString string];
  if (_imageDepth > 0) return;
  if (!_inEntry) { if ([name isEqual:@"title"] && !self.feedTitle) self.feedTitle = PlainTitle(text); return; }
  if ([name isEqual:@"title"]) _title = PlainTitle(text);
  else if ([name isEqual:@"link"] && Trimmed(text).length) _link = text;
  else if ([name isEqual:@"guid"] || [name isEqual:@"id"]) _guid = Trimmed(text);
  else if ([name isEqual:@"pubDate"] || [name isEqual:@"published"] || [name isEqual:@"dc:date"]) _date = text;
  else if ([name isEqual:@"updated"]) _updated = text;
  else if ([name isEqual:@"item"] || [name isEqual:@"entry"]) {
    _inEntry = NO;
    NSString *link = Resolved(_atomLink ?: _link ?: @"",self.base);
    if (!link.length && [_guid hasPrefix:@"http"]) link = _guid;
    if (link.length) _entries.push_back({C(_guid ?: @""),C(link),C(_title ?: @""),ParsedDate(_date ?: _updated ?: @"")});
  }
}
@end

namespace rail {
ParsedFeed ParseFeed(NSData *data, NSString *base) {
  ParsedFeed feed; if (!data.length) return feed;
  NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
  // Feeds come from the network: never let one pull in other documents.
  parser.shouldResolveExternalEntities = NO;
  RailFeedReader *reader = [[RailFeedReader alloc] init]; reader.base = base; parser.delegate = reader;
  const BOOL parsed = [parser parse];
  // A feed cut off near the end is still worth its finished entries.
  feed.valid = reader.validRoot && (parsed || !reader->_entries.empty());
  feed.title = C(reader.feedTitle ?: @""); feed.entries = reader->_entries;
  return feed;
}
NSString *DiscoverFeedURL(NSData *html, NSString *base) {
  NSString *text = [[NSString alloc] initWithData:html encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:html encoding:NSISOLatin1StringEncoding];
  if (!text.length) return nil;
  NSRegularExpression *tag = [NSRegularExpression regularExpressionWithPattern:@"<link\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
  NSRegularExpression *href = [NSRegularExpression regularExpressionWithPattern:@"href\\s*=\\s*[\"']([^\"']+)[\"']" options:NSRegularExpressionCaseInsensitive error:nil];
  for (NSTextCheckingResult *match in [tag matchesInString:text options:0 range:NSMakeRange(0,text.length)]) {
    NSString *link = [text substringWithRange:match.range], *lower = link.lowercaseString;
    if ([lower rangeOfString:@"alternate"].location == NSNotFound) continue;
    if ([lower rangeOfString:@"application/rss+xml"].location == NSNotFound && [lower rangeOfString:@"application/atom+xml"].location == NSNotFound) continue;
    NSTextCheckingResult *found = [href firstMatchInString:link options:0 range:NSMakeRange(0,link.length)];
    if (!found) continue;
    NSString *resolved = Resolved([[link substringWithRange:[found rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"],base);
    if (resolved.length) return resolved;
  }
  return nil;
}
}
