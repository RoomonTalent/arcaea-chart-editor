#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <limits>
#include <optional>

#include "chart_audio.h"
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
  chart_audio_ = std::make_unique<ChartAudio>(
      flutter_controller_->engine()->messenger());
  calibration_audio_ = std::make_unique<ChartAudio>(
      flutter_controller_->engine()->messenger(),
      "arcaea_manager/chart_calibration_audio");
  flutter::MethodChannel<flutter::EncodableValue> editor_input(
      flutter_controller_->engine()->messenger(), "arcaea_manager/chart_input",
      &flutter::StandardMethodCodec::GetInstance());
  editor_input.SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "wheelStep") {
      result->NotImplemented();
      return;
    }
    UINT lines = 3;
    SystemParametersInfo(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
    // Flutter scales WM_MOUSEWHEEL detents by this system preference.
    const double scale = static_cast<float>(lines) * 100.0 / 3.0;
    const double step = lines == WHEEL_PAGESCROLL
                            ? static_cast<double>((std::numeric_limits<int>::min)())
                            : static_cast<double>(static_cast<int>(scale));
    result->Success(flutter::EncodableValue(step));
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  calibration_audio_.reset();
  chart_audio_.reset();
  if (flutter_controller_) {
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
