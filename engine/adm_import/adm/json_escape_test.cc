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

#include <string>

#include "gtest/gtest.h"

namespace adm2iamf {
namespace adm {
namespace {

std::string Escaped(absl::string_view s) {
  std::string out;
  AppendJsonString(out, s);
  return out;
}

TEST(JsonEscapeTest, PlainAsciiIsQuotedVerbatim) {
  EXPECT_EQ(Escaped("audioProgramme"), "\"audioProgramme\"");
  EXPECT_EQ(Escaped(""), "\"\"");
}

TEST(JsonEscapeTest, SpecialsAreEscaped) {
  EXPECT_EQ(Escaped("a\"b\\c"), "\"a\\\"b\\\\c\"");
  EXPECT_EQ(Escaped("a\nb\rc\td"), "\"a\\nb\\rc\\td\"");
}

TEST(JsonEscapeTest, ControlBytesAreUEscaped) {
  EXPECT_EQ(Escaped(std::string("a\x01z", 3)), "\"a\\u0001z\"");
  EXPECT_EQ(Escaped(std::string("\x1f", 1)), "\"\\u001f\"");
}

TEST(JsonEscapeTest, WellFormedUtf8PassesThrough) {
  // 2-, 3- and 4-byte sequences: é, €, 𝄞.
  EXPECT_EQ(Escaped("caf\xc3\xa9"), "\"caf\xc3\xa9\"");
  EXPECT_EQ(Escaped("\xe2\x82\xac"), "\"\xe2\x82\xac\"");
  EXPECT_EQ(Escaped("\xf0\x9d\x84\x9e"), "\"\xf0\x9d\x84\x9e\"");
}

TEST(JsonEscapeTest, MalformedBytesBecomeReplacementChar) {
  // A bare Latin-1 byte (the classic legacy-tool case).
  EXPECT_EQ(Escaped("Caf\xe9!"), "\"Caf\\ufffd!\"");
  // A lone continuation byte.
  EXPECT_EQ(Escaped("\x80"), "\"\\ufffd\"");
  // Overlong encoding of '/' (0xC0 0xAF) — both bytes are invalid.
  EXPECT_EQ(Escaped("\xc0\xaf"), "\"\\ufffd\\ufffd\"");
  // A CESU-8 surrogate half (0xED 0xA0 0x80).
  EXPECT_EQ(Escaped("\xed\xa0\x80"), "\"\\ufffd\\ufffd\\ufffd\"");
  // Truncated sequence at end of string.
  EXPECT_EQ(Escaped("ok\xe2\x82"), "\"ok\\ufffd\\ufffd\"");
}

TEST(JsonEscapeTest, ValidTextAroundMalformedBytesIsKept) {
  EXPECT_EQ(Escaped("a\xff caf\xc3\xa9"), "\"a\\ufffd caf\xc3\xa9\"");
}

}  // namespace
}  // namespace adm
}  // namespace adm2iamf
