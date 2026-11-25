#include "win32_window.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// Keep Windows sizing and taskbar commands without requesting a native caption.
constexpr DWORD kWindowStyle =
    WS_POPUP | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

// Match the logical dimensions of the Flutter title bar and its three buttons.
constexpr int kTitleBarHeight = 36;
constexpr int kCaptionButtonWidth = 46;
constexpr int kWindowCornerRadius = 9;
constexpr wchar_t kExpandedMenuProperty[] = L"PyvisExpandedTitleBarMenu";
constexpr UINT_PTR kChildFrameSubclass = 1;
// DWMWA_BORDER_COLOR is available at runtime on Windows 11.
constexpr DWORD kBorderColorAttribute = 34;
constexpr DWORD kNoBorderColor = 0xFFFFFFFE;

LRESULT HitTestFrame(HWND window, LPARAM position) {
  const UINT dpi = GetDpiForWindow(window);
  POINT point{GET_X_LPARAM(position), GET_Y_LPARAM(position)};
  ScreenToClient(window, &point);
  RECT client{};
  GetClientRect(window, &client);

  if (!IsZoomed(window)) {
    const int padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    const int edge_x = GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) + padding;
    const int edge_y = GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) + padding;
    const bool left = point.x < edge_x;
    const bool right = point.x >= client.right - edge_x;
    if (point.y < edge_y) {
      return left ? HTTOPLEFT : right ? HTTOPRIGHT : HTTOP;
    }
    if (point.y >= client.bottom - edge_y) {
      return left ? HTBOTTOMLEFT : right ? HTBOTTOMRIGHT : HTBOTTOM;
    }
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
  }

  if (point.y < MulDiv(kTitleBarHeight, dpi, 96)) {
    int menu_width = client.right < MulDiv(240, dpi, 96) ? 36 : 72;
    if (client.right >= MulDiv(500, dpi, 96) &&
        GetProp(window, kExpandedMenuProperty)) {
      menu_width += 5 * 48;  // Match the five categories in the Flutter menu.
    }
    if (point.x < MulDiv(menu_width, dpi, 96)) {
      return HTCLIENT;
    }
    const int from_right = client.right - point.x;
    if (from_right > MulDiv(3 * kCaptionButtonWidth, dpi, 96)) {
      return HTCAPTION;
    }
    if (from_right > MulDiv(kCaptionButtonWidth, dpi, 96) &&
        from_right <= MulDiv(2 * kCaptionButtonWidth, dpi, 96)) {
      return HTMAXBUTTON;
    }
  }
  return HTCLIENT;
}

LRESULT CALLBACK ChildFrameProc(HWND child, UINT message, WPARAM wparam,
                                LPARAM lparam, UINT_PTR id, DWORD_PTR) {
  if (message == WM_NCHITTEST &&
      HitTestFrame(GetParent(child), lparam) != HTCLIENT) {
    // Let the parent receive non-client mouse messages over the Flutter view.
    return HTTRANSPARENT;
  }
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(child, ChildFrameProc, id);
  }
  return DefSubclassProc(child, message, wparam, lparam);
}

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindowEx(
      WS_EX_APPWINDOW, window_class, title.c_str(), kWindowStyle,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);
  DwmSetWindowAttribute(window, kBorderColorAttribute, &kNoBorderColor,
                        sizeof(kNoBorderColor));
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
  UpdateWindowRegion(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCCALCSIZE: {
      if (wparam && IsZoomed(hwnd)) {
        auto* bounds = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        const HMONITOR monitor =
            MonitorFromRect(&bounds->rgrc[0], MONITOR_DEFAULTTONEAREST);
        MONITORINFO info{};
        info.cbSize = sizeof(info);
        if (GetMonitorInfo(monitor, &info)) {
          bounds->rgrc[0] = info.rcWork;
        }
      }
      return 0;
    }

    case WM_NCHITTEST:
      return HitTestFrame(hwnd, lparam);

    case WM_GETMINMAXINFO: {
      DefWindowProc(hwnd, message, wparam, lparam);
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      const int min_width = MulDiv(190, GetDpiForWindow(hwnd), 96);
      if (limits->ptMinTrackSize.x < min_width) {
        limits->ptMinTrackSize.x = min_width;
      }
      return 0;
    }

    case WM_NCLBUTTONDOWN:
      if (wparam == HTMAXBUTTON) {
        SetCapture(hwnd);
        maximize_pressed_ = true;
        return 0;
      }
      break;

    case WM_NCLBUTTONDBLCLK:
      if (wparam == HTCAPTION) {
        PostMessage(hwnd, WM_SYSCOMMAND,
                    IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
        return 0;
      }
      break;

    case WM_LBUTTONUP:
      if (maximize_pressed_) {
        maximize_pressed_ = false;
        ReleaseCapture();
        POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        ClientToScreen(hwnd, &point);
        if (HitTestFrame(hwnd, MAKELPARAM(point.x, point.y)) == HTMAXBUTTON) {
          PostMessage(hwnd, WM_SYSCOMMAND,
                      IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
        }
        return 0;
      }
      break;

    case WM_CAPTURECHANGED:
      maximize_pressed_ = false;
      break;

    case WM_NCDESTROY:
      RemoveProp(hwnd, kExpandedMenuProperty);
      break;

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);
      UpdateWindowRegion(hwnd);

      return 0;
    }
    case WM_SIZE: {
      UpdateWindowRegion(hwnd);
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  SetWindowSubclass(content, ChildFrameProc, kChildFrameSubclass, 0);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetTitleBarMenuExpanded(bool expanded) {
  if (expanded) {
    SetProp(window_handle_, kExpandedMenuProperty,
            reinterpret_cast<HANDLE>(static_cast<INT_PTR>(1)));
  } else {
    RemoveProp(window_handle_, kExpandedMenuProperty);
  }
}

void Win32Window::UpdateWindowRegion(HWND window) {
  if (IsIconic(window)) return;
  if (IsZoomed(window)) {
    if (rounded_size_.cx != 0) {
      rounded_size_ = {};
      SetWindowRgn(window, nullptr, TRUE);
    }
    return;
  }

  RECT bounds{};
  if (!GetWindowRect(window, &bounds)) return;
  const SIZE size{bounds.right - bounds.left, bounds.bottom - bounds.top};
  const UINT dpi = GetDpiForWindow(window);
  if (size.cx <= 0 || size.cy <= 0 ||
      (size.cx == rounded_size_.cx && size.cy == rounded_size_.cy &&
       dpi == rounded_dpi_)) {
    return;
  }

  const int diameter = MulDiv(2 * kWindowCornerRadius, dpi, 96);
  HRGN region = CreateRoundRectRgn(0, 0, size.cx, size.cy, diameter, diameter);
  if (!region) return;
  // SetWindowRgn sends window-position messages and takes ownership on success.
  rounded_size_ = size;
  rounded_dpi_ = dpi;
  if (SetWindowRgn(window, region, TRUE) == 0) {
    rounded_size_ = {};
    DeleteObject(region);
  }
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
