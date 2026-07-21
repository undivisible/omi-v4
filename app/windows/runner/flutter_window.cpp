#include "flutter_window.h"

#include <UIAutomation.h>
#include <flutter/event_stream_handler_functions.h>
#include <shellapi.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

bool HasMicrophoneAccess() {
  wchar_t value[16] = {};
  DWORD size = sizeof(value);
  return RegGetValueW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Capabilit"
                      L"yAccessManager\\ConsentStore\\microphone",
                      L"Value", RRF_RT_REG_SZ, nullptr, value,
                      &size) == ERROR_SUCCESS &&
         _wcsicmp(value, L"Allow") == 0;
}

} // namespace

FlutterWindow *FlutterWindow::keyboard_window_ = nullptr;

FlutterWindow::FlutterWindow(const flutter::DartProject &project)
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
  capabilities_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "omi/core_capabilities",
          &flutter::StandardMethodCodec::GetInstance());
  capabilities_channel_->SetMethodCallHandler(
      [](const auto &call, auto result) {
        if (call.method_name() == "check") {
          result->Success(flutter::EncodableMap{
              {flutter::EncodableValue("microphone"),
               flutter::EncodableValue(HasMicrophoneAccess())},
          });
          return;
        }
        if (call.method_name() == "request") {
          const auto *capability = std::get_if<std::string>(call.arguments());
          if (capability == nullptr || *capability != "microphone") {
            result->Error("invalid_capability");
            return;
          }
          const auto opened =
              ShellExecuteW(nullptr, L"open", L"ms-settings:privacy-microphone",
                            nullptr, nullptr, SW_SHOWNORMAL);
          if (reinterpret_cast<INT_PTR>(opened) <= 32) {
            result->Error("settings_unavailable");
            return;
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  keyboard_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "omi/desktop_keyboard",
          &flutter::StandardMethodCodec::GetInstance());
  keyboard_channel_->SetStreamHandler(
      std::make_unique<
          flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const auto *, auto &&sink) {
            keyboard_sink_ = std::move(sink);
            SendKeyboardEvent(flutter::EncodableMap{
                {flutter::EncodableValue("type"),
                 flutter::EncodableValue("secureInput")},
                {flutter::EncodableValue("enabled"),
                 flutter::EncodableValue(SecureInputActive())},
            });
            return nullptr;
          },
          [this](const auto *) {
            keyboard_sink_.reset();
            return nullptr;
          }));
  keyboard_control_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "omi/desktop_keyboard_control",
          &flutter::StandardMethodCodec::GetInstance());
  keyboard_control_channel_->SetMethodCallHandler(
      [this](const auto &call, auto result) {
        if (call.method_name() != "focus") {
          result->NotImplemented();
          return;
        }
        ShowWindow(GetHandle(), SW_RESTORE);
        SetForegroundWindow(GetHandle());
        result->Success();
      });
  keyboard_window_ = this;
  keyboard_hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardHook, nullptr, 0);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    if (keyboard_hook_) {
      UnhookWindowsHookEx(keyboard_hook_);
      keyboard_hook_ = nullptr;
    }
    keyboard_window_ = nullptr;
    keyboard_sink_.reset();
    keyboard_control_channel_.reset();
    keyboard_channel_.reset();
    capabilities_channel_.reset();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SendKeyboardEvent(const flutter::EncodableValue &event) {
  if (keyboard_sink_)
    keyboard_sink_->Success(event);
}

bool FlutterWindow::SecureInputActive() const {
  IUIAutomation *automation = nullptr;
  IUIAutomationElement *element = nullptr;
  BOOL password = FALSE;
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const HRESULT created =
      CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                       IID_PPV_ARGS(&automation));
  if (SUCCEEDED(created)) {
    if (FAILED(automation->GetFocusedElement(&element)) || !element ||
        FAILED(element->get_CurrentIsPassword(&password))) {
      password = TRUE;
    }
  }
  if (element)
    element->Release();
  if (automation)
    automation->Release();
  if (SUCCEEDED(initialized))
    CoUninitialize();
  return FAILED(created) || password == TRUE;
}

LRESULT CALLBACK FlutterWindow::KeyboardHook(int code, WPARAM wparam,
                                             LPARAM lparam) {
  if (code == HC_ACTION && keyboard_window_) {
    const auto *event = reinterpret_cast<KBDLLHOOKSTRUCT *>(lparam);
    const bool pressed = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
    const bool released = wparam == WM_KEYUP || wparam == WM_SYSKEYUP;
    const bool relevant = event->vkCode == VK_LSHIFT ||
                          event->vkCode == VK_RSHIFT ||
                          event->vkCode == VK_ESCAPE;
    if (!relevant || (event->flags & LLKHF_INJECTED) != 0 ||
        (!pressed && !released)) {
      return CallNextHookEx(nullptr, code, wparam, lparam);
    }
    const bool secure = keyboard_window_->SecureInputActive();
    keyboard_window_->SendKeyboardEvent(flutter::EncodableMap{
        {flutter::EncodableValue("type"),
         flutter::EncodableValue("secureInput")},
        {flutter::EncodableValue("enabled"), flutter::EncodableValue(secure)},
    });
    if (!secure) {
      if (event->vkCode == VK_LSHIFT || event->vkCode == VK_RSHIFT) {
        keyboard_window_->SendKeyboardEvent(flutter::EncodableMap{
            {flutter::EncodableValue("type"), flutter::EncodableValue("shift")},
            {flutter::EncodableValue("key"),
             flutter::EncodableValue(event->vkCode == VK_LSHIFT ? "left"
                                                                : "right")},
            {flutter::EncodableValue("pressed"),
             flutter::EncodableValue(pressed)},
        });
      } else if (event->vkCode == VK_ESCAPE && pressed) {
        keyboard_window_->SendKeyboardEvent(flutter::EncodableMap{
            {flutter::EncodableValue("type"),
             flutter::EncodableValue("escape")},
        });
      }
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
