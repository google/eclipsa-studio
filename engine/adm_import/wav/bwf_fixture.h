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

// Test-only writer for synthetic ADM-BWF files.
//
// Emits a RIFF/WAVE with `fmt ` (float32), interleaved `data`, an `axml` chunk
// (the ADM XML) and a `chna` chunk. Lets tests exercise the full read path
// (Bw64Reader -> ParseAxml/ParseChna -> scene -> render) without a real ADM
// master. Also exposes a `chna` row builder.

#ifndef ADM2IAMF_WAV_BWF_FIXTURE_H_
#define ADM2IAMF_WAV_BWF_FIXTURE_H_

#include <cstdint>
#include <string>
#include <tuple>
#include <vector>

#include "absl/status/status.h"
#include "absl/strings/string_view.h"

namespace adm2iamf {
namespace test {

// (track_index, audioTrackUID, audioTrackFormatID, audioPackFormatID).
using ChnaRow = std::tuple<uint16_t, std::string, std::string, std::string>;

// Serializes `rows` into a BS.2088 `chna` chunk payload.
std::vector<uint8_t> MakeChna(const std::vector<ChnaRow>& rows);

// Writes a float32 ADM-BWF to `path`. `tracks` are planar (channel-major), all
// equal length.
absl::Status WriteAdmBwf(absl::string_view path,
                         const std::vector<std::vector<float>>& tracks,
                         uint32_t sample_rate, absl::string_view axml,
                         const std::vector<uint8_t>& chna);

}  // namespace test
}  // namespace adm2iamf

#endif  // ADM2IAMF_WAV_BWF_FIXTURE_H_
