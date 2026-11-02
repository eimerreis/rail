#include "CredentialRenderer.h"
#include "CredentialForm.h"
#include "include/cef_process_message.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_helpers.h"
#include <cstdlib>
#include <map>

namespace {
class CredentialRenderer final : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context>) override {
    if (frame->IsMain()) documents_[browser->GetIdentifier()] = std::to_string(arc4random()) + "-" + std::to_string(arc4random());
  }
  void OnContextReleased(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context>) override {
    if (frame->IsMain()) documents_.erase(browser->GetIdentifier());
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    CEF_REQUIRE_RENDERER_THREAD();
    if (source != PID_BROWSER || !frame->IsMain() || message->GetName() != "rail.credentials.request") return false;
    auto a = message->GetArgumentList();
    if (a->GetSize() != 7) return true;
    auto reply = CefProcessMessage::Create("rail.credentials.reply"); auto out = reply->GetArgumentList();
    const auto command = a->GetString(1).ToString(), url = frame->GetURL().ToString();
    auto found = documents_.find(browser->GetIdentifier());
    std::string token = found == documents_.end() ? "" : found->second;
    out->SetString(0,a->GetString(0)); out->SetString(1,command); out->SetString(2,url); out->SetString(3,token);
    std::string status = "stale_page";
    if (!token.empty() && url == a->GetString(2).ToString()) {
      if (command == "context") status = "ready";
      else if (command == "fill" && token == a->GetString(3).ToString()) {
        status = "no_fields";
        auto context = frame->GetV8Context();
        if (context && context->Enter()) {
          CefRefPtr<CefV8Value> function; CefRefPtr<CefV8Exception> exception;
          if (context->Eval(RailCredentialFormScript,"rail://credentials",1,function,exception) && function && function->IsFunction()) {
            CefV8ValueList args{CefV8Value::CreateString(a->GetString(4)),CefV8Value::CreateString(a->GetString(5)),CefV8Value::CreateBool(a->GetBool(6))};
            auto result = function->ExecuteFunction(nullptr,args);
            if (result && result->IsString()) status = result->GetStringValue().ToString();
          }
          context->Exit();
        }
      }
    }
    out->SetString(4,status); frame->SendProcessMessage(PID_BROWSER,reply); return true;
  }
 private:
  std::map<int,std::string> documents_;
  IMPLEMENT_REFCOUNTING(CredentialRenderer);
};
}
CefRefPtr<CefApp> MakeRailRendererApp() { return new CredentialRenderer(); }
