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

#ifndef ECLIPSA_STUDIO_VIDEO_STILL_VIDEO_ENCODER_H_
#define ECLIPSA_STUDIO_VIDEO_STILL_VIDEO_ENCODER_H_

#include <cmath>
#include <cstdint>

namespace eclipsa_studio {

// Hard ceilings on what StillVideoEncode accepts. 4096 stays inside
// every H.264 hardware encoder's per-dimension limit (VideoToolbox and
// Media Foundation both cap at 4096 for level 5.2); callers downscale
// beforehand (the app fits into 3840x2160). The duration ceiling turns
// a nonsense value into an error instead of an hours-long synchronous
// encode on the worker isolate.
inline constexpr uint32_t kStillVideoMaxDimension = 4096;
inline constexpr double kStillVideoMaxDurationSeconds = 24.0 * 3600.0;

// Shared argument validation for every StillVideoEncode implementation
// (macOS / Windows / stub) so the documented -1 contract cannot drift
// per OS. `rgba_size` guards the FFI boundary: the pixel pointer is
// only as trustworthy as the byte count the caller pairs with it.
inline bool StillVideoArgsValid(const uint8_t* rgba, uint64_t rgba_size,
                                uint32_t width, uint32_t height, uint32_t fps,
                                double duration_seconds,
                                const char* output_mp4) {
  if (rgba == nullptr || output_mp4 == nullptr) return false;
  if (width == 0 || height == 0 || (width % 2) != 0 || (height % 2) != 0) {
    return false;
  }
  if (width > kStillVideoMaxDimension || height > kStillVideoMaxDimension) {
    return false;
  }
  if (rgba_size < static_cast<uint64_t>(width) * height * 4) return false;
  if (fps == 0 || fps > 120) return false;
  if (!std::isfinite(duration_seconds) || !(duration_seconds > 0) ||
      duration_seconds > kStillVideoMaxDurationSeconds) {
    return false;
  }
  return true;
}

// Encode a single RGBA frame into an H.264 video-only MP4 of the given
// duration — the video half of a still-image "Export to YouTube" (ES-192):
// the caller muxes the result with the IAMF audio via eclipsa_studio_iamf_mux,
// whose phase-2 stream-copy accepts any ISOBMFF input.
//
// The frame is repeated at `fps` for `duration_seconds`, rounded UP to
// whole frames so the video never ends before the audio (the muxer's
// edit list clamps playback to the shorter track). Uses the OS encoder —
// VideoToolbox on macOS, Media Foundation on Windows — so the LGPL
// decode-only FFmpeg build stays encoder-free. `rgba` is tightly packed
// RGBA8888 (stride = width * 4, top-down) of at least `rgba_size` =
// width*height*4 bytes; dimensions must be even (H.264 4:2:0) and
// within kStillVideoMaxDimension. A failed encode does not leave a
// partial file behind.
//
// Error codes (keep in sync with the `eclipsa_studio_still_video_encode`
// contract in engine.h — that comment points here):
//   0    success
//  -1    bad arguments (StillVideoArgsValid)
//  -2    encoder session setup failed
//  -3    encoding failed
//  -4    writing the MP4 failed
//  -100  unsupported on this OS
int32_t StillVideoEncode(const uint8_t* rgba, uint64_t rgba_size,
                         uint32_t width, uint32_t height, uint32_t fps,
                         double duration_seconds, const char* output_mp4);

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_VIDEO_STILL_VIDEO_ENCODER_H_
