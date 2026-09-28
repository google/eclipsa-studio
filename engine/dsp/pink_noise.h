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

#ifndef ECLIPSA_STUDIO_DSP_PINK_NOISE_H_
#define ECLIPSA_STUDIO_DSP_PINK_NOISE_H_

#include <cstdint>

namespace dsp {

/// RT-safe pink-noise generator. One instance lives on the audio thread and
/// is never shared — all state is plain audio-thread-only fields, so there is
/// no allocation and no locking on the real-time path.
///
/// White source is a 32-bit LCG; the spectrum is shaped to ~-3 dB/oct by Paul
/// Kellet's economy "refined" pink filter (well-known public-domain
/// coefficients). next() is normalised to ~unity RMS (≈ 0 dBFS RMS), NOT to a
/// unity peak — like any noise it has a crest factor > 1, so individual
/// samples routinely exceed ±1. Multiply by a linear amplitude `a` outside the
/// class to set the output level: RMS dBFS ≈ 20·log10(a) (e.g. a = 0.1 →
/// −20 dBFS RMS). RMS is independent of the playback sample rate; only the
/// spectral tilt, tuned around ~44.1 kHz, drifts at higher rates.
class PinkNoise {
 public:
  float next() {
    state_ = state_ * 1664525u + 1013904223u;  // LCG step.
    // White in ~[-1, 1): take the top 24 bits as a signed value.
    const float white = static_cast<float>(static_cast<int32_t>(state_) >> 8) *
                        (1.0f / 8388608.0f);
    b0_ = 0.99886f * b0_ + white * 0.0555179f;
    b1_ = 0.99332f * b1_ + white * 0.0750759f;
    b2_ = 0.96900f * b2_ + white * 0.1538520f;
    b3_ = 0.86650f * b3_ + white * 0.3104856f;
    b4_ = 0.55000f * b4_ + white * 0.5329522f;
    b5_ = -0.7616f * b5_ - white * 0.0168980f;
    const float pink =
        b0_ + b1_ + b2_ + b3_ + b4_ + b5_ + b6_ + white * 0.5362f;
    b6_ = white * 0.115926f;
    // Normalise to unity RMS so the caller's linear amplitude maps directly
    // to the calibrated dBFS reference. Tuned empirically on BlackHole: with
    // the textbook 0.11 scale a −20 dBFS reference metered ~−24 dBFS RMS
    // (generator RMS ≈ 0.63), so the scale is raised by 4 dB (×10^(4/20)) to
    // 0.174 → a −20 dBFS reference now reads ≈ −20 dBFS RMS.
    return pink * 0.174f;
  }

  /// Reset filter history (not strictly required — the engine just lets the
  /// generator free-run — but handy for deterministic tests).
  void reset() {
    b0_ = b1_ = b2_ = b3_ = b4_ = b5_ = b6_ = 0.0f;
    state_ = 0x1234567u;
  }

 private:
  uint32_t state_ = 0x1234567u;
  float b0_ = 0, b1_ = 0, b2_ = 0, b3_ = 0, b4_ = 0, b5_ = 0, b6_ = 0;
};

}  // namespace dsp

#endif  // ECLIPSA_STUDIO_DSP_PINK_NOISE_H_
