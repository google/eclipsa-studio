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

#ifndef ECLIPSA_STUDIO_BOUNCE_ELEMENT_STREAM_H_
#define ECLIPSA_STUDIO_BOUNCE_ELEMENT_STREAM_H_

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "dsp/resampler.h"
#include "graph/audio_buffer.h"
#include "io/wav_reader.h"

namespace eclipsa_studio {

/// Streaming core of the offline element bounce: reads a source WAV,
/// applies pre-gain, channel routing, and an optional sample-rate
/// conversion, and hands out planar float blocks on demand. This is the
/// exact pipeline ElementBouncer::Bounce always ran — factored into a
/// pull API so the same blocks can feed either a WAV writer (bounce)
/// or the IAMF push encoder (export) without a temp-file round trip.
///
/// End-of-stream semantics match the historical bounce output: once the
/// source (and the resampler's sinc tail, ES-83) is exhausted, Pull()
/// keeps delivering silence up to total_frames(), then returns 0.
/// Sources longer than the target are truncated.
///
/// Thread-safety: control-thread only; one instance per source. Open()
/// allocates; Pull() does not.
class ElementStream {
 public:
  struct Config {
    /// Source WAV file path.
    std::string input_wav_path;

    /// Pre-gain in dB (element gain). 0 = unity (passthrough).
    float gain_db = 0.0f;

    /// Channel routing map: output_ch[i] = input_ch[routing[i]].
    /// -1 = silence that output channel.
    /// Empty = identity (no remap; output channels == input channels).
    std::vector<int> routing;

    /// If > 0, the stream delivers exactly this many frames: shorter
    /// sources are padded with trailing silence, longer sources are
    /// truncated. 0 = the source length (converted to the output rate
    /// when resampling). Counted at the OUTPUT sample rate.
    uint64_t pad_to_frames = 0;

    /// If > 0 and different from the source rate, output is resampled
    /// to this rate (the IAMF target rate — decoupled from whatever
    /// rate the engine/device runs at). 0 = keep the source rate.
    uint32_t output_sample_rate = 0;
  };

  ElementStream() = default;

  ElementStream(const ElementStream&) = delete;
  ElementStream& operator=(const ElementStream&) = delete;

  /// Open the source and set up the pipeline. Logs specifics and
  /// returns false on failure (unopenable source, channel count over
  /// the bounce limit, resampler init failure).
  bool Open(const Config& config);

  /// Output channel count (routing size, or the source's).
  uint32_t channels() const { return out_channels_; }

  /// Output sample rate.
  uint32_t sample_rate() const { return out_rate_; }

  /// Total frames this stream will deliver (see Config::pad_to_frames).
  uint64_t total_frames() const { return target_frames_; }

  // Source properties (valid after Open) — the bounce writer matches
  // the source bit depth, and completion logs quote the source shape.
  uint32_t source_channels() const { return in_channels_; }
  uint32_t source_sample_rate() const { return in_rate_; }
  uint32_t source_bit_depth() const { return reader_.bit_depth(); }
  uint64_t source_total_frames() const { return source_frames_; }

  /// Fill `out` with the next `want` frames (out.capacity_frames >=
  /// want, out.channels == channels()). Returns the count delivered
  /// and sets out.frames to it; short only when the stream ends, 0
  /// once total_frames() have been delivered.
  uint32_t Pull(AudioBuffer& out, uint32_t want);

  // Signal-overload stats over everything delivered so far (gain,
  // routing, and resampling applied — the exact samples the consumer
  // received). Cumulative since Open(); Open() resets both.

  /// Count of samples with |x| strictly > 1.0 — past what a downstream
  /// ±1.0 clamp (e.g. iamf-tools' int conversion) preserves losslessly.
  /// Exactly ±1.0 is not counted: integer sources legitimately hit
  /// -1.0 at full scale, and a ±1.0 clamp maps it to itself.
  uint64_t clipped_samples() const { return clipped_samples_; }

  /// Largest |sample| delivered (linear; 0 until audio is delivered).
  /// dBFS = 20 * log10(peak_linear()).
  float peak_linear() const { return peak_linear_; }

  /// Largest single Pull() request.
  static constexpr uint32_t kMaxPullFrames = 1024;

 private:
  // Produce up to `want` pipeline frames (pre-routing) into read_buf_.
  // Returns 0 when source + resampler tail are exhausted.
  uint32_t Produce(uint32_t want);

  WavReader reader_;
  std::unique_ptr<dsp::Resampler> resampler_;
  std::vector<float> read_storage_;
  AudioBuffer read_buf_;

  uint32_t in_channels_ = 0;
  uint32_t out_channels_ = 0;
  uint32_t in_rate_ = 0;
  uint32_t out_rate_ = 0;
  uint64_t source_frames_ = 0;
  uint64_t target_frames_ = 0;
  uint64_t delivered_ = 0;
  uint64_t clipped_samples_ = 0;
  float peak_linear_ = 0.0f;
  float gain_linear_ = 1.0f;
  std::vector<int> routing_;
  bool draining_ = false;
  bool exhausted_ = false;
};

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_BOUNCE_ELEMENT_STREAM_H_
