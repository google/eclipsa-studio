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

#include "dsp/gain.h"

#include <algorithm>
#include <cmath>

namespace dsp {

static float db_to_linear(float db) { return std::pow(10.0f, db / 20.0f); }

Gain::Gain() {
  for (uint32_t i = 0; i < kGainMaxChannels; ++i) {
    target_linear_[i] = 1.0f;
    current_linear_[i] = 1.0f;
  }
}

void Gain::set_gain_db(float gain_db) {
  float lin = db_to_linear(gain_db);
  for (auto& t : target_linear_) {
    t = lin;
  }
}

void Gain::set_channel_gain_db(uint32_t channel, float gain_db) {
  if (channel < kGainMaxChannels) {
    target_linear_[channel] = db_to_linear(gain_db);
  }
}

void Gain::process(AudioBuffer& buffer, uint32_t frames) {
  const uint32_t channels = buffer.channels;

  for (uint32_t ch = 0; ch < channels; ++ch) {
    float* samples = buffer.channel(ch);
    float target = target_linear_[ch];
    float current = current_linear_[ch];

    for (uint32_t i = 0; i < frames; ++i) {
      // One-pole smoothing toward target.
      current += kSmoothCoeff * (target - current);
      samples[i] *= current;
    }

    current_linear_[ch] = current;
  }
}

void Gain::reset() {
  for (uint32_t i = 0; i < kGainMaxChannels; ++i) {
    current_linear_[i] = target_linear_[i];
  }
}

}  // namespace dsp
