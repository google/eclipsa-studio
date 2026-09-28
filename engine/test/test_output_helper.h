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

#ifndef ECLIPSA_STUDIO_TEST_TEST_OUTPUT_HELPER_H_
#define ECLIPSA_STUDIO_TEST_TEST_OUTPUT_HELPER_H_

/// Output-level (post-OAR) test harness for AudioGraph (ES-88).
///
/// Historically engine tests asserted on meter state, which taps the
/// chain BEFORE OAR — the ES-85 click train (a broken output) passed the
/// whole suite that way. These helpers make rendered-PCM assertions
/// cheap: mirror the app's element-registration recipe (a graph slot
/// alone renders silence — the app registers each element with OAR via
/// a separate FFI call), set a target layout with identity device
/// routing, collect one channel of rendered output, and run sine
/// signal-integrity analysis (level / continuity / pitch) on it.
///
/// All functions are inline so this header can be included in multiple
/// test TUs without linker conflicts.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "graph/audio_graph.h"
#include "renderer/oar_renderer.h"

namespace test_output {

// oar_layout_t values used by output-level tests. The engine API
// passes these through as raw uint32_t (see engine.h: "2=stereo,
// 8=7.1.4, 0xFF=binaural"); tests can't include oar.h directly
// because OarRenderer deliberately keeps it out of its header.
inline constexpr uint32_t kLayoutMono = 1;
inline constexpr uint32_t kLayoutStereo = 2;
inline constexpr uint32_t kLayout51 = 3;
inline constexpr uint32_t kLayout714 = 8;
inline constexpr uint32_t kLayoutBinaural = 0xFF;

/// Blocks to discard before collecting output: covers the element
/// mute-gain ramp (~145 ms at 48 kHz / 512) plus OAR's post-rebuild
/// fade-in (5 ms).
inline constexpr int kWarmupBlocks = 30;

/// Load a WAV into a graph slot AND register it with OAR — the two
/// separate calls the app's FFI layer makes (eclipsa_studio_add_element +
/// eclipsa_studio_oar_add_element). `sub_type` is the element's oar_layout_t
/// and `channels` must match the WAV. Channel-based elements only.
inline bool add_wav_element(AudioGraph& g, uint32_t id,
                            const std::string& wav_path, int sub_type,
                            uint32_t channels) {
  if (g.add_element(id, wav_path.c_str()) != 0) return false;
  return g.oar_renderer()->add_element(id, /*type=*/0, sub_type, channels);
}

/// Set the OAR target layout with identity device routing (OAR channel
/// i feeds device channel i) — what the app pushes for a fresh routing
/// matrix. `channels` is the new layout's channel count (set_routing
/// rejects a mismatched length).
inline bool set_layout_identity(AudioGraph& g, uint32_t layout,
                                uint32_t channels) {
  uint64_t masks[64] = {};
  for (uint32_t i = 0; i < channels && i < 64; ++i) masks[i] = 1ull << i;
  return g.set_layout_and_routing(layout, masks, channels) == 0;
}

/// Run `blocks` process() callbacks, discarding the output (warm-up,
/// or skipping past a known-discontinuous boundary such as a seek).
inline void run_blocks(AudioGraph& g, int blocks, uint32_t frames,
                       uint32_t channels) {
  std::vector<float> out(static_cast<size_t>(frames) * channels, 0.0f);
  for (int b = 0; b < blocks; ++b) g.process(out.data(), frames, channels);
}

/// Collect `blocks` blocks of device channel `ch` from the rendered
/// interleaved output.
inline std::vector<float> collect_channel(AudioGraph& g, int blocks,
                                          uint32_t frames, uint32_t channels,
                                          uint32_t ch) {
  std::vector<float> out(static_cast<size_t>(frames) * channels, 0.0f);
  std::vector<float> sig;
  sig.reserve(static_cast<size_t>(blocks) * frames);
  for (int b = 0; b < blocks; ++b) {
    g.process(out.data(), frames, channels);
    for (uint32_t f = 0; f < frames; ++f) {
      sig.push_back(out[f * channels + ch]);
    }
  }
  return sig;
}

/// Largest sample-to-sample step a continuous sine can take:
/// amp · 2π · freq / rate. Continuity thresholds are a small multiple
/// of this — a splice jumps by up to 2·amp.
inline float sine_max_step(float freq_hz, float sample_rate, float amp) {
  return amp * 2.0f * 3.14159265f * freq_hz / sample_rate;
}

/// Signal-integrity statistics for one collected output channel.
struct SignalStats {
  float peak = 0.0f;        // max |x|
  float max_jump = 0.0f;    // max |x[i] - x[i-1]|
  int jumps = 0;            // steps exceeding jump_threshold
  double zc_per_sec = 0.0;  // zero-crossing rate (2× freq for a sine)
};

inline SignalStats analyze_signal(const std::vector<float>& sig,
                                  double sample_rate, float jump_threshold) {
  SignalStats s;
  if (sig.empty()) return s;
  s.peak = std::fabs(sig[0]);
  int zc = 0;
  for (size_t i = 1; i < sig.size(); ++i) {
    const float jump = std::fabs(sig[i] - sig[i - 1]);
    s.max_jump = std::max(s.max_jump, jump);
    if (jump > jump_threshold) ++s.jumps;
    if ((sig[i - 1] < 0.0f) != (sig[i] < 0.0f)) ++zc;
    s.peak = std::max(s.peak, std::fabs(sig[i]));
  }
  s.zc_per_sec =
      static_cast<double>(zc) * sample_rate / static_cast<double>(sig.size());
  return s;
}

}  // namespace test_output

#endif  // ECLIPSA_STUDIO_TEST_TEST_OUTPUT_HELPER_H_
