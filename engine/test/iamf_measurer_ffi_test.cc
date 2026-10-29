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

// C-ABI tests for the eclipsa_studio_iamf_measurer_* FFI surface
// (engine.h): the return codes, the NULL-handle behaviour, the
// out-pointer contract of a failed measure and the trace queries, as
// the Dart measure isolate calls them. The class-level measurement
// cells live in iamf_loudness_agreement_test.cc; these tests cover the
// extern "C" boundary in engine.cc.
//
// The file under test is the multi_mix golden (two stereo LPCM
// elements, ids 300 and 301) encoded from two sine WAVs of 147456
// frames (3.072 s at 48 kHz), which is long enough for one short-term
// loudness block and so for a loudness range.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include "engine.h"
#include "gtest/gtest.h"
#include "iamf/iamf_exporter.h"
#include "mix_renderer/offline_iamf_measurer.h"
#include "test/test_wav_helper.h"

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kBufferSize = 1024;
constexpr uint32_t kStereoLayout = 2;  // oar_layout_t stereo
constexpr int kSourceFrames = 1024 * 144;
// ceil(3072 ms / 100 ms): the limiter GR series has one entry per
// 100 ms step and no warmup window.
constexpr uint32_t kGrTraceLen = 31;

// Out values of a measure call, pre-filled with sentinels no
// measurement produces.
struct Scalars {
  float lufs = 1.0f;
  float tp = 2.0f;
  float dp = 3.0f;
};

void ExpectUntouched(const Scalars& s) {
  EXPECT_FLOAT_EQ(s.lufs, 1.0f);
  EXPECT_FLOAT_EQ(s.tp, 2.0f);
  EXPECT_FLOAT_EQ(s.dp, 3.0f);
}

bool HasPrefix(const char* text, const char* prefix) {
  return text != nullptr && std::string(text).rfind(prefix, 0) == 0;
}

std::string FindFixture(const char* name) {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir == nullptr) srcdir = ".";
  const std::string candidates[] = {
      std::string(srcdir) + "/_main/test/fixtures/" + name,
      std::string(srcdir) + "/_main/engine/test/fixtures/" + name,
      std::string("test/fixtures/") + name,
      std::string("engine/test/fixtures/") + name,
  };
  for (const auto& c : candidates) {
    std::ifstream probe(c, std::ios::binary);
    if (probe) return c;
  }
  return {};
}

class IamfMeasurerFfiTest : public ::testing::Test {
 protected:
  // Encodes the golden once for the whole suite; iamf_path_ stays empty
  // when any step fails.
  static void SetUpTestSuite() {
    const std::string golden = FindFixture("golden/multi_mix.textproto");
    ASSERT_FALSE(golden.empty()) << "golden fixture missing";
    std::ifstream f(golden);
    std::stringstream config;
    config << f.rdbuf();

    const std::string dir = test_wav::temp_dir();
    const std::string bed = dir + "/iamf_measurer_ffi_bed.wav";
    const std::string vocal = dir + "/iamf_measurer_ffi_vocal.wav";
    ASSERT_TRUE(test_wav::write_sine_frames(bed, 2, kSampleRate, 16, 440.0f,
                                            kSourceFrames, 0.25f));
    ASSERT_TRUE(test_wav::write_sine_frames(vocal, 2, kSampleRate, 16, 2000.0f,
                                            kSourceFrames, 0.25f));

    // The basenames are keys into the golden's audio_frame_metadata.
    std::vector<eclipsa_studio::IamfExporter::PushElement> elements(2);
    elements[0].wav_basename = "bed.wav";
    elements[0].stream.input_wav_path = bed;
    elements[0].stream.pad_to_frames = kSourceFrames;
    elements[0].stream.output_sample_rate = kSampleRate;
    elements[1].wav_basename = "vocal.wav";
    elements[1].stream.input_wav_path = vocal;
    elements[1].stream.pad_to_frames = kSourceFrames;
    elements[1].stream.output_sample_rate = kSampleRate;
    const std::string out = dir + "/iamf_measurer_ffi.iamf";
    eclipsa_studio::IamfExporter exporter;
    ASSERT_EQ(exporter.EncodePush(config.str(), out, elements), 0);
    iamf_path_ = out;
  }

  void SetUp() override {
    ASSERT_FALSE(iamf_path_.empty()) << "golden encode failed";
  }

  static eclipsa_studio_iamf_measurer_t* Create() {
    return eclipsa_studio_iamf_measurer_create(iamf_path_.c_str(), kBufferSize,
                                               kStereoLayout);
  }

  static std::string iamf_path_;
};

std::string IamfMeasurerFfiTest::iamf_path_;

TEST_F(IamfMeasurerFfiTest, CreateReturnsNullOnBadArguments) {
  EXPECT_EQ(
      eclipsa_studio_iamf_measurer_create(nullptr, kBufferSize, kStereoLayout),
      nullptr);

  const std::string missing =
      test_wav::temp_dir() + "/iamf_measurer_ffi_missing.iamf";
  std::remove(missing.c_str());  // independence from the shared temp dir
  EXPECT_EQ(eclipsa_studio_iamf_measurer_create(missing.c_str(), kBufferSize,
                                                kStereoLayout),
            nullptr);

  // A render block of 0 frames is rejected before the file is opened.
  EXPECT_EQ(
      eclipsa_studio_iamf_measurer_create(iamf_path_.c_str(), 0, kStereoLayout),
      nullptr);
}

TEST_F(IamfMeasurerFfiTest, NullHandleIsTolerated) {
  EXPECT_EQ(
      eclipsa_studio_iamf_measurer_include_element(nullptr, 301, 0.0f, 1, 0),
      -1);
  eclipsa_studio_iamf_measurer_set_output_gain(nullptr, -3.0f);

  Scalars s;
  EXPECT_EQ(
      eclipsa_studio_iamf_measurer_measure(nullptr, &s.lufs, &s.tp, &s.dp), -1);
  ExpectUntouched(s);

  EXPECT_EQ(eclipsa_studio_iamf_measurer_trace_len(
                nullptr, eclipsa_studio::kTraceLimiterGrDb),
            0u);
  float trace[4] = {-1.0f, -1.0f, -1.0f, -1.0f};
  EXPECT_EQ(eclipsa_studio_iamf_measurer_copy_trace(
                nullptr, eclipsa_studio::kTraceLimiterGrDb, trace, 4),
            0u);
  EXPECT_FLOAT_EQ(trace[0], -1.0f);

  float lra = -1.0f;
  int32_t stable = 7;
  EXPECT_EQ(eclipsa_studio_iamf_measurer_loudness_range(nullptr, &lra, &stable),
            -1);
  EXPECT_FLOAT_EQ(lra, -1.0f);
  EXPECT_EQ(stable, 7);

  const char* error = eclipsa_studio_iamf_measurer_last_error(nullptr);
  ASSERT_NE(error, nullptr);
  EXPECT_STREQ(error, "");

  eclipsa_studio_iamf_measurer_destroy(nullptr);
}

TEST_F(IamfMeasurerFfiTest, IncludeElementRejectsUnknownId) {
  eclipsa_studio_iamf_measurer_t* m = Create();
  ASSERT_NE(m, nullptr);
  EXPECT_STREQ(eclipsa_studio_iamf_measurer_last_error(m), "");

  EXPECT_EQ(eclipsa_studio_iamf_measurer_include_element(m, 999, 0.0f, 1, 0),
            -2);
  EXPECT_TRUE(HasPrefix(eclipsa_studio_iamf_measurer_last_error(m),
                        "invalid_argument:"))
      << eclipsa_studio_iamf_measurer_last_error(m);

  // A known id succeeds on the same handle and clears the error.
  EXPECT_EQ(eclipsa_studio_iamf_measurer_include_element(m, 301, 0.0f, 1, 0),
            0);
  EXPECT_STREQ(eclipsa_studio_iamf_measurer_last_error(m), "");
  eclipsa_studio_iamf_measurer_destroy(m);
}

// A measure with nothing included fails with -2 and writes none of the
// out values, so the failure cannot be read as a silent program.
TEST_F(IamfMeasurerFfiTest, MeasureWithNothingIncludedFails) {
  eclipsa_studio_iamf_measurer_t* m = Create();
  ASSERT_NE(m, nullptr);

  Scalars s;
  EXPECT_EQ(eclipsa_studio_iamf_measurer_measure(m, &s.lufs, &s.tp, &s.dp), -2);
  ExpectUntouched(s);
  EXPECT_TRUE(HasPrefix(eclipsa_studio_iamf_measurer_last_error(m),
                        "invalid_argument:"))
      << eclipsa_studio_iamf_measurer_last_error(m);

  // Nothing was measured, so there is no series and no loudness range.
  EXPECT_EQ(eclipsa_studio_iamf_measurer_trace_len(
                m, eclipsa_studio::kTraceLimiterGrDb),
            0u);
  EXPECT_EQ(eclipsa_studio_iamf_measurer_loudness_range(m, nullptr, nullptr),
            -1);
  eclipsa_studio_iamf_measurer_destroy(m);
}

// The golden's "Main" presentation: AE 300 at -3 dB, AE 301 at 0 dB,
// output -1.5 dB. The C API result equals the C++ class result for the
// same configuration, which pins the marshalling of the ids and both
// gains. The second measure on the handle then fails.
TEST_F(IamfMeasurerFfiTest, MeasureSucceedsOncePerHandle) {
  eclipsa_studio_iamf_measurer_t* m = Create();
  ASSERT_NE(m, nullptr);
  ASSERT_EQ(eclipsa_studio_iamf_measurer_include_element(m, 300, -3.0f, 1, 0),
            0);
  ASSERT_EQ(eclipsa_studio_iamf_measurer_include_element(m, 301, 0.0f, 1, 0),
            0);
  eclipsa_studio_iamf_measurer_set_output_gain(m, -1.5f);

  Scalars first;
  ASSERT_EQ(eclipsa_studio_iamf_measurer_measure(m, &first.lufs, &first.tp,
                                                 &first.dp),
            0)
      << eclipsa_studio_iamf_measurer_last_error(m);
  EXPECT_STREQ(eclipsa_studio_iamf_measurer_last_error(m), "");
  EXPECT_TRUE(std::isfinite(first.lufs));
  EXPECT_GT(first.lufs, -60.0f);  // a measured program, not the default

  eclipsa_studio::OfflineIamfMeasurer reference;
  ASSERT_TRUE(reference.Open(iamf_path_, kBufferSize, kStereoLayout))
      << reference.last_error();
  ASSERT_TRUE(reference.IncludeElement(300, -3.0f, 1, 0));
  ASSERT_TRUE(reference.IncludeElement(301, 0.0f, 1, 0));
  reference.SetOutputMixGain(-1.5f);
  const std::optional<eclipsa_studio::LoudnessResult> expected =
      reference.Measure();
  ASSERT_TRUE(expected.has_value()) << reference.last_error();
  EXPECT_FLOAT_EQ(first.lufs, expected->integrated_lufs);
  EXPECT_FLOAT_EQ(first.tp, expected->true_peak_dbtp);
  EXPECT_FLOAT_EQ(first.dp, expected->digital_peak_dbfs);

  // The first run's series are readable until the second measure.
  EXPECT_EQ(eclipsa_studio_iamf_measurer_trace_len(
                m, eclipsa_studio::kTraceLimiterGrDb),
            kGrTraceLen);

  Scalars second;
  EXPECT_EQ(eclipsa_studio_iamf_measurer_measure(m, &second.lufs, &second.tp,
                                                 &second.dp),
            -2);
  ExpectUntouched(second);
  EXPECT_TRUE(HasPrefix(eclipsa_studio_iamf_measurer_last_error(m),
                        "invalid_argument:"))
      << eclipsa_studio_iamf_measurer_last_error(m);
  eclipsa_studio_iamf_measurer_destroy(m);
}

// The "Vocal Only" presentation: AE 301 at +2 dB, output 0 dB.
TEST_F(IamfMeasurerFfiTest, TraceAndLoudnessRangeAfterMeasure) {
  eclipsa_studio_iamf_measurer_t* m = Create();
  ASSERT_NE(m, nullptr);
  ASSERT_EQ(eclipsa_studio_iamf_measurer_include_element(m, 301, 2.0f, 1, 0),
            0);

  // Before a measure: no series and no loudness range.
  EXPECT_EQ(eclipsa_studio_iamf_measurer_trace_len(
                m, eclipsa_studio::kTraceLimiterGrDb),
            0u);
  EXPECT_EQ(eclipsa_studio_iamf_measurer_loudness_range(m, nullptr, nullptr),
            -1);

  Scalars s;
  ASSERT_EQ(eclipsa_studio_iamf_measurer_measure(m, &s.lufs, &s.tp, &s.dp), 0)
      << eclipsa_studio_iamf_measurer_last_error(m);

  // The Dart side passes the literal 4 for the limiter GR series.
  static_assert(eclipsa_studio::kTraceLimiterGrDb == 4,
                "C ABI series id is frozen");
  ASSERT_EQ(eclipsa_studio_iamf_measurer_trace_len(m, 4), kGrTraceLen);

  // A cap below the series length copies `cap` entries and returns
  // `cap`. GR entries are >= 0 dB, so the -1 sentinel marks the entries
  // the call did not write.
  constexpr uint32_t kCap = 10;
  std::vector<float> gr(kGrTraceLen, -1.0f);
  EXPECT_EQ(eclipsa_studio_iamf_measurer_copy_trace(m, 4, gr.data(), kCap),
            kCap);
  for (uint32_t i = 0; i < kGrTraceLen; ++i) {
    SCOPED_TRACE(i);
    if (i < kCap) {
      EXPECT_GE(gr[i], 0.0f);
    } else {
      EXPECT_FLOAT_EQ(gr[i], -1.0f);
    }
  }
  // A cap above the series length returns the series length.
  std::vector<float> all(kGrTraceLen + 8, -1.0f);
  EXPECT_EQ(eclipsa_studio_iamf_measurer_copy_trace(
                m, 4, all.data(), static_cast<uint32_t>(all.size())),
            kGrTraceLen);
  EXPECT_FLOAT_EQ(all[kGrTraceLen], -1.0f);
  // An unknown series id and a NULL buffer copy nothing.
  EXPECT_EQ(eclipsa_studio_iamf_measurer_trace_len(m, 99), 0u);
  EXPECT_EQ(eclipsa_studio_iamf_measurer_copy_trace(m, 99, gr.data(), kCap),
            0u);
  EXPECT_EQ(eclipsa_studio_iamf_measurer_copy_trace(m, 4, nullptr, kCap), 0u);

  // One short-term block is enough for a range; 3.072 s is below the
  // 60 s the range needs to be reported stable.
  float lra = -1.0f;
  int32_t stable = 7;
  EXPECT_EQ(eclipsa_studio_iamf_measurer_loudness_range(m, &lra, &stable), 0);
  EXPECT_TRUE(std::isfinite(lra));
  EXPECT_GE(lra, 0.0f);
  EXPECT_EQ(stable, 0);
  // Either out pointer may be NULL.
  EXPECT_EQ(eclipsa_studio_iamf_measurer_loudness_range(m, nullptr, nullptr),
            0);
  eclipsa_studio_iamf_measurer_destroy(m);
}

}  // namespace
