#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/event_channel.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject &project);
  virtual ~FlutterWindow();

protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

private:
  static LRESULT CALLBACK KeyboardHook(int code, WPARAM wparam, LPARAM lparam);
  void SendKeyboardEvent(const flutter::EncodableValue &event);
  bool SecureInputActive() const;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      capabilities_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      keyboard_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      keyboard_control_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> keyboard_sink_;
  HHOOK keyboard_hook_ = nullptr;
  static FlutterWindow *keyboard_window_;
};

#endif // RUNNER_FLUTTER_WINDOW_H_
