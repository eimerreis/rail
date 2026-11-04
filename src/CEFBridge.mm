#import "CEFBridge.h"
#include "include/cef_parser.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_find_handler.h"
#include "include/wrapper/cef_helpers.h"

namespace {
NSString *S(const CefString &s) { return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @""; }

// DevTools never send tab lifecycle callbacks; they only tell the controller about their window.
// Chromium always gives DevTools their own window: on macOS they can't be embedded in a view.
// Docked, the controller attaches that window over the right side of the page.
class DevToolsClient final : public CefClient, public CefLifeSpanHandler, public CefKeyboardHandler {
 public:
  DevToolsClient(BrowserController *controller, std::string tabID, uint64_t generation, bool docked)
      : controller_(controller), tabID_(std::move(tabID)), generation_(generation), docked_(docked) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD(); [controller_ devToolsCreated:browser tab:tabID_ generation:generation_];
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD(); [controller_ devToolsClosed:browser tab:tabID_ generation:generation_];
  }
  bool OnPreKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent &event, CefEventHandle nativeEvent, bool *) override {
    if (!docked_ || event.type != KEYEVENT_RAWKEYDOWN || !nativeEvent) return false;
    return [controller_ handleDevToolsShortcut:(__bridge NSEvent *)nativeEvent];
  }
 private:
  __weak BrowserController *controller_;
  std::string tabID_;
  uint64_t generation_;
  bool docked_;
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};
constexpr int InspectElementCommand = MENU_ID_USER_FIRST;
constexpr int OpenLinkCommand = MENU_ID_USER_FIRST + 1;
constexpr int OpenImageCommand = MENU_ID_USER_FIRST + 2;
constexpr int CopyImageCommand = MENU_ID_USER_FIRST + 3;
// New tabs and popups can show a local file only when a local file asks for it, so a web
// page can't use Rail's own browser-side navigation to get around Chromium's file:// block.
bool RailOpenAllowedFrom(const CefString &url, const CefString &page) {
  return RailNavigationAllowed(url) || (RailIsFileURL(url) && RailIsFileURL(page));
}
// The address bar, reloads, restored tabs and history may load a file. Links and forms may only from another file.
bool FileNavigationAllowed(CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request) {
  const int transition = request->GetTransitionType();
  if (transition & TT_FORWARD_BACK_FLAG) return true;
  const int source = transition & TT_SOURCE_MASK;
  return (source != TT_LINK && source != TT_FORM_SUBMIT) || RailIsFileURL(frame->GetURL());
}

class CopyImageCallback final : public CefDownloadImageCallback {
 public:
  explicit CopyImageCallback(BrowserController *controller)
      : controller_(controller), pasteboardChange_(NSPasteboard.generalPasteboard.changeCount) {}
  void OnDownloadImageFinished(const CefString &, int, CefRefPtr<CefImage> image) override {
    CEF_REQUIRE_UI_THREAD();
    // A slow image request must not replace something the user copied more recently.
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    if (pasteboard.changeCount != pasteboardChange_) return;
    int width = 0, height = 0;
    CefRefPtr<CefBinaryValue> png = image ? image->GetAsPNG(1.0f, true, width, height) : nullptr;
    if (!png) { [controller_ setStatus:@"Couldn't copy the image. Try again."]; return; }
    NSMutableData *data = [NSMutableData dataWithLength:png->GetSize()];
    png->GetData(data.mutableBytes, data.length, 0);
    NSImage *nativeImage = [[NSImage alloc] initWithData:data];
    if (!nativeImage) { [controller_ setStatus:@"Couldn't copy the image. Try again."]; return; }
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setData:data forType:NSPasteboardTypePNG];
    NSData *tiff = nativeImage.TIFFRepresentation;
    if (tiff) [item setData:tiff forType:NSPasteboardTypeTIFF];
    [pasteboard clearContents];
    if (![pasteboard writeObjects:@[item]]) [controller_ setStatus:@"Couldn't copy the image. Try again."];
  }
 private:
  __weak BrowserController *controller_;
  NSInteger pasteboardChange_;
  IMPLEMENT_REFCOUNTING(CopyImageCallback);
};

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
  public CefPermissionHandler, public CefDownloadHandler, public CefJSDialogHandler,
  public CefContextMenuHandler, public CefFindHandler, public CefFocusHandler {
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
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  // A page starting or navigating behind Reading or Home must not take the keyboard from them.
  bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource) override {
    CEF_REQUIRE_UI_THREAD();
    return [controller_ pageIsCovered];
  }
  void OnFindResult(CefRefPtr<CefBrowser>, int identifier, int count, const CefRect &,
      int ordinal, bool finalUpdate) override {
    CEF_REQUIRE_UI_THREAD();
    [controller_ findResult:identifier count:count ordinal:ordinal final:finalUpdate tab:tabID_ generation:generation_];
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
      CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    CEF_REQUIRE_UI_THREAD();
    if (source != PID_RENDERER || !frame->IsMain() || message->GetName() != "rail.credentials.reply") return false;
    [controller_ passwordReply:message tab:tabID_ generation:generation_]; return true;
  }

  void OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
      CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> menu) override {
    CEF_REQUIRE_UI_THREAD();
    size_t index = 0;
    if (!params->GetLinkUrl().empty() && RailOpenAllowedFrom(params->GetLinkUrl(), params->GetFrameUrl()))
      menu->InsertItemAt(index++, OpenLinkCommand, "Open Link in New Tab");
    if (params->GetMediaType() == CM_MEDIATYPE_IMAGE) {
      if (!params->GetSourceUrl().empty() && RailOpenAllowedFrom(params->GetSourceUrl(), params->GetFrameUrl()))
        menu->InsertItemAt(index++, OpenImageCommand, "Open Image in New Tab");
      menu->InsertItemAt(index++, CopyImageCommand, "Copy Image");
      menu->SetEnabled(CopyImageCommand, params->HasImageContents() && !params->GetSourceUrl().empty());
    }
    if (index && menu->GetCount() > index) menu->InsertSeparatorAt(index);
    if (menu->GetCount()) menu->AddSeparator();
    menu->AddItem(InspectElementCommand, "Inspect Element");
  }
  bool RunContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams>,
      CefRefPtr<CefMenuModel> menu, CefRefPtr<CefRunContextMenuCallback> callback) override {
    return [controller_ automateContextMenu:menu callback:callback];
  }
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
      CefRefPtr<CefContextMenuParams> params, int commandID, EventFlags) override {
    CEF_REQUIRE_UI_THREAD();
    if (commandID == OpenLinkCommand || commandID == OpenImageCommand) {
      const CefString url = commandID == OpenLinkCommand ? params->GetLinkUrl() : params->GetSourceUrl();
      if (!url.empty() && RailOpenAllowedFrom(url, params->GetFrameUrl()))
        [controller_ openLinkFrom:tabID_ generation:generation_ url:S(url) background:YES];
      return true;
    }
    if (commandID == CopyImageCommand) {
      if (params->GetMediaType() == CM_MEDIATYPE_IMAGE && params->HasImageContents() && !params->GetSourceUrl().empty())
        browser->GetHost()->DownloadImage(params->GetSourceUrl(), false, 0, false, new CopyImageCallback(controller_));
      return true;
    }
    if (commandID != InspectElementCommand) return false;
    [controller_ inspectTab:tabID_ generation:generation_ at:CefPoint(params->GetXCoord(), params->GetYCoord())];
    return true;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD(); [controller_ browserCreated:browser tab:tabID_ generation:generation_];
  }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD(); [controller_ browserReadyToClose:browser tab:tabID_ generation:generation_]; return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    CEF_REQUIRE_UI_THREAD(); [controller_ browserClosed:tabID_ generation:generation_];
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int popupID, const CefString &url,
      const CefString &, WindowOpenDisposition disposition, bool gesture, const CefPopupFeatures &,
      CefWindowInfo &info, CefRefPtr<CefClient> &client, CefBrowserSettings &,
      CefRefPtr<CefDictionaryValue> &, bool *) override {
    CEF_REQUIRE_UI_THREAD();
    if (!gesture) return true;
    if (!url.empty() && !RailOpenAllowedFrom(url, frame ? frame->GetURL() : CefString())) {
      [controller_ requestExternalAppURL:S(url) fromPage:frame ? S(frame->GetURL()) : @"" tab:tabID_ generation:generation_];
      return true;
    }
    if (disposition == CEF_WOD_NEW_BACKGROUND_TAB && !url.empty()) {
      [controller_ openLinkFrom:tabID_ generation:generation_ url:S(url) background:YES];
      return true;
    }
    return ![controller_ preparePopupFrom:tabID_ generation:generation_ popupID:popupID url:S(url) windowInfo:info client:client];
  }
  void OnBeforePopupAborted(CefRefPtr<CefBrowser>, int popupID) override {
    [controller_ popupAbortedFrom:tabID_ generation:generation_ popupID:popupID];
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &title) override {
    [controller_ updateTitle:S(title) tab:tabID_ generation:generation_];
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser>, const std::vector<CefString> &urls) override {
    if (!urls.empty()) [controller_ updateFavicon:S(urls.front()) tab:tabID_ generation:generation_];
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
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool gesture, bool) override {
    CEF_REQUIRE_UI_THREAD();
    if (frame->IsMain()) [controller_ passwordPageNavigating:tabID_ generation:generation_];
    const CefString url = request->GetURL();
    const bool allowed = RailNavigationAllowed(url) || (RailIsFileURL(url) && frame->IsMain() && FileNavigationAllowed(frame, request));
    if (!allowed && (frame->IsMain() || RailIsExternalAppURL(url))) {
      // Auth redirects often have no user gesture. The native prompt supplies
      // consent for top-level navigation; hidden frames cannot initiate it.
      if (frame->IsMain() || gesture)
        [controller_ requestExternalAppURL:S(url) fromPage:S(frame->GetURL()) tab:tabID_ generation:generation_];
      return true;
    }
    return false;
  }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString &url,
      WindowOpenDisposition disposition, bool gesture) override {
    CEF_REQUIRE_UI_THREAD();
    if (RailOpenAllowedFrom(url, frame ? frame->GetURL() : CefString())) {
      if (disposition == CEF_WOD_NEW_BACKGROUND_TAB || disposition == CEF_WOD_NEW_FOREGROUND_TAB) {
        [controller_ openLinkFrom:tabID_ generation:generation_ url:S(url) background:disposition == CEF_WOD_NEW_BACKGROUND_TAB];
        return true;
      }
      return false;
    }
    if (gesture && frame)
      [controller_ requestExternalAppURL:S(url) fromPage:S(frame->GetURL()) tab:tabID_ generation:generation_];
    return true;
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
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, const CefString &name,
      CefRefPtr<CefBeforeDownloadCallback> callback) override {
    // Files go straight to Downloads, as in Arc; the toolbar's downloads button lists them.
    BrowserController *controller = controller_; if (!controller) return false;
    NSString *path = [controller downloadPathForName:S(name) download:item->GetId()];
    if (!path) return false;
    callback->Continue(path.UTF8String, false); return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback> callback) override {
    [controller_ downloadUpdated:item callback:callback];
  }
 private:
  __weak BrowserController *controller_;
  std::string tabID_;
  uint64_t generation_;
  IMPLEMENT_REFCOUNTING(RailClient);
};
}
void ShowRailDevTools(BrowserController *controller, CefRefPtr<CefBrowser> browser, const std::string &tabID, uint64_t generation,
    bool docked, const CefPoint &inspectAt) {
  CEF_REQUIRE_UI_THREAD();
  if (!browser || !browser->IsValid()) return;
  CefWindowInfo info;
  info.bounds=CefRect(0,0,1100,750); CefString(&info.window_name)="Rail DevTools";
  info.runtime_style=CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  browser->GetHost()->ShowDevTools(info,new DevToolsClient(controller,tabID,generation,docked),settings,inspectAt);
}
bool RailNavigationAllowed(const CefString &url) {
  NSString *address = S(url);
  if ([address isEqualToString:@"about:blank"]) return true;
  NSString *scheme = [NSURLComponents componentsWithString:address].scheme.lowercaseString;
  return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
}
bool RailIsFileURL(const CefString &url) {
  NSURLComponents *parts = [NSURLComponents componentsWithString:S(url)];
  // A host would point at a network share, which is not a file on this Mac.
  return [parts.scheme.lowercaseString isEqualToString:@"file"] && (!parts.host.length || [parts.host.lowercaseString isEqualToString:@"localhost"]);
}
bool RailIsExternalAppURL(const CefString &url) {
  NSURLComponents *parts = [NSURLComponents componentsWithString:S(url)];
  NSString *scheme = parts.scheme.lowercaseString;
  if (!scheme.length || !parts.URL) return false;
  // Browser content and local files must never be handed to Launch Services,
  // even if macOS happens to have an application registered for their scheme.
  if ([@[@"http", @"https", @"file", @"about", @"data", @"blob", @"filesystem",
         @"javascript", @"view-source", @"chrome", @"devtools", @"chrome-devtools",
         @"ws", @"wss"] containsObject:scheme] || [scheme hasPrefix:@"chrome-"]) return false;
  return true;
}
CefRefPtr<CefClient> MakeRailClient(BrowserController *controller, const std::string &tabID, uint64_t generation) {
  return new RailClient(controller,tabID,generation);
}
CefRefPtr<CefApp> MakeRailApp(BrowserController *controller) { return new RailApp(controller); }
