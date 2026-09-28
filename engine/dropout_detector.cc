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

#include "dropout_detector.h"

#include <algorithm>
#include <cmath>

DropoutDetector::Result DropoutDetector::on_callback(uint64_t now_ns,
                                                     uint32_t frames,
                                                     uint32_t sample_rate) {
  Result result;
  if (frames == 0 || sample_rate == 0) return result;

  if (!anchored_ || sample_rate != sample_rate_) {
    anchored_ = true;
    sample_rate_ = sample_rate;
    anchor_ns_ = now_ns;
    frames_delivered_ = static_cast<double>(frames);
    baseline_frames_ = 0.0;
    window_start_ns_ = now_ns;
    window_has_sample_ = false;
    return result;
  }

  // Deficit at entry: frames the device has consumed since the anchor
  // minus frames we have delivered to it. Healthy burst pacing makes
  // this oscillate by up to a device period; its lower envelope stays
  // near zero unless delivery genuinely falls behind.
  const double elapsed_frames = static_cast<double>(now_ns - anchor_ns_) *
                                1e-9 * static_cast<double>(sample_rate);
  const double deficit = elapsed_frames - frames_delivered_;
  frames_delivered_ += static_cast<double>(frames);

  if (!window_has_sample_ || deficit < window_min_deficit_) {
    window_min_deficit_ = deficit;
    window_has_sample_ = true;
  }

  const uint64_t window_ns = now_ns - window_start_ns_;
  if (window_ns < kEvalWindowNs) return result;

  // Window closes: compare this window's deficit envelope against the
  // drift-adjusted baseline.
  const double diff = window_min_deficit_ - baseline_frames_;
  const auto buffer_frames = static_cast<double>(frames);
  if (diff >= buffer_frames * (1.0 - kCountSlack)) {
    const double buffers_lost = std::floor(diff / buffer_frames + kCountSlack);
    result.new_dropouts = static_cast<uint32_t>(buffers_lost);
    result.behind_ms =
        static_cast<float>(diff / static_cast<double>(sample_rate) * 1e3);
    // Absorb the counted loss so each lost buffer is reported once.
    baseline_frames_ += buffers_lost * buffer_frames;
  } else {
    // Bleed clock skew (either direction) into the baseline, capped so
    // a genuine deficit step cannot be silently absorbed.
    const double cap = static_cast<double>(window_ns) * 1e-9 *
                       static_cast<double>(sample_rate) * kDriftCapPpm * 1e-6;
    baseline_frames_ += std::clamp(diff, -cap, cap);
  }
  window_start_ns_ = now_ns;
  window_has_sample_ = false;
  return result;
}
