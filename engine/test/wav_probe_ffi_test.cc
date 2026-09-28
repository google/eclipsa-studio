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

// The Dart-facing WAV probe (io/wav_probe_ffi.h): byte-level acceptance
// lives here, next to the parser — the Dart side only maps the JSON, so
// what this test pins is exactly what the UI accepts.

#include "io/wav_probe_ffi.h"

#include <cstdlib>
#include <cstring>
#include <string>

#include "gtest/gtest.h"
#include "wav/testing/fixture.h"

namespace {

namespace wt = wav::testing;
namespace wtf = wav::testing::fixture_internal;

// Runs the probe and returns the JSON, freeing the C string.
std::string Probe(const std::string& path) {
  char* raw = eclipsa_studio_wav_probe_json(path.c_str());
  if (raw == nullptr) return "";
  std::string out(raw);
  std::free(
      raw);  // malloc'd; eclipsa_studio_string_free is the same allocator.
  return out;
}

bool Contains(const std::string& json, const std::string& needle) {
  return json.find(needle) != std::string::npos;
}

TEST(WavProbeFfi, ReportsHeaderFieldsForPlainRiff) {
  wt::FixtureSpec spec;
  spec.format = wav::SampleFormat::kInt16;
  spec.channels = 2;
  spec.num_frames = 48;
  const std::string json = Probe(wt::WriteFixture("probe_riff", spec));
  EXPECT_TRUE(Contains(json, "\"ok\":true")) << json;
  EXPECT_TRUE(Contains(json, "\"container\":\"riff\"")) << json;
  EXPECT_TRUE(Contains(json, "\"channels\":2")) << json;
  EXPECT_TRUE(Contains(json, "\"sample_rate\":48000")) << json;
  EXPECT_TRUE(Contains(json, "\"bits_per_sample\":16")) << json;
  EXPECT_TRUE(Contains(json, "\"is_float\":false")) << json;
  EXPECT_TRUE(Contains(json, "\"num_frames\":48")) << json;
  EXPECT_TRUE(Contains(json, "\"axml_bytes\":0")) << json;
}

TEST(WavProbeFfi, ReportsAdmMetadataOnBw64) {
  wt::FixtureSpec spec;
  spec.container = wav::Container::kBw64;
  spec.format = wav::SampleFormat::kFloat32;
  spec.channels = 1;
  spec.include_axml = true;
  spec.include_chna = true;
  const std::string json = Probe(wt::WriteFixture("probe_bw64", spec));
  EXPECT_TRUE(Contains(json, "\"ok\":true")) << json;
  EXPECT_TRUE(Contains(json, "\"container\":\"bw64\"")) << json;
  EXPECT_TRUE(Contains(json, "\"is_float\":true")) << json;
  const std::string axml_bytes =
      "\"axml_bytes\":" + std::to_string(std::strlen(wt::kFixtureAxml()));
  EXPECT_TRUE(Contains(json, axml_bytes)) << json;
  EXPECT_TRUE(Contains(json, "\"chna_bytes\":12")) << json;
}

TEST(WavProbeFfi, ReportsDataChunkLocation) {
  // data_offset/data_size come from the reader's authoritative fields,
  // not the capped chunk inventory — a plain fixture pins the values.
  wt::FixtureSpec spec;
  spec.format = wav::SampleFormat::kInt16;
  spec.channels = 2;
  spec.num_frames = 48;
  auto f = wt::BuildFixture(spec);
  const std::string path = wt::TempDir() + "/probe_data_loc.wav";
  ASSERT_TRUE(wt::WriteBytes(path, f.bytes));
  const std::string json = Probe(path);
  EXPECT_TRUE(Contains(json, "\"ok\":true")) << json;
  EXPECT_TRUE(Contains(
      json, "\"data_offset\":" + std::to_string(f.data_payload_offset)))
      << json;
  EXPECT_TRUE(Contains(json, "\"data_size\":" + std::to_string(48 * 2 * 2)))
      << json;
}

TEST(WavProbeFfi, EscapesControlCharactersInErrorJson) {
  // A newline in a filename is legal on POSIX and lands verbatim in the
  // parser's "Cannot open" message; jsonDecode on the Dart side rejects
  // raw control characters, so the probe must emit \uXXXX / \n forms.
  const std::string weird = wt::TempDir() + "/probe\nweird\"quote\\.wav";
  const std::string json = Probe(weird);
  EXPECT_TRUE(Contains(json, "\"ok\":false")) << json;
  EXPECT_TRUE(Contains(json, "\\n")) << json;
  EXPECT_TRUE(Contains(json, "\\\"quote")) << json;
  EXPECT_TRUE(Contains(json, "\\\\.wav")) << json;
  for (const char c : json) {
    EXPECT_GE(static_cast<unsigned char>(c), 0x20u)
        << "raw control character leaked into JSON";
  }
}

TEST(WavProbeFfi, WideChannelCountsPassThrough) {
  // The probe reports what the file declares; the 32-channel playback cap
  // is applied UI-side (and engine-side at open).
  wt::FixtureSpec spec;
  spec.channels = 33;
  const std::string json = Probe(wt::WriteFixture("probe_33ch", spec));
  EXPECT_TRUE(Contains(json, "\"ok\":true")) << json;
  EXPECT_TRUE(Contains(json, "\"channels\":33")) << json;
}

TEST(WavProbeFfi, FailsClosedWithParserErrors) {
  // Unsupported encoding: header-level damage fails even the lenient
  // probe — there is nothing trustworthy to report.
  auto f = wt::BuildFixture(wt::FixtureSpec{});
  wtf::PutU16At(f.bytes, f.fmt_size_field_offset + 4, 0x55);  // MP3 tag.
  const std::string tag_path = wt::TempDir() + "/probe_mp3.wav";
  ASSERT_TRUE(wt::WriteBytes(tag_path, f.bytes));
  std::string json = Probe(tag_path);
  EXPECT_TRUE(Contains(json, "\"ok\":false")) << json;
  EXPECT_TRUE(Contains(json, "Unsupported format tag")) << json;

  // Missing file: the "Cannot open" prefix is the Dart side's cue to
  // throw FileSystemException instead of FormatException.
  json = Probe(wt::TempDir() + "/probe_absent.wav");
  EXPECT_TRUE(Contains(json, "\"ok\":false")) << json;
  EXPECT_TRUE(Contains(json, "Cannot open")) << json;
}

TEST(WavProbeFfi, DroppedAdmMetadataIsFlagged) {
  // A BW64 with a truncated `axml` after `data`: the lenient recovery
  // keeps the audio but reports metadata_dropped, which the Dart ADM
  // sniff uses to route the file to the strict ADM import (honest
  // damage error) instead of silently importing it as plain audio.
  wt::FixtureSpec spec;
  spec.container = wav::Container::kBw64;
  auto f = wt::BuildFixture(spec);
  wtf::AppendId(f.bytes, "axml");
  wtf::AppendU32(f.bytes, 64);  // declares 64 bytes, one present
  f.bytes.push_back('<');
  const std::string path = wt::TempDir() + "/probe_dropped_axml.wav";
  ASSERT_TRUE(wt::WriteBytes(path, f.bytes));
  const std::string json = Probe(path);
  EXPECT_TRUE(Contains(json, "\"ok\":true")) << json;
  EXPECT_TRUE(Contains(json, "\"recovered\":true")) << json;
  EXPECT_TRUE(Contains(json, "\"metadata_dropped\":true")) << json;
  EXPECT_TRUE(Contains(json, "\"axml_bytes\":0")) << json;
}

TEST(WavProbeFfi, TruncatedDataProbesUsableWithRecoveredFlag) {
  // The probe opens leniently, matching playback and the waveform scan:
  // a damaged-but-playable file (here: 10 of 20 declared payload bytes,
  // i.e. 5 whole mono frames) probes as usable, reports the clamped
  // frame count, and flags the recovery.
  auto f = wt::BuildFixture(wt::FixtureSpec{});
  f.bytes.resize(f.data_payload_offset + 10);
  const std::string trunc_path = wt::TempDir() + "/probe_trunc.wav";
  ASSERT_TRUE(wt::WriteBytes(trunc_path, f.bytes));
  const std::string json = Probe(trunc_path);
  EXPECT_TRUE(Contains(json, "\"ok\":true")) << json;
  EXPECT_TRUE(Contains(json, "\"recovered\":true")) << json;
  EXPECT_TRUE(Contains(json, "\"num_frames\":5")) << json;
}

}  // namespace
