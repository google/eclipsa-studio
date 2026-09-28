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

#include "video/video_ffi.h"

#include "video/video_decoder.h"

// Thin C shim over eclipsa_studio::video::VideoDecoder, linked into the engine
// shared library and bound from Dart. See video/README.md.

using eclipsa_studio::video::VideoDecoder;

extern "C" {

EclipsaStudioVideoDecoder* eclipsa_studio_video_open(const char* path) {
  if (path == nullptr) {
    return nullptr;
  }
  // Don't let std::bad_alloc / FFmpeg-wrapper exceptions escape across the
  // C ABI boundary.
  try {
    auto* dec = new VideoDecoder();
    if (!dec->Open(path)) {
      delete dec;
      return nullptr;
    }
    return reinterpret_cast<EclipsaStudioVideoDecoder*>(dec);
  } catch (...) {
    return nullptr;
  }
}

EclipsaStudioVideoInfo eclipsa_studio_video_info(
    EclipsaStudioVideoDecoder* handle) {
  EclipsaStudioVideoInfo out = {};
  if (handle == nullptr) {
    return out;
  }
  const auto& info = reinterpret_cast<VideoDecoder*>(handle)->Info();
  out.width = info.width;
  out.height = info.height;
  out.fps = info.fps;
  out.duration_ms = info.duration_ms;
  out.ok = info.ok ? 1 : 0;
  out.hw = info.hw ? 1 : 0;
  out.quarter_turns = info.quarter_turns;
  return out;
}

const uint8_t* eclipsa_studio_video_frame_at_seconds(
    EclipsaStudioVideoDecoder* handle, double seconds, int* out_w, int* out_h,
    int* out_stride) {
  if (handle == nullptr) {
    return nullptr;
  }
  return reinterpret_cast<VideoDecoder*>(handle)->FrameAtSeconds(
      seconds, out_w, out_h, out_stride);
}

void* eclipsa_studio_video_frame_at_seconds_pixbuf(
    EclipsaStudioVideoDecoder* handle, double seconds, int* out_w, int* out_h) {
  if (handle == nullptr) {
    return nullptr;
  }
  return reinterpret_cast<VideoDecoder*>(handle)->FrameAtSecondsPixbuf(
      seconds, out_w, out_h);
}

void eclipsa_studio_video_release_pixbuf(void* pixbuf) {
  VideoDecoder::ReleasePixbuf(pixbuf);
}

void eclipsa_studio_video_close(EclipsaStudioVideoDecoder* handle) {
  delete reinterpret_cast<VideoDecoder*>(handle);
}

}  // extern "C"
