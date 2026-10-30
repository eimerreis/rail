#import "BrowserController.h"
#include "include/cef_app.h"

CefRefPtr<CefClient> MakeRailClient(BrowserController *controller, const std::string &tabID, uint64_t generation);
CefRefPtr<CefApp> MakeRailApp(BrowserController *controller);
void ShowRailDevTools(CefRefPtr<CefBrowser> browser, const CefPoint &inspectAt = CefPoint());
bool RailNavigationAllowed(const CefString &url);
