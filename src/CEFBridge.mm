#import "CEFBridge.h"
#include "include/cef_parser.h"
#include "include/wrapper/cef_helpers.h"

namespace {
NSString *S(const CefString &s) { return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @""; }

class RailApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit RailApp(BrowserController *controller) : controller_(controller) {}
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnContextInitialized() override { CEF_REQUIRE_UI_THREAD(); [controller_ start]; }
 private:
  __weak BrowserController *controller_;
  IMPLEMENT_REFCOUNTING(RailApp);
};

class RailClient final : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler,
  public CefLoadHandler, public CefRequestHandler, public CefKeyboardHandler,
  public CefPermissionHandler, public CefDownloadHandler, public CefJSDialogHandler {
 public:
  RailClient(BrowserController *controller, std::string tabID, uint64_t generation)
      : controller_(controller), tabID_(std::move(tabID)), generation_(generation) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD(); [controller_ browserCreated:browser tab:tabID_ generation:generation_];
  }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD(); [controller_ browserReadyToClose:browser tab:tabID_ generation:generation_]; return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    CEF_REQUIRE_UI_THREAD(); [controller_ browserClosed:tabID_ generation:generation_];
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int popupID, const CefString &url,
      const CefString &, WindowOpenDisposition, bool gesture, const CefPopupFeatures &,
      CefWindowInfo &info, CefRefPtr<CefClient> &client, CefBrowserSettings &,
      CefRefPtr<CefDictionaryValue> &, bool *) override {
    CEF_REQUIRE_UI_THREAD();
    if (!gesture || (!url.empty() && !RailNavigationAllowed(url))) return true;
    return ![controller_ preparePopupFrom:tabID_ generation:generation_ popupID:popupID url:S(url) windowInfo:info client:client];
  }
  void OnBeforePopupAborted(CefRefPtr<CefBrowser>, int popupID) override {
    [controller_ popupAbortedFrom:tabID_ generation:generation_ popupID:popupID];
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &title) override {
    [controller_ updateTitle:S(title) tab:tabID_ generation:generation_];
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString &url) override {
    if (frame->IsMain()) [controller_ updateURL:S(url) tab:tabID_ generation:generation_];
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool back, bool forward) override {
    [controller_ updateLoading:loading back:back forward:forward tab:tabID_ generation:generation_];
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code,
      const CefString &text, const CefString &) override {
    if (frame->IsMain() && code != ERR_ABORTED) [controller_ loadFailed:S(text) tab:tabID_ generation:generation_];
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool, bool) override {
    if (frame->IsMain() && !RailNavigationAllowed(request->GetURL())) {
      [controller_ setStatus:@"This address type is not supported."]; return true;
    }
    return false;
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus, int, const CefString &) override {
    [controller_ loadFailed:@"The page stopped responding. Reload to try again." tab:tabID_ generation:generation_];
  }
  bool OnPreKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent &event, CefEventHandle nativeEvent, bool *) override {
    if (event.type != KEYEVENT_RAWKEYDOWN || !nativeEvent) return false;
    return [controller_ handleShortcut:(__bridge NSEvent *)nativeEvent];
  }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString &, bool, CefRefPtr<CefJSDialogCallback> callback) override {
    BrowserController *controller = controller_;
    if (!controller) { callback->Continue(true, CefString()); return true; }
    NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Leave this page?";
    alert.informativeText = @"This page may have unsaved changes. Leaving closes its page content.";
    [alert addButtonWithTitle:@"Stay"]; [alert addButtonWithTitle:@"Leave"];
    std::string tab = tabID_; uint64_t gen = generation_;
    [alert beginSheetModalForWindow:controller.window completionHandler:^(NSModalResponse result) {
      bool leave = result == NSAlertSecondButtonReturn;
      if (!leave) [controller closeCancelled:tab generation:gen];
      callback->Continue(leave, CefString());
    }]; return true;
  }
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString &origin,
      uint32_t permissions, CefRefPtr<CefMediaAccessCallback> callback) override {
    // Desktop capture needs a screen picker; deny instead of silently selecting a screen.
    if (permissions & (CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) {
      callback->Cancel(); [controller_ setStatus:@"Screen sharing is not available in this version."]; return true;
    }
    NSMutableArray *names = [NSMutableArray array];
    if (permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) [names addObject:@"microphone"];
    if (permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) [names addObject:@"camera"];
    BrowserController *controller = controller_; if (!controller) { callback->Cancel(); return true; }
    NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Allow media access?";
    alert.informativeText = [NSString stringWithFormat:@"%@ wants to use your %@.",S(origin),[names componentsJoinedByString:@" and "]];
    [alert addButtonWithTitle:@"Don't allow"]; [alert addButtonWithTitle:@"Allow"];
    [alert beginSheetModalForWindow:controller.window completionHandler:^(NSModalResponse result) {
      if (result == NSAlertSecondButtonReturn) callback->Continue(permissions); else callback->Cancel();
    }]; return true;
  }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString &origin, uint32_t permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    BrowserController *controller = controller_;
    if (!controller) { callback->Continue(CEF_PERMISSION_RESULT_DENY); return true; }
    NSString *purpose = nil;
    if (permissions == CEF_PERMISSION_TYPE_GEOLOCATION) purpose = @"your location";
    else if (permissions == CEF_PERMISSION_TYPE_NOTIFICATIONS) purpose = @"notifications";
    else if (permissions == CEF_PERMISSION_TYPE_CLIPBOARD) purpose = @"the clipboard";
    if (!purpose) { callback->Continue(CEF_PERMISSION_RESULT_DENY); return true; }
    NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Website permission";
    alert.informativeText = [NSString stringWithFormat:@"%@ requests access to %@.",S(origin),purpose];
    [alert addButtonWithTitle:@"Don't allow"]; [alert addButtonWithTitle:@"Allow"];
    [alert beginSheetModalForWindow:controller.window completionHandler:^(NSModalResponse result) {
      callback->Continue(result == NSAlertSecondButtonReturn ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
    }]; return true;
  }
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>, const CefString &name,
      CefRefPtr<CefBeforeDownloadCallback> callback) override {
    BrowserController *controller = controller_; if (!controller) return false;
    NSSavePanel *panel = [NSSavePanel savePanel]; panel.nameFieldStringValue = S(name).lastPathComponent;
    [panel beginSheetModalForWindow:controller.window completionHandler:^(NSModalResponse result) {
      if (result == NSModalResponseOK) callback->Continue(panel.URL.path.UTF8String, false);
    }]; return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback>) override {
    if (item->IsComplete()) [controller_ setStatus:[NSString stringWithFormat:@"Downloaded %@",S(item->GetFullPath()).lastPathComponent]];
    else if (item->IsInProgress()) [controller_ setStatus:[NSString stringWithFormat:@"Downloading %@ · %d%%",S(item->GetSuggestedFileName()),item->GetPercentComplete()]];
    else if (item->IsCanceled()) [controller_ setStatus:@"Download canceled."];
  }
 private:
  __weak BrowserController *controller_;
  std::string tabID_;
  uint64_t generation_;
  IMPLEMENT_REFCOUNTING(RailClient);
};
}
bool RailNavigationAllowed(const CefString &url) {
  NSString *address = S(url);
  if ([address isEqualToString:@"about:blank"]) return true;
  NSString *scheme = [NSURLComponents componentsWithString:address].scheme.lowercaseString;
  return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
}
CefRefPtr<CefClient> MakeRailClient(BrowserController *controller, const std::string &tabID, uint64_t generation) {
  return new RailClient(controller,tabID,generation);
}
CefRefPtr<CefApp> MakeRailApp(BrowserController *controller) { return new RailApp(controller); }
