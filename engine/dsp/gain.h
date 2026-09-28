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

#ifndef ECLIPSA_STUDIO_DSP_GAIN_H_
#define ECLIPSA_STUDIO_DSP_GAIN_H_

#include <cstdint>

#include "graph/audio_buffer.h"

namespace dsp {

static constexpr uint32_t kGainMaxChannels = 32;

/// Per-channel gain node with parameter smoothing.
///
/// Gain is stored as a linear multiplier internally.  Targets are set in dB
/// and converted immediately.  On each process() call the current gain ramps
/// toward the target to avoid clicks on parameter changes.
class Gain {
 public:
  Gain();

  /// Set the target gain for all channels at once (mono gain).
  void set_gain_db(float gain_db);

  /// Set the target gain for a specific channel.
  void set_channel_gain_db(uint32_t channel, float gain_db);

  /// Apply smoothed per-channel gain in-place.
  /// output.frames must be set by the caller before calling process().
  void process(AudioBuffer& buffer, uint32_t frames);

  void reset();

 private:
  static constexpr float kSmoothCoeff = 0.001f;  ///< Per-sample approach

  float target_linear_[kGainMaxChannels];
  float current_linear_[kGainMaxChannels];
};

}  // namespace dsp

#endif  // ECLIPSA_STUDIO_DSP_GAIN_H_
