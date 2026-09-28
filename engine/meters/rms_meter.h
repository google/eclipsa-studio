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

#ifndef ECLIPSA_STUDIO_METERS_RMS_METER_H_
#define ECLIPSA_STUDIO_METERS_RMS_METER_H_

#include <cstdint>

#include "graph/audio_buffer.h"
#include "meters/meter_state.h"

/// Per-channel RMS meter using an exponential moving average.
///
/// Computes the true RMS over approximately the last `window_ms` milliseconds
/// and writes the linear amplitude value to state.elements[element_index].rms.
/// No allocation occurs on the audio thread.
class RmsMeter {
 public:
  /// @param window_ms   Integration window in milliseconds.
  explicit RmsMeter(float window_ms = 300.0f, uint32_t sample_rate = 48000);

  void set_sample_rate(uint32_t sample_rate);

  /// Process one buffer block and write linear RMS values into `state`
  /// at the given element slot. Called from the audio thread — no allocation.
  void process(const AudioBuffer& buffer, uint32_t frames,
               EclipsaStudioMeterState& state, uint32_t element_index);

  void reset(EclipsaStudioMeterState& state, uint32_t element_index);

 private:
  uint32_t sample_rate_ = 48000;
  float window_ms_ = 300.0f;

  // Exponential moving average coefficient (per-sample).
  float alpha_ = 0.0f;

  // Per-channel squared RMS accumulator.
  // RelaxedAtomic: reset() writes it from the control thread while
  // process() runs on the audio thread (see meter_state.h).
  RelaxedAtomic<float> squared_avg_[kMeterMaxChannels] = {};

  void update_alpha();
};

#endif  // ECLIPSA_STUDIO_METERS_RMS_METER_H_
