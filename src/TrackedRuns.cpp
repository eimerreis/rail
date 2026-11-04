#include "TrackedRuns.h"

#include <algorithm>

namespace rail {

namespace {
bool finished(RunState state) { return state == RunState::failed || state == RunState::passed; }
bool isListed(const TrackedRun& run, double now) {
    if (run.cleared) return false;
    if (run.state == RunState::running || run.state == RunState::waiting) return true;
    if (run.state == RunState::failed && !run.acknowledged) return true;
    return now - run.changedAt < TrackedRuns::KeptSeconds;
}
int rank(const TrackedRun& run) {
    if (run.state == RunState::failed && !run.acknowledged) return 0;
    return run.state == RunState::waiting ? 1 : run.state == RunState::running ? 2 : 3;
}
void copyDescriptors(TrackedRun& to, const TrackedRun& from) {
    to.sourceKey = from.sourceKey; to.kind = from.kind; to.title = from.title; to.project = from.project; to.spaceID = from.spaceID;
    to.sessionID = from.sessionID; to.number = from.number; to.url = from.url; to.pageURL = from.pageURL; to.startedAt = from.startedAt;
}
}

std::vector<TrackedRun> TrackedRuns::observe(const std::vector<RunObservation>& observations, const std::set<std::string>& readSources, double now) {
    std::vector<TrackedRun> announcements;
    std::set<std::string> seen;
    for (const auto& observation : observations) {
        const auto& incoming = observation.run;
        if (!readSources.count(incoming.sourceKey)) continue;
        seen.insert(incoming.key);
        const bool quiet = !checkedSinceLaunch_.count(incoming.sourceKey);
        auto known = std::find_if(runs.begin(), runs.end(), [&](const TrackedRun& run) { return run.key == incoming.key; });
        if (observation.stopped) { if (known != runs.end()) runs.erase(known); continue; }
        if (observation.noChecks) {
            if (known != runs.end() && known->revision != incoming.revision) runs.erase(known);
            continue;
        }
        if (known != runs.end() && known->state == incoming.state && known->revision == incoming.revision) {
            copyDescriptors(*known, incoming);
            continue;
        }
        const bool isNew = known == runs.end();
        if (isNew) { runs.push_back(incoming); known = runs.end() - 1; }
        else { copyDescriptors(*known, incoming); known->state = incoming.state; known->revision = incoming.revision; }
        known->changedAt = observation.finishedAt > 0 && quiet ? observation.finishedAt : now;
        known->acknowledged = false; known->passedSeen = false;
        // Remembered without showing, so a later check doesn't take it for news.
        const bool old = observation.finishedAt > 0 && now - observation.finishedAt >= KeptSeconds;
        known->cleared = isNew && finished(incoming.state) && old;
        if (quiet) {
            if (incoming.state == RunState::passed) known->cleared = true;
        } else if (incoming.state != RunState::running && !known->cleared) {
            announcements.push_back(*known);
        }
    }
    runs.erase(std::remove_if(runs.begin(), runs.end(), [&](const TrackedRun& run) {
        if (!readSources.count(run.sourceKey) || seen.count(run.key)) return false;
        if (run.kind == "pipeline" && run.state == RunState::failed && !run.acknowledged) return false;
        return !(run.state == RunState::passed && isListed(run, now));
    }), runs.end());
    checkedSinceLaunch_.insert(readSources.begin(), readSources.end());
    return announcements;
}

bool TrackedRuns::keepOnlySources(const std::set<std::string>& sources) {
    const auto before = runs.size();
    runs.erase(std::remove_if(runs.begin(), runs.end(), [&](const TrackedRun& run) { return !sources.count(run.sourceKey); }), runs.end());
    return runs.size() != before;
}

bool TrackedRuns::acknowledge(const std::string& key) {
    for (auto& run : runs) if (run.key == key && run.state == RunState::failed && !run.acknowledged) { run.acknowledged = true; return true; }
    return false;
}

bool TrackedRuns::clearFinished() {
    bool changed = false;
    for (auto& run : runs) {
        if (run.cleared || !(run.state == RunState::passed || (run.state == RunState::failed && run.acknowledged))) continue;
        run.cleared = true; changed = true;
    }
    return changed;
}

bool TrackedRuns::markPassedSeen() {
    bool changed = false;
    for (auto& run : runs) if (run.state == RunState::passed && !run.passedSeen) { run.passedSeen = true; changed = true; }
    return changed;
}

const TrackedRun* TrackedRuns::run(const std::string& key) const {
    auto found = std::find_if(runs.begin(), runs.end(), [&](const TrackedRun& run) { return run.key == key; });
    return found == runs.end() ? nullptr : &*found;
}

std::vector<TrackedRun> TrackedRuns::listed(double now) const {
    std::vector<TrackedRun> out;
    for (const auto& run : runs) if (isListed(run, now)) out.push_back(run);
    std::stable_sort(out.begin(), out.end(), [](const TrackedRun& a, const TrackedRun& b) { return rank(a) != rank(b) ? rank(a) < rank(b) : a.changedAt > b.changedAt; });
    return out;
}

RunCounts TrackedRuns::counts(double now) const {
    RunCounts counts;
    for (const auto& run : runs) {
        if (!isListed(run, now)) continue;
        if (run.state == RunState::running) counts.running++;
        else if (run.state == RunState::waiting) counts.waiting++;
        else if (run.state == RunState::failed) counts.failed += run.acknowledged ? 0 : 1;
        else counts.passed += run.passedSeen ? 0 : 1;
    }
    return counts;
}

std::vector<TrackedRun> TrackedRuns::changedSince(double when) const {
    std::vector<TrackedRun> out;
    for (const auto& run : runs) if (!run.cleared && run.changedAt >= when) out.push_back(run);
    return out;
}

std::vector<RunObservation> observeRuns(const Projects& projects, const StatusSnapshot& status) {
    std::vector<RunObservation> out;
    std::set<std::string> done;
    for (const auto& project : projects.state.projects) for (const auto& binding : project.sources) {
        const auto key = sourceKey(binding);
        auto source = status.sources.find(key);
        if (source == status.sources.end() || !done.insert(key).second) continue;
        const bool github = std::count(binding.resource.begin(), binding.resource.end(), '/') == 1;
        TrackedRun common;
        common.sourceKey = key; common.project = project.name; common.spaceID = project.spaceID; common.sessionID = projects.accessSession(project);
        for (const auto& pr : source->second.myPullRequests) {
            RunObservation observation; observation.run = common; auto& run = observation.run;
            run.key = "pr:" + key + ":" + pr.id; run.kind = "pullRequest"; run.revision = pr.detailsSHA; run.title = pr.title;
            run.number = (github ? "#" : "!") + pr.id; run.url = pr.url; run.pageURL = pr.url;
            const auto checks = pullRequestChecks(pr);
            run.state = checks == "failed" ? RunState::failed : checks == "succeeded" ? RunState::passed : RunState::running;
            observation.noChecks = checks == "none";
            for (const auto& check : pr.checks) {
                if (check.kind != "build" || !check.blocking) continue;
                if (check.state == "failed" && !check.url.empty() && run.url == pr.url) run.url = check.url;
                if (check.startedAt > 0 && (run.startedAt == 0 || check.startedAt < run.startedAt)) run.startedAt = check.startedAt;
            }
            out.push_back(observation);
        }
        for (const auto& pipeline : source->second.myRuns) {
            RunObservation observation; observation.run = common; auto& run = observation.run;
            run.key = "run:" + key + ":" + pipeline.definitionID; run.kind = "pipeline"; run.revision = pipeline.id; run.title = pipeline.name;
            run.number = pipeline.number; run.url = pipeline.url; run.startedAt = pipeline.startedAt;
            run.state = pipeline.result == "failed" || pipeline.result == "partial" ? RunState::failed : pipeline.result == "succeeded" ? RunState::passed : pipeline.result == "waiting" ? RunState::waiting : RunState::running;
            observation.finishedAt = pipeline.finishedAt;
            observation.stopped = pipeline.result == "canceled" || pipeline.result == "unknown";
            out.push_back(observation);
        }
    }
    return out;
}

std::set<std::string> readSources(const StatusSnapshot& status) {
    std::set<std::string> out;
    for (const auto& [key, source] : status.sources) if (source.myPullRequestsKnown && source.error.empty()) out.insert(key);
    return out;
}

std::set<std::string> boundSources(const ProjectsState& state) {
    std::set<std::string> out;
    for (const auto& project : state.projects) for (const auto& binding : project.sources) out.insert(sourceKey(binding));
    return out;
}

std::vector<RunWarning> runWarnings(const ProjectsState& state, const StatusSnapshot& status, double now) {
    std::vector<RunWarning> out;
    for (const auto& connection : state.connections) {
        std::vector<SourceBinding> bindings;
        for (const auto& project : state.projects) for (const auto& binding : project.sources) if (binding.connectionID == connection.id) bindings.push_back(binding);
        if (bindings.empty()) continue;
        const std::string provider = connection.provider == "github" ? "GitHub" : "Azure DevOps";
        auto found = status.connections.find(connection.id);
        if (found != status.connections.end() && (found->second.access == Access::signedOut || found->second.access == Access::rejected)) {
            out.push_back({connection.id, "Sign in to " + provider + " to keep checks up to date", true});
            continue;
        }
        if (found != status.connections.end() && found->second.throttled) {
            out.push_back({connection.id, provider + " asked Rail to slow down, so checks may be behind", false});
            continue;
        }
        for (const auto& binding : bindings) {
            auto source = status.sources.find(sourceKey(binding));
            if (source == status.sources.end() || source->second.notCovered || source->second.readAt <= 0 || now - source->second.readAt < StaleSeconds) continue;
            out.push_back({connection.id, "Couldn't reach " + provider + " for a while, so checks may be behind", false});
            break;
        }
    }
    return out;
}

}
