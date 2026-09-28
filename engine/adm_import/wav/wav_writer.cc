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

#include "adm_import/wav/wav_writer.h"

#include <cstdint>
#include <string>
#include <vector>

#include "absl/status/status.h"
#include "absl/strings/str_cat.h"
#include "wav/writer.h"

namespace adm2iamf {

absl::Status WriteWavPlanar(const std::string& path,
                            const std::vector<std::vector<float>>& planar,
                            uint32_t sample_rate, WavEncoding encoding) {
  const auto num_channels = static_cast<uint16_t>(planar.size());
  if (num_channels == 0) {
    return absl::InvalidArgumentError("WriteWavPlanar: no channels.");
  }
  const size_t frames = planar[0].size();
  for (const auto& ch : planar) {
    if (ch.size() != frames) {
      return absl::InvalidArgumentError(
          "WriteWavPlanar: channels have unequal length.");
    }
  }

  wav::WriterOptions opt;
  opt.channels = num_channels;
  opt.sample_rate = sample_rate;
  switch (encoding) {
    case WavEncoding::kFloat32:
      opt.format = wav::WriteFormat::kFloat32;
      break;
    case WavEncoding::kPcm24:
      opt.format = wav::WriteFormat::kPcm24;
      break;
    case WavEncoding::kPcm16:
      opt.format = wav::WriteFormat::kPcm16;
      break;
  }

  // The library streams the payload (no whole-file buffering) and
  // auto-upgrades the container to RF64 past the 4 GiB RIFF ceiling, so
  // long renders no longer error out.
  auto w = wav::Writer::Create(path, opt);
  if (!w.ok()) {
    return absl::UnavailableError(absl::StrCat("WriteWavPlanar: ", w.error()));
  }
  if (auto s = w->PushPlanarFloat(planar); !s.ok()) {
    return absl::UnavailableError(
        absl::StrCat("WriteWavPlanar: ", s.message()));
  }
  if (auto s = w->Finalize(); !s.ok()) {
    return absl::UnavailableError(
        absl::StrCat("WriteWavPlanar: ", s.message()));
  }
  return absl::OkStatus();
}

}  // namespace adm2iamf
