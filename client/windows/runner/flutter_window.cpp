#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "pyvis/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const HWND window = GetHandle();
    const auto& command = call.method_name();
    if (command == "minimize") {
      ShowWindow(window, SW_MINIMIZE);
    } else if (command == "toggleMaximize") {
      ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
    } else if (command == "close") {
      PostMessage(window, WM_CLOSE, 0, 0);
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_SIZE && window_channel_ && wparam != SIZE_MINIMIZED) {
    const bool maximized = wparam == SIZE_MAXIMIZED;
    if (maximized_ != maximized) {
      maximized_ = maximized;
      window_channel_->InvokeMethod(
          "maximized", std::make_unique<flutter::EncodableValue>(maximized));
    }
  }
  if (window_channel_ &&
      (message == WM_NCMOUSEMOVE || message == WM_NCMOUSELEAVE)) {
    const bool hovered = message == WM_NCMOUSEMOVE && wparam == HTMAXBUTTON;
    if (maximize_hovered_ != hovered) {
      maximize_hovered_ = hovered;
      if (hovered) {
        TRACKMOUSEEVENT tracking{sizeof(TRACKMOUSEEVENT),
                                 TME_LEAVE | TME_NONCLIENT, hwnd, 0};
        TrackMouseEvent(&tracking);
      }
      window_channel_->InvokeMethod(
          "maximizeHovered",
          std::make_unique<flutter::EncodableValue>(hovered));
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
