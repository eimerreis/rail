#import "AddressInput.h"
#include "SearchEngine.h"

namespace {
// File addresses are often pasted with raw spaces; escape those and keep any existing escapes.
NSString *FileAddress(NSString *text) {
  NSMutableCharacterSet *allowed = [NSCharacterSet.URLPathAllowedCharacterSet mutableCopy];
  [allowed addCharactersInString:@"%?#"];
  NSString *escaped = [text stringByAddingPercentEncodingWithAllowedCharacters:allowed];
  NSURLComponents *parts = escaped ? [NSURLComponents componentsWithString:escaped] : nil;
  NSString *address = [parts.path hasPrefix:@"/"] ? parts.URL.absoluteString : nil;
  // Match RailIsFileURL: a host other than localhost would point at a network share.
  BOOL local = [parts.scheme.lowercaseString isEqualToString:@"file"] && (!parts.host.length || [parts.host.lowercaseString isEqualToString:@"localhost"]);
  return address && local ? address : nil;
}
// "/a/b" and "~/a/b" name files literally, so "%", "?" and "#" are part of the name. No file
// system access: this runs on every keystroke, and touching a protected folder prompts.
NSString *PathAddress(NSString *text) {
  BOOL home = [text isEqualToString:@"~"] || [text hasPrefix:@"~/"];
  if (!home && ![text hasPrefix:@"/"]) return nil;
  NSString *path = home ? [NSHomeDirectory() stringByAppendingString:[text substringFromIndex:1]] : text;
  NSString *escaped = [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
  return escaped ? [@"file://" stringByAppendingString:escaped] : nil;
}
}

namespace rail {
NSString *NormalizedAddress(NSString *input, const std::string &engineID, BOOL *isSearch) {
  if (isSearch) *isSearch = NO;
  NSString *text = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!text.length) return nil;
  if ([text isEqualToString:@"about:blank"]) return text;
  if ([text.lowercaseString hasPrefix:@"file:"]) return FileAddress(text);
  if (NSString *path = PathAddress(text)) return path;
  if ([text rangeOfString:@"://"].location != NSNotFound) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:text];
    return ([@[@"http",@"https"] containsObject:parts.scheme.lowercaseString] && parts.host.length) ? parts.URL.absoluteString : nil;
  }
  if ([text hasPrefix:@"javascript:"] || [text hasPrefix:@"data:"]) return nil;
  BOOL noSpaces = [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound;
  if (noSpaces && ([text containsString:@"."] || [text hasPrefix:@"localhost"] || [text hasPrefix:@"[::1]"])) {
    BOOL local = [text hasPrefix:@"localhost"] || [text hasPrefix:@"127."] || [text hasPrefix:@"[::1]"];
    NSURLComponents *parts = [NSURLComponents componentsWithString:[(local ? @"http://" : @"https://") stringByAppendingString:text]];
    return parts.host.length ? parts.URL.absoluteString : nil;
  }
  NSURLComponents *search = [NSURLComponents componentsWithString:@(searchEngineForID(engineID).url)];
  search.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:text]];
  if (isSearch) *isSearch = YES;
  return search.URL.absoluteString;
}
} // namespace rail
