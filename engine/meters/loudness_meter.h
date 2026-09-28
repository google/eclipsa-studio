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

#ifndef ECLIPSA_STUDIO_METERS_LOUDNESS_METER_H_
#define ECLIPSA_STUDIO_METERS_LOUDNESS_METER_H_

#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

#include "graph/audio_buffer.h"
#include "meters/meter_state.h"

// Forward-declare to avoid pulling the full header into every TU.
namespace loudness {
class EbuR128Analyzer;
}

/// ITU-R BS.1770-4 loudness meter backed by google/loudness_ebur128.
///
/// ## Design
///
/// This class bridges two use-cases from the same underlying EBU R128 math:
///
/// 1. **SPEC values** (go into the IAMF LoudnessInfo OBU):
///    - Integrated loudness (relative-gated, BS.1770-4)
///    - True peak (intersample, 4x upsampled)
///    - Digital peak (sample peak)
///
/// 2. **INFORMATIONAL values** (live metering display only, not in bitstream):
///    - Momentary loudness  — latest 400 ms block  [marked with * in UI]
///    - Short-term loudness — latest 3 s block      [marked with * in UI]
///
/// The IAMF export pipeline uses its own separate
/// LoudnessCalculatorItu1770_4 pass over the rendered PCM; the values
/// produced here are for real-time monitoring only.
///
/// ## Threading
///
/// process() MUST be called from a single thread. In the engine that is
/// the audio thread: AudioGraph::process() runs it on the post-OAR
/// rendered buffer each callback (guarded against concurrent
/// reconfigure — see issue ES-145).
/// Writes to EclipsaStudioLoudnessData are plain float stores — the struct is
/// read by Dart via FFI at ~10 Hz, and the values are display-only so
/// slight tearing is acceptable.
class LoudnessMeter {
 public:
  /// Scratch capacity per channel, in frames. rebuild_analyzer() allocates
  /// it so the wrapper does not allocate in process(); process() feeds
  /// longer blocks to the analyzer in chunks of this size.
  static constexpr uint32_t kMaxBlockFrames = 4096;

  /// @param sample_rate    Input sample rate.
  /// @param num_channels   Number of channels the analyzer sees. Must match
  ///                       the AudioBuffer passed to process().
  /// @param layout         oar_layout_t value used to pick per-channel
  ///                       BS.1770 weights. If the layout's weight vector
  ///                       size doesn't match `num_channels`, the meter
  ///                       falls back to uniform 1.0 weights and warns
  ///                       once. 0 = unspecified → uniform weights.
  explicit LoudnessMeter(uint32_t sample_rate = 48000,
                         uint32_t num_channels = 2, uint32_t layout = 0);
  ~LoudnessMeter();

  void set_sample_rate(uint32_t sample_rate);

  /// Reconfigure the meter for a new channel count + layout (e.g. when the
  /// OAR output layout changes). Rebuilds the analyzer and resets all
  /// accumulated gating blocks — caller is responsible for also clearing
  /// any loudness fields in EclipsaStudioMeterState on the next process() call.
  void reconfigure(uint32_t num_channels, uint32_t layout);

  /// Feed one block of planar float PCM (channel × frame). Updates
  /// state.loudness after each call. A block whose channel count differs
  /// from the configured count is skipped, counted and (first one per
  /// configuration) logged. The wrapper does not allocate; the
  /// EbuR128Analyzer still appends to its per-block history vectors as
  /// blocks complete.
  void process(const AudioBuffer& buffer, uint32_t frames,
               EclipsaStudioMeterState& state);

  /// Rebuild the underlying analyzer, dropping every accumulated momentary,
  /// short-term and integrated block. Does NOT touch any
  /// EclipsaStudioMeterState — the loudness fields are only refreshed on the
  /// next process() call.
  void reset();

  uint32_t num_channels() const { return num_channels_; }
  uint32_t layout() const { return layout_; }

  /// Blocks process() skipped because their channel count differed from
  /// num_channels(). Safe to read from any thread.
  uint64_t mismatched_blocks() const {
    return mismatched_blocks_.load(std::memory_order_relaxed);
  }

 private:
  uint32_t sample_rate_;
  uint32_t num_channels_;
  uint32_t layout_;
  std::unique_ptr<loudness::EbuR128Analyzer> analyzer_;

  // Planar double scratch for the analyzer: num_channels_ planes of
  // kMaxBlockFrames each, allocated by rebuild_analyzer().
  std::vector<double> planar_;
  // Channel pointer table handed to the analyzer; entry c points at plane
  // c of planar_. Filled by rebuild_analyzer().
  std::vector<double*> channel_ptrs_;
  // Set by process() after it logs the first mismatched block; cleared by
  // rebuild_analyzer(). Written on the audio thread and on the control
  // thread only while the caller keeps process() from running (the
  // AudioGraph loudness fence), like the rest of the configuration.
  bool mismatch_logged_ = false;
  // Written by process() (audio thread), read by any thread.
  std::atomic<uint64_t> mismatched_blocks_{0};

  void rebuild_analyzer();
  void update_state(EclipsaStudioMeterState& state) const;
};

#endif  // ECLIPSA_STUDIO_METERS_LOUDNESS_METER_H_
