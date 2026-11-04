#import "BrowserController.h"
#include "include/cef_app.h"

CefRefPtr<CefClient> MakeRailClient(BrowserController *controller, const std::string &tabID, uint64_t generation);
CefRefPtr<CefApp> MakeRailApp(BrowserController *controller);
// Shows DevTools for a tab's page in their own window; the controller attaches a docked one beside the page.
void ShowRailDevTools(BrowserController *controller, CefRefPtr<CefBrowser> browser, const std::string &tabID, uint64_t generation,
  bool docked, const CefPoint &inspectAt = CefPoint());
bool RailNavigationAllowed(const CefString &url);
// A file on this Mac. Web pages can't reach these; only the user or another local file can.
bool RailIsFileURL(const CefString &url);
// Eligible for a native confirmation, never automatic OS execution.
bool RailIsExternalAppURL(const CefString &url);
