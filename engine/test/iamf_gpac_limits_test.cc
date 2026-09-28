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

// Characterizes GPAC's IAMF acceptance boundary — profile and codec — as
// guard tests.
//
// The 0.17.0 MP4 export failure muxed an Advanced-2 (primary_profile = 5,
// v2.0.0-draft) IAMF bitstream and GPAC rejected it during the Phase-1 mux
// with "BitStream Not Compliant". The hypothesis: GPAC's vendored IAMF
// reframer/muxer implements only the ratified profiles — Simple (0), Base
// (1), Base-Enhanced (2) — and discards any sequence whose primary_profile it
// doesn't support (IAMF spec: primary_profile is the floor).
//
// This test pins that boundary down empirically rather than by inference. It
// takes a single-stereo-element seed `.iamf` (valid content under *every*
// profile, so the profile byte is the only variable), patches the two profile
// fields of its IA Sequence Header OBU to each value 0..5 plus a reserved
// value, and runs each variant through the same gpac filter session
// IamfMuxer::MuxAudio uses. Stable profiles must mux; draft/reserved profiles
// must fail with GF_NON_COMPLIANT_BITSTREAM specifically.
//
// A second axis covers codecs: the Opus and FLAC seeds we ship must mux, and a
// bitstream whose Codec Config OBU codec_id is corrupted to an unknown 4CC must
// be rejected (GPAC's IAMF reframer gates on codec_id).
//
// If a stable profile/codec is rejected — or a draft profile is accepted — the
// test fails, which is the signal we want after an external/gpac bump.

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#include "gtest/gtest.h"

// GPAC headers last on purpose: setup.h poisons strcpy/strncat/etc. with
// #error macros (use gf_* instead), which break <cstring> if a standard header
// is first parsed after them. Including the standard library + gtest first
// means <cstring> is already parsed before the poison macros are defined.
#include <gpac/filters.h>
#include <gpac/tools.h>

namespace {

// A single stereo Opus element — valid under all IAMF profiles, so patching
// the profile byte changes nothing else about the bitstream's validity.
constexpr char kStereoFixture[] = "noise_3s_stereo_opus.iamf";

std::string FindFixture(const char* name) {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir == nullptr) srcdir = ".";
  const std::string candidates[] = {
      std::string(srcdir) + "/_main/test/fixtures/" + name,
      std::string(srcdir) + "/_main/engine/test/fixtures/" + name,
      std::string(srcdir) + "/eclipsa_studio_engine/test/fixtures/" + name,
      std::string("test/fixtures/") + name,
      std::string("engine/test/fixtures/") + name,
  };
  for (const auto& c : candidates) {
    std::ifstream probe(c, std::ios::binary);
    if (probe) return c;
  }
  return {};
}

std::vector<uint8_t> LoadFile(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

std::string TempPath(const char* name) {
  const char* dir = std::getenv("TEST_TMPDIR");
  if (dir == nullptr) dir = "/tmp";
  return std::string(dir) + "/" + name;
}

bool WriteFile(const std::string& path, const std::vector<uint8_t>& bytes) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  if (!out) return false;
  out.write(reinterpret_cast<const char*>(bytes.data()),
            static_cast<std::streamsize>(bytes.size()));
  return out.good();
}

// Overwrite primary_profile / additional_profile in the IA Sequence Header
// OBU. Layout of a bare .iamf's first OBU:
//
//   f8 <leb128 size> 69 61 6d 66 PP AA ...
//   │                └─ "iamf" ─┘ │  └ additional_profile  (magic + 5)
//   └ OBU header, obu_type 31     └ primary_profile        (magic + 4)
//
// Find the "iamf" magic whose preceding byte is the sequence-header OBU header
// (0xF8) and rewrite the two bytes after it. Returns false if not found. This
// assumes the sequence header's leb128 obu_size is a single byte (true for all
// shipped fixtures, size 6); a 2-byte size would shift the 0xF8 to magic-3 and
// the match would miss — which the caller's ASSERT turns into a loud failure
// rather than a silent mis-patch.
bool PatchProfiles(std::vector<uint8_t>& buf, uint8_t primary,
                   uint8_t additional) {
  static constexpr uint8_t kMagic[4] = {'i', 'a', 'm', 'f'};
  for (size_t i = 2; i + 5 < buf.size(); ++i) {
    if (buf[i] == kMagic[0] && buf[i + 1] == kMagic[1] &&
        buf[i + 2] == kMagic[2] && buf[i + 3] == kMagic[3] &&
        buf[i - 2] == 0xF8) {
      buf[i + 4] = primary;
      buf[i + 5] = additional;
      return true;
    }
  }
  return false;
}

// Overwrite the 4CC codec_id in the Codec Config OBU. The codec_id is the
// first 4CC in the stream (e.g. "Opus", "fLaC"); a codec's own magic
// ("OpusHead", the FLAC stream marker) appears later in the decoder config, so
// the first match is the IAMF codec_id. `from`/`to` are 4-char string literals
// (the trailing NUL is ignored). Returns false if `from` is not present.
bool PatchCodec(std::vector<uint8_t>& buf, const char (&from)[5],
                const char (&to)[5]) {
  for (size_t i = 0; i + 4 <= buf.size(); ++i) {
    if (buf[i] == static_cast<uint8_t>(from[0]) &&
        buf[i + 1] == static_cast<uint8_t>(from[1]) &&
        buf[i + 2] == static_cast<uint8_t>(from[2]) &&
        buf[i + 3] == static_cast<uint8_t>(from[3])) {
      buf[i] = static_cast<uint8_t>(to[0]);
      buf[i + 1] = static_cast<uint8_t>(to[1]);
      buf[i + 2] = static_cast<uint8_t>(to[2]);
      buf[i + 3] = static_cast<uint8_t>(to[3]);
      return true;
    }
  }
  return false;
}

// Mux a bare `.iamf` into an audio-only IAMF-in-ISOBMFF `.mp4` via the same
// libgpac filter session IamfMuxer::MuxAudio uses, returning the GF_Err so the
// caller can distinguish GF_NON_COMPLIANT_BITSTREAM from other failures. Each
// call brackets gpac with gf_sys_init / gf_sys_close (matching IamfMuxer), so
// iterations don't share filter-registry state.
GF_Err MuxIamfToMp4Err(const std::string& input_iamf,
                       const std::string& output_mp4) {
  if (gf_sys_init(GF_MemTrackerNone, nullptr) != GF_OK) return GF_IO_ERR;
  GF_FilterSession* session = gf_fs_new_defaults(GF_FilterSessionFlags(0));
  if (session == nullptr) {
    gf_sys_close();
    return GF_OUT_OF_MEM;
  }
  GF_Err err = GF_OK;
  GF_Filter* src =
      gf_fs_load_source(session, input_iamf.c_str(), nullptr, nullptr, &err);
  // A null filter with err still GF_OK must not read as success — mirror
  // IamfMuxer::MuxAudio, which treats `filter == nullptr` as failure. Without
  // this the run block would be skipped and the stale GF_OK returned, masking
  // a load failure as a passing mux.
  if (src == nullptr && err == GF_OK) err = GF_FILTER_NOT_FOUND;
  if (err == GF_OK) {
    GF_Filter* dst = gf_fs_load_destination(session, output_mp4.c_str(),
                                            nullptr, nullptr, &err);
    if (dst == nullptr && err == GF_OK) err = GF_FILTER_NOT_FOUND;
  }
  if (err == GF_OK) {
    err = gf_fs_run(session);
    if (err >= GF_OK) err = gf_fs_get_last_connect_error(session);
    if (err >= GF_OK) err = gf_fs_get_last_process_error(session);
  }
  gf_fs_del(session);
  gf_sys_close();
  return err;
}

struct ProfileCase {
  uint8_t profile;  // written to both primary_profile and additional_profile
  bool expect_ok;   // true = GPAC should mux it; false = should reject
};

}  // namespace

class GpacIamfProfileTest : public testing::TestWithParam<ProfileCase> {};

// Each profile value is a self-contained probe: patch the seed, mux, and assert
// GPAC's verdict matches the documented boundary. RecordProperty surfaces the
// per-profile result so `--test_output=all` shows the full accept/reject matrix
// even when every case passes.
TEST_P(GpacIamfProfileTest, MuxAcceptsOnlyRatifiedProfiles) {
  const ProfileCase tc = GetParam();

  const std::string seed = FindFixture(kStereoFixture);
  if (seed.empty()) GTEST_SKIP() << "fixture missing: " << kStereoFixture;

  std::vector<uint8_t> bytes = LoadFile(seed);
  ASSERT_FALSE(bytes.empty());
  ASSERT_TRUE(PatchProfiles(bytes, tc.profile, tc.profile))
      << "IA Sequence Header OBU not found in seed";

  const std::string in =
      TempPath(("profile_" + std::to_string(tc.profile) + ".iamf").c_str());
  const std::string out =
      TempPath(("profile_" + std::to_string(tc.profile) + ".mp4").c_str());
  ASSERT_TRUE(WriteFile(in, bytes));

  const GF_Err err = MuxIamfToMp4Err(in, out);
  RecordProperty("profile", static_cast<int>(tc.profile));
  RecordProperty("err", gf_error_to_string(err));

  if (tc.expect_ok) {
    EXPECT_GE(err, GF_OK) << "profile " << static_cast<int>(tc.profile)
                          << " should mux but failed: "
                          << gf_error_to_string(err);
  } else {
    EXPECT_LT(err, GF_OK) << "profile " << static_cast<int>(tc.profile)
                          << " should be rejected but muxed OK";
    EXPECT_EQ(err, GF_NON_COMPLIANT_BITSTREAM)
        << "profile " << static_cast<int>(tc.profile)
        << " rejected with unexpected error: " << gf_error_to_string(err);
  }
}

INSTANTIATE_TEST_SUITE_P(
    Profiles, GpacIamfProfileTest,
    testing::Values(ProfileCase{0, true},      // Simple        (v1.0.0)
                    ProfileCase{1, true},      // Base          (v1.0.0)
                    ProfileCase{2, true},      // Base-Enhanced (v1.1.0)
                    ProfileCase{3, false},     // Base-Advanced (v2.0.0 draft)
                    ProfileCase{4, false},     // Advanced-1    (v2.0.0 draft)
                    ProfileCase{5, false},     // Advanced-2    (v2.0.0 draft)
                    ProfileCase{255, false}),  // reserved
    [](const testing::TestParamInfo<ProfileCase>& info) {
      return "Profile_" + std::to_string(info.param.profile);
    });

// The codecs we actually ship fixtures for must mux through GPAC unmodified —
// documents GPAC's IAMF codec support for the formats Eclipsa Studio emits. One
// case per codec (rather than a loop) so each gets its own test name and
// RecordProperty entry.
struct CodecCase {
  const char* fixture;
  const char* name;  // test-name suffix, e.g. "Opus"
};

class GpacIamfCodecMuxTest : public testing::TestWithParam<CodecCase> {};

TEST_P(GpacIamfCodecMuxTest, MuxesShippedCodec) {
  const CodecCase tc = GetParam();
  const std::string seed = FindFixture(tc.fixture);
  if (seed.empty()) GTEST_SKIP() << "fixture missing: " << tc.fixture;

  const std::string out = TempPath((std::string(tc.fixture) + ".mp4").c_str());
  const GF_Err err = MuxIamfToMp4Err(seed, out);
  RecordProperty("err", gf_error_to_string(err));
  EXPECT_GE(err, GF_OK) << tc.fixture << " should mux but failed: "
                        << gf_error_to_string(err);
}

INSTANTIATE_TEST_SUITE_P(
    ShippedCodecs, GpacIamfCodecMuxTest,
    testing::Values(CodecCase{"noise_3s_stereo_opus.iamf", "Opus"},
                    CodecCase{"noise_1024samp_stereo_flac.iamf", "FLAC"}),
    [](const testing::TestParamInfo<CodecCase>& info) {
      return std::string("Codec_") + info.param.name;
    });

// Corrupting the codec_id 4CC to an unknown value must make GPAC reject the
// stream — the codec gate, distinct from the profile gate above. Unlike the
// profile reject (which pins GF_NON_COMPLIANT_BITSTREAM, the documented crash
// signature), we only assert rejection here: how GPAC's reframer fails an
// unknown codec_id is an implementation detail, not a spec-defined code.
TEST(GpacIamfCodecTest, RejectsUnknownCodec) {
  const std::string seed = FindFixture(kStereoFixture);
  if (seed.empty()) GTEST_SKIP() << "fixture missing: " << kStereoFixture;

  std::vector<uint8_t> bytes = LoadFile(seed);
  ASSERT_FALSE(bytes.empty());
  ASSERT_TRUE(PatchCodec(bytes, "Opus", "ZZZZ")) << "codec_id 4CC not found";

  const std::string in = TempPath("codec_unknown.iamf");
  const std::string out = TempPath("codec_unknown.mp4");
  ASSERT_TRUE(WriteFile(in, bytes));

  const GF_Err err = MuxIamfToMp4Err(in, out);
  RecordProperty("err", gf_error_to_string(err));
  EXPECT_LT(err, GF_OK) << "unknown codec_id should be rejected but muxed OK";
}
