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

#ifndef ECLIPSA_STUDIO_BOUNCE_ELEMENT_BOUNCER_H_
#define ECLIPSA_STUDIO_BOUNCE_ELEMENT_BOUNCER_H_

#include <cstdint>
#include <string>
#include <vector>

namespace eclipsa_studio {

/// Reusable offline bounce: reads a WAV, applies pre-gain and channel
/// routing, writes a new WAV. Uses the same WavReader and gain logic
/// as the real-time playback path, just with a file sink instead of
/// the device output.
///
/// Thread-safety: Bounce() is blocking and runs on the caller's
/// thread. Multiple instances may run concurrently on different files.
class ElementBouncer {
 public:
  struct Config {
    /// Source WAV file path.
    std::string input_wav_path;

    /// Output WAV file path. Parent directory must exist.
    std::string output_wav_path;

    /// Pre-gain in dB (element gain). 0 = unity (passthrough).
    float gain_db = 0.0f;

    /// Channel routing map: output_ch[i] = input_ch[routing[i]].
    /// -1 = silence that output channel.
    /// Empty = identity (no remap; output channels == input channels).
    std::vector<int> routing;

    /// If > 0, the output WAV is zero-padded to exactly this many
    /// frames. Shorter inputs are appended with silence; longer
    /// inputs are truncated. 0 = no padding/truncation (output
    /// mirrors input length). Counted at the OUTPUT sample rate.
    uint64_t pad_to_frames = 0;

    /// If > 0 and different from the source rate, the output WAV is
    /// resampled to this rate (the IAMF target rate — decoupled from
    /// whatever rate the engine/device runs at). 0 = keep the source
    /// rate.
    uint32_t output_sample_rate = 0;
  };

  /// Bounce one element offline.
  ///
  /// Returns 0 on success, negative on error:
  ///   -1  failed to open input WAV
  ///   -2  failed to open output WAV
  ///   -3  read/write error during processing, or finalizing the output
  ///       failed
  static int32_t Bounce(const Config& config);
};

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_BOUNCE_ELEMENT_BOUNCER_H_
