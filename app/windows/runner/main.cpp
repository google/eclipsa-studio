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

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// From the desktop_multi_window plugin: register a callback invoked with each
// pop-out sub-window's flutter::FlutterViewController* when it is created.
// Declared here (rather than including the plugin header) to avoid depending on
// the plugin's include path from the runner; the symbol is resolved via the
// plugin the runner already links.
extern "C" void DesktopMultiWindowSetWindowCreatedCallback(
    void (*callback)(void* flutter_view_controller));

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

  // Register plugins on every pop-out sub-window desktop_multi_window
  // creates — the Windows analogue of macOS AppDelegate's
  // setOnWindowCreatedCallback: the native video texture plugins
  // (eclipsa/ffmpeg_video, eclipsa/mf_video) so the FFmpeg and Media
  // Foundation backends work in the pop-out too, plus the pub plugins the
  // pop-out's Dart main() needs (window_manager, screen_retriever). The main
  // window registers the video plugins itself in FlutterWindow::OnCreate and
  // gets its pub plugins from the generated registrant.
  DesktopMultiWindowSetWindowCreatedCallback(
      &EclipsaStudioVideoOnWindowCreated);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Eclipsa Studio", origin, size)) {
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
