#include "BrowserModel.h"
#include "Projects.h"

#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

void recognizesRepositories() {
    auto github = rail::recognizeRepo("https://github.com/contoso/webhook-relay/pull/12?x=1");
    require(github && github.provider == "github", "GitHub repo should be recognized");
    require(github.resource() == "contoso/webhook-relay", "GitHub resource is owner/repo");
    require(github.repoURL() == "https://github.com/contoso/webhook-relay", "GitHub repo URL is canonical");
    require(github.pipelinesURL() == "https://github.com/contoso/webhook-relay/actions", "GitHub pipelines are Actions");
    require(rail::recognizeRepo("https://github.com/contoso/tool.git").repo == "tool", ".git suffix is dropped");
    require(!rail::recognizeRepo("https://github.com/settings/profile"), "reserved GitHub pages are not repos");
    require(!rail::recognizeRepo("https://github.com/contoso"), "an owner page is not a repo");
    auto azure = rail::recognizeRepo("https://dev.azure.com/contoso/Billing/_git/billing-api?path=/src");
    require(azure && azure.provider == "azureDevOps", "Azure DevOps repo should be recognized");
    require(azure.resource() == "contoso/Billing/billing-api", "Azure resource is org/project/repo");
    require(azure.pipelinesURL() == "https://dev.azure.com/contoso/Billing/_build", "Azure pipelines URL");
    auto legacy = rail::recognizeRepo("https://contoso.visualstudio.com/DefaultCollection/Billing/_git/billing-api");
    require(legacy && legacy.repoURL() == "https://dev.azure.com/contoso/Billing/_git/billing-api", "visualstudio.com is normalized");
    require(!rail::recognizeRepo("https://dev.azure.com/contoso/Billing/_build"), "a pipelines page alone is not a repo");
    require(!rail::recognizeRepo("http://github.com/a/b"), "only https repo pages are recognized");
    rail::Projects named;
    require(named.project(named.addProject("", "work", "https://dev.azure.com/org/My%20Project/_git/Some%20Repo", "work"))->name == "Some Repo", "encoded repo names are decoded");
}

void parsesURLs() {
    require(rail::originOf("http://localhost:3000/account?x#y") == "http://localhost:3000", "origin keeps the port");
    require(rail::originOf("https://User@Billing.Contoso.com/x") == "https://billing.contoso.com", "origin drops credentials and lowercases");
    require(rail::isLocalURL("http://127.0.0.1:5001") && rail::isLocalURL("http://app.localhost:8080") && rail::isLocalURL("http://[::1]:4000"), "local hosts");
    require(!rail::isLocalURL("https://localhost.example.com"), "a public host is not local");
    require(rail::portOf("http://localhost:5001") == 5001 && rail::portOf("https://a.b") == 443 && rail::portOf("http://a.b") == 80, "ports");
    require(!rail::isWebURL("javascript:alert(1)") && !rail::isWebURL("file:///etc") && !rail::isWebURL("https://"), "non-web URLs");
    require(rail::joinURL("https://a.b/", "/healthz") == "https://a.b/healthz" && rail::joinURL("https://a.b/app?x", "health") == "https://a.b/app/health", "health URL");
    require(rail::Projects::suggestedEnvironmentName("https://billing-int.contoso.dev") == "INT", "INT from host");
    require(rail::Projects::suggestedEnvironmentName("https://billing.contoso.com") == "billing", "first label otherwise");
    require(rail::Projects::suggestedEnvironmentName("http://localhost:3000") == "Local", "local");
}

void addingAProjectFromARepoURL() {
    rail::BrowserModel browser;
    rail::Projects projects;
    auto id = projects.addProject("", "work", "https://dev.azure.com/contoso/Billing/_git/billing-api", "work");
    const auto* project = projects.project(id);
    require(project && project->name == "billing-api", "name comes from the repo");
    require(project->links.size() == 2 && project->links[0].kind == "repo" && project->links[1].kind == "pipelines", "repo and pipelines links");
    require(project->sources.size() == 1 && project->sources[0].resource == "contoso/Billing/billing-api", "source binding");
    const auto* connection = projects.connection(project->sources[0].connectionID);
    require(connection && connection->auth == "session" && connection->sessionID == "work" && connection->account == "contoso", "Azure connection uses the session");
    auto second = projects.addProject("Other", "work", "https://dev.azure.com/contoso/Other/_git/x", "work");
    require(projects.project(second)->sources[0].connectionID == connection->id, "one connection per organization and session");
    require(projects.projectForRepo(rail::recognizeRepo("https://dev.azure.com/CONTOSO/Billing/_git/billing-api/commits")) == id, "existing project is found by repo");
    auto github = projects.addProject("", "work", "https://github.com/contoso/relay", "personal");
    const auto* gh = projects.connection(projects.project(github)->sources[0].connectionID);
    require(gh->provider == "github" && gh->auth == "deviceToken" && gh->sessionID == "personal", "GitHub connection is per session");
    require(projects.project(github)->links[1].label == "Actions", "GitHub pipelines are labelled Actions");
    require(projects.inSpace("work").size() == 3 && projects.inSpace("work")[2]->id == github, "appended in order");
}

void changingTheRepoSessionRebinds() {
    rail::Projects projects;
    auto id = projects.addProject("", "work", "https://dev.azure.com/contoso/Billing/_git/billing-api", "work");
    auto link = projects.project(id)->links[0];
    link.sessionID = "personal";
    require(projects.updateLink(id, link), "link updated");
    const auto* connection = projects.connection(projects.project(id)->sources[0].connectionID);
    require(connection->sessionID == "personal", "binding follows the repo link session");
}

void environmentsAndLinks() {
    rail::Projects projects;
    auto id = projects.addProject("Billing", "work", "", "work");
    auto prod = projects.addEnvironment(id, "PROD", "https://billing.contoso.com", "__isolated__", "/healthz");
    auto local = projects.addEnvironment(id, "", "http://localhost:5001", "work");
    const auto* project = projects.project(id);
    require(project->environments.size() == 2 && project->environments[0].id == local, "local environments come first");
    require(project->environments[0].name == "Local", "local gets a name");
    require(project->environments[1].sessionID == "isolated-" + prod, "own isolated profile");
    require(projects.addEnvironment(id, "x", "file:///etc/passwd", "work").empty(), "non-web environment rejected");
    auto flags = projects.addLink(id, "custom", "LaunchDarkly", "https://app.launchdarkly.com/billing/production/features", "work", prod);
    require(!flags.empty() && projects.project(id)->links.back().environmentID == prod, "custom link tied to an environment");
    auto profiles = projects.ownedProfiles();
    require(profiles.size() == 1 && profiles[0] == "isolated-" + prod, "owned profiles");
    require(projects.removeEnvironment(id, prod), "environment removed");
    require(projects.project(id)->links.back().environmentID.empty(), "link becomes project-wide");
}

void tabsMayUseProjectProfiles() {
    rail::BrowserModel browser;
    browser.projectProfiles = {"isolated-env-abc"};
    auto tab = browser.addTab("work", "https://billing.contoso.com", 10, "isolated-env-abc");
    require(browser.tab(tab)->sessionID == "isolated-env-abc", "new tab opens in the project profile");
    browser.sanitize(20);
    require(browser.tab(tab)->sessionID == "isolated-env-abc", "sanitize keeps the project profile");
    browser.projectProfiles.clear();
    browser.sanitize(30);
    require(browser.tab(tab)->sessionID == rail::BrowserModel::isolatedSessionID(tab), "an unknown profile falls back to the tab's own");
    require(!browser.setSession(tab, "isolated-env-other"), "unowned profiles are refused");
}

void sanitizeRepairsProjects() {
    rail::BrowserModel browser;
    rail::Projects projects;
    rail::Project broken;
    broken.id = "../bad"; broken.spaceID = "gone"; broken.name = " ";
    broken.environments = {{"env-1", "", "http://localhost:3000", "", "nope"}, {"env-2", "X", "javascript:x", "", "work"}};
    broken.links = {{"link-1", "weird", "", "https://grafana.example.com", "isolated-link-1", "env-missing"}};
    broken.sources = {{"connection-missing", "a/b"}};
    rail::Project duplicate; duplicate.id = "project-a"; duplicate.spaceID = "work"; duplicate.name = "A";
    rail::Project again = duplicate; again.name = "B";
    projects.state.projects = {broken, duplicate, again};
    projects.state.connections = {{"connection-x", "azureDevOps", "", "session", "work"}, {"connection-y", "gitlab", "a", "session", "work"}};
    projects.sanitize(browser);
    const auto& fixed = projects.state.projects[0];
    require(fixed.id != "../bad" && fixed.name == "Project" && fixed.spaceID == browser.state.spaces.front().id, "project repaired");
    require(fixed.environments.size() == 1 && fixed.environments[0].sessionID == "work" && fixed.environments[0].name == "Local", "environment repaired");
    require(fixed.links[0].kind == "custom" && fixed.links[0].label == "grafana.example.com" && fixed.links[0].environmentID.empty(), "link repaired");
    require(fixed.links[0].sessionID == "isolated-link-1", "isolated link profile kept");
    require(fixed.sources.empty(), "dangling binding dropped");
    require(projects.state.connections.empty(), "invalid connections dropped");
    require(projects.state.projects[1].id != projects.state.projects[2].id, "duplicate IDs repaired");
    require(projects.inSpace("work").size() == 3, "all projects land in an existing Space");
}

void mapsStatus() {
    using rail::Health;
    require(rail::healthFromHTTP(200, false, 120) == Health::up, "200 is up");
    require(rail::healthFromHTTP(200, false, 1500) == Health::slow, "slow");
    require(rail::healthFromHTTP(302, true, 50) == Health::loginRequired, "redirect elsewhere means login");
    require(rail::healthFromHTTP(401, false, 50) == Health::loginRequired, "401 means login");
    require(rail::healthFromHTTP(503, false, 50) == Health::down && rail::healthFromHTTP(0, false, 0) == Health::down, "down");
    require(rail::healthFromHTTP(404, false, 50) == Health::up, "a 404 still means the server answers");
    require(rail::azureBuildResult("completed", "failed") == "failed" && rail::azureBuildResult("inProgress", "none") == "running"
        && rail::azureBuildResult("completed", "partiallySucceeded") == "partial" && rail::azureBuildResult("notStarted", "") == "queued", "Azure builds");
    require(rail::githubRunResult("completed", "success") == "succeeded" && rail::githubRunResult("completed", "timed_out") == "failed"
        && rail::githubRunResult("in_progress", "") == "running" && rail::githubRunResult("queued", "") == "queued", "GitHub runs");
    using rail::Access;
    require(rail::azureAccess(200, "", "application/json", "Anonymous") == Access::signedOut, "anonymous is signed out");
    require(rail::azureAccess(200, "", "application/json; charset=utf-8", "Ada") == Access::signedIn, "named user is signed in");
    require(rail::azureAccess(302, "https://spsprodweu3.vssps.visualstudio.com/_signin?realm=dev.azure.com", "", "") == Access::signedOut, "sign-in redirect");
    require(rail::azureAccess(203, "", "text/html", "") == Access::signedOut, "sign-in page");
    require(rail::azureAccess(500, "", "", "") == Access::unknown, "server error is unknown");
}

void attentionIsComputed() {
    rail::Projects projects;
    auto id = projects.addProject("", "work", "https://dev.azure.com/contoso/Billing/_git/billing-api", "work");
    auto prod = projects.addEnvironment(id, "PROD", "https://billing.contoso.com", "work");
    auto local = projects.addEnvironment(id, "Local", "http://localhost:5001", "work");
    const auto& project = *projects.project(id);
    rail::StatusSnapshot status;
    status.environments[local].health = rail::Health::notRunning;
    status.environments[prod].health = rail::Health::up;
    require(rail::attentionFor(project, projects.state, status).empty(), "a stopped local server needs no attention");
    status.environments[prod] = {rail::Health::down, 0, "", 1, "Timed out"};
    rail::SourceStatus source;
    source.runs.push_back({"billing-ci", "2148", "main", "failed", "https://dev.azure.com/run/2148", 1});
    status.sources[rail::sourceKey(project.sources[0])] = source;
    auto items = rail::attentionFor(project, projects.state, status);
    require(items.size() == 2 && items[0].tone == rail::Tone::critical && items[1].tone == rail::Tone::critical, "down and failed run");
    require(items[0].title == "PROD is down" && items[1].action == "openRun", "titles and actions");
    status.connections[project.sources[0].connectionID].access = rail::Access::signedOut;
    items = rail::attentionFor(project, projects.state, status);
    require(items.size() == 2 && items[1].action == "signIn" && items[1].title == "Sign in to Azure DevOps", "signed out hides runs and asks to sign in");
}

} // namespace

int main(int argc, char** argv) {
    const std::vector<std::pair<std::string, std::function<void()>>> tests = {
        {"recognize", recognizesRepositories},
        {"urls", parsesURLs},
        {"add-project", addingAProjectFromARepoURL},
        {"rebind", changingTheRepoSessionRebinds},
        {"environments", environmentsAndLinks},
        {"profiles", tabsMayUseProjectProfiles},
        {"sanitize", sanitizeRepairsProjects},
        {"status", mapsStatus},
        {"attention", attentionIsComputed},
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
