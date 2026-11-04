#include "Projects.h"
#include "BrowserModel.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <iomanip>
#include <random>
#include <set>
#include <sstream>

namespace rail {

namespace {

std::string uniqueID(const char* kind) {
    static std::atomic<std::uint64_t> sequence{0};
    static thread_local std::mt19937_64 random{std::random_device{}()};
    std::ostringstream value;
    value << kind << '-' << std::hex << std::setfill('0')
          << std::setw(16) << random() << std::setw(16) << (random() ^ ++sequence);
    return value.str();
}

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

std::string trimmed(const std::string& value) {
    const auto begin = std::find_if_not(value.begin(), value.end(), [](unsigned char c) { return std::isspace(c); });
    const auto end = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char c) { return std::isspace(c); }).base();
    return begin < end ? std::string(begin, end) : std::string{};
}

bool safeID(const std::string& id) {
    return !id.empty() && id.size() <= 128 && std::all_of(id.begin(), id.end(), [](unsigned char c) {
        return std::isalnum(c) || c == '-' || c == '_';
    });
}

std::string percentDecoded(const std::string& value) {
    std::string out;
    for (std::size_t i = 0; i < value.size(); ++i) {
        if (value[i] == '%' && i + 2 < value.size() && std::isxdigit(static_cast<unsigned char>(value[i + 1])) && std::isxdigit(static_cast<unsigned char>(value[i + 2]))) {
            out += static_cast<char>(std::stoi(value.substr(i + 1, 2), nullptr, 16)); i += 2;
        } else out += value[i];
    }
    return out;
}

bool startsWith(const std::string& value, const std::string& prefix) { return value.compare(0, prefix.size(), prefix) == 0; }

struct ParsedURL {
    std::string scheme, host, port, path; // path without query or fragment, starts with "/" or is empty
    bool valid = false;
};

ParsedURL parse(const std::string& url) {
    ParsedURL out;
    const auto schemeEnd = url.find("://");
    if (schemeEnd == std::string::npos) return out;
    out.scheme = lower(url.substr(0, schemeEnd));
    if (out.scheme != "http" && out.scheme != "https") return out;
    const auto rest = url.substr(schemeEnd + 3);
    const auto authorityEnd = rest.find_first_of("/?#");
    auto authority = rest.substr(0, authorityEnd);
    if (const auto at = authority.rfind('@'); at != std::string::npos) authority = authority.substr(at + 1);
    if (!authority.empty() && authority.front() == '[') {
        const auto close = authority.find(']');
        if (close == std::string::npos) return out;
        out.host = lower(authority.substr(0, close + 1));
        if (close + 1 < authority.size() && authority[close + 1] == ':') out.port = authority.substr(close + 2);
    } else {
        const auto colon = authority.rfind(':');
        out.host = lower(authority.substr(0, colon));
        if (colon != std::string::npos) out.port = authority.substr(colon + 1);
    }
    if (out.host.empty() || !std::all_of(out.port.begin(), out.port.end(), [](unsigned char c) { return std::isdigit(c); }) || out.port.size() > 5) return out;
    if (authorityEnd != std::string::npos) {
        const auto tail = rest.substr(authorityEnd);
        out.path = tail.substr(0, tail.find_first_of("?#"));
    }
    out.valid = true;
    return out;
}

std::vector<std::string> segments(const std::string& path) {
    std::vector<std::string> parts;
    std::string part;
    std::istringstream stream(path);
    while (std::getline(stream, part, '/')) if (!part.empty()) parts.push_back(part);
    return parts;
}

template <typename Records>
void repairIDs(Records& records, const char* kind, std::set<std::string>& used) {
    for (auto& record : records) {
        if (!safeID(record.id) || used.count(record.id)) do { record.id = uniqueID(kind); } while (used.count(record.id));
        used.insert(record.id);
    }
}

int severity(Tone tone) {
    switch (tone) {
        case Tone::critical: return 0;
        case Tone::warn: return 1;
        case Tone::info: return 2;
        case Tone::ok: return 3;
        case Tone::neutral: return 4;
    }
    return 4;
}

std::string providerName(const std::string& provider) { return provider == "github" ? "GitHub" : "Azure DevOps"; }

} // namespace

std::string RepoRef::resource() const {
    return provider == "github" ? account + "/" + repo : account + "/" + project + "/" + repo;
}
std::string RepoRef::repoURL() const {
    return provider == "github" ? "https://github.com/" + account + "/" + repo
                                : "https://dev.azure.com/" + account + "/" + project + "/_git/" + repo;
}
std::string RepoRef::pipelinesURL() const {
    return provider == "github" ? repoURL() + "/actions" : "https://dev.azure.com/" + account + "/" + project + "/_build";
}

RepoRef recognizeRepo(const std::string& url) {
    const auto parsed = parse(trimmed(url));
    RepoRef out;
    if (!parsed.valid || parsed.scheme != "https") return out;
    const auto parts = segments(parsed.path);
    auto host = parsed.host;
    if (startsWith(host, "www.")) host = host.substr(4);
    if (host == "github.com" && parts.size() >= 2) {
        static const std::set<std::string> reserved = {"settings", "orgs", "organizations", "login", "logout", "marketplace", "features",
            "topics", "explore", "notifications", "pulls", "issues", "sponsors", "about", "enterprise", "apps", "collections",
            "search", "new", "codespaces", "users", "account", "dashboard", "trending", "security", "site", "contact", "pricing"};
        if (reserved.count(lower(parts[0]))) return out;
        auto repo = parts[1];
        if (repo.size() > 4 && repo.compare(repo.size() - 4, 4, ".git") == 0) repo.resize(repo.size() - 4);
        out = {"github", parts[0], "", repo};
    } else if (host == "dev.azure.com" && parts.size() >= 4 && parts[2] == "_git") {
        out = {"azureDevOps", parts[0], parts[1], parts[3]};
    } else if (host.size() > 17 && host.compare(host.size() - 17, 17, ".visualstudio.com") == 0) {
        const auto org = host.substr(0, host.size() - 17);
        std::size_t start = !parts.empty() && lower(parts[0]) == "defaultcollection" ? 1 : 0;
        if (parts.size() >= start + 3 && parts[start + 1] == "_git") out = {"azureDevOps", org, parts[start], parts[start + 2]};
    }
    return out;
}

bool isWebURL(const std::string& url) { return parse(url).valid; }
std::string hostOf(const std::string& url) { return parse(url).host; }
int portOf(const std::string& url) {
    const auto parsed = parse(url);
    if (!parsed.valid) return 0;
    if (!parsed.port.empty()) return std::stoi(parsed.port);
    return parsed.scheme == "https" ? 443 : 80;
}
std::string originOf(const std::string& url) {
    const auto parsed = parse(url);
    if (!parsed.valid) return {};
    return parsed.scheme + "://" + parsed.host + (parsed.port.empty() ? "" : ":" + parsed.port);
}
bool isLocalURL(const std::string& url) {
    const auto host = hostOf(url);
    return host == "localhost" || host == "[::1]" || startsWith(host, "127.")
        || (host.size() > 10 && host.compare(host.size() - 10, 10, ".localhost") == 0);
}
std::string joinURL(const std::string& base, const std::string& path) {
    const auto clean = trimmed(path);
    if (clean.empty()) return base;
    auto root = base;
    if (const auto cut = root.find_first_of("?#"); cut != std::string::npos) root.resize(cut);
    while (!root.empty() && root.back() == '/') root.pop_back();
    return root + (clean.front() == '/' ? clean : "/" + clean);
}

std::string sourceKey(const SourceBinding& binding) { return binding.connectionID + "|" + binding.resource; }

Health healthFromHTTP(int status, bool redirectedToOtherHost, int latencyMs) {
    if (status <= 0) return Health::down;
    if (redirectedToOtherHost || status == 401 || status == 403 || status == 407) return Health::loginRequired;
    if (status >= 500) return Health::down;
    return latencyMs > SlowMilliseconds ? Health::slow : Health::up;
}

std::string azureBuildResult(const std::string& status, const std::string& result) {
    if (status == "inProgress" || status == "cancelling") return "running";
    if (status == "notStarted" || status == "postponed") return "queued";
    if (result == "succeeded") return "succeeded";
    if (result == "partiallySucceeded") return "partial";
    if (result == "canceled") return "canceled";
    if (result == "failed") return "failed";
    return "unknown";
}

std::string githubRunResult(const std::string& status, const std::string& conclusion) {
    if (status == "in_progress") return "running";
    if (status != "completed") return "queued";
    if (conclusion == "success" || conclusion == "neutral" || conclusion == "skipped") return "succeeded";
    if (conclusion == "failure" || conclusion == "timed_out" || conclusion == "startup_failure") return "failed";
    if (conclusion == "cancelled" || conclusion == "stale") return "canceled";
    if (conclusion == "action_required") return "queued";
    return "unknown";
}

std::string githubCheckState(const std::string& status, const std::string& conclusion) {
    if (status == "in_progress") return "running";
    if (status != "completed") return "pending";
    if (conclusion == "skipped" || conclusion == "neutral") return "skipped";
    const auto run = githubRunResult(status, conclusion);
    return run == "canceled" || run == "unknown" ? "failed" : run == "queued" ? "pending" : run;
}

std::string azurePolicyState(const std::string& status) {
    if (status == "approved") return "succeeded";
    if (status == "rejected" || status == "broken") return "failed";
    if (status == "running") return "running";
    if (status == "notApplicable") return "skipped";
    return "pending";
}

std::string azureVote(int vote) {
    if (vote >= 5) return "approved";
    if (vote == -5) return "waiting";
    if (vote <= -10) return "rejected";
    return "none";
}

std::string githubMyRunResult(const std::string& status, const std::string& conclusion) {
    if (status == "waiting" || (status == "completed" && conclusion == "action_required")) return "waiting";
    return githubRunResult(status, conclusion);
}
int sourcePollSeconds(const SourceStatus& source) {
    for (const auto& run : source.myRuns) if (run.result == "running" || run.result == "queued") return RunningPollSeconds;
    for (const auto& pr : source.myPullRequests) {
        const auto checks = pullRequestChecks(pr);
        if (checks == "running" || checks == "pending") return RunningPollSeconds;
    }
    return IdlePollSeconds;
}
std::string statusSignature(const StatusSnapshot& status) {
    std::string out;
    for (const auto& [id, environment] : status.environments) out += id + '=' + std::to_string(static_cast<int>(environment.health)) + environment.version + ';';
    for (const auto& [id, connection] : status.connections) out += id + '=' + std::to_string(static_cast<int>(connection.access)) + (connection.throttled ? "t" : "") + ';';
    for (const auto& [key, source] : status.sources) {
        out += key + '=' + source.error + (source.notCovered ? "n" : "") + std::to_string(source.openPullRequests) + ';';
        for (const auto& run : source.runs) out += run.name + run.number + run.result + ',';
        for (const auto& run : source.myRuns) out += run.id + run.result + ',';
        for (const auto& pr : source.myPullRequests) {
            out += pr.id + pr.title + (pr.conflicts ? "c" : "") + (pr.draft ? "d" : "") + std::to_string(pr.openThreads) + ',';
            for (const auto& check : pr.checks) out += check.name + check.state + ',';
            for (const auto& reviewer : pr.reviewers) out += reviewer.name + reviewer.vote + ',';
        }
    }
    return out;
}
std::string pullRequestChecks(const PullRequest& pr) {
    bool any = false, running = false, pending = false;
    for (const auto& check : pr.checks) {
        if (check.kind != "build" || !check.blocking) continue;
        any = true;
        if (check.state == "failed") return "failed";
        running = running || check.state == "running";
        pending = pending || check.state == "pending";
    }
    return !any ? "none" : running ? "running" : pending ? "pending" : "succeeded";
}

namespace {
bool hasPolicies(const PullRequest& pr) {
    return std::any_of(pr.checks.begin(), pr.checks.end(), [](const PullRequestCheck& c) { return c.kind == "policy"; });
}
const PullRequestCheck* failedCheck(const PullRequest& pr) {
    for (const auto& check : pr.checks) if (check.blocking && check.state == "failed" && check.kind == "build") return &check;
    for (const auto& check : pr.checks) if (check.blocking && check.state == "failed") return &check;
    return nullptr;
}
const PullRequestReviewer* blockingReviewer(const PullRequest& pr) {
    for (const auto& reviewer : pr.reviewers) if (reviewer.vote == "rejected" || reviewer.vote == "waiting") return &reviewer;
    return nullptr;
}
bool allBlockingPass(const PullRequest& pr) {
    return std::all_of(pr.checks.begin(), pr.checks.end(), [](const PullRequestCheck& c) {
        return !c.blocking || c.state == "succeeded" || c.state == "skipped";
    });
}
bool approved(const PullRequest& pr) {
    if (hasPolicies(pr)) return true; // the reviewer policies already decide
    return std::any_of(pr.reviewers.begin(), pr.reviewers.end(), [](const PullRequestReviewer& r) { return r.vote == "approved"; });
}
} // namespace

PullRequestStage pullRequestStage(const PullRequest& pr) {
    if (pr.conflicts || failedCheck(pr) || blockingReviewer(pr) || pr.openThreads > 0) return PullRequestStage::needsYou;
    if (!pr.draft && allBlockingPass(pr) && approved(pr)) return PullRequestStage::ready;
    return PullRequestStage::waiting;
}

std::string pullRequestReason(const PullRequest& pr) {
    if (pr.conflicts) return "Merge conflicts";
    if (const auto* check = failedCheck(pr)) return check->name + " failed";
    if (const auto* reviewer = blockingReviewer(pr))
        return reviewer->name + (reviewer->vote == "waiting" ? " is waiting for you" : hasPolicies(pr) ? " rejected" : " requested changes");
    if (pr.openThreads > 0) return std::to_string(pr.openThreads) + (pr.openThreads == 1 ? " open thread" : " open threads");
    if (pr.draft) return "Draft";
    const auto checks = pullRequestChecks(pr);
    if (checks == "running") return "Checks running";
    if (checks == "pending") return "Checks pending";
    if (pullRequestStage(pr) == PullRequestStage::ready) return "Ready to merge";
    const auto required = std::count_if(pr.reviewers.begin(), pr.reviewers.end(), [](const PullRequestReviewer& r) { return r.required; });
    const auto counted = required ? required : static_cast<long>(pr.reviewers.size());
    const auto approvals = std::count_if(pr.reviewers.begin(), pr.reviewers.end(), [&](const PullRequestReviewer& r) { return r.vote == "approved" && (r.required || !required); });
    if (counted > 0 && approvals < counted) return std::to_string(approvals) + " of " + std::to_string(counted) + " approved";
    if (!allBlockingPass(pr)) {
        for (const auto& check : pr.checks) if (check.blocking && check.state != "succeeded" && check.state != "skipped") return check.name;
    }
    return "Needs review";
}

Access azureAccess(int status, const std::string& location, const std::string& mime, const std::string& displayName) {
    const auto where = lower(location);
    if (status == 401 || status == 403 || status == 203) return Access::signedOut;
    if (status >= 300 && status < 400) {
        return where.find("_signin") != std::string::npos || where.find("login.microsoftonline") != std::string::npos
            || where.find("vssps.visualstudio.com") != std::string::npos ? Access::signedOut : Access::unknown;
    }
    if (status >= 200 && status < 300) {
        if (lower(mime).find("json") == std::string::npos) return Access::signedOut;
        return displayName.empty() || displayName == "Anonymous" ? Access::signedOut : Access::signedIn;
    }
    return Access::unknown;
}

std::vector<Attention> attentionFor(const Project& project, const ProjectsState& state, const StatusSnapshot& status) {
    std::vector<Attention> out;
    for (const auto& environment : project.environments) {
        const auto found = status.environments.find(environment.id);
        if (found == status.environments.end()) continue;
        const auto& health = found->second;
        if (health.health == Health::down && !isLocalURL(environment.url)) {
            out.push_back({Tone::critical, environment.name + " is down", health.error.empty() ? "No response" : health.error, "openEnvironment", environment.id});
        } else if (health.health == Health::slow && health.slowStreak >= 2) {
            std::ostringstream detail;
            detail << std::fixed << std::setprecision(1) << health.latencyMs / 1000.0 << " s response time";
            out.push_back({Tone::warn, environment.name + " responds slowly", detail.str(), "openEnvironment", environment.id});
        }
    }
    std::set<std::string> connectionsShown;
    for (const auto& binding : project.sources) {
        const Connection* owner = nullptr;
        for (const auto& connection : state.connections) if (connection.id == binding.connectionID) owner = &connection;
        if (!owner) continue;
        const auto access = status.connections.find(owner->id);
        if (access != status.connections.end() && (access->second.access == Access::signedOut || access->second.access == Access::rejected)) {
            if (connectionsShown.insert(owner->id).second) {
                const auto account = owner->provider == "github" ? std::string("GitHub") : owner->account;
                out.push_back({Tone::warn, access->second.access == Access::rejected ? providerName(owner->provider) + " sign-in expired"
                                                                                     : "Sign in to " + providerName(owner->provider),
                               "Needed to show pipelines and pull requests for " + account, "signIn", owner->id});
            }
            continue;
        }
        const auto found = status.sources.find(sourceKey(binding));
        if (found == status.sources.end()) continue;
        const auto& source = found->second;
        if (source.notCovered) {
            out.push_back({Tone::warn, "Rail can't see " + binding.resource, "Add the repository to the GitHub App installation", "openInstallations", owner->id});
            continue;
        }
        // runs holds the latest run of each pipeline on the default branch.
        for (const auto& run : source.runs) {
            if (run.result != "failed" && run.result != "partial") continue;
            out.push_back({run.result == "failed" ? Tone::critical : Tone::warn,
                           run.result == "failed" ? "Pipeline failed" : "Pipeline partly failed",
                           run.name + (run.number.empty() ? "" : " #" + run.number) + " on " + run.branch, "openRun", run.url});
        }
    }
    std::stable_sort(out.begin(), out.end(), [](const Attention& a, const Attention& b) { return severity(a.tone) < severity(b.tone); });
    return out;
}

Project* Projects::project(const std::string& id) {
    for (auto& item : state.projects) if (item.id == id) return &item;
    return nullptr;
}
const Project* Projects::project(const std::string& id) const { return const_cast<Projects*>(this)->project(id); }
Connection* Projects::connection(const std::string& id) {
    for (auto& item : state.connections) if (item.id == id) return &item;
    return nullptr;
}
const Connection* Projects::connection(const std::string& id) const { return const_cast<Projects*>(this)->connection(id); }

std::vector<const Project*> Projects::inSpace(const std::string& spaceID) const {
    std::vector<const Project*> out;
    for (const auto& item : state.projects) if (item.spaceID == spaceID) out.push_back(&item);
    std::stable_sort(out.begin(), out.end(), [](const Project* a, const Project* b) { return a->order < b->order; });
    return out;
}

std::string Projects::isolatedProfileFor(const std::string& ownerID) { return "isolated-" + ownerID; }

std::string Projects::addProject(const std::string& name, const std::string& spaceID, const std::string& repoURL, const std::string& sessionID) {
    Project item;
    item.id = uniqueID("project");
    item.spaceID = spaceID;
    int last = -1;
    for (const auto* other : inSpace(spaceID)) last = std::max(last, other->order);
    item.order = last + 1;
    const auto repo = recognizeRepo(repoURL);
    item.name = trimmed(name).empty() ? (repo ? percentDecoded(repo.repo) : std::string("Project")) : trimmed(name);
    if (repo) {
        item.links.push_back({uniqueID("link"), "repo", "Repo", repo.repoURL(), sessionID, ""});
        item.links.push_back({uniqueID("link"), "pipelines", repo.provider == "github" ? "Actions" : "Pipelines", repo.pipelinesURL(), sessionID, ""});
    } else if (isWebURL(trimmed(repoURL))) {
        item.links.push_back({uniqueID("link"), "repo", "Repo", trimmed(repoURL), sessionID, ""});
    }
    state.projects.push_back(item);
    bindSources(item.id);
    return item.id;
}

std::string Projects::addEnvironment(const std::string& projectID, const std::string& name, const std::string& url,
                                     const std::string& sessionID, const std::string& healthPath) {
    auto* owner = project(projectID);
    const auto address = trimmed(url);
    if (!owner || !isWebURL(address)) return {};
    Environment item{uniqueID("env"), trimmed(name), address, trimmed(healthPath), sessionID};
    if (item.name.empty()) item.name = suggestedEnvironmentName(address);
    if (item.sessionID == "__isolated__") item.sessionID = isolatedProfileFor(item.id);
    // Local first, then remotes in the order they were added.
    auto at = owner->environments.end();
    if (isLocalURL(address)) at = std::find_if(owner->environments.begin(), owner->environments.end(), [](const Environment& e) { return !isLocalURL(e.url); });
    owner->environments.insert(at, item);
    return item.id;
}

std::string Projects::addLink(const std::string& projectID, const std::string& kind, const std::string& label,
                              const std::string& url, const std::string& sessionID, const std::string& environmentID) {
    auto* owner = project(projectID);
    const auto address = trimmed(url);
    if (!owner || !isWebURL(address)) return {};
    ProjectLink item{uniqueID("link"), kind == "repo" || kind == "pipelines" ? kind : "custom", trimmed(label), address, sessionID, environmentID};
    if (item.label.empty()) item.label = item.kind == "repo" ? "Repo" : item.kind == "pipelines" ? "Pipelines" : hostOf(address);
    if (item.sessionID == "__isolated__") item.sessionID = isolatedProfileFor(item.id);
    owner->links.push_back(item);
    if (item.kind == "repo") bindSources(projectID);
    return item.id;
}

bool Projects::updateEnvironment(const std::string& projectID, const Environment& changed) {
    auto* owner = project(projectID);
    if (!owner || !isWebURL(trimmed(changed.url))) return false;
    for (auto& item : owner->environments) if (item.id == changed.id) {
        item.name = trimmed(changed.name).empty() ? suggestedEnvironmentName(changed.url) : trimmed(changed.name);
        item.url = trimmed(changed.url); item.healthPath = trimmed(changed.healthPath);
        item.sessionID = changed.sessionID == "__isolated__" ? isolatedProfileFor(item.id) : changed.sessionID;
        return true;
    }
    return false;
}

bool Projects::updateLink(const std::string& projectID, const ProjectLink& changed) {
    auto* owner = project(projectID);
    if (!owner || !isWebURL(trimmed(changed.url))) return false;
    for (auto& item : owner->links) if (item.id == changed.id) {
        item.label = trimmed(changed.label).empty() ? item.label : trimmed(changed.label);
        item.url = trimmed(changed.url); item.environmentID = changed.environmentID;
        item.sessionID = changed.sessionID == "__isolated__" ? isolatedProfileFor(item.id) : changed.sessionID;
        if (item.kind == "repo") bindSources(projectID);
        return true;
    }
    return false;
}

bool Projects::removeEnvironment(const std::string& projectID, const std::string& environmentID) {
    auto* owner = project(projectID);
    if (!owner) return false;
    const auto before = owner->environments.size();
    owner->environments.erase(std::remove_if(owner->environments.begin(), owner->environments.end(), [&](const Environment& e) { return e.id == environmentID; }), owner->environments.end());
    for (auto& link : owner->links) if (link.environmentID == environmentID) link.environmentID.clear();
    return owner->environments.size() != before;
}

bool Projects::removeLink(const std::string& projectID, const std::string& linkID) {
    auto* owner = project(projectID);
    if (!owner) return false;
    const auto before = owner->links.size();
    owner->links.erase(std::remove_if(owner->links.begin(), owner->links.end(), [&](const ProjectLink& l) { return l.id == linkID; }), owner->links.end());
    bindSources(projectID);
    return owner->links.size() != before;
}

bool Projects::removeProject(const std::string& projectID) {
    const auto before = state.projects.size();
    state.projects.erase(std::remove_if(state.projects.begin(), state.projects.end(), [&](const Project& p) { return p.id == projectID; }), state.projects.end());
    return state.projects.size() != before;
}

bool Projects::renameProject(const std::string& projectID, const std::string& name) {
    auto* owner = project(projectID);
    if (!owner || trimmed(name).empty()) return false;
    owner->name = trimmed(name);
    return true;
}

bool Projects::moveProject(const std::string& projectID, const std::string& spaceID) {
    auto* owner = project(projectID);
    if (!owner || owner->spaceID == spaceID) return false;
    int last = -1;
    for (const auto* other : inSpace(spaceID)) last = std::max(last, other->order);
    owner->spaceID = spaceID;
    owner->order = last + 1;
    return true;
}

bool Projects::reorderProject(const std::string& projectID, int offset) {
    auto* owner = project(projectID);
    if (!owner) return false;
    auto list = inSpace(owner->spaceID);
    const auto at = std::find(list.begin(), list.end(), owner) - list.begin();
    const auto target = at + offset;
    if (target < 0 || target >= static_cast<long>(list.size())) return false;
    std::vector<std::string> ids;
    for (const auto* item : list) ids.push_back(item->id);
    std::swap(ids[at], ids[target]);
    for (std::size_t index = 0; index < ids.size(); ++index) project(ids[index])->order = static_cast<int>(index);
    return true;
}

std::string Projects::projectForRepo(const RepoRef& repo) const {
    if (!repo) return {};
    for (const auto& item : state.projects) for (const auto& link : item.links) {
        const auto other = recognizeRepo(link.url);
        if (link.kind == "repo" && other && other.provider == repo.provider && lower(other.resource()) == lower(repo.resource())) return item.id;
    }
    return {};
}

std::string Projects::accessSession(const Project& item) const {
    for (const auto& link : item.links) if (link.kind == "repo") return link.sessionID;
    if (!item.links.empty()) return item.links.front().sessionID;
    if (!item.environments.empty()) return item.environments.front().sessionID;
    return {};
}

std::string Projects::ensureConnection(const std::string& provider, const std::string& account, const std::string& sessionID) {
    for (const auto& item : state.connections) {
        if (item.provider != provider || item.sessionID != sessionID) continue;
        if (provider == "github" || lower(item.account) == lower(account)) return item.id;
    }
    Connection item{uniqueID("connection"), provider, provider == "github" ? "" : account,
                    provider == "github" ? "deviceToken" : "session", sessionID};
    state.connections.push_back(item);
    return item.id;
}

void Projects::bindSources(const std::string& projectID) {
    auto* owner = project(projectID);
    if (!owner) return;
    const auto session = accessSession(*owner);
    std::vector<SourceBinding> sources;
    for (const auto& link : owner->links) {
        if (link.kind != "repo") continue;
        const auto repo = recognizeRepo(link.url);
        if (!repo || session.empty()) continue;
        sources.push_back({ensureConnection(repo.provider, repo.account, session), repo.resource()});
    }
    owner->sources = sources;
}

std::vector<std::string> Projects::ownedProfiles() const {
    std::vector<std::string> out;
    for (const auto& item : state.projects) {
        for (const auto& e : item.environments) if (BrowserModel::isIsolatedSession(e.sessionID)) out.push_back(e.sessionID);
        for (const auto& l : item.links) if (BrowserModel::isIsolatedSession(l.sessionID)) out.push_back(l.sessionID);
    }
    return out;
}

std::string Projects::suggestedEnvironmentName(const std::string& url) {
    if (isLocalURL(url)) return "Local";
    const auto host = hostOf(url);
    static const std::vector<std::pair<std::string, std::string>> known = {
        {"prod", "PROD"}, {"production", "PROD"}, {"int", "INT"}, {"integration", "INT"}, {"staging", "Staging"}, {"stage", "Staging"},
        {"stg", "Staging"}, {"preview", "Preview"}, {"dev", "DEV"}, {"test", "TEST"}, {"qa", "QA"}, {"uat", "UAT"}};
    std::string label;
    std::istringstream stream(host);
    std::vector<std::string> words;
    while (std::getline(stream, label, '.')) {
        std::string word;
        for (char c : label) { if (c == '-' || c == '_') { words.push_back(word); word.clear(); } else word += c; }
        words.push_back(word);
    }
    for (const auto& word : words) for (const auto& [match, name] : known) if (word == match) return name;
    const auto first = host.substr(0, host.find('.'));
    return first.empty() ? std::string("Environment") : first;
}

void Projects::sanitize(const BrowserModel& browser) {
    const auto sessionKnown = [&](const std::string& id) { return browser.session(id) != nullptr || BrowserModel::isIsolatedSession(id); };
    std::set<std::string> used;
    repairIDs(state.connections, "connection", used);
    state.connections.erase(std::remove_if(state.connections.begin(), state.connections.end(), [&](const Connection& c) {
        const bool provider = c.provider == "azureDevOps" || c.provider == "github";
        const bool auth = c.auth == "session" || c.auth == "deviceToken" || c.auth == "token";
        return !provider || !auth || !sessionKnown(c.sessionID) || (c.provider == "azureDevOps" && trimmed(c.account).empty());
    }), state.connections.end());
    repairIDs(state.projects, "project", used);
    for (auto& item : state.projects) {
        if (!browser.space(item.spaceID)) item.spaceID = browser.state.spaces.front().id;
        const auto fallback = browser.space(item.spaceID)->sessionID;
        if (trimmed(item.name).empty()) item.name = "Project";
        repairIDs(item.environments, "env", used);
        item.environments.erase(std::remove_if(item.environments.begin(), item.environments.end(), [](const Environment& e) { return !isWebURL(e.url); }), item.environments.end());
        for (auto& e : item.environments) {
            if (trimmed(e.name).empty()) e.name = suggestedEnvironmentName(e.url);
            if (!sessionKnown(e.sessionID)) e.sessionID = fallback;
        }
        repairIDs(item.links, "link", used);
        item.links.erase(std::remove_if(item.links.begin(), item.links.end(), [](const ProjectLink& l) { return !isWebURL(l.url); }), item.links.end());
        for (auto& l : item.links) {
            if (l.kind != "repo" && l.kind != "pipelines") l.kind = "custom";
            if (trimmed(l.label).empty()) l.label = l.kind == "repo" ? "Repo" : l.kind == "pipelines" ? "Pipelines" : hostOf(l.url);
            if (!sessionKnown(l.sessionID)) l.sessionID = fallback;
            if (!l.environmentID.empty() && std::none_of(item.environments.begin(), item.environments.end(), [&](const Environment& e) { return e.id == l.environmentID; })) l.environmentID.clear();
        }
        item.sources.erase(std::remove_if(item.sources.begin(), item.sources.end(), [&](const SourceBinding& b) { return !connection(b.connectionID) || trimmed(b.resource).empty(); }), item.sources.end());
    }
    for (const auto& space : browser.state.spaces) {
        int order = 0;
        for (const auto* item : inSpace(space.id)) project(item->id)->order = order++;
    }
}

} // namespace rail
