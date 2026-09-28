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

import '../logging/log.dart';
import 'av_foundation_backend.dart';
import 'ffmpeg_engine_backend.dart';
import 'mf_video_backend.dart';
import 'still_image_backend.dart';
import 'video_backend.dart';
import 'video_backend_kind.dart';

/// Construct the concrete [VideoBackend] for [kind].
///
/// [kind] is expected to be a *resolved concrete* kind: `resolveBackendKind`
/// maps `auto` and falls unimplemented / unsupported kinds back to
/// [kHardFallbackBackend], so in practice only AVFoundation / Media
/// Foundation / FFmpeg reach here. `auto` is unreachable; it asserts in debug
/// (to catch a newly-added kind that forgot a factory) and degrades
/// gracefully to the hard fallback in release.
///
/// Shared by the main coordinator ([VideoNotifier]) and the pop-out window
/// ([VideoPopoutApp], which runs in its own Flutter engine), so both build
/// the selected backend the same way.
VideoBackend createVideoBackend(VideoBackendKind kind) {
  switch (kind) {
    case VideoBackendKind.avFoundation:
      // macOS-native, the macOS default. The native Runner controller
      // (macos/Runner/AvfVideoController.swift) is registered both in the
      // main window (MainFlutterWindow) and in pop-out sub-windows (the
      // setOnWindowCreatedCallback in AppDelegate), so the same channel is
      // available wherever this backend is built.
      return AvFoundationBackend();
    case VideoBackendKind.ffmpegEngine:
      // FFmpeg decode in the C++ engine, pulled over the eclipsa_studio_video_*
      // FFI. Pure Dart + FFI (no native texture plugin), so it builds the same
      // way in the main window and in pop-out sub-windows.
      return FfmpegEngineBackend();
    case VideoBackendKind.mediaFoundation:
      // Windows-native, the Windows default. The native runner controller
      // (windows/runner/mf_video_controller.{h,cpp}) is registered both in the
      // main window (flutter_window.cpp) and in pop-out sub-windows, so the
      // eclipsa/mf_video channel is available wherever this backend is built.
      return MfVideoBackend();
    case VideoBackendKind.stillImage:
      // Pure Dart (Flutter's bundled image codecs), so like FFmpeg-in-engine
      // it builds the same way in the main window and in pop-out sub-windows.
      return StillImageBackend();
    case VideoBackendKind.auto:
      assert(false, 'no factory registered for video backend ${kind.name}');
      Log.w(
        LogCat.video,
        'video backend ${kind.name} unavailable; '
        'using ${kHardFallbackBackend.name}',
      );
      return FfmpegEngineBackend();
  }
}
