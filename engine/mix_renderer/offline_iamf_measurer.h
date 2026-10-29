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

#ifndef ECLIPSA_STUDIO_MIX_RENDERER_OFFLINE_IAMF_MEASURER_H_
#define ECLIPSA_STUDIO_MIX_RENDERER_OFFLINE_IAMF_MEASURER_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#include "mix_renderer/loudness_analysis_sink.h"

namespace eclipsa_studio {

/// Decodes an IAMF file (raw `.iamf`, or IAMF-in-MP4) offline, renders
/// a selection of its audio elements through a private OarRenderer at
/// one output layout, and measures the render with LoudnessAnalysisSink
/// — the same analyzer, weights, limiter and traces as
/// OfflineMixRenderer, so a QC Loudness Report on a loaded file and a
/// creator Loudness Report on a session read the same way.
///
/// Where OfflineMixRenderer streams session WAV sources, this class
/// pulls decoded temporal units from the iamf_tools stream API and
/// re-blocks them to the render block size. The decode is the one the
/// playback session uses (in-place from the mapped file for MP4 and
/// raw IAMF; a track whose sample data lives in another file is demuxed
/// into memory first), with an eager temporal-unit scan so the program
/// length is known before the pass starts.
///
/// One row of the report is one instance: Open() the file for the row's
/// layout, IncludeElement() each audio element of the row's sub-mix
/// with its static mix gain, SetOutputMixGain(), then Measure() once.
/// The renderer keeps its limiter and rendering state across calls, so
/// a second Measure() on an instance fails; a new pass opens the file
/// again. Mix gains are the caller's static values (the mix presentation's
/// default element gain plus the sub-mix output gain), not the
/// per-temporal-unit gains the stream carries, which track one presentation
/// only.
///
/// Each instance is standalone: no dependency on the real-time graph or
/// audio thread, and several instances may run concurrently on different
/// threads, each with its own mapping of the file. The one forbidden
/// overlap is with the live renderer (ES-44): callers hold the graph's
/// offline-exclusive access for the whole pass, as the creator report
/// does.
class OfflineIamfMeasurer {
 public:
  /// Per-audio-element facts from the file's descriptors, for callers
  /// that select elements by id. Mirrors the playback session's AeInfo.
  struct ElementInfo {
    uint32_t audio_element_id = 0;
    int32_t kind = 0;  ///< 0 channel, 1 scene, 2 object
    uint32_t num_channels = 0;
    int32_t layout_info = 0;
    int32_t loudspeaker_layout_raw = -1;
    int32_t expanded_loudspeaker_layout_raw = -1;
    bool supported = false;   ///< upstream can decode it
    bool renderable = false;  ///< supported and OAR has a sub-renderer
  };

  OfflineIamfMeasurer();
  ~OfflineIamfMeasurer();

  OfflineIamfMeasurer(const OfflineIamfMeasurer&) = delete;
  OfflineIamfMeasurer& operator=(const OfflineIamfMeasurer&) = delete;

  /// Open `path`, scan it and initialise the private renderer for
  /// `layout` (oar_layout_t: 2=stereo, 8=7.1.4, 0xFF=binaural, etc.) at
  /// the file's sample rate with `buffer_size` frames per render block.
  /// Returns false and sets last_error() on failure.
  bool Open(const std::string& path, uint32_t buffer_size, uint32_t layout);

  uint32_t sample_rate() const;
  uint64_t total_frames() const;
  uint32_t num_elements() const;
  ElementInfo element(uint32_t index) const;

  /// Register the audio element `audio_element_id` with the renderer,
  /// with a static mix gain and its IAMF rendering config
  /// (headphones_mode 0=stereo, 1=binaural world-locked, 2=binaural
  /// head-locked; binaural_profile 0=ambient, 1=direct, 2=reverberant).
  /// Elements not included render nothing. Returns false for an unknown
  /// id or an element that is not renderable.
  bool IncludeElement(uint32_t audio_element_id, float mix_gain_db,
                      uint32_t headphones_mode, uint32_t binaural_profile);

  /// Set the sub-mix output gain in dB.
  void SetOutputMixGain(float gain_db);

  /// Run the pass with OAR's -1 dBFS limiter on (the default) or off.
  /// With it off, Measure() reads the unlimited render of the input
  /// file; the GR trace is all zeros and the render has no limiter
  /// delay. The app's Loudness Report always measures limited. Call
  /// before Measure(); the setting stays in effect across Open().
  /// Returns false when the renderer refuses the change
  /// (OarRenderer::set_limiter_enabled), which an offline instance does
  /// not do.
  bool SetLimiterEnabled(bool enabled);

  /// Hand each rendered block's program frames to `tap` during
  /// Measure() (see LoudnessAnalysisSink::ProgramTap); the render has
  /// output_channels() channels. Call after Open(), which clears the
  /// tap, and before Measure(); an empty function clears it too.
  void SetProgramTap(LoudnessAnalysisSink::ProgramTap tap);

  /// Output channel count of the render at the opened layout, 0 before
  /// a successful Open().
  uint32_t output_channels() const;

  /// Decode, render and measure the whole program. Blocking. Returns
  /// nullopt on error (nothing included, a second call on this
  /// instance, a decode error, an element whose temporal units do not
  /// match its channel count, renderer failure); specifics in
  /// last_error() and the engine log. A failed measure must never pass
  /// for a silent (-120 LUFS) program.
  std::optional<LoudnessResult> Measure();

  /// Step between consecutive trace entries, uniform across series.
  static constexpr uint32_t kTraceStepMs = LoudnessAnalysisSink::kTraceStepMs;

  /// Trace and range queries, valid after a successful Measure(). Same
  /// contract as OfflineMixRenderer.
  uint32_t TraceLength(uint32_t series) const;
  uint32_t CopyTrace(uint32_t series, float* out, uint32_t cap) const;
  bool GetLoudnessRange(float* lra_lu, bool* is_stable) const;

  /// The last failure, prefixed like the stream API's statuses
  /// (`invalid_argument:`, `io:`, `malformed:`, `unsupported:`,
  /// `internal:`). Empty after a successful Open(), IncludeElement() or
  /// Measure().
  const std::string& last_error() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_MIX_RENDERER_OFFLINE_IAMF_MEASURER_H_
