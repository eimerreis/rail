#pragma once

#include "Projects.h"

#include <set>
#include <string>
#include <vector>

namespace rail {

enum class RunState { running, waiting, failed, passed };

// One unit of work Rail follows: all the checks of one of the user's own open pull requests,
// or a pipeline run the user started by hand. See GLOSSARY.md.
struct TrackedRun {
    std::string key;
    std::string sourceKey;
    std::string kind;          // "pullRequest" | "pipeline"
    std::string revision;      // the head commit or run ID; a new one replaces what came before
    std::string title;
    std::string project;
    std::string spaceID;
    std::string sessionID;
    std::string number;        // "!1187", "#214", or a build number
    std::string url;           // what "Open run" opens
    std::string pageURL;       // pull requests: the page, which also identifies its Activity row
    RunState state = RunState::running;
    double startedAt = 0;
    double changedAt = 0;      // when Rail saw the state change
    bool acknowledged = false;
    bool passedSeen = false;   // no longer counted, though still listed
    bool cleared = false;      // kept only so the same result isn't announced again
};

// What a check of a source says about one run.
struct RunObservation {
    TrackedRun run;            // state and descriptors; the bookkeeping fields are ignored
    double finishedAt = 0;     // 0 when the provider doesn't say
    bool noChecks = false;     // a pull request with nothing to wait for yet
    bool stopped = false;      // canceled: nothing to report, and nothing left to follow
};

struct RunCounts {
    int running = 0, waiting = 0, failed = 0, passed = 0;
    bool any() const { return running || waiting || failed || passed; }
};

struct RunWarning {
    std::string connectionID;
    std::string text;
    bool signIn = false;
};

class TrackedRuns {
public:
    static constexpr double KeptSeconds = 24 * 60 * 60;

    // Applies what the sources in readSources said and returns the runs to announce, oldest first.
    // A source's first check since launch is quiet: it stands for everything that happened while
    // Rail was closed, so failures appear without an announcement and passes are skipped.
    std::vector<TrackedRun> observe(const std::vector<RunObservation>& observations, const std::set<std::string>& readSources, double now);
    // Drops runs of sources no project uses any more.
    bool keepOnlySources(const std::set<std::string>& sources);

    bool acknowledge(const std::string& key);
    bool clearFinished();
    bool markPassedSeen();

    const TrackedRun* run(const std::string& key) const;
    // Listed runs: failed, then waiting, running and finished, newest first within each.
    std::vector<TrackedRun> listed(double now) const;
    RunCounts counts(double now) const;
    // The runs whose state changed in the last seconds, for tinting them on the pages.
    std::vector<TrackedRun> changedSince(double when) const;

    std::vector<TrackedRun> runs;

private:
    std::set<std::string> checkedSinceLaunch_;
};

// The user's own runs in the snapshot, across all Spaces.
std::vector<RunObservation> observeRuns(const Projects& projects, const StatusSnapshot& status);
// Sources whose latest check can be trusted to say what is and isn't there.
std::set<std::string> readSources(const StatusSnapshot& status);
std::set<std::string> boundSources(const ProjectsState& state);
// Reasons the Capsule's picture may be out of date. A source is stale after StaleSeconds without a good check.
constexpr double StaleSeconds = 5 * 60;
std::vector<RunWarning> runWarnings(const ProjectsState& state, const StatusSnapshot& status, double now);

}
