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

#ifndef ECLIPSA_STUDIO_GRAPH_AUDIO_BUFFER_H_
#define ECLIPSA_STUDIO_GRAPH_AUDIO_BUFFER_H_

#include <cassert>
#include <cstdint>
#include <cstring>

/// Non-owning, non-allocating planar float buffer.
///
/// Layout: data[channel * capacity_frames + frame_index]
///
/// All memory is pre-allocated outside this struct; AudioBuffer is just
/// a lightweight view. Safe to copy/assign (copies the view, not the data).
struct AudioBuffer {
  float* data = nullptr;
  uint32_t channels = 0;
  uint32_t frames = 0;           ///< Valid frame count for current block
  uint32_t capacity_frames = 0;  ///< Allocated frames per channel

  /// Pointer to the start of channel `ch`'s sample data.
  float* channel(uint32_t ch) {
    assert(ch < channels);
    return data + static_cast<size_t>(ch) * capacity_frames;
  }

  const float* channel(uint32_t ch) const {
    assert(ch < channels);
    return data + static_cast<size_t>(ch) * capacity_frames;
  }

  /// Zero all sample memory (not just the valid frames — full capacity).
  void zero() {
    if (data && channels && capacity_frames) {
      std::memset(
          data, 0,
          static_cast<size_t>(channels) * capacity_frames * sizeof(float));
    }
  }

  /// Zero only the valid frame region.
  void zero_frames() {
    for (uint32_t ch = 0; ch < channels; ++ch) {
      std::memset(channel(ch), 0, frames * sizeof(float));
    }
  }
};

#endif  // ECLIPSA_STUDIO_GRAPH_AUDIO_BUFFER_H_
