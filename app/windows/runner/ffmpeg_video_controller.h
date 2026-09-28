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

#ifndef RUNNER_FFMPEG_VIDEO_CONTROLLER_H_
#define RUNNER_FFMPEG_VIDEO_CONTROLLER_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <memory>

#include "win_video_texture.h"

// Windows counterpart of macos/Runner/FfmpegVideoController.swift. Unlike the
// AVFoundation/MF backends this side does NOT decode: the C++ engine decodes
// with D3D11VA and blits each frame into a shared BGRA texture, whose stable
// DXGI shared handle is handed through Dart to `present`. This registers a
// Flutter GpuSurfaceTexture and forwards the handle so the picture is sampled
// on the GPU with no readback — the zero-copy path the software RawImage
// fallback in FfmpegEngineBackend replaces when a HW surface is available.
//
// Handles the eclipsa/ffmpeg_video channel; registered in the main window and
// pop-out sub-windows (flutter_window.cpp), mirroring the macOS controller.
//
// Channel protocol (mirrors the Swift side):
//   create  {width, height}  -> {textureId}
//   present {buffer}         -> null   (buffer = the shared HANDLE as an int)
//   dispose                  -> null
class FfmpegVideoPlugin {
 public:
  FfmpegVideoPlugin(flutter::BinaryMessenger* messenger,
                    flutter::TextureRegistrar* textures);
  ~FfmpegVideoPlugin();

  FfmpegVideoPlugin(const FfmpegVideoPlugin&) = delete;
  FfmpegVideoPlugin& operator=(const FfmpegVideoPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::TextureRegistrar* textures_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  WinGpuSurfaceSink sink_;
  // Clip pixel dimensions from `create`, reported in the surface descriptor
  // (`present` carries only the shared handle).
  int width_ = 0;
  int height_ = 0;
};

#endif  // RUNNER_FFMPEG_VIDEO_CONTROLLER_H_
