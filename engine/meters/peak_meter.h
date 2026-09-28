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

#ifndef ECLIPSA_STUDIO_METERS_PEAK_METER_H_
#define ECLIPSA_STUDIO_METERS_PEAK_METER_H_

#include <cstdint>

#include "graph/audio_buffer.h"
#include "meters/meter_state.h"

/// Per-channel peak meter with peak hold.
///
/// Processes a buffer on the audio thread and writes LINEAR amplitude values
/// (0..1+) into state.elements[element_index].peak and .peak_hold.
/// No allocation occurs on the audio thread.
class PeakMeter {
 public:
  /// @param hold_seconds  How long peak hold is retained (in seconds).
  explicit PeakMeter(float hold_seconds = 2.0f, uint32_t sample_rate = 48000);

  void set_sample_rate(uint32_t sample_rate);

  /// Process one buffer block and write linear peak values into `state`
  /// at the given element slot. Called from the audio thread — no allocation.
  void process(const AudioBuffer& buffer, uint32_t frames,
               EclipsaStudioMeterState& state, uint32_t element_index);

  /// Zero the peak/peak-hold state. Deliberately does NOT touch the
  /// sticky clip latches: those are owned by AudioGraph's clip-clear
  /// paths (clear_clips_now), the single definition of "clear every
  /// latch" — overload markers must outlive a transport stop (ES-528).
  void reset(EclipsaStudioMeterState& state, uint32_t element_index);

 private:
  uint32_t sample_rate_ = 48000;
  float hold_seconds_ = 2.0f;

  // Per-channel peak hold state (internal, not in FFI struct).
  // RelaxedAtomic: reset() writes these from the control thread while
  // process() runs on the audio thread (same contract as the shared
  // meter fields — see meter_state.h).
  RelaxedAtomic<float> peak_hold_linear_[kMeterMaxChannels] = {};
  RelaxedAtomic<uint32_t> hold_counter_[kMeterMaxChannels] =
      {};  // samples remaining
};

#endif  // ECLIPSA_STUDIO_METERS_PEAK_METER_H_
