#include "flutter_window.h"

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
    capabilities_channel_.reset();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
