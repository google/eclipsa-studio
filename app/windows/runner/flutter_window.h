/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

namespace flutter {
class PluginRegistrarWindows;
}  // namespace flutter
class FfmpegVideoPlugin;
class MfVideoPlugin;

// Registers the native video texture plugins (eclipsa/ffmpeg_video,
// eclipsa/mf_video) on a pop-out sub-window's engine. Passed to
// DesktopMultiWindowSetWindowCreatedCallback in main.cpp; [flutter_view_controller]
// is the sub-window's flutter::FlutterViewController* (the Windows analogue of
// macOS AppDelegate.setOnWindowCreatedCallback). The created plugins are
// retained for the process lifetime — see the definition.
void EclipsaStudioVideoOnWindowCreated(void* flutter_view_controller);

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Native video texture plugins hand-registered after RegisterPlugins (they
  // are not pub plugins). The registrar owns the messenger + texture registrar
  // both plugins share; keep all three alive for the window's lifetime and tear
  // them down before the Flutter controller in OnDestroy.
  std::unique_ptr<flutter::PluginRegistrarWindows> video_registrar_;
  std::unique_ptr<FfmpegVideoPlugin> ffmpeg_video_;
  std::unique_ptr<MfVideoPlugin> mf_video_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
