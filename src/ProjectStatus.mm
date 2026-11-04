#import "ProjectStatus.h"
#import "Keychain.h"
#import <Network/Network.h>
#include "include/cef_urlrequest.h"
#include <algorithm>
#include <map>
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

// Azure DevOps limits a user across the whole organization, so one sign to slow down covers every connection.
double AzureRetryAt = 0;

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
    if (response) {
      double retry = S(response->GetHeaderByName("Retry-After").ToString()).doubleValue;
      if (retry > 0 || status == 429) AzureRetryAt = MAX(AzureRetryAt, Now() + MAX(retry, 60));
    }
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
  std::map<std::string, double> _sourceChecked;
  BOOL _forcedCheck;
  double _gitHubRetryAt;
  NSMutableDictionary<NSString *, NSString *> *_gitHubTags;
  NSMutableDictionary<NSString *, id> *_gitHubBodies;
  BOOL _deviceFlowCancelled;
  NSUInteger _deviceFlow;
}
- (instancetype)initWithContexts:(CefRefPtr<CefRequestContext> (^)(NSString *))contexts {
  if ((self = [super init])) {
    _contexts = [contexts copy];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage = nil; config.HTTPShouldSetCookies = NO; config.URLCredentialStorage = nil; config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData; config.timeoutIntervalForRequest = 10;
    config.HTTPAdditionalHeaders = @{@"User-Agent":@"Rail"};
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    _healthTasks = [NSMutableSet set]; _gitHubTags = [NSMutableDictionary dictionary]; _gitHubBodies = [NSMutableDictionary dictionary];
  }
  return self;
}
- (const rail::StatusSnapshot &)snapshot { return _snapshot; }
- (BOOL)isChecking { return _forcedCheck; }
- (NSString *)gitHubClientID {
  NSString *configured = [NSUserDefaults.standardUserDefaults stringForKey:@"GitHubClientID"];
  if (configured.length) return configured;
  NSString *bundled = [NSBundle.mainBundle objectForInfoDictionaryKey:@"RailGitHubClientID"];
  return [bundled isKindOfClass:NSString.class] && bundled.length && ![bundled hasPrefix:@"$"] ? bundled : nil;
}
- (void)changed { if (_inFlight.empty()) _forcedCheck = NO; if (self.onChange) self.onChange(); }

// Health checks follow no redirects: a redirect to another host means a login sits in front.
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
  (void)session; (void)response;
  completionHandler([_healthTasks containsObject:@(task.taskIdentifier)] ? nil : request);
}

- (void)checkHealth:(const std::vector<rail::Project> &)health sources:(const std::vector<rail::Project> &)sources connections:(const std::vector<rail::Connection> &)connections force:(BOOL)force {
  double now = Now();
  if (force) _forcedCheck = YES;
  for (const auto &project : health) for (const auto &environment : project.environments) {
    auto known = _snapshot.environments.find(environment.id);
    double last = known == _snapshot.environments.end() ? 0 : known->second.checkedAt;
    if (_inFlight.count(environment.id) || (!force && now - last < 55)) continue;
    [self checkEnvironment:environment];
  }
  std::map<std::string, std::vector<rail::SourceBinding>> byConnection;
  for (const auto &project : sources) for (const auto &binding : project.sources) byConnection[binding.connectionID].push_back(binding);
  for (const auto &connection : connections) {
    auto bindings = byConnection.find(connection.id);
    if (bindings == byConnection.end()) continue;
    std::string key = "connection:" + connection.id;
    if (_inFlight.count(key)) continue;
    BOOL throttled = now < (connection.provider == "azureDevOps" ? AzureRetryAt : _gitHubRetryAt);
    if (_snapshot.connections[connection.id].throttled != (bool)throttled) _snapshot.connections[connection.id].throttled = throttled;
    if (throttled) continue;
    std::vector<rail::SourceBinding> due;
    for (const auto &binding : bindings->second) {
      std::string source = rail::sourceKey(binding);
      auto known = _snapshot.sources.find(source);
      int interval = known == _snapshot.sources.end() ? rail::IdlePollSeconds : rail::sourcePollSeconds(known->second);
      if (force || now - _sourceChecked[source] >= interval) { due.push_back(binding); _sourceChecked[source] = now; }
    }
    if (due.empty()) continue;
    if (connection.provider == "azureDevOps") [self checkAzure:connection bindings:due];
    else if (connection.provider == "github") [self checkGitHub:connection bindings:due];
  }
  [self changed];
}
// Keeps when the source last answered cleanly, which a replaced status would otherwise lose.
- (void)storeSource:(rail::SourceStatus)result key:(const std::string &)key {
  auto previous = _snapshot.sources.find(key);
  result.checkedAt = Now(); result.readAt = result.error.empty() ? result.checkedAt : previous == _snapshot.sources.end() ? 0 : previous->second.readAt;
  _snapshot.sources[key] = result;
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
    state.access = access; state.account = C(Str(Dict(Dict(user[@"properties"])[@"Account"])[@"$value"])); state.userID = C(Str(user[@"id"]));
    state.error = access == rail::Access::unknown ? (status ? C([NSString stringWithFormat:@"Azure DevOps answered HTTP %d", status]) : "Azure DevOps did not answer") : "";
    if (access == rail::Access::signedIn) for (const auto &binding : bindings) [strong fetchAzureSource:binding context:context user:Str(user[@"id"])];
    [strong changed];
  });
}
- (void)fetchAzureSource:(rail::SourceBinding)binding context:(CefRefPtr<CefRequestContext>)context user:(NSString *)userID {
  NSArray *parts = [S(binding.resource) componentsSeparatedByString:@"/"];
  if (parts.count != 3) return;
  std::string key = rail::sourceKey(binding);
  if (_inFlight.count(key)) return;
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
    NSString *repoID = Str(repo[@"id"]), *branch = Str(repo[@"defaultBranch"]), *projectID = Str(Dict(repo[@"project"])[@"id"]);
    NSString *project = [NSString stringWithFormat:@"https://dev.azure.com/%@/%@/_apis", parts[0], parts[1]];
    __block int pending = 3; __block rail::SourceStatus result;
    result.defaultBranch = C([branch stringByReplacingOccurrencesOfString:@"refs/heads/" withString:@""]);
    result.pullRequestsURL = C([NSString stringWithFormat:@"https://dev.azure.com/%@/%@/_git/%@/pullrequests", parts[0], parts[1], parts[2]]);
    void (^complete)(void) = ^{
      if (--pending) return;
      ProjectStatusService *strong = weak; if (!strong) return;
      strong->_inFlight.erase(key); [strong storeSource:result key:key]; [strong changed];
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
    // Runs the user started by hand, on any branch. CI and pull request builds are not theirs to follow here.
    NSDictionary *mine = @{@"repositoryId":repoID,@"repositoryType":@"TfsGit",@"reasonFilter":@"manual",@"$top":@"30",@"queryOrder":@"queueTimeDescending",@"api-version":@"7.1"};
    SessionGET(context, Query([project stringByAppendingString:@"/build/builds"], mine), ^(int buildStatus, NSString *l, NSString *m, NSData *builds) {
      (void)l; (void)m;
      std::set<std::string> seen;
      for (id item in List(Dict(JSON(builds))[@"value"])) {
        NSDictionary *build = Dict(item); if (!build) continue;
        if (!userID.length || [Str(Dict(build[@"requestedFor"])[@"id"]) caseInsensitiveCompare:userID] != NSOrderedSame) continue;
        NSDictionary *definition = Dict(build[@"definition"]);
        if (!seen.insert(C(Str(definition[@"id"]))).second) continue;
        rail::PipelineRun run;
        run.name = C(Str(definition[@"name"])); run.number = C(Str(build[@"buildNumber"])); run.id = C(Str(build[@"id"])); run.definitionID = C(Str(definition[@"id"]));
        run.branch = C([Str(build[@"sourceBranch"]) stringByReplacingOccurrencesOfString:@"refs/heads/" withString:@""]);
        run.result = rail::azureBuildResult(C(Str(build[@"status"])), C(Str(build[@"result"])));
        run.url = C(Str(Dict(Dict(Dict(build[@"_links"])[@"web"]))[@"href"])); run.finishedAt = ISODate(Str(build[@"finishTime"]));
        run.startedAt = ISODate(Str(build[@"startTime"])) ?: ISODate(Str(build[@"queueTime"]));
        result.myRuns.push_back(run);
      }
      if (buildStatus != 200) result.error = "Couldn't read pipelines";
      // A run held for approval still reads as in progress; only its timeline tells.
      for (size_t i = 0; i < result.myRuns.size(); i++) {
        if (result.myRuns[i].result != "running") continue;
        pending++;
        SessionGET(context, [project stringByAppendingFormat:@"/build/builds/%@/timeline?api-version=7.1", S(result.myRuns[i].id)], ^(int status, NSString *l2, NSString *m2, NSData *body) {
          (void)l2; (void)m2;
          if (status == 200) for (id record in List(Dict(JSON(body))[@"records"]))
            if ([Str(Dict(record)[@"type"]) isEqualToString:@"Checkpoint.Approval"] && [Str(Dict(record)[@"state"]) isEqualToString:@"inProgress"]) result.myRuns[i].result = "waiting";
          complete();
        });
      }
      complete();
    });
    SessionGET(context, Query([base stringByAppendingString:@"/pullrequests"], @{@"searchCriteria.status":@"active",@"$top":@"100",@"api-version":@"7.1"}), ^(int prStatus, NSString *l, NSString *m, NSData *prs) {
      (void)l; (void)m;
      NSArray *open = List(Dict(JSON(prs))[@"value"]);
      if (prStatus == 200) { result.openPullRequests = (int)open.count; result.myPullRequestsKnown = userID.length > 0; }
      // The user's own pull requests, each with its policy evaluations and comment threads.
      NSString *web = [NSString stringWithFormat:@"https://dev.azure.com/%@/%@", parts[0], parts[1]];
      for (id item in open) {
        NSDictionary *pr = Dict(item);
        if (!pr || !userID.length || [Str(Dict(pr[@"createdBy"])[@"id"]) caseInsensitiveCompare:userID] != NSOrderedSame) continue;
        rail::PullRequest mine; NSString *number = Str(pr[@"pullRequestId"]);
        mine.id = C(number); mine.title = C(Str(pr[@"title"]));
        mine.url = C([NSString stringWithFormat:@"%@/_git/%@/pullrequest/%@", web, parts[2], number]);
        mine.sourceBranch = C([Str(pr[@"sourceRefName"]) stringByReplacingOccurrencesOfString:@"refs/heads/" withString:@""]);
        mine.targetBranch = C([Str(pr[@"targetRefName"]) stringByReplacingOccurrencesOfString:@"refs/heads/" withString:@""]);
        mine.draft = [pr[@"isDraft"] boolValue]; mine.conflicts = [Str(pr[@"mergeStatus"]) isEqualToString:@"conflicts"];
        mine.autoComplete = Dict(pr[@"autoCompleteSetBy"]) != nil; mine.createdAt = ISODate(Str(pr[@"creationDate"]));
        mine.detailsSHA = C(Str(Dict(pr[@"lastMergeSourceCommit"])[@"commitId"]));
        for (id r in List(pr[@"reviewers"])) {
          NSDictionary *reviewer = Dict(r);
          if (!reviewer || [Str(reviewer[@"id"]) caseInsensitiveCompare:userID] == NSOrderedSame) continue;
          mine.reviewers.push_back({C(Str(reviewer[@"displayName"])), rail::azureVote([reviewer[@"vote"] intValue]), [reviewer[@"isRequired"] boolValue]});
        }
        result.myPullRequests.push_back(mine);
      }
      pending += (int)result.myPullRequests.size() * 2;
      for (size_t i = 0; i < result.myPullRequests.size(); i++) {
        NSString *number = S(result.myPullRequests[i].id);
        NSString *artifact = [NSString stringWithFormat:@"vstfs:///CodeReview/CodeReviewId/%@/%@", projectID, number];
        SessionGET(context, Query([project stringByAppendingString:@"/policy/evaluations"], @{@"artifactId":artifact,@"api-version":@"7.1-preview.1"}), ^(int status, NSString *l2, NSString *m2, NSData *body) {
          (void)l2; (void)m2;
          if (status == 200) for (id e in List(Dict(JSON(body))[@"value"])) {
            NSDictionary *evaluation = Dict(e), *configuration = Dict(evaluation[@"configuration"]), *context = Dict(evaluation[@"context"]);
            if (!evaluation || (configuration[@"isEnabled"] && ![configuration[@"isEnabled"] boolValue])) continue;
            NSString *type = Str(Dict(configuration[@"type"])[@"displayName"]), *name = Str(Dict(configuration[@"settings"])[@"displayName"]);
            if (!name.length) name = Str(context[@"buildDefinitionName"]);
            if (!name.length) name = type;
            BOOL build = [type isEqualToString:@"Build"] || [type isEqualToString:@"Status"];
            rail::PullRequestCheck check; check.kind = build ? "build" : "policy"; check.name = C(name);
            check.state = rail::azurePolicyState(C(Str(evaluation[@"status"])));
            check.blocking = !configuration[@"isBlocking"] || [configuration[@"isBlocking"] boolValue];
            check.startedAt = ISODate(Str(evaluation[@"startedDate"]));
            if ([context[@"isExpired"] boolValue]) { check.state = "pending"; check.detail = "Expired"; }
            if (Str(context[@"buildId"]).length) check.url = C([NSString stringWithFormat:@"%@/_build/results?buildId=%@", web, Str(context[@"buildId"])]);
            if (!build) check.detail = check.state == "succeeded" ? "" : C(type);
            result.myPullRequests[i].checks.push_back(check);
          }
          complete();
        });
        SessionGET(context, Query([base stringByAppendingFormat:@"/pullRequests/%@/threads", number], @{@"api-version":@"7.1"}), ^(int status, NSString *l2, NSString *m2, NSData *body) {
          (void)l2; (void)m2;
          if (status == 200) {
            int active = 0;
            for (id t in List(Dict(JSON(body))[@"value"])) {
              NSDictionary *thread = Dict(t); NSDictionary *first = Dict(List(thread[@"comments"]).firstObject);
              if (!thread || [thread[@"isDeleted"] boolValue] || !first || [Str(first[@"commentType"]) isEqualToString:@"system"]) continue;
              NSString *state = Str(thread[@"status"]);
              if ([state isEqualToString:@"active"] || [state isEqualToString:@"pending"]) active++;
            }
            result.myPullRequests[i].openThreads = active;
          }
          complete();
        });
      }
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
  // An unchanged answer costs nothing against the rate limit, which is what makes frequent checks affordable.
  if (_gitHubTags[path]) [request setValue:_gitHubTags[path] forHTTPHeaderField:@"If-None-Match"];
  __weak ProjectStatusService *weak = self;
  [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    (void)error;
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    ProjectStatusService *strong = weak;
    if (strong && http) {
      if (http.statusCode == 304 && strong->_gitHubBodies[path]) { done(strong->_gitHubBodies[path], 200); return; }
      [strong noteGitHubLimits:http];
      id body = JSON(data);
      NSString *tag = [http valueForHTTPHeaderField:@"ETag"];
      if (http.statusCode == 200 && tag.length && body) {
        if (strong->_gitHubTags.count > 500) { [strong->_gitHubTags removeAllObjects]; [strong->_gitHubBodies removeAllObjects]; }
        strong->_gitHubTags[path] = tag; strong->_gitHubBodies[path] = body;
      }
      done(body, http.statusCode); return;
    }
    done(JSON(data), http.statusCode);
  }] resume];
}
- (void)noteGitHubLimits:(NSHTTPURLResponse *)http {
  double now = Now(), retry = [http valueForHTTPHeaderField:@"Retry-After"].doubleValue, reset = [http valueForHTTPHeaderField:@"X-RateLimit-Reset"].doubleValue;
  NSString *remaining = [http valueForHTTPHeaderField:@"X-RateLimit-Remaining"];
  if (retry > 0) _gitHubRetryAt = MAX(_gitHubRetryAt, now + retry);
  else if (http.statusCode == 429 || (remaining.length && remaining.intValue < 100)) _gitHubRetryAt = MAX(_gitHubRetryAt, reset > now ? MIN(reset, now + 15 * 60) : now + 60);
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
    if (token) for (const auto &binding : bindings) [strong fetchGitHubSource:binding token:token connection:connection.id account:S(connection.account)];
    [strong changed];
  }];
}
- (void)fetchGitHubSource:(rail::SourceBinding)binding token:(NSString *)token connection:(std::string)connectionID account:(NSString *)login {
  std::string key = rail::sourceKey(binding);
  NSArray *parts = [S(binding.resource) componentsSeparatedByString:@"/"];
  if (parts.count != 2 || _inFlight.count(key)) return;
  _inFlight.insert(key);
  NSString *repoPath = [NSString stringWithFormat:@"/repos/%@/%@", parts[0], parts[1]];
  __weak ProjectStatusService *weak = self;
  [self gitHubGET:repoPath token:token done:^(id body, NSInteger status) {
    ProjectStatusService *strong = weak; if (!strong) return;
    if (status == 401) { strong->_inFlight.erase(key); strong->_snapshot.connections[connectionID].access = rail::Access::rejected; [strong changed]; return; }
    if (status == 404 || status == 403) {
      strong->_inFlight.erase(key); rail::SourceStatus source; source.notCovered = true;
      [strong storeSource:source key:key]; [strong changed]; return;
    }
    NSString *branch = Str(Dict(body)[@"default_branch"]);
    __block int pending = 3; __block rail::SourceStatus result;
    result.defaultBranch = C(branch); result.pullRequestsURL = C([NSString stringWithFormat:@"https://github.com/%@/%@/pulls", parts[0], parts[1]]);
    if (status != 200) result.error = C([NSString stringWithFormat:@"GitHub answered HTTP %ld", (long)status]);
    void (^complete)(void) = ^{
      if (--pending) return;
      ProjectStatusService *inner = weak; if (!inner) return;
      inner->_inFlight.erase(key); [inner storeSource:result key:key]; [inner changed];
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
    // Runs the user started by hand, on any branch.
    if (!login.length) complete();
    else [strong gitHubGET:Query([repoPath stringByAppendingString:@"/actions/runs"], @{@"actor":login,@"event":@"workflow_dispatch",@"per_page":@"20"}) token:token done:^(id runsBody, NSInteger runsStatus) {
      std::set<std::string> seen;
      for (id item in List(Dict(runsBody)[@"workflow_runs"])) {
        NSDictionary *found = Dict(item); if (!found || !seen.insert(C(Str(found[@"workflow_id"]))).second) continue;
        rail::PipelineRun run;
        run.name = C(Str(found[@"name"])); run.number = C(Str(found[@"run_number"])); run.branch = C(Str(found[@"head_branch"])); run.url = C(Str(found[@"html_url"]));
        run.id = C(Str(found[@"id"])); run.definitionID = C(Str(found[@"workflow_id"]));
        run.result = rail::githubMyRunResult(C(Str(found[@"status"])), C(Str(found[@"conclusion"])));
        run.startedAt = ISODate(Str(found[@"run_started_at"])); run.finishedAt = [Str(found[@"status"]) isEqualToString:@"completed"] ? ISODate(Str(found[@"updated_at"])) : 0;
        result.myRuns.push_back(run);
      }
      if (runsStatus != 200 && result.error.empty()) result.error = "Couldn't read workflow runs";
      complete();
    }];
    [strong gitHubGET:[repoPath stringByAppendingString:@"/pulls?state=open&per_page=100"] token:token done:^(id prs, NSInteger prStatus) {
      if (prStatus == 200) { result.openPullRequests = (int)List(prs).count; result.myPullRequestsKnown = login.length > 0; }
      // The user's own pull requests, each with its check runs, reviews and mergeability.
      for (id item in List(prs)) {
        NSDictionary *pr = Dict(item);
        if (!pr || !login.length || [Str(Dict(pr[@"user"])[@"login"]) caseInsensitiveCompare:login] != NSOrderedSame) continue;
        rail::PullRequest mine; mine.id = C(Str(pr[@"number"])); mine.title = C(Str(pr[@"title"])); mine.url = C(Str(pr[@"html_url"]));
        mine.sourceBranch = C(Str(Dict(pr[@"head"])[@"ref"])); mine.targetBranch = C(Str(Dict(pr[@"base"])[@"ref"]));
        mine.draft = [pr[@"draft"] boolValue]; mine.autoComplete = Dict(pr[@"auto_merge"]) != nil; mine.createdAt = ISODate(Str(pr[@"created_at"]));
        for (id r in List(pr[@"requested_reviewers"])) mine.reviewers.push_back({C(Str(Dict(r)[@"login"])), "none", false});
        mine.detailsSHA = C(Str(Dict(pr[@"head"])[@"sha"]));
        result.myPullRequests.push_back(mine);
      }
      pending += (int)result.myPullRequests.size() * 3;
      for (size_t i = 0; i < result.myPullRequests.size(); i++) {
        NSString *number = S(result.myPullRequests[i].id), *sha = S(result.myPullRequests[i].detailsSHA);
        [strong gitHubGET:[NSString stringWithFormat:@"%@/commits/%@/check-runs?per_page=100", repoPath, sha] token:token done:^(id body, NSInteger status) {
          std::set<std::string> seen;
          if (status == 200) for (id c in List(Dict(body)[@"check_runs"])) {
            NSDictionary *run = Dict(c); if (!run || !seen.insert(C(Str(run[@"name"]))).second) continue;
            rail::PullRequestCheck check; check.kind = "build"; check.name = C(Str(run[@"name"])); check.url = C(Str(run[@"html_url"]));
            check.state = rail::githubCheckState(C(Str(run[@"status"])), C(Str(run[@"conclusion"]))); check.startedAt = ISODate(Str(run[@"started_at"]));
            result.myPullRequests[i].checks.push_back(check);
          }
          complete();
        }];
        [strong gitHubGET:[NSString stringWithFormat:@"%@/pulls/%@/reviews?per_page=100", repoPath, number] token:token done:^(id body, NSInteger status) {
          // The latest decisive review of each reviewer counts.
          std::map<std::string, std::string> votes;
          if (status == 200) for (id r in List(body)) {
            NSDictionary *review = Dict(r); NSString *state = Str(review[@"state"]); std::string who = C(Str(Dict(review[@"user"])[@"login"]));
            if (who.empty() || [Str(Dict(review[@"user"])[@"login"]) caseInsensitiveCompare:login] == NSOrderedSame) continue;
            if ([state isEqualToString:@"APPROVED"]) votes[who] = "approved";
            else if ([state isEqualToString:@"CHANGES_REQUESTED"]) votes[who] = "rejected";
            else if ([state isEqualToString:@"DISMISSED"]) votes[who] = "none";
          }
          auto &reviewers = result.myPullRequests[i].reviewers;
          for (const auto &[who, vote] : votes) {
            auto found = std::find_if(reviewers.begin(), reviewers.end(), [&](const rail::PullRequestReviewer &r) { return r.name == who; });
            if (found != reviewers.end()) found->vote = vote; else reviewers.push_back({who, vote, false});
          }
          complete();
        }];
        [strong gitHubGET:[NSString stringWithFormat:@"%@/pulls/%@", repoPath, number] token:token done:^(id body, NSInteger status) {
          if (status == 200) result.myPullRequests[i].conflicts = [Str(Dict(body)[@"mergeable_state"]) isEqualToString:@"dirty"];
          complete();
        }];
      }
      complete();
    }];
  }];
}
- (void)signInToGitHub:(NSString *)connectionID code:(void (^)(NSString *, NSString *))code done:(void (^)(NSString *, NSString *))done {
  NSString *client = self.gitHubClientID;
  if (!client.length) { done(nil, @"GitHub sign-in isn't set up yet. Register the Rail GitHub App and set its client ID (see README)."); return; }
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
        last->_sourceChecked.clear();
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
