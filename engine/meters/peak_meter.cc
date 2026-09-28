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

#include "meters/peak_meter.h"

#include <algorithm>
#include <cmath>

PeakMeter::PeakMeter(float hold_seconds, uint32_t sample_rate)
    : sample_rate_(sample_rate), hold_seconds_(hold_seconds) {
  for (uint32_t i = 0; i < kMeterMaxChannels; ++i) {
    peak_hold_linear_[i] = 0.0f;
    hold_counter_[i] = 0;
  }
}

void PeakMeter::set_sample_rate(uint32_t sample_rate) {
  sample_rate_ = sample_rate;
}

void PeakMeter::process(const AudioBuffer& buffer, uint32_t frames,
                        EclipsaStudioMeterState& state,
                        uint32_t element_index) {
  if (element_index >= kEclipsaStudioMaxElements) return;

  const uint32_t channels = std::min(buffer.channels, kMeterMaxChannels);
  const auto hold_samples =
      static_cast<uint32_t>(hold_seconds_ * static_cast<float>(sample_rate_));

  EclipsaStudioMeterData& elem = state.elements[element_index];
  elem.channel_count = channels;

  for (uint32_t ch = 0; ch < channels; ++ch) {
    const float* samples = buffer.channel(ch);

    // Instantaneous peak over this block.
    float peak = 0.0f;
    for (uint32_t i = 0; i < frames; ++i) {
      float abs_val = std::abs(samples[i]);
      if (abs_val > peak) peak = abs_val;
    }

    // Update peak hold.
    const uint32_t held = hold_counter_[ch];
    if (peak >= peak_hold_linear_[ch]) {
      peak_hold_linear_[ch] = peak;
      hold_counter_[ch] = hold_samples;
    } else if (held > 0) {
      hold_counter_[ch] = held - std::min(held, frames);
    } else {
      // Decay peak hold back toward instantaneous.
      peak_hold_linear_[ch] = std::max(peak_hold_linear_[ch] * 0.999f, peak);
    }

    // Write linear amplitude values (0..1+) to the FFI struct.
    elem.peak[ch] = peak;
    elem.peak_hold[ch] = peak_hold_linear_[ch];

    // Sticky clip indicator (>= 0 dBFS = linear amplitude >= 1.0).
    if (peak >= 1.0f) {
      elem.clip[ch] = 1;
    }
  }
}

void PeakMeter::reset(EclipsaStudioMeterState& state, uint32_t element_index) {
  for (uint32_t i = 0; i < kMeterMaxChannels; ++i) {
    peak_hold_linear_[i] = 0.0f;
    hold_counter_[i] = 0;
  }
  if (element_index >= kEclipsaStudioMaxElements) return;
  EclipsaStudioMeterData& elem = state.elements[element_index];
  for (uint32_t i = 0; i < kMeterMaxChannels; ++i) {
    elem.peak[i] = 0.0f;
    elem.peak_hold[i] = 0.0f;
  }
}
