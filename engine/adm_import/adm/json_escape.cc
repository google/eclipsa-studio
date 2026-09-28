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

#include "adm_import/adm/json_escape.h"

#include <cstddef>

#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"

namespace adm2iamf {
namespace adm {
namespace {

// Returns the length (1-4) of the well-formed UTF-8 sequence starting at
// s[i], or 0 if the bytes there are not one (RFC 3629: continuation ranges
// exclude overlong encodings, surrogates and > U+10FFFF).
size_t Utf8SequenceLength(absl::string_view s, size_t i) {
  const auto byte = [&s](size_t k) -> unsigned char {
    return k < s.size() ? static_cast<unsigned char>(s[k]) : 0;
  };
  const auto in = [&byte](size_t k, unsigned char lo, unsigned char hi) {
    const unsigned char b = byte(k);
    return b >= lo && b <= hi;
  };
  const auto cont = [&in](size_t k) { return in(k, 0x80, 0xBF); };
  const unsigned char b0 = byte(i);
  if (b0 < 0x80) return 1;
  if (b0 >= 0xC2 && b0 <= 0xDF) return cont(i + 1) ? 2 : 0;
  if (b0 == 0xE0) return in(i + 1, 0xA0, 0xBF) && cont(i + 2) ? 3 : 0;
  if (b0 >= 0xE1 && b0 <= 0xEC) return cont(i + 1) && cont(i + 2) ? 3 : 0;
  if (b0 == 0xED) return in(i + 1, 0x80, 0x9F) && cont(i + 2) ? 3 : 0;
  if (b0 >= 0xEE && b0 <= 0xEF) return cont(i + 1) && cont(i + 2) ? 3 : 0;
  if (b0 == 0xF0) {
    return in(i + 1, 0x90, 0xBF) && cont(i + 2) && cont(i + 3) ? 4 : 0;
  }
  if (b0 >= 0xF1 && b0 <= 0xF3) {
    return cont(i + 1) && cont(i + 2) && cont(i + 3) ? 4 : 0;
  }
  if (b0 == 0xF4) {
    return in(i + 1, 0x80, 0x8F) && cont(i + 2) && cont(i + 3) ? 4 : 0;
  }
  return 0;
}

}  // namespace

void AppendJsonString(std::string& out, absl::string_view s) {
  out.push_back('"');
  for (size_t i = 0; i < s.size();) {
    const char ch = s[i];
    switch (ch) {
      case '"':
        out += "\\\"";
        ++i;
        continue;
      case '\\':
        out += "\\\\";
        ++i;
        continue;
      case '\n':
        out += "\\n";
        ++i;
        continue;
      case '\r':
        out += "\\r";
        ++i;
        continue;
      case '\t':
        out += "\\t";
        ++i;
        continue;
      default:
        break;
    }
    const unsigned char b = static_cast<unsigned char>(ch);
    if (b < 0x20) {
      absl::StrAppend(&out, "\\u00", absl::Hex(b, absl::kZeroPad2));
      ++i;
      continue;
    }
    const size_t len = Utf8SequenceLength(s, i);
    if (len == 0) {
      out += "\\ufffd";  // One replacement per offending byte.
      ++i;
      continue;
    }
    out.append(s.data() + i, len);
    i += len;
  }
  out.push_back('"');
}

}  // namespace adm
}  // namespace adm2iamf
