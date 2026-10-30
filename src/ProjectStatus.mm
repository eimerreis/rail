#import "ProjectStatus.h"
#import "Keychain.h"
#import <Network/Network.h>
#include "include/cef_urlrequest.h"
#include <set>

namespace {
NSString *S(const std::string &s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
std::string C(NSString *s) { return std::string(s.UTF8String ?: ""); }
double Now() { return NSDate.date.timeIntervalSince1970; }
id JSON(NSData *data) { return data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; }
NSDictionary *Dict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
NSArray *List(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
NSString *Str(id value) { return [value isKindOfClass:NSString.class] ? value : [value isKindOfClass:NSNumber.class] ? [value stringValue] : @""; }
double ISODate(NSString *text) {
  if (!text.length) return 0;
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
  NSDate *date = [formatter dateFromString:text];
  if (!date) { formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime; date = [formatter dateFromString:text]; }
  return date.timeIntervalSince1970;
}
NSString *Query(NSString *base, NSDictionary<NSString *, NSString *> *items) {
  NSURLComponents *parts = [NSURLComponents componentsWithString:base];
  NSMutableArray *query = [NSMutableArray arrayWithArray:parts.queryItems ?: @[]];
  for (NSString *key in items) [query addObject:[NSURLQueryItem queryItemWithName:key value:items[key]]];
  parts.queryItems = query;
  // NSURLComponents leaves "/" and "$" alone; Azure DevOps expects branch names encoded.
  parts.percentEncodedQuery = [parts.percentEncodedQuery stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
  return parts.URL.absoluteString;
}

// GET in a session's request context, carrying that session's login. Redirects are not followed,
// so a sign-in redirect stays visible. Only Azure DevOps API paths are allowed.
class SessionRequestClient final : public CefURLRequestClient {
 public:
  using Done = void (^)(int status, NSString *location, NSString *mime, NSData *body);
  explicit SessionRequestClient(Done done) : done_(done) {}
  void OnRequestComplete(CefRefPtr<CefURLRequest> request) override {
    if (!done_) return;
    CefRefPtr<CefResponse> response = request->GetResponse();
    int status = response ? response->GetStatus() : 0;
    NSString *location = response ? S(response->GetHeaderByName("Location").ToString()) : @"";
    NSString *mime = response ? S(response->GetMimeType().ToString()) : @"";
    Done done = done_; done_ = nil; request_ = nullptr;
    done(status, location, mime, [NSData dataWithBytes:body_.data() length:body_.size()]);
  }
  void OnUploadProgress(CefRefPtr<CefURLRequest>, int64_t, int64_t) override {}
  void OnDownloadProgress(CefRefPtr<CefURLRequest>, int64_t, int64_t) override {}
  void OnDownloadData(CefRefPtr<CefURLRequest>, const void *data, size_t length) override {
    if (body_.size() < 4 * 1024 * 1024) body_.append(static_cast<const char *>(data), length);
  }
  bool GetAuthCredentials(bool, const CefString &, int, const CefString &, const CefString &, CefRefPtr<CefAuthCallback>) override { return false; }
  CefRefPtr<CefURLRequest> request_;
 private:
  Done done_;
  std::string body_;
  IMPLEMENT_REFCOUNTING(SessionRequestClient);
};

bool AzureAPI(NSString *url) {
  NSURLComponents *parts = [NSURLComponents componentsWithString:url];
  return [parts.scheme isEqualToString:@"https"] && [parts.host.lowercaseString isEqualToString:@"dev.azure.com"] && [parts.path containsString:@"/_apis/"];
}

void SessionGET(CefRefPtr<CefRequestContext> context, NSString *url, SessionRequestClient::Done done) {
  if (!context || !AzureAPI(url)) { done(0, @"", @"", nil); return; }
  CefRefPtr<CefRequest> request = CefRequest::Create();
  request->SetURL(C(url)); request->SetMethod("GET"); request->SetFirstPartyForCookies(C(url));
  CefRequest::HeaderMap headers; headers.insert({"Accept", "application/json"}); request->SetHeaderMap(headers);
  request->SetFlags(UR_FLAG_ALLOW_STORED_CREDENTIALS | UR_FLAG_DISABLE_CACHE | UR_FLAG_STOP_ON_REDIRECT);
  CefRefPtr<SessionRequestClient> client = new SessionRequestClient(done);
  client->request_ = CefURLRequest::Create(request, client, context);
  // Chromium has its own timeouts, but a card should not wait that long.
  CefRefPtr<CefURLRequest> pending = client->request_;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (pending && pending->GetRequestStatus() == UR_IO_PENDING) pending->Cancel(); });
}

NSString *ShortError(NSError *error) {
  if ([error.domain isEqualToString:NSURLErrorDomain]) {
    switch (error.code) {
      case NSURLErrorTimedOut: return @"Timed out";
      case NSURLErrorCannotFindHost: case NSURLErrorDNSLookupFailed: return @"Host not found";
      case NSURLErrorCannotConnectToHost: return @"Connection refused";
      case NSURLErrorNotConnectedToInternet: return @"Offline";
      case NSURLErrorSecureConnectionFailed: case NSURLErrorServerCertificateUntrusted: case NSURLErrorServerCertificateHasBadDate:
      case NSURLErrorServerCertificateNotYetValid: case NSURLErrorServerCertificateHasUnknownRoot: return @"Certificate problem";
    }
  }
  return error.localizedDescription ?: @"No response";
}
}

@implementation ProjectRepository
@end

@interface ProjectStatusService () <NSURLSessionTaskDelegate>
@end

@implementation ProjectStatusService {
  CefRefPtr<CefRequestContext> (^_contexts)(NSString *);
  rail::StatusSnapshot _snapshot;
  NSURLSession *_session;
  NSMutableSet<NSNumber *> *_healthTasks;
  std::set<std::string> _inFlight;
  std::map<std::string, double> _connectionChecked, _sourceChecked;
  BOOL _deviceFlowCancelled;
  NSUInteger _deviceFlow;
}
- (instancetype)initWithContexts:(CefRefPtr<CefRequestContext> (^)(NSString *))contexts {
  if ((self = [super init])) {
    _contexts = [contexts copy];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage = nil; config.HTTPShouldSetCookies = NO; config.URLCredentialStorage = nil; config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData; config.timeoutIntervalForRequest = 10;
    config.HTTPAdditionalHeaders = @{@"User-Agent":@"Eimerrail"};
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    _healthTasks = [NSMutableSet set];
  }
  return self;
}
- (const rail::StatusSnapshot &)snapshot { return _snapshot; }
- (BOOL)isChecking { return !_inFlight.empty(); }
- (NSString *)gitHubClientID {
  NSString *configured = [NSUserDefaults.standardUserDefaults stringForKey:@"GitHubClientID"];
  if (configured.length) return configured;
  NSString *bundled = [NSBundle.mainBundle objectForInfoDictionaryKey:@"EimerrailGitHubClientID"];
  return [bundled isKindOfClass:NSString.class] && bundled.length && ![bundled hasPrefix:@"$"] ? bundled : nil;
}
- (void)changed { if (self.onChange) self.onChange(); }

// Health checks follow no redirects: a redirect to another host means a login sits in front.
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
  (void)session; (void)response;
  completionHandler([_healthTasks containsObject:@(task.taskIdentifier)] ? nil : request);
}

- (void)checkProjects:(const std::vector<rail::Project> &)projects connections:(const std::vector<rail::Connection> &)connections force:(BOOL)force {
  double now = Now();
  for (const auto &project : projects) for (const auto &environment : project.environments) {
    auto known = _snapshot.environments.find(environment.id);
    double last = known == _snapshot.environments.end() ? 0 : known->second.checkedAt;
    if (_inFlight.count(environment.id) || (!force && now - last < 55)) continue;
    [self checkEnvironment:environment];
  }
  std::map<std::string, std::vector<rail::SourceBinding>> byConnection;
  for (const auto &project : projects) for (const auto &binding : project.sources) byConnection[binding.connectionID].push_back(binding);
  for (const auto &connection : connections) {
    auto bindings = byConnection.find(connection.id);
    if (bindings == byConnection.end()) continue;
    std::string key = "connection:" + connection.id;
    if (_inFlight.count(key) || (!force && now - _connectionChecked[connection.id] < 115)) continue;
    _connectionChecked[connection.id] = now;
    if (connection.provider == "azureDevOps") [self checkAzure:connection bindings:bindings->second];
    else if (connection.provider == "github") [self checkGitHub:connection bindings:bindings->second];
  }
  [self changed];
}

#pragma mark Health

- (void)checkEnvironment:(const rail::Environment &)environment {
  std::string id = environment.id, url = environment.url, health = environment.healthPath;
  _inFlight.insert(id);
  __weak ProjectStatusService *weak = self;
  auto finish = [weak, id](rail::Health health, int ms, NSString *version, NSString *error) {
    ProjectStatusService *strong = weak; if (!strong) return;
    strong->_inFlight.erase(id);
    auto &status = strong->_snapshot.environments[id];
    status.slowStreak = health == rail::Health::slow ? status.slowStreak + 1 : 0;
    status.health = health; status.latencyMs = ms; status.version = C(version ?: @""); status.error = C(error ?: @""); status.checkedAt = Now();
    [strong changed];
  };
  if (rail::isLocalURL(url)) {
    NSString *host = S(rail::hostOf(url));
    if ([host hasPrefix:@"["]) host = [host substringWithRange:NSMakeRange(1, host.length - 2)];
    [self probeHost:host port:rail::portOf(url) done:^(BOOL open, int ms) {
      ProjectStatusService *strong = weak; if (!strong) return;
      if (!open) { finish(rail::Health::notRunning, 0, nil, nil); return; }
      if (health.empty()) { finish(rail::Health::up, ms, nil, nil); return; }
      [strong fetchHealth:S(rail::joinURL(url, health)) done:finish];
    }];
  } else {
    [self fetchHealth:S(rail::joinURL(url, health)) done:finish];
  }
}
- (void)fetchHealth:(NSString *)address done:(std::function<void(rail::Health, int, NSString *, NSString *)>)done {
  NSURL *url = [NSURL URLWithString:address];
  if (!url) { done(rail::Health::down, 0, nil, @"Invalid address"); return; }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
  request.HTTPShouldHandleCookies = NO; [request setValue:@"application/json, */*" forHTTPHeaderField:@"Accept"];
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  __block NSURLSessionDataTask *task = nil;
  __weak ProjectStatusService *weak = self;
  task = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    ProjectStatusService *strong = weak; if (strong) [strong->_healthTasks removeObject:@(task.taskIdentifier)];
    int ms = (int)((CFAbsoluteTimeGetCurrent() - start) * 1000);
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    if (!http) { done(rail::Health::down, ms, nil, ShortError(error)); return; }
    NSString *location = [http valueForHTTPHeaderField:@"Location"];
    NSURL *target = location.length ? [NSURL URLWithString:location relativeToURL:url] : nil;
    BOOL elsewhere = target && target.host && ![target.host.lowercaseString isEqualToString:url.host.lowercaseString];
    NSString *version = [http valueForHTTPHeaderField:@"X-Version"] ?: [http valueForHTTPHeaderField:@"X-App-Version"];
    if (!version.length && [http.MIMEType containsString:@"json"] && data.length < 64 * 1024) {
      NSDictionary *body = Dict(JSON(data)); version = Str(body[@"version"] ?: body[@"Version"]);
    }
    rail::Health health = rail::healthFromHTTP((int)http.statusCode, elsewhere, ms);
    done(health, ms, version.length ? version : nil, health == rail::Health::down ? [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode] : nil);
  }];
  [_healthTasks addObject:@(task.taskIdentifier)];
  [task resume];
}
- (void)probeHost:(NSString *)host port:(int)port done:(void (^)(BOOL open, int ms))done {
  nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, [NSString stringWithFormat:@"%d", port].UTF8String);
  nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
  nw_connection_t connection = nw_connection_create(endpoint, parameters);
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  __block BOOL finished = NO;
  void (^finish)(BOOL) = ^(BOOL open) {
    if (finished) return; finished = YES;
    nw_connection_cancel(connection);
    done(open, (int)((CFAbsoluteTimeGetCurrent() - start) * 1000));
  };
  nw_connection_set_queue(connection, dispatch_get_main_queue());
  nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
    (void)error;
    if (state == nw_connection_state_ready) finish(YES);
    else if (state == nw_connection_state_failed || state == nw_connection_state_waiting) finish(NO);
  });
  nw_connection_start(connection);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(NO); });
}

#pragma mark Azure DevOps

- (void)checkAzure:(rail::Connection)connection bindings:(std::vector<rail::SourceBinding>)bindings {
  CefRefPtr<CefRequestContext> context = _contexts(S(connection.sessionID));
  std::string key = "connection:" + connection.id;
  _inFlight.insert(key);
  NSString *url = [NSString stringWithFormat:@"https://dev.azure.com/%@/_apis/connectionData?api-version=7.1-preview", S(connection.account)];
  __weak ProjectStatusService *weak = self;
  SessionGET(context, url, ^(int status, NSString *location, NSString *mime, NSData *body) {
    ProjectStatusService *strong = weak; if (!strong) return;
    strong->_inFlight.erase(key);
    NSDictionary *user = Dict(Dict(JSON(body))[@"authenticatedUser"]);
    rail::Access access = rail::azureAccess(status, C(location), C(mime), C(Str(user[@"providerDisplayName"])));
    auto &state = strong->_snapshot.connections[connection.id];
    state.access = access; state.account = C(Str(Dict(Dict(user[@"properties"])[@"Account"])[@"$value"]));
    state.error = access == rail::Access::unknown ? (status ? C([NSString stringWithFormat:@"Azure DevOps answered HTTP %d", status]) : "Azure DevOps did not answer") : "";
    if (access == rail::Access::signedIn) for (const auto &binding : bindings) [strong fetchAzureSource:binding context:context];
    [strong changed];
  });
}
- (void)fetchAzureSource:(rail::SourceBinding)binding context:(CefRefPtr<CefRequestContext>)context {
  NSArray *parts = [S(binding.resource) componentsSeparatedByString:@"/"];
  if (parts.count != 3) return;
  std::string key = rail::sourceKey(binding);
  _inFlight.insert(key);
  NSString *base = [NSString stringWithFormat:@"https://dev.azure.com/%@/%@/_apis/git/repositories/%@", parts[0], parts[1], parts[2]];
  __weak ProjectStatusService *weak = self;
  auto fail = [weak, key](NSString *error) {
    ProjectStatusService *strong = weak; if (!strong) return;
    strong->_inFlight.erase(key);
    auto &source = strong->_snapshot.sources[key]; source.error = C(error); source.checkedAt = Now(); [strong changed];
  };
  SessionGET(context, [base stringByAppendingString:@"?api-version=7.1"], ^(int status, NSString *location, NSString *mime, NSData *body) {
    (void)location; (void)mime;
    NSDictionary *repo = Dict(JSON(body));
    if (status != 200 || !Str(repo[@"id"]).length) { fail(status == 404 ? @"Repository not found" : [NSString stringWithFormat:@"Couldn't read the repository (HTTP %d)", status]); return; }
    NSString *repoID = Str(repo[@"id"]), *branch = Str(repo[@"defaultBranch"]);
    NSString *project = [NSString stringWithFormat:@"https://dev.azure.com/%@/%@/_apis", parts[0], parts[1]];
    __block int pending = 2; __block rail::SourceStatus result;
    result.defaultBranch = C([branch stringByReplacingOccurrencesOfString:@"refs/heads/" withString:@""]);
    result.pullRequestsURL = C([NSString stringWithFormat:@"https://dev.azure.com/%@/%@/_git/%@/pullrequests", parts[0], parts[1], parts[2]]);
    void (^complete)(void) = ^{
      if (--pending) return;
      ProjectStatusService *strong = weak; if (!strong) return;
      strong->_inFlight.erase(key); result.checkedAt = Now(); strong->_snapshot.sources[key] = result; [strong changed];
    };
    NSMutableDictionary *query = [@{@"repositoryId":repoID,@"repositoryType":@"TfsGit",@"$top":@"25",@"queryOrder":@"queueTimeDescending",@"api-version":@"7.1"} mutableCopy];
    if (branch.length) query[@"branchName"] = branch;
    SessionGET(context, Query([project stringByAppendingString:@"/build/builds"], query), ^(int buildStatus, NSString *l, NSString *m, NSData *builds) {
      (void)l; (void)m;
      std::set<std::string> seen;
      for (id item in List(Dict(JSON(builds))[@"value"])) {
        NSDictionary *build = Dict(item); if (!build) continue;
        NSDictionary *definition = Dict(build[@"definition"]);
        if (!seen.insert(C(Str(definition[@"id"]))).second) continue;
        result.runs.push_back({C(Str(definition[@"name"])), C(Str(build[@"buildNumber"])), result.defaultBranch,
                               rail::azureBuildResult(C(Str(build[@"status"])), C(Str(build[@"result"]))),
                               C(Str(Dict(Dict(Dict(build[@"_links"])[@"web"]))[@"href"])), ISODate(Str(build[@"finishTime"]))});
      }
      if (buildStatus != 200) result.error = "Couldn't read pipelines";
      complete();
    });
    SessionGET(context, Query([base stringByAppendingString:@"/pullrequests"], @{@"searchCriteria.status":@"active",@"$top":@"100",@"api-version":@"7.1"}), ^(int prStatus, NSString *l, NSString *m, NSData *prs) {
      (void)l; (void)m;
      if (prStatus == 200) result.openPullRequests = (int)List(Dict(JSON(prs))[@"value"]).count;
      complete();
    });
  });
}
- (void)azureRepositories:(NSString *)organization session:(NSString *)sessionID completion:(void (^)(NSArray<ProjectRepository *> *, NSString *, BOOL))completion {
  NSString *org = [organization stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString *safe = [org stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
  if (!safe.length || [org containsString:@"/"]) { completion(@[], @"Enter an organization name, such as contoso.", NO); return; }
  SessionGET(_contexts(sessionID), [NSString stringWithFormat:@"https://dev.azure.com/%@/_apis/git/repositories?api-version=7.1", safe], ^(int status, NSString *location, NSString *mime, NSData *body) {
    NSDictionary *value = Dict(JSON(body));
    if (rail::azureAccess(status, C(location), C(mime), value ? "listed" : "") == rail::Access::signedOut) { completion(@[], nil, YES); return; }
    if (status != 200) { completion(@[], status == 404 ? @"No such organization." : [NSString stringWithFormat:@"Azure DevOps answered HTTP %d.", status], NO); return; }
    NSMutableArray *repositories = [NSMutableArray array];
    for (id item in List(value[@"value"])) {
      NSDictionary *repo = Dict(item); if (!repo || [repo[@"isDisabled"] boolValue]) continue;
      ProjectRepository *entry = [[ProjectRepository alloc] init];
      entry.name = Str(repo[@"name"]); entry.detail = Str(Dict(repo[@"project"])[@"name"]); entry.url = Str(repo[@"webUrl"]);
      if (entry.url.length) [repositories addObject:entry];
    }
    [repositories sortUsingComparator:^NSComparisonResult(ProjectRepository *a, ProjectRepository *b) { NSComparisonResult r = [a.detail localizedCaseInsensitiveCompare:b.detail]; return r != NSOrderedSame ? r : [a.name localizedCaseInsensitiveCompare:b.name]; }];
    completion(repositories, nil, NO);
  });
}

#pragma mark GitHub

- (NSDictionary *)tokenFor:(NSString *)connectionID { return Dict(JSON(KeychainRead(connectionID))); }
- (BOOL)hasGitHubToken:(NSString *)connectionID { return Str([self tokenFor:connectionID][@"access"]).length > 0; }
- (void)forgetConnection:(NSString *)connectionID { KeychainDelete(connectionID); _snapshot.connections.erase(C(connectionID)); [self changed]; }
- (void)storeToken:(NSDictionary *)response connection:(NSString *)connectionID {
  double now = Now(); NSMutableDictionary *token = [@{@"access":Str(response[@"access_token"])} mutableCopy];
  if ([response[@"expires_in"] isKindOfClass:NSNumber.class]) token[@"expires"] = @(now + [response[@"expires_in"] doubleValue]);
  if (Str(response[@"refresh_token"]).length) token[@"refresh"] = Str(response[@"refresh_token"]);
  if ([response[@"refresh_token_expires_in"] isKindOfClass:NSNumber.class]) token[@"refreshExpires"] = @(now + [response[@"refresh_token_expires_in"] doubleValue]);
  NSData *data = [NSJSONSerialization dataWithJSONObject:token options:0 error:nil];
  if (data) KeychainWrite(connectionID, data);
}
- (void)postForm:(NSString *)url fields:(NSDictionary<NSString *, NSString *> *)fields done:(void (^)(NSDictionary *body, NSInteger status))done {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
  request.HTTPMethod = @"POST"; [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  NSURLComponents *form = [[NSURLComponents alloc] init]; NSMutableArray *items = [NSMutableArray array];
  for (NSString *key in fields) [items addObject:[NSURLQueryItem queryItemWithName:key value:fields[key]]];
  form.queryItems = items; request.HTTPBody = [form.percentEncodedQuery dataUsingEncoding:NSUTF8StringEncoding];
  [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    (void)error; done(Dict(JSON(data)), [(NSHTTPURLResponse *)response statusCode]);
  }] resume];
}
// Calls back with a usable access token, refreshing it first when it has expired.
- (void)gitHubToken:(NSString *)connectionID done:(void (^)(NSString *token, rail::Access access))done {
  NSDictionary *token = [self tokenFor:connectionID];
  NSString *access = Str(token[@"access"]);
  if (!access.length) { done(nil, rail::Access::signedOut); return; }
  double expires = [token[@"expires"] doubleValue], now = Now();
  if (!expires || expires - 120 > now) { done(access, rail::Access::signedIn); return; }
  NSString *refresh = Str(token[@"refresh"]); NSString *client = self.gitHubClientID;
  if (!refresh.length || !client.length || ([token[@"refreshExpires"] doubleValue] && [token[@"refreshExpires"] doubleValue] < now)) { done(nil, rail::Access::rejected); return; }
  __weak ProjectStatusService *weak = self;
  [self postForm:@"https://github.com/login/oauth/access_token" fields:@{@"client_id":client,@"grant_type":@"refresh_token",@"refresh_token":refresh} done:^(NSDictionary *body, NSInteger status) {
    ProjectStatusService *strong = weak; if (!strong) return;
    if (status != 200 || !Str(body[@"access_token"]).length) { done(nil, rail::Access::rejected); return; }
    [strong storeToken:body connection:connectionID]; done(Str(body[@"access_token"]), rail::Access::signedIn);
  }];
}
- (void)gitHubGET:(NSString *)path token:(NSString *)token done:(void (^)(id body, NSInteger status))done {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://api.github.com" stringByAppendingString:path]]];
  [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
  [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
  [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
  [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    (void)error; done(JSON(data), [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0);
  }] resume];
}
- (void)checkGitHub:(rail::Connection)connection bindings:(std::vector<rail::SourceBinding>)bindings {
  std::string key = "connection:" + connection.id;
  _inFlight.insert(key);
  __weak ProjectStatusService *weak = self;
  [self gitHubToken:S(connection.id) done:^(NSString *token, rail::Access access) {
    ProjectStatusService *strong = weak; if (!strong) return;
    strong->_inFlight.erase(key);
    auto &state = strong->_snapshot.connections[connection.id];
    state.access = access; state.account = connection.account; state.error.clear();
    if (token) for (const auto &binding : bindings) [strong fetchGitHubSource:binding token:token connection:connection.id];
    [strong changed];
  }];
}
- (void)fetchGitHubSource:(rail::SourceBinding)binding token:(NSString *)token connection:(std::string)connectionID {
  std::string key = rail::sourceKey(binding);
  NSArray *parts = [S(binding.resource) componentsSeparatedByString:@"/"];
  if (parts.count != 2) return;
  _inFlight.insert(key);
  NSString *repoPath = [NSString stringWithFormat:@"/repos/%@/%@", parts[0], parts[1]];
  __weak ProjectStatusService *weak = self;
  [self gitHubGET:repoPath token:token done:^(id body, NSInteger status) {
    ProjectStatusService *strong = weak; if (!strong) return;
    if (status == 401) { strong->_inFlight.erase(key); strong->_snapshot.connections[connectionID].access = rail::Access::rejected; [strong changed]; return; }
    if (status == 404 || status == 403) {
      strong->_inFlight.erase(key); rail::SourceStatus source; source.notCovered = true; source.checkedAt = Now();
      strong->_snapshot.sources[key] = source; [strong changed]; return;
    }
    NSString *branch = Str(Dict(body)[@"default_branch"]);
    __block int pending = 2; __block rail::SourceStatus result;
    result.defaultBranch = C(branch); result.pullRequestsURL = C([NSString stringWithFormat:@"https://github.com/%@/%@/pulls", parts[0], parts[1]]);
    if (status != 200) result.error = C([NSString stringWithFormat:@"GitHub answered HTTP %ld", (long)status]);
    void (^complete)(void) = ^{
      if (--pending) return;
      ProjectStatusService *inner = weak; if (!inner) return;
      inner->_inFlight.erase(key); result.checkedAt = Now(); inner->_snapshot.sources[key] = result; [inner changed];
    };
    NSString *runs = Query([repoPath stringByAppendingString:@"/actions/runs"], branch.length ? @{@"branch":branch,@"per_page":@"30"} : @{@"per_page":@"30"});
    [strong gitHubGET:runs token:token done:^(id runsBody, NSInteger runsStatus) {
      std::set<std::string> seen;
      for (id item in List(Dict(runsBody)[@"workflow_runs"])) {
        NSDictionary *run = Dict(item); if (!run || !seen.insert(C(Str(run[@"workflow_id"]))).second) continue;
        result.runs.push_back({C(Str(run[@"name"])), C(Str(run[@"run_number"])), C(Str(run[@"head_branch"])),
                               rail::githubRunResult(C(Str(run[@"status"])), C(Str(run[@"conclusion"]))), C(Str(run[@"html_url"])), ISODate(Str(run[@"updated_at"]))});
      }
      if (runsStatus != 200 && result.error.empty()) result.error = "Couldn't read workflow runs";
      complete();
    }];
    [strong gitHubGET:[repoPath stringByAppendingString:@"/pulls?state=open&per_page=100"] token:token done:^(id prs, NSInteger prStatus) {
      if (prStatus == 200) result.openPullRequests = (int)List(prs).count;
      complete();
    }];
  }];
}
- (void)signInToGitHub:(NSString *)connectionID code:(void (^)(NSString *, NSString *))code done:(void (^)(NSString *, NSString *))done {
  NSString *client = self.gitHubClientID;
  if (!client.length) { done(nil, @"GitHub sign-in isn't set up yet. Register the Eimerrail GitHub App and set its client ID (see README)."); return; }
  NSUInteger flow = ++_deviceFlow; _deviceFlowCancelled = NO;
  __weak ProjectStatusService *weak = self;
  [self postForm:@"https://github.com/login/device/code" fields:@{@"client_id":client} done:^(NSDictionary *body, NSInteger status) {
    ProjectStatusService *strong = weak; if (!strong || flow != strong->_deviceFlow) return;
    NSString *device = Str(body[@"device_code"]);
    if (status != 200 || !device.length) { done(nil, Str(body[@"error_description"]).length ? Str(body[@"error_description"]) : @"GitHub didn't start the sign-in."); return; }
    code(Str(body[@"user_code"]), Str(body[@"verification_uri"]).length ? Str(body[@"verification_uri"]) : @"https://github.com/login/device");
    double deadline = Now() + MAX(60, [body[@"expires_in"] doubleValue] ?: 900);
    [strong pollDevice:device client:client interval:MAX(5, [body[@"interval"] doubleValue]) deadline:deadline flow:flow connection:connectionID done:done];
  }];
}
- (void)pollDevice:(NSString *)device client:(NSString *)client interval:(double)interval deadline:(double)deadline flow:(NSUInteger)flow connection:(NSString *)connectionID done:(void (^)(NSString *, NSString *))done {
  __weak ProjectStatusService *weak = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    ProjectStatusService *strong = weak; if (!strong || flow != strong->_deviceFlow || strong->_deviceFlowCancelled) return;
    if (Now() > deadline) { done(nil, @"The code expired. Start the sign-in again."); return; }
    [strong postForm:@"https://github.com/login/oauth/access_token" fields:@{@"client_id":client,@"device_code":device,@"grant_type":@"urn:ietf:params:oauth:grant-type:device_code"} done:^(NSDictionary *body, NSInteger status) {
      (void)status;
      ProjectStatusService *inner = weak; if (!inner || flow != inner->_deviceFlow || inner->_deviceFlowCancelled) return;
      NSString *error = Str(body[@"error"]);
      if ([error isEqualToString:@"authorization_pending"]) { [inner pollDevice:device client:client interval:interval deadline:deadline flow:flow connection:connectionID done:done]; return; }
      if ([error isEqualToString:@"slow_down"]) { [inner pollDevice:device client:client interval:MAX(interval + 5, [body[@"interval"] doubleValue]) deadline:deadline flow:flow connection:connectionID done:done]; return; }
      if (error.length || !Str(body[@"access_token"]).length) {
        done(nil, [error isEqualToString:@"access_denied"] ? @"Sign-in was cancelled on GitHub." : [error isEqualToString:@"expired_token"] || [error isEqualToString:@"token_expired"] ? @"The code expired. Start the sign-in again." : [error isEqualToString:@"device_flow_disabled"] ? @"Enable Device Flow in the GitHub App settings." : @"GitHub didn't complete the sign-in.");
        return;
      }
      [inner storeToken:body connection:connectionID];
      [inner gitHubGET:@"/user" token:Str(body[@"access_token"]) done:^(id user, NSInteger userStatus) {
        ProjectStatusService *last = weak; if (!last) return;
        NSString *login = userStatus == 200 ? Str(Dict(user)[@"login"]) : @"";
        auto &state = last->_snapshot.connections[C(connectionID)]; state.access = rail::Access::signedIn; state.account = C(login);
        last->_connectionChecked.erase(C(connectionID));
        done(login, nil); [last changed];
      }];
    }];
  });
}
- (void)cancelGitHubSignIn { _deviceFlowCancelled = YES; ++_deviceFlow; }
- (void)gitHubRepositories:(NSString *)connectionID completion:(void (^)(NSArray<ProjectRepository *> *, NSString *, BOOL))completion {
  __weak ProjectStatusService *weak = self;
  [self gitHubToken:connectionID done:^(NSString *token, rail::Access access) {
    ProjectStatusService *strong = weak; if (!strong) return;
    if (!token) { completion(@[], nil, access != rail::Access::signedIn); return; }
    [strong gitHubRepositoryPage:1 token:token into:[NSMutableArray array] completion:completion];
  }];
}
// GitHub returns at most 100 repositories per page; keep reading until a page comes back short.
- (void)gitHubRepositoryPage:(NSInteger)page token:(NSString *)token into:(NSMutableArray<ProjectRepository *> *)repositories completion:(void (^)(NSArray<ProjectRepository *> *, NSString *, BOOL))completion {
  __weak ProjectStatusService *weak = self;
  NSString *path = [NSString stringWithFormat:@"/user/repos?per_page=100&page=%ld&sort=full_name", (long)page];
  [self gitHubGET:path token:token done:^(id body, NSInteger status) {
    if (status == 401) { completion(@[], nil, YES); return; }
    if (status != 200) { completion(@[], [NSString stringWithFormat:@"GitHub answered HTTP %ld.", (long)status], NO); return; }
    NSArray *items = List(body);
    for (id item in items) {
      NSDictionary *repo = Dict(item); if (!repo || [repo[@"archived"] boolValue]) continue;
      ProjectRepository *entry = [[ProjectRepository alloc] init];
      entry.name = Str(repo[@"name"]); entry.detail = Str(Dict(repo[@"owner"])[@"login"]); entry.url = Str(repo[@"html_url"]);
      [repositories addObject:entry];
    }
    ProjectStatusService *strong = weak;
    if (strong && items.count == 100 && page < 50) [strong gitHubRepositoryPage:page + 1 token:token into:repositories completion:completion];
    else completion(repositories, nil, NO);
  }];
}
@end
