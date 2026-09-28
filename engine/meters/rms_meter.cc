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

#include "meters/rms_meter.h"

#include <algorithm>
#include <cmath>

RmsMeter::RmsMeter(float window_ms, uint32_t sample_rate)
    : sample_rate_(sample_rate), window_ms_(window_ms) {
  update_alpha();
  for (auto& avg : squared_avg_) {
    avg = 0.0f;
  }
}

void RmsMeter::set_sample_rate(uint32_t sample_rate) {
  sample_rate_ = sample_rate;
  update_alpha();
}

void RmsMeter::update_alpha() {
  // Decay constant so that the window is ~window_ms of integration.
  float window_samples =
      (window_ms_ / 1000.0f) * static_cast<float>(sample_rate_);
  if (window_samples < 1.0f) window_samples = 1.0f;
  alpha_ = 1.0f - std::exp(-1.0f / window_samples);
}

void RmsMeter::process(const AudioBuffer& buffer, uint32_t frames,
                       EclipsaStudioMeterState& state, uint32_t element_index) {
  if (element_index >= kEclipsaStudioMaxElements) return;

  const uint32_t channels = std::min(buffer.channels, kMeterMaxChannels);
  EclipsaStudioMeterData& elem = state.elements[element_index];

  for (uint32_t ch = 0; ch < channels; ++ch) {
    const float* samples = buffer.channel(ch);
    float avg = squared_avg_[ch];

    for (uint32_t i = 0; i < frames; ++i) {
      float s2 = samples[i] * samples[i];
      avg += alpha_ * (s2 - avg);
    }

    // A NaN/Inf sample would poison the EMA permanently (NaN never
    // leaves an average) — drop the state back to silence instead.
    if (!std::isfinite(avg)) avg = 0.0f;

    squared_avg_[ch] = avg;

    // Write linear RMS amplitude (sqrt of mean-square).
    elem.rms[ch] = std::sqrt(avg);
  }
}

void RmsMeter::reset(EclipsaStudioMeterState& state, uint32_t element_index) {
  for (auto& avg : squared_avg_) {
    avg = 0.0f;
  }
  if (element_index >= kEclipsaStudioMaxElements) return;
  EclipsaStudioMeterData& elem = state.elements[element_index];
  for (auto& r : elem.rms) {
    r = 0.0f;
  }
}
