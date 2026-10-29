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

#ifndef ECLIPSA_STUDIO_GRAPH_ROUTING_SCATTER_H_
#define ECLIPSA_STUDIO_GRAPH_ROUTING_SCATTER_H_

#include <algorithm>
#include <bit>
#include <cstddef>
#include <cstdint>

// Pure, audio-thread-safe helpers that map the planar OAR render into the
// interleaved device buffer per the monitoring routing matrix. Factored out
// of AudioGraph::process() so the engine tests can drive them without an OAR
// renderer. No allocation, no locks, no globals.

/// Scatter planar OAR output `rendered[rch][fr]` (stride `fr`, channel-major)
/// into the interleaved device buffer `out[fr][channels]` per the per-OAR-
/// channel `routing` masks (length `rch`). `routing[c]` is a device-channel
/// bitmask: bit `d` set = OAR channel `c` feeds device channel `d`.
///
/// `out` MUST be pre-zeroed. Splits (one OAR channel → several device
/// channels) write each set bit; sums (several OAR channels → one device
/// channel) accumulate via `+=`. Bits `>= channels` are skipped so a mask
/// pointing past the device's channel count can never write out of bounds.
inline void scatter_routed(float* out, const float* rendered,
                           const uint64_t* routing, uint32_t rch, uint32_t fr,
                           uint32_t channels) {
  for (uint32_t c = 0; c < rch; ++c) {
    uint64_t mask = routing[c];
    while (mask) {
      // lowest set device ch
      const uint32_t dst = static_cast<uint32_t>(std::countr_zero(mask));
      mask &= mask - 1;               // clear it, advance
      if (dst >= channels) continue;  // out-of-range guard
      const float* src = rendered + static_cast<size_t>(c) * fr;
      for (uint32_t f = 0; f < fr; ++f) {
        out[static_cast<size_t>(f) * channels + dst] += src[f];
      }
    }
  }
}

/// scatter_routed() with a ramped gain on each channel of `rendered`, for
/// the output-channel solo and mute of the monitoring target; AudioGraph
/// passes the block in monitoring channel order. Bit `c` of
/// `silenced` set = channel `c` ramps to silence; clear = to unity.
/// `gains[c]` (length `rch`) is the channel's gain at the start of the
/// block; it moves toward its target by at most `step` per frame, and the
/// value reached is written back for the next block. A channel at 0 that
/// stays silenced is skipped. `out` and `routing` as in scatter_routed();
/// `rch` must not exceed 64.
inline void scatter_routed_ramped(float* out, const float* rendered,
                                  const uint64_t* routing, uint64_t silenced,
                                  float* gains, float step, uint32_t rch,
                                  uint32_t fr, uint32_t channels) {
  for (uint32_t c = 0; c < rch; ++c) {
    const float target = ((silenced >> c) & 1u) != 0 ? 0.0f : 1.0f;
    float g = gains[c];
    if (g == 0.0f && target == 0.0f) continue;
    const uint64_t routed = routing[c];
    const float* src = rendered + static_cast<size_t>(c) * fr;
    for (uint32_t f = 0; f < fr; ++f) {
      if (g < target) {
        g = std::min(g + step, target);
      } else if (g > target) {
        g = std::max(g - step, target);
      }
      const float v = src[f] * g;
      uint64_t mask = routed;
      while (mask) {
        const uint32_t dst = static_cast<uint32_t>(std::countr_zero(mask));
        mask &= mask - 1;
        if (dst < channels) out[static_cast<size_t>(f) * channels + dst] += v;
      }
    }
    gains[c] = g;
  }
}

/// Inject a per-frame noise block into the interleaved device buffer.
/// `noise[f]` is the already-scaled noise sample for frame `f`.
///
///  - `mode == 1` (row, pre-routing): `channel` indexes the active OAR output
///    channel; the sample fans out through `routing[channel]` exactly like
///    program audio would, so it follows the patch to its device channel(s).
///  - `mode == 2` (col, post-routing): `channel` indexes the device output
///    channel; the sample goes straight there, bypassing the routing matrix.
///
/// `out` MUST be pre-zeroed and program audio MUST already be muted by the
/// caller (single-select, program-muting calibration). Accumulates via `+=`.
/// Out-of-range channels / device bits are skipped.
inline void scatter_noise(float* out, const float* noise, uint8_t mode,
                          uint32_t channel, const uint64_t* routing,
                          uint32_t rch, uint32_t fr, uint32_t channels) {
  if (mode == 1) {  // row: pre-routing, follow the patch.
    if (channel >= rch) return;
    const uint64_t base = routing[channel];
    for (uint32_t f = 0; f < fr; ++f) {
      uint64_t mask = base;
      while (mask) {
        const uint32_t dst = static_cast<uint32_t>(std::countr_zero(mask));
        mask &= mask - 1;
        if (dst < channels) {
          out[static_cast<size_t>(f) * channels + dst] += noise[f];
        }
      }
    }
  } else if (mode == 2) {  // col: post-routing, straight to the device.
    if (channel >= channels) return;
    for (uint32_t f = 0; f < fr; ++f) {
      out[static_cast<size_t>(f) * channels + channel] += noise[f];
    }
  }
}

#endif  // ECLIPSA_STUDIO_GRAPH_ROUTING_SCATTER_H_
