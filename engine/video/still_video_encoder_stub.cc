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

// Fallback for platforms without a wired OS encoder (neither VideoToolbox
// nor Media Foundation). Keeps //video:still_video_encoder linkable
// everywhere; callers surface the unsupported error to the user.

#include "video/still_video_encoder.h"

namespace eclipsa_studio {

int32_t StillVideoEncode(const uint8_t* rgba, uint64_t rgba_size,
                         uint32_t width, uint32_t height, uint32_t fps,
                         double duration_seconds, const char* output_mp4) {
  // Validate first so the -1 contract (and its tests) hold on every
  // platform; only well-formed requests report "unsupported".
  if (!StillVideoArgsValid(rgba, rgba_size, width, height, fps,
                           duration_seconds, output_mp4)) {
    return -1;
  }
  return -100;
}

}  // namespace eclipsa_studio
