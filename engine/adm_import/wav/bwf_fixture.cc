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

#include "adm_import/wav/bwf_fixture.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <tuple>
#include <vector>

#include "absl/status/status.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"

namespace adm2iamf {
namespace test {
namespace {

void PutU16(std::string& b, uint16_t v) {
  b.push_back(static_cast<char>(v & 0xFF));
  b.push_back(static_cast<char>((v >> 8) & 0xFF));
}
void PutU32(std::string& b, uint32_t v) {
  for (int i = 0; i < 4; ++i)
    b.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
}
// Appends a chunk (id + size + payload + word-alignment pad).
void PutChunk(std::string& b, absl::string_view id, absl::string_view payload) {
  b.append(id.data(), id.size());
  PutU32(b, static_cast<uint32_t>(payload.size()));
  b.append(payload.data(), payload.size());
  if (payload.size() & 1) b.push_back('\0');
}

void AppendField(std::vector<uint8_t>& v, const std::string& s, size_t len) {
  for (size_t i = 0; i < len; ++i) {
    v.push_back(i < s.size() ? static_cast<uint8_t>(s[i]) : ' ');
  }
}

}  // namespace

std::vector<uint8_t> MakeChna(const std::vector<ChnaRow>& rows) {
  std::vector<uint8_t> v;
  const uint16_t n = static_cast<uint16_t>(rows.size());
  for (int i = 0; i < 2; ++i) {  // numTracks, numUIDs.
    v.push_back(n & 0xFF);
    v.push_back((n >> 8) & 0xFF);
  }
  for (const auto& [idx, uid, track, pack] : rows) {
    v.push_back(idx & 0xFF);
    v.push_back((idx >> 8) & 0xFF);
    AppendField(v, uid, 12);
    AppendField(v, track, 14);
    AppendField(v, pack, 11);
    v.push_back(0);  // pad
  }
  return v;
}

absl::Status WriteAdmBwf(absl::string_view path,
                         const std::vector<std::vector<float>>& tracks,
                         uint32_t sample_rate, absl::string_view axml,
                         const std::vector<uint8_t>& chna) {
  if (tracks.empty()) return absl::InvalidArgumentError("no tracks");
  const uint16_t num_channels = static_cast<uint16_t>(tracks.size());
  const size_t frames = tracks[0].size();
  for (const auto& t : tracks) {
    if (t.size() != frames) {
      return absl::InvalidArgumentError("tracks unequal length");
    }
  }

  // Interleaved float32 `data`.
  std::string data;
  data.reserve(frames * num_channels * 4);
  for (size_t n = 0; n < frames; ++n) {
    for (uint16_t c = 0; c < num_channels; ++c) {
      uint32_t bits;
      float v = tracks[c][n];
      std::memcpy(&bits, &v, 4);
      PutU32(data, bits);
    }
  }

  std::string fmt;
  PutU16(fmt, 3);  // IEEE float
  PutU16(fmt, num_channels);
  PutU32(fmt, sample_rate);
  PutU32(fmt, sample_rate * num_channels * 4);           // avg bytes/sec
  PutU16(fmt, static_cast<uint16_t>(num_channels * 4));  // block align
  PutU16(fmt, 32);                                       // bits

  std::string body;
  body += "WAVE";
  PutChunk(body, "fmt ", fmt);
  PutChunk(body, "data", data);
  PutChunk(body, "axml", axml);
  PutChunk(body, "chna",
           absl::string_view(reinterpret_cast<const char*>(chna.data()),
                             chna.size()));

  std::string out;
  out += "RIFF";
  PutU32(out, static_cast<uint32_t>(body.size()));
  out += body;

  std::ofstream file(std::string(path), std::ios::binary);
  if (!file) {
    return absl::UnavailableError(absl::StrCat("cannot write ", path));
  }
  file.write(out.data(), static_cast<std::streamsize>(out.size()));
  return file ? absl::OkStatus()
              : absl::DataLossError(absl::StrCat("write failed ", path));
}

}  // namespace test
}  // namespace adm2iamf
