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

#ifndef ECLIPSA_STUDIO_IO_STREAM_LAYOUT_H_
#define ECLIPSA_STUDIO_IO_STREAM_LAYOUT_H_

#include <cstdint>
#include <cstring>
#include <vector>

// Pure helpers for mapping a device's multi-stream output topology to
// the engine's single interleaved buffer. CoreAudio HAL devices expose
// their outputs as one or more streams (MOTU MicroBook II: four stereo
// streams for 8 outs); the engine renders one interleaved block of the
// device's total channel count, which the IOProc scatters into the
// per-stream buffers. Kept free of any CoreAudio types so the mapping
// is unit-testable without audio hardware (same posture as
// graph/routing_scatter.h).

namespace stream_layout {

/// Channel layout of a device's output streams: stream i covers device
/// channels [offsets[i], offsets[i] + counts[i]).
struct StreamLayout {
  std::vector<uint32_t> counts;   // channels per stream
  std::vector<uint32_t> offsets;  // first device channel per stream
  uint32_t total = 0;             // sum of counts
};

/// Build a StreamLayout from per-stream channel counts, in stream
/// order. Streams with zero channels keep a slot (offset equal to the
/// running total) so indices stay aligned with the device's stream
/// list.
inline StreamLayout MakeStreamLayout(const std::vector<uint32_t>& counts) {
  StreamLayout layout;
  layout.counts = counts;
  layout.offsets.reserve(counts.size());
  for (uint32_t c : counts) {
    layout.offsets.push_back(layout.total);
    layout.total += c;
  }
  return layout;
}

/// Scatter `frames` frames of `interleaved` (layout.total channels,
/// out[f * total + ch]) into per-stream interleaved destinations:
/// stream_dsts[s][f * counts[s] + c] = interleaved[f * total +
/// offsets[s] + c]. A null stream destination is skipped.
inline void ScatterToStreams(const float* interleaved, uint32_t frames,
                             const StreamLayout& layout,
                             float* const* stream_dsts) {
  for (size_t s = 0; s < layout.counts.size(); ++s) {
    float* dst = stream_dsts[s];
    if (dst == nullptr) continue;
    const uint32_t nc = layout.counts[s];
    const uint32_t off = layout.offsets[s];
    for (uint32_t f = 0; f < frames; ++f) {
      std::memcpy(dst + static_cast<size_t>(f) * nc,
                  interleaved + static_cast<size_t>(f) * layout.total + off,
                  nc * sizeof(float));
    }
  }
}

}  // namespace stream_layout

#endif  // ECLIPSA_STUDIO_IO_STREAM_LAYOUT_H_
