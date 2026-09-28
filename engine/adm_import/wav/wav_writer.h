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

// Minimal multichannel WAV writer for rendered beds — a convenience
// wrapper over the shared in-house wav library (engine/wav).
//
// Writes planar float32 channels out as an interleaved WAV. Float32 output
// is the default (lossless for our render core); 24/16-bit PCM are
// available for interchange. Output is a plain RIFF/WAVE file (no ADM),
// auto-upgraded to RF64 past the 4 GiB ceiling.

#ifndef ADM2IAMF_WAV_WAV_WRITER_H_
#define ADM2IAMF_WAV_WAV_WRITER_H_

#include <cstdint>
#include <string>
#include <vector>

#include "absl/status/status.h"

namespace adm2iamf {

enum class WavEncoding { kFloat32, kPcm24, kPcm16 };

// Writes `planar` (channels × frames; all channels equal length) to `path`.
// Returns an error if the channels differ in length or the file can't be
// written.
absl::Status WriteWavPlanar(const std::string& path,
                            const std::vector<std::vector<float>>& planar,
                            uint32_t sample_rate,
                            WavEncoding encoding = WavEncoding::kFloat32);

}  // namespace adm2iamf

#endif  // ADM2IAMF_WAV_WAV_WRITER_H_
