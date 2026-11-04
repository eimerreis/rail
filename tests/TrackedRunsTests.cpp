#include "TrackedRuns.h"

#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

const std::string Source = "connection|contoso/app";
const std::set<std::string> Read = {Source};
const double Hour = 60 * 60;

rail::RunObservation pr(rail::RunState state, const std::string& revision = "sha1") {
    rail::RunObservation observation; auto& run = observation.run;
    run.key = "pr:1"; run.sourceKey = Source; run.kind = "pullRequest"; run.revision = revision; run.title = "Add invoices"; run.state = state;
    return observation;
}
rail::RunObservation pipeline(rail::RunState state, const std::string& id = "41", double finishedAt = 0) {
    rail::RunObservation observation; auto& run = observation.run;
    run.key = "run:release"; run.sourceKey = Source; run.kind = "pipeline"; run.revision = id; run.title = "release"; run.state = state;
    observation.finishedAt = finishedAt;
    return observation;
}
// Past the quiet first check since launch.
rail::TrackedRuns started(double now = 1000) {
    rail::TrackedRuns runs; runs.observe({}, Read, now);
    return runs;
}

void failureAnnouncesAndStaysUntilAcknowledged() {
    auto runs = started();
    require(runs.observe({pr(rail::RunState::running)}, Read, 1010).empty(), "running is not announced");
    require(runs.counts(1010).running == 1, "running is counted");
    auto announced = runs.observe({pr(rail::RunState::failed)}, Read, 1020);
    require(announced.size() == 1 && announced[0].state == rail::RunState::failed, "a failure is announced");
    require(runs.observe({pr(rail::RunState::failed)}, Read, 1030).empty(), "a failure is announced once");
    require(runs.counts(1020 + 3 * 24 * Hour).failed == 1, "a failure stays however long it takes");
    require(runs.acknowledge("pr:1"), "a failure can be acknowledged");
    require(runs.counts(1040).failed == 0, "acknowledged failures aren't counted");
    require(runs.listed(1040).size() == 1, "and stay listed as finished");
    require(runs.observe({pr(rail::RunState::failed)}, Read, 1050).empty(), "an acknowledged failure stays quiet");
    require(runs.run("pr:1")->acknowledged, "and stays acknowledged");
}

void aNewerRunReplacesAFailure() {
    auto runs = started();
    runs.observe({pr(rail::RunState::failed)}, Read, 1010);
    runs.observe({pr(rail::RunState::running)}, Read, 1020);
    require(runs.counts(1020).failed == 0 && runs.counts(1020).running == 1, "a re-run replaces the failure");
    require(runs.observe({pr(rail::RunState::failed)}, Read, 1030).size() == 1, "failing again announces again");
    runs.acknowledge("pr:1");
    require(runs.observe({pr(rail::RunState::failed, "sha2")}, Read, 1040).size() == 1, "a new commit that fails is news, even after an acknowledgement");
    require(!runs.run("pr:1")->acknowledged, "and needs acknowledging again");
}

void passedAnnouncesOnceFinishedAndLeaves() {
    auto runs = started();
    runs.observe({pr(rail::RunState::running)}, Read, 1010);
    auto announced = runs.observe({pr(rail::RunState::passed)}, Read, 1020);
    require(announced.size() == 1 && announced[0].state == rail::RunState::passed, "a pass is announced");
    require(runs.counts(1020).passed == 1, "and counted");
    runs.markPassedSeen();
    require(runs.counts(1020).passed == 0 && runs.listed(1020).size() == 1, "opening the list resets the count, not the list");
    require(runs.listed(1020 + 24 * Hour).empty(), "a pass leaves the list after a day");
    require(runs.observe({pr(rail::RunState::passed)}, Read, 1020 + 25 * Hour).empty(), "and isn't announced again");
}

void clearingKeepsResultsFromReturning() {
    auto runs = started();
    runs.observe({pr(rail::RunState::passed)}, Read, 1010);
    require(runs.clearFinished() && runs.listed(1010).empty(), "clear empties the finished list");
    require(runs.observe({pr(rail::RunState::passed)}, Read, 1020).empty() && runs.listed(1020).empty(), "a cleared pass stays gone");
    runs.observe({pipeline(rail::RunState::failed)}, Read, 1030);
    runs.clearFinished();
    require(runs.counts(1030).failed == 1, "clear doesn't touch an unacknowledged failure");
}

void waitingAnnouncesOnceAndStays() {
    auto runs = started();
    runs.observe({pipeline(rail::RunState::running)}, Read, 1010);
    auto announced = runs.observe({pipeline(rail::RunState::waiting)}, Read, 1020);
    require(announced.size() == 1 && announced[0].state == rail::RunState::waiting, "waiting for approval is announced");
    require(runs.observe({pipeline(rail::RunState::waiting)}, Read, 1030).empty(), "once");
    require(runs.counts(1030).waiting == 1 && runs.listed(1030 + 3 * 24 * Hour).size() == 1, "and stays until it moves on");
    runs.observe({pipeline(rail::RunState::running)}, Read, 1040);
    require(runs.counts(1040).waiting == 0 && runs.counts(1040).running == 1, "approval moves it on");
}

void whatHappenedWhileClosedIsQuiet() {
    rail::TrackedRuns runs;
    auto announced = runs.observe({pipeline(rail::RunState::failed, "41", 900), pr(rail::RunState::passed)}, Read, 1000);
    require(announced.empty(), "nothing announces on the first check");
    require(runs.counts(1000).failed == 1, "a failure while closed still shows");
    require(runs.counts(1000).passed == 0 && runs.listed(1000).size() == 1, "a pass while closed is skipped");
    require(runs.observe({pipeline(rail::RunState::failed, "41", 900), pr(rail::RunState::passed)}, Read, 1010).empty(), "and neither is news on the next check");

    rail::TrackedRuns restarted; restarted.runs = runs.runs;
    restarted.acknowledge("run:release");
    rail::TrackedRuns again; again.runs = restarted.runs;
    again.observe({pipeline(rail::RunState::failed, "41", 900)}, Read, 2000);
    require(again.counts(2000).failed == 0, "an acknowledged failure stays cleared across restarts");

    rail::TrackedRuns stale;
    stale.observe({pipeline(rail::RunState::failed, "41", 1000)}, Read, 1000 + 25 * Hour);
    require(stale.listed(1000 + 25 * Hour).empty(), "a run that failed days before isn't dug up");
    require(stale.observe({pipeline(rail::RunState::running, "42")}, Read, 1000 + 26 * Hour).empty() && stale.counts(1000 + 26 * Hour).running == 1, "its next run is followed");

    rail::TrackedRuns waiting;
    require(waiting.observe({pipeline(rail::RunState::waiting)}, Read, 1000).empty() && waiting.counts(1000).waiting == 1, "a run left waiting shows quietly");
}

void onlyTrustworthyChecksRemoveRuns() {
    auto runs = started();
    runs.observe({pr(rail::RunState::running)}, Read, 1010);
    runs.observe({}, {}, 1020);
    require(runs.counts(1020).running == 1, "a source that couldn't be read says nothing");
    runs.observe({}, Read, 1030);
    require(runs.listed(1030).empty(), "a pull request that's gone stops being followed");

    runs.observe({pr(rail::RunState::passed)}, Read, 1040);
    runs.observe({}, Read, 1050);
    require(runs.listed(1050).size() == 1, "a pass stays listed after its pull request merges");

    runs = started();
    runs.observe({pipeline(rail::RunState::failed)}, Read, 1010);
    runs.observe({}, Read, 1020);
    require(runs.counts(1020).failed == 1, "a failed pipeline waits for its acknowledgement");
    runs.observe({pipeline(rail::RunState::failed)}, Read, 1030);
    auto stopped = pipeline(rail::RunState::running, "42"); stopped.stopped = true;
    runs.observe({stopped}, Read, 1040);
    require(runs.listed(1040).empty(), "a canceled newer run replaces it, quietly");

    runs = started();
    runs.observe({pr(rail::RunState::failed)}, Read, 1010);
    auto none = pr(rail::RunState::running); none.noChecks = true;
    runs.observe({none}, Read, 1020);
    require(runs.counts(1020).failed == 1, "checks that didn't load don't clear a failure");
    auto pushed = pr(rail::RunState::running, "sha2"); pushed.noChecks = true;
    runs.observe({pushed}, Read, 1030);
    require(runs.listed(1030).empty(), "a push with no checks yet does");

    runs = started();
    runs.observe({pr(rail::RunState::failed)}, Read, 1010);
    require(!runs.keepOnlySources({Source}), "a source still in use is kept");
    require(runs.keepOnlySources({}) && runs.runs.empty(), "a removed project's runs go with it");
}

void listsWhatNeedsYouFirst() {
    auto runs = started();
    auto other = pr(rail::RunState::running); other.run.key = "pr:2"; other.run.revision = "sha";
    auto done = pr(rail::RunState::passed); done.run.key = "pr:3";
    runs.observe({done, other, pipeline(rail::RunState::waiting), pr(rail::RunState::failed)}, Read, 1010);
    auto listed = runs.listed(1010);
    require(listed.size() == 4 && listed[0].key == "pr:1" && listed[1].key == "run:release" && listed[2].key == "pr:2" && listed[3].key == "pr:3", "failed, waiting, running, finished");
    require(runs.changedSince(1010).size() == 4 && runs.changedSince(1011).empty(), "recent changes can be found");
}

rail::Projects projectWith(rail::SourceStatus source, rail::StatusSnapshot& status) {
    rail::Projects projects;
    projects.state.connections.push_back({"c", "github", "me", "deviceToken", "work"});
    rail::Project project; project.id = "p"; project.name = "App"; project.spaceID = "work"; project.sources.push_back({"c", "contoso/app"});
    projects.state.projects.push_back(project);
    status.sources[rail::sourceKey(project.sources[0])] = source;
    return projects;
}

void readsRunsFromTheSnapshot() {
    rail::SourceStatus source; source.myPullRequestsKnown = true;
    rail::PullRequest failing; failing.id = "7"; failing.title = "Fix"; failing.url = "https://github.com/contoso/app/pull/7"; failing.detailsSHA = "abc";
    failing.checks.push_back({"build", "test", "failed", "", "https://github.com/run/1"});
    failing.checks.push_back({"build", "lint", "running", "", ""});
    rail::PullRequest none; none.id = "8"; none.detailsSHA = "def";
    source.myPullRequests = {failing, none};
    rail::PipelineRun manual; manual.name = "release"; manual.number = "12"; manual.result = "waiting"; manual.id = "99"; manual.definitionID = "3";
    rail::PipelineRun canceled; canceled.result = "canceled"; canceled.id = "98"; canceled.definitionID = "4";
    source.myRuns = {manual, canceled};
    rail::StatusSnapshot status;
    auto projects = projectWith(source, status);
    auto observed = rail::observeRuns(projects, status);
    require(observed.size() == 4, "one per pull request and pipeline");
    require(observed[0].run.state == rail::RunState::failed && observed[0].run.number == "#7", "the first failing check fails the pull request");
    require(observed[0].run.url == "https://github.com/run/1" && observed[0].run.pageURL == failing.url, "Open run goes to the failing check");
    require(observed[1].noChecks, "no checks means nothing to follow");
    require(observed[2].run.state == rail::RunState::waiting && observed[2].run.revision == "99", "pipelines carry their run");
    require(observed[3].stopped, "a canceled run stops");
    require(observed[0].run.spaceID == "work" && observed[0].run.project == "App", "runs know their Space");
    require(rail::readSources(status).size() == 1, "a clean check is trusted");
    status.sources.begin()->second.error = "Couldn't read pipelines";
    require(rail::readSources(status).empty(), "a partial check isn't");
}

void warnsWhenTheDataIsBehind() {
    rail::SourceStatus source; source.readAt = 1000;
    rail::StatusSnapshot status;
    auto projects = projectWith(source, status);
    require(rail::runWarnings(projects.state, status, 1100).empty(), "a recent check needs no warning");
    require(rail::runWarnings(projects.state, status, 1000 + rail::StaleSeconds).size() == 1, "an old one does");
    status.connections["c"].throttled = true;
    require(rail::runWarnings(projects.state, status, 1100).size() == 1, "being throttled does");
    status.connections["c"].throttled = false; status.connections["c"].access = rail::Access::rejected;
    auto warnings = rail::runWarnings(projects.state, status, 1100);
    require(warnings.size() == 1 && warnings[0].signIn, "a lost login asks for a sign-in");
    status.connections["c"].access = rail::Access::signedIn; status.sources.begin()->second.notCovered = true;
    require(rail::runWarnings(projects.state, status, 1000 + rail::StaleSeconds).empty(), "a repository the app can't see is a Projects matter");
}

void pollsFasterWhileSomethingRuns() {
    rail::SourceStatus source;
    require(rail::sourcePollSeconds(source) == rail::IdlePollSeconds, "idle by default");
    rail::PipelineRun run; run.result = "waiting"; source.myRuns = {run};
    require(rail::sourcePollSeconds(source) == rail::IdlePollSeconds, "waiting on a person is idle");
    source.myRuns[0].result = "running";
    require(rail::sourcePollSeconds(source) == rail::RunningPollSeconds, "a running pipeline is fast");
    source.myRuns.clear();
    rail::PullRequest pr; pr.checks.push_back({"build", "test", "pending", "", ""}); source.myPullRequests = {pr};
    require(rail::sourcePollSeconds(source) == rail::RunningPollSeconds, "a pending check is fast");
    require(rail::githubMyRunResult("waiting", "") == "waiting" && rail::githubMyRunResult("in_progress", "") == "running", "GitHub runs held for approval");

    rail::StatusSnapshot a, b; a.sources["s"] = source; b.sources["s"] = source; b.sources["s"].checkedAt = 99;
    require(rail::statusSignature(a) == rail::statusSignature(b), "timings alone change nothing");
    b.sources["s"].myPullRequests[0].checks[0].state = "failed";
    require(rail::statusSignature(a) != rail::statusSignature(b), "a state does");
}

}

int main(int argc, char** argv) {
    const std::vector<std::pair<std::string, std::function<void()>>> tests = {
        {"failure", failureAnnouncesAndStaysUntilAcknowledged},
        {"replaced", aNewerRunReplacesAFailure},
        {"passed", passedAnnouncesOnceFinishedAndLeaves},
        {"clear", clearingKeepsResultsFromReturning},
        {"waiting", waitingAnnouncesOnceAndStays},
        {"closed", whatHappenedWhileClosedIsQuiet},
        {"trust", onlyTrustworthyChecksRemoveRuns},
        {"order", listsWhatNeedsYouFirst},
        {"snapshot", readsRunsFromTheSnapshot},
        {"warnings", warnsWhenTheDataIsBehind},
        {"polling", pollsFasterWhileSomethingRuns},
    };
    unsigned passed = 0, failed = 0;
    for (const auto& test : tests) {
        if (argc > 1 && test.first != argv[1]) continue;
        try {
            test.second();
            ++passed;
            std::cout << "PASS " << test.first << '\n';
        } catch (const std::exception& error) {
            ++failed;
            std::cerr << "FAIL " << test.first << ": " << error.what() << '\n';
        }
    }
    if (passed + failed == 0) { std::cerr << "No matching tests\n"; return 2; }
    std::cout << passed << " passed, " << failed << " failed\n";
    return failed ? 1 : 0;
}
