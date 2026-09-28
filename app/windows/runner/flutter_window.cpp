// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "flutter_window.h"

#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <optional>
#include <vector>

#include <screen_retriever_windows/screen_retriever_windows_plugin_c_api.h>
#include <window_manager/window_manager_plugin.h>

#include "flutter/generated_plugin_registrant.h"
#include "ffmpeg_video_controller.h"
#include "mf_video_controller.h"

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

  // Hand-register the native video texture plugins (they are not pub plugins,
  // so RegisterPlugins doesn't touch them) — the Windows analogue of macOS's
  // MainFlutterWindow registration. One registrar provides the messenger +
  // texture registrar both the FFmpeg-in-engine (eclipsa/ffmpeg_video) and
  // native Media Foundation (eclipsa/mf_video) backends use. Registering here
  // (and in the pop-out window's runner) makes the channels available wherever
  // a Flutter engine hosts the video panel.
  video_registrar_ = std::make_unique<flutter::PluginRegistrarWindows>(
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "EclipsaStudioVideo"));
  ffmpeg_video_ = std::make_unique<FfmpegVideoPlugin>(
      video_registrar_->messenger(), video_registrar_->texture_registrar());
  mf_video_ = std::make_unique<MfVideoPlugin>(
      video_registrar_->messenger(), video_registrar_->texture_registrar());

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
  // Tear the native video plugins down before the engine: they unregister their
  // textures via the registrar, which must outlive them.
  ffmpeg_video_ = nullptr;
  mf_video_ = nullptr;
  video_registrar_ = nullptr;

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

namespace {
// One registrar + native video plugin pair per pop-out sub-window.
struct VideoPluginSet {
  std::unique_ptr<flutter::PluginRegistrarWindows> registrar;
  std::unique_ptr<FfmpegVideoPlugin> ffmpeg;
  std::unique_ptr<MfVideoPlugin> mf;
};

std::vector<std::unique_ptr<VideoPluginSet>>& VideoPluginRegistry() {
  static auto* registry = new std::vector<std::unique_ptr<VideoPluginSet>>();
  return *registry;
}
}  // namespace

void EclipsaStudioVideoOnWindowCreated(void* flutter_view_controller) {
  auto* controller =
      static_cast<flutter::FlutterViewController*>(flutter_view_controller);
  if (controller == nullptr || controller->engine() == nullptr) return;

  // A desktop_multi_window sub-window's engine starts with NO pub plugins —
  // the plugin registers only its own window channel (unlike macOS, where
  // AppDelegate calls RegisterGeneratedPlugins for every sub-window). The
  // pop-out re-enters Dart main(), which awaits window_manager
  // (ensureInitialized / show / fullscreen / preventClose) and — via
  // window_manager's Dart-side `center` — screen_retriever before it can
  // runApp; without these channels main() dies on a MissingPluginException
  // and the pop-out stays black. Register exactly those two here. Do NOT
  // switch this to the full generated RegisterPlugins(): flutter_angle keeps
  // its texture registrar in a static, so registering it on a sub-engine
  // would repoint the main window's 3D renderer at the pop-out's registrar.
  WindowManagerPluginRegisterWithRegistrar(
      controller->engine()->GetRegistrarForPlugin("WindowManagerPlugin"));
  ScreenRetrieverWindowsPluginCApiRegisterWithRegistrar(
      controller->engine()->GetRegistrarForPlugin(
          "ScreenRetrieverWindowsPluginCApi"));

  auto set = std::make_unique<VideoPluginSet>();
  set->registrar = std::make_unique<flutter::PluginRegistrarWindows>(
      controller->engine()->GetRegistrarForPlugin("EclipsaStudioVideo"));
  set->ffmpeg = std::make_unique<FfmpegVideoPlugin>(
      set->registrar->messenger(), set->registrar->texture_registrar());
  set->mf = std::make_unique<MfVideoPlugin>(
      set->registrar->messenger(), set->registrar->texture_registrar());

  // Retained for the process lifetime. desktop_multi_window gives no
  // window-destroyed hook on Windows, but the pop-out's Dart side disposes its
  // backend (channel 'dispose'/'unload') before the sub-engine tears down, so
  // the players clean themselves up while the engine is still alive. Keeping
  // these (by-then empty) shells alive avoids their destructors touching the
  // already-destroyed messenger / texture registrar.
  VideoPluginRegistry().push_back(std::move(set));
}
