#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shlobj.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

void ConfigureWebViewUserDataFolder() {
  constexpr wchar_t variable[] = L"WEBVIEW2_USER_DATA_FOLDER";
  if (::GetEnvironmentVariableW(variable, nullptr, 0) != 0) {
    return;
  }

  // MSI installs may run from Program Files, where a standard user cannot
  // create WebView2's default data folder next to the executable.
  PWSTR local_app_data = nullptr;
  if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                       &local_app_data))) {
    const std::wstring folder =
        std::wstring(local_app_data) + L"\\Pyvis\\WebView2";
    ::SetEnvironmentVariableW(variable, folder.c_str());
  }
  ::CoTaskMemFree(local_app_data);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  ConfigureWebViewUserDataFolder();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Pyvis", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
