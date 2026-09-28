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

#ifndef ECLIPSA_STUDIO_ENGINE_TRANSPORT_FADE_H_
#define ECLIPSA_STUDIO_ENGINE_TRANSPORT_FADE_H_

#include <algorithm>
#include <cstdint>

/// Transport edge fades (ES-530): a short gain ramp applied to the device
/// output so play/stop never hard-cut the program mid-waveform. The
/// user stop click was the reported symptom; the start edge gets the
/// symmetric (shorter) ramp — less audible because program follows the
/// discontinuity, but the same mechanism.
///
/// Durations are WALL-CLOCK milliseconds: the per-frame step derives
/// from the device sample rate, and the gain value persists across
/// callbacks, so the fade shape is invariant across every sample-rate /
/// buffer-size combination — a 64-frame buffer just spends more
/// callbacks inside the ramp than a 2048-frame one. Pinned per
/// rate × buffer in //test:transport_fade_test.
///
/// Pure functions, audio-thread-safe by construction (no state, no
/// allocation); the caller owns the gain value.

/// Fade durations. Both 10 ms: a 5 ms attack was still faintly
/// audible on program material in by-ear testing (ES-530), and at this
/// scale the transient softening is imperceptible.
inline constexpr float kTransportFadeInMs = 10.0f;
inline constexpr float kTransportFadeOutMs = 10.0f;

/// Per-frame gain step for a [0,1] traversal in `fade_ms` at `rate`.
inline float transport_fade_step(float fade_ms, uint32_t sample_rate) {
  const float frames = fade_ms * 0.001f * static_cast<float>(sample_rate);
  return frames >= 1.0f ? 1.0f / frames : 1.0f;
}

/// Ramps `gain` toward `target` across the interleaved block, applying
/// it per frame, and returns the gain after the block. Frames at
/// gain == 1 are left untouched (unity is a multiply-free pass);
/// callers should skip the call entirely in the steady gain == target
/// == 1 state.
inline float transport_fade_apply(float* out, uint32_t frames,
                                  uint32_t channels, float gain, float target,
                                  float step_up, float step_down) {
  for (uint32_t f = 0; f < frames; ++f) {
    if (gain < target) {
      gain = std::min(target, gain + step_up);
    } else if (gain > target) {
      gain = std::max(target, gain - step_down);
    }
    if (gain < 1.0f) {
      for (uint32_t c = 0; c < channels; ++c) {
        out[f * channels + c] *= gain;
      }
    }
  }
  return gain;
}

#endif  // ECLIPSA_STUDIO_ENGINE_TRANSPORT_FADE_H_
