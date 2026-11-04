#pragma once

#include <map>
#include <string>
#include <vector>

namespace rail {

class BrowserModel;

// A place where a project runs: Local, INT, Staging, PROD… Local or remote is derived from the URL.
struct Environment {
    std::string id;
    std::string name;
    std::string url;
    std::string healthPath;  // optional, e.g. "/healthz"; empty checks url itself
    std::string sessionID;   // a named session or an isolated profile; always concrete
};

// A button on the card that only opens: Repo, Pipelines, or any custom URL (LaunchDarkly, Grafana…).
struct ProjectLink {
    std::string id;
    std::string kind;          // "repo" | "pipelines" | "custom"
    std::string label;
    std::string url;
    std::string sessionID;
    std::string environmentID; // optional: a custom link that belongs to one environment
};

// Where pipeline and pull request status comes from.
struct SourceBinding {
    std::string connectionID;
    std::string resource;      // GitHub "owner/repo"; Azure DevOps "org/project/repo"
};

struct Project {
    std::string id;
    std::string name;
    std::string spaceID;       // exactly one Space; its home shows the card
    int order = 0;
    std::vector<Environment> environments;
    std::vector<ProjectLink> links;
    std::vector<SourceBinding> sources;
};

// One provider account in one session, shared by projects. Tokens live in the Keychain only.
struct Connection {
    std::string id;
    std::string provider;      // "azureDevOps" | "github"
    std::string account;       // Azure DevOps organization, or the GitHub login once signed in
    std::string auth;          // "session" | "deviceToken" | "token"
    std::string sessionID;     // whose login this uses, or where the device sign-in happened
};

struct ProjectsState {
    std::vector<Connection> connections;
    std::vector<Project> projects;
};

// A recognized repository page.
struct RepoRef {
    std::string provider;      // "" when the URL is not a repo page
    std::string account;       // GitHub owner or Azure DevOps organization
    std::string project;       // Azure DevOps project; empty for GitHub
    std::string repo;
    std::string resource() const;
    std::string repoURL() const;
    std::string pipelinesURL() const;
    explicit operator bool() const { return !provider.empty(); }
};
RepoRef recognizeRepo(const std::string& url);

// URL helpers. Only http and https URLs with a host count.
bool isWebURL(const std::string& url);
std::string hostOf(const std::string& url);
int portOf(const std::string& url);     // explicit port, else 80/443 by scheme
std::string originOf(const std::string& url);
bool isLocalURL(const std::string& url);
std::string joinURL(const std::string& base, const std::string& path);

// Live status. Never saved.
enum class Health { unknown, up, slow, down, notRunning, loginRequired };
enum class Access { unknown, signedIn, signedOut, rejected, notCovered };

struct EnvironmentStatus {
    Health health = Health::unknown;
    int latencyMs = 0;
    std::string version;
    double checkedAt = 0;
    std::string error;
    int slowStreak = 0;
};

struct PipelineRun {
    std::string name, number, branch, result, url; // result: succeeded|failed|running|canceled|queued, and waiting for runs in myRuns
    double finishedAt = 0;
    std::string id, definitionID;    // set for runs in myRuns
    double startedAt = 0;
};

// A required step on the way to merge: a build or status check, or (Azure DevOps) a branch policy.
struct PullRequestCheck {
    std::string kind;                // "build" | "policy"
    std::string name;
    std::string state;               // succeeded|failed|running|pending|skipped
    std::string detail;
    std::string url;
    bool blocking = true;
    double startedAt = 0;
};

struct PullRequestReviewer {
    std::string name;
    std::string vote;                // approved|waiting|rejected|none
    bool required = false;
};

// One of the user's own open pull requests.
struct PullRequest {
    std::string id;                  // provider number
    std::string title, url, sourceBranch, targetBranch;
    bool draft = false, conflicts = false, autoComplete = false;
    double createdAt = 0;
    int openThreads = -1;            // -1 = unknown
    std::vector<PullRequestCheck> checks;
    std::vector<PullRequestReviewer> reviewers;
    std::string detailsSHA;          // the head commit whose checks apply
};

enum class PullRequestStage { needsYou, waiting, ready };
// Overall state of the build checks: failed|running|pending|succeeded|none.
std::string pullRequestChecks(const PullRequest& pr);
PullRequestStage pullRequestStage(const PullRequest& pr);
// A short reason for the stage, such as "billing-ci failed" or "1 of 2 approved".
std::string pullRequestReason(const PullRequest& pr);

struct SourceStatus {
    std::vector<PipelineRun> runs;   // latest run of each pipeline on the default branch, newest first
    std::vector<PullRequest> myPullRequests; // open pull requests created by the connection's user
    bool myPullRequestsKnown = false;
    std::vector<PipelineRun> myRuns; // latest run of each pipeline the connection's user started by hand, on any branch
    int openPullRequests = -1;       // -1 = unknown
    std::string defaultBranch;
    std::string pullRequestsURL;
    double checkedAt = 0;
    double readAt = 0;               // the last check that returned without an error
    std::string error;
    bool notCovered = false;         // GitHub: no installation can see the repo
};

struct ConnectionStatus {
    Access access = Access::unknown;
    std::string account;             // as the provider reports it
    std::string userID;              // Azure DevOps: the signed-in identity, to find the user's own pull requests
    std::string error;
    bool throttled = false;          // the provider asked Rail to slow down
};

struct StatusSnapshot {
    std::map<std::string, EnvironmentStatus> environments; // by environment ID
    std::map<std::string, SourceStatus> sources;           // by sourceKey()
    std::map<std::string, ConnectionStatus> connections;   // by connection ID
};
std::string sourceKey(const SourceBinding& binding);

// Thresholds and mappings, kept pure so they can be tested without a network.
constexpr int SlowMilliseconds = 1000;
Health healthFromHTTP(int status, bool redirectedToOtherHost, int latencyMs);
std::string azureBuildResult(const std::string& status, const std::string& result);
std::string githubRunResult(const std::string& status, const std::string& conclusion);
std::string githubCheckState(const std::string& status, const std::string& conclusion);
// A run the user started: like githubRunResult, but it tells apart a run held for approval.
std::string githubMyRunResult(const std::string& status, const std::string& conclusion);
std::string azurePolicyState(const std::string& status);
std::string azureVote(int vote);
// Seconds between checks of a source: short while something of the user's is running.
constexpr int RunningPollSeconds = 20, IdlePollSeconds = 115;
int sourcePollSeconds(const SourceStatus& source);
// Everything the pages show from a snapshot, without timings, to tell whether a check changed anything.
std::string statusSignature(const StatusSnapshot& status);
// What an Azure DevOps response in a session says about its login.
Access azureAccess(int status, const std::string& location, const std::string& mime, const std::string& displayName);

enum class Tone { neutral, info, ok, warn, critical };
struct Attention {
    Tone tone = Tone::neutral;
    std::string title;
    std::string detail;
    std::string action;        // "signIn" | "openRun" | "openEnvironment" | "openInstallations" | ""
    std::string target;        // connection ID, URL, or environment ID
};
// What needs attention on one card, most severe first.
std::vector<Attention> attentionFor(const Project& project, const ProjectsState& state, const StatusSnapshot& status);

class Projects {
public:
    ProjectsState state;

    Project* project(const std::string& id);
    const Project* project(const std::string& id) const;
    Connection* connection(const std::string& id);
    const Connection* connection(const std::string& id) const;
    std::vector<const Project*> inSpace(const std::string& spaceID) const;

    // Fills Repo and Pipelines links and a source binding when repoURL is a recognized repository.
    std::string addProject(const std::string& name, const std::string& spaceID,
                           const std::string& repoURL, const std::string& sessionID);
    std::string addEnvironment(const std::string& projectID, const std::string& name, const std::string& url,
                               const std::string& sessionID, const std::string& healthPath = "");
    std::string addLink(const std::string& projectID, const std::string& kind, const std::string& label,
                        const std::string& url, const std::string& sessionID, const std::string& environmentID = "");
    bool updateEnvironment(const std::string& projectID, const Environment& changed);
    bool updateLink(const std::string& projectID, const ProjectLink& changed);
    bool removeEnvironment(const std::string& projectID, const std::string& environmentID);
    bool removeLink(const std::string& projectID, const std::string& linkID);
    bool removeProject(const std::string& projectID);
    bool renameProject(const std::string& projectID, const std::string& name);
    bool moveProject(const std::string& projectID, const std::string& spaceID);
    bool reorderProject(const std::string& projectID, int offset);
    // The project that already uses this repository, in any Space.
    std::string projectForRepo(const RepoRef& repo) const;

    // The session a project is accessed as: its Repo link's, else its first environment's.
    std::string accessSession(const Project& project) const;
    // Points every source of a project at the connection for its repo and access session.
    void bindSources(const std::string& projectID);
    std::string ensureConnection(const std::string& provider, const std::string& account, const std::string& sessionID);
    std::vector<std::string> ownedProfiles() const;

    // Repairs loaded data against the browser's Spaces and sessions.
    void sanitize(const BrowserModel& browser);

    static std::string isolatedProfileFor(const std::string& ownerID);
    // Name suggested for an environment created from a tab.
    static std::string suggestedEnvironmentName(const std::string& url);
};

} // namespace rail
