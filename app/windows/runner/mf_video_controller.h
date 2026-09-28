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

#ifndef RUNNER_MF_VIDEO_CONTROLLER_H_
#define RUNNER_MF_VIDEO_CONTROLLER_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <memory>

#include "win_video_texture.h"

// Impl detail (owns the Media Foundation reader + D3D11 objects for one clip).
class MfVideoPlayer;

// Native Windows Media Foundation video backend controller — the counterpart of
// macos/Runner/AvfVideoController.swift. Owns the eclipsa/mf_video channel and
// the active clip's IMFSourceReader; decodes with a D3D11 device (hardware
// where available), converts each decoded NV12 frame to a shareable BGRA
// texture (ID3D11VideoProcessor) and vends it as a zero-copy Flutter
// GpuSurfaceTexture. Pull-based: renderAt seeks + reads the exact frame, so
// there is no drift loop (setPlaying is a no-op). Registered in the main and
// pop-out windows (flutter_window.cpp).
//
// Channel protocol (mirrors AvfVideoController):
//   load {path}          -> {textureId, width, height, fps, durationMs}
//   renderAt {seconds}   -> null
//   setPlaying {playing} -> null   (pull-based: no-op)
//   unload               -> null
//   dispose              -> null
class MfVideoPlugin {
 public:
  MfVideoPlugin(flutter::BinaryMessenger* messenger,
                flutter::TextureRegistrar* textures);
  ~MfVideoPlugin();

  MfVideoPlugin(const MfVideoPlugin&) = delete;
  MfVideoPlugin& operator=(const MfVideoPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::TextureRegistrar* textures_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<MfVideoPlayer> player_;  // the active clip, or null
};

#endif  // RUNNER_MF_VIDEO_CONTROLLER_H_
