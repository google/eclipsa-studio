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

#ifndef ECLIPSA_STUDIO_IAMF_IAMF_EXPORTER_H_
#define ECLIPSA_STUDIO_IAMF_IAMF_EXPORTER_H_

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "bounce/element_stream.h"

namespace iamf_tools_cli_proto {
class UserMetadata;
}  // namespace iamf_tools_cli_proto

namespace eclipsa_studio {

// IAMF encode driver (ES-480): streams each element straight from its
// source WAV through the bounce pipeline (gain, routing, resample, pad)
// into the fork's push-PCM encoder API — no temp WAVs, no bit-depth
// matching, per-coded-frame progress and cancel.
//
// The public FFI surface (`eclipsa_studio_iamf_push_export_*` in engine.h)
// delegates to this class. The encode runs synchronously on the calling
// thread — control-thread only, never the audio thread.
//
// Lifecycle: construct once; per encode, call `ResetForNewRequest()`
// then `EncodePush` (the FFI begin/run sequence does exactly this);
// destroy. The reset matters: after a cancelled run the cancel flag
// stays armed, so an un-reset `EncodePush` aborts immediately with
// -99. `Progress` and `Cancel` are safe to call from any thread while
// an encode runs.
class IamfExporter {
 public:
  IamfExporter();
  ~IamfExporter();

  IamfExporter(const IamfExporter&) = delete;
  IamfExporter& operator=(const IamfExporter&) = delete;

  // One source element for `EncodePush`.
  struct PushElement {
    // Must match an `audio_frame_metadata.wav_filename` in the
    // UserMetadata — that entry supplies the audio_element_id and the
    // per-channel IAMF labels. (No WAV of that name exists anywhere;
    // the field is repurposed as the join key.)
    std::string wav_basename;

    // Source WAV plus the bounce pipeline parameters (gain, routing,
    // pad target, output rate) — the exact inputs the temp-WAV bounce
    // took, minus the output path.
    ElementStream::Config stream;
  };

  // Drive a single encode through the push API, writing the standalone
  // .iamf to `output_iamf_path`. `config_textproto` is the same
  // UserMetadata textproto `Encode` takes. Every element must resolve
  // to an audio_frame_metadata entry and every stream must deliver the
  // same total frame count (the dialog pads all elements to a common
  // length).
  //
  // Returns 0 on success, negative on error:
  //   -1   empty config
  //   -2   empty output path
  //   -3   no elements
  //   -10  textproto parse failure
  //   -11  unusable codec config (missing/zero num_samples_per_frame)
  //   -12  element/UserMetadata mismatch (basename, channel labels,
  //        duplicate resolved audio_element_id, duplicate channel_id)
  //   -13  element stream open failure
  //   -14  element stream length mismatch
  //   -21  encoder creation failure
  //   -22  Encode() rejected a temporal unit
  //   -23  OutputTemporalUnit() failure
  //   -24  FinalizeEncode() failure
  //   -99  cancelled (partial output removed)
  int32_t EncodePush(const std::string& config_textproto,
                     const std::string& output_iamf_path,
                     const std::vector<PushElement>& elements);

  // Convenience over `EncodePush` for callers holding a directory of
  // pre-staged WAVs (the dev CLI, golden-fixture tests): derives one
  // pass-through element per audio_frame_metadata entry — input
  // `input_wav_dir/<wav_filename>`, no gain/routing/resample, natural
  // length — and writes `output_dir/<file_name_prefix>.iamf`. Same
  // return codes as EncodePush.
  int32_t EncodePushFromWavDir(const std::string& config_textproto,
                               const std::string& input_wav_dir,
                               const std::string& output_dir);

  // `EncodePushFromWavDir` writing `output_iamf_path` instead of
  // `output_dir/<file_name_prefix>.iamf`; the config's file_name_prefix
  // is not used. Same return codes as EncodePush.
  int32_t EncodePushFromWavDirToFile(const std::string& config_textproto,
                                     const std::string& input_wav_dir,
                                     const std::string& output_iamf_path);

  // Current progress in [0.0, 1.0]. Returns 0 before the first encode.
  float Progress() const { return progress_.load(std::memory_order_relaxed); }

  // Signal-overload stats for the element at add-order `index` of the
  // last run, counted on the PCM actually pulled into the encoder —
  // partial when the run failed or was cancelled mid-stream. A sample
  // counts as clipped when |x| strictly > 1.0 (see
  // ElementStream::clipped_samples()); `out_peak_linear` is max |x|
  // (dBFS = 20*log10). Returns false for an out-of-range index or
  // before any run reached its streams. Valid after EncodePush /
  // EncodePushFromWavDir(ToFile) returns, until the next
  // ResetForNewRequest().
  // Thread-safe, but a mid-run read observes the previous (or cleared)
  // snapshot — the intended use is after the run returns. Either out
  // pointer may be null.
  bool GetElementClipStats(uint32_t index, uint64_t* out_clipped_samples,
                           float* out_peak_linear) const;

  // Arm a new encode request: zero the progress and drop any stale
  // cancel. The FFI builder calls this at begin so (a) a caller polling
  // Progress() between begin and run never reads the previous encode's
  // final value, and (b) a Cancel() raised before begin (e.g. during
  // the measure phase) cannot leak into the new encode. EncodePush
  // deliberately does NOT reset the cancel flag on entry: a cancel
  // raised after begin but before run reaches EncodePush must still
  // abort that run (it is honored at the first per-frame check).
  void ResetForNewRequest() {
    progress_.store(0.0f, std::memory_order_relaxed);
    cancel_.store(false, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(stats_mutex_);
    element_stats_.clear();
  }

  // Best-effort cancel. Stays armed until the next ResetForNewRequest()
  // (or EncodePushFromWavDir(ToFile), which arms its own request).
  void Cancel() { cancel_.store(true, std::memory_order_relaxed); }

 private:
  // Encode body shared by the public entry points, which parse the
  // textproto exactly once before delegating here. Progress is reset
  // by all of them; the cancel flag only by ResetForNewRequest() /
  // EncodePushFromWavDir(ToFile) — EncodePush deliberately leaves it armed so
  // a begin→run-window cancel aborts the run (do NOT "clean this up"
  // by resetting cancel_ at EncodePush entry).
  int32_t EncodePushParsed(
      const iamf_tools_cli_proto::UserMetadata& user_metadata,
      const std::string& output_iamf_path,
      const std::vector<PushElement>& elements);

  struct ElementClipStats {
    uint64_t clipped_samples = 0;
    float peak_linear = 0.0f;
  };

  std::atomic<float> progress_{0.0f};
  std::atomic<bool> cancel_{false};
  // Add-order per-element overload stats of the last run; written by
  // the encode thread on every exit from EncodePushParsed, cleared by
  // ResetForNewRequest(). Guarded because Progress/Cancel established
  // that this object is reachable from other threads mid-run.
  mutable std::mutex stats_mutex_;
  std::vector<ElementClipStats> element_stats_;
};

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_IAMF_IAMF_EXPORTER_H_
