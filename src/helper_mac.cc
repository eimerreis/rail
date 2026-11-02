#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "CredentialRenderer.h"

#if !defined(CEF_USE_SANDBOX)
#error Rail helpers must be built with the Chromium sandbox enabled.
#endif

int main(int argc, char* argv[]) {
  // The seatbelt sandbox must be initialized before the CEF framework is loaded.
  // See CEF's process_helper_mac.cc and include/wrapper/cef_library_loader.h.
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }

  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }

  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, MakeRailRendererApp(), nullptr);
}
