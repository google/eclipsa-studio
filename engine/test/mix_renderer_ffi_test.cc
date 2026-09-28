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

// C-ABI tests for the eclipsa_studio_mix_renderer_* FFI surface (engine.h),
// exercising the exact call shapes Dart uses (ES-484): the stream-fed
// add_element marshalling (pre-gain / routing / pad / output rate),
// NULL-routing identity semantics, object positioning through the
// exported symbol, and error codes on null arguments. The class-level
// stream tests live in offline_mix_renderer_test.cc; here the point is
// the extern "C" boundary in engine.cc.

#include <cstdint>
#include <cstdio>
#include <optional>
#include <string>

#include "engine.h"
#include "gtest/gtest.h"
#include "mix_renderer/offline_mix_renderer.h"
#include "test_wav_helper.h"

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kBufferSize = 1024;
constexpr uint32_t kStereoLayout = 2;  // oar_layout_t stereo

struct Scalars {
  float lufs = -120.0f;
  float tp = -120.0f;
  float dp = -120.0f;
};

// The FFI marshalling must reproduce the C++ class result exactly —
// same code underneath, so the comparison is tight, not tolerance-based.
TEST(MixRendererFfiTest, AddElementMarshalsStreamConfig) {
  const std::string src = test_wav::temp_dir() + "/ffi_marshal_src.wav";
  ASSERT_TRUE(
      test_wav::write_sine_frames(src, 2, 44100, 24, 997.0f, 44100, 0.25f));
  const uint64_t pad = 2 * kSampleRate;

  // Through the C API, the way iamf_measure_isolate.dart calls it.
  Scalars ffi;
  {
    eclipsa_studio_mix_renderer_t* r = eclipsa_studio_mix_renderer_create(
        kSampleRate, kBufferSize, kStereoLayout);
    ASSERT_NE(r, nullptr);
    const int32_t routing[2] = {1, 0};  // channel swap
    ASSERT_EQ(eclipsa_studio_mix_renderer_add_element(
                  r, src.c_str(), /*element_id=*/1, /*element_type=*/0,
                  /*element_sub_type=*/kStereoLayout, /*channels=*/2,
                  /*mix_gain_db=*/0.0f, /*headphones_mode=*/1,
                  /*binaural_profile=*/0, /*gain_db=*/-6.0f, routing,
                  /*routing_len=*/2, pad, kSampleRate),
              0);
    ASSERT_EQ(
        eclipsa_studio_mix_renderer_measure(r, &ffi.lufs, &ffi.tp, &ffi.dp), 0);
    // ES-517: the limiter GR series passes through the same trace
    // surface. The Dart side mirrors the literal 4 — freeze it here.
    static_assert(eclipsa_studio::kTraceLimiterGrDb == 4,
                  "C ABI series id is frozen");
    // The 2 s padded program has no warmup window: 20 full steps.
    ASSERT_EQ(eclipsa_studio_mix_renderer_trace_len(r, 4), 20u);
    float gr[20];
    EXPECT_EQ(eclipsa_studio_mix_renderer_copy_trace(r, 4, gr, 20), 20u);
    eclipsa_studio_mix_renderer_destroy(r);
  }
  ASSERT_GT(ffi.lufs, -60.0f);  // actually measured, not the default

  // Through the C++ class with the identical config.
  eclipsa_studio::OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  eclipsa_studio::MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream.input_wav_path = src;
  cfg.stream.gain_db = -6.0f;
  cfg.stream.routing = {1, 0};
  cfg.stream.pad_to_frames = pad;
  cfg.stream.output_sample_rate = kSampleRate;
  cfg.element_type = 0;
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;
  ASSERT_TRUE(renderer.AddElement(cfg));
  const std::optional<eclipsa_studio::LoudnessResult> ref =
      renderer.RenderAndMeasure();
  ASSERT_TRUE(ref.has_value());

  EXPECT_FLOAT_EQ(ffi.lufs, ref->integrated_lufs);
  EXPECT_FLOAT_EQ(ffi.tp, ref->true_peak_dbtp);
  EXPECT_FLOAT_EQ(ffi.dp, ref->digital_peak_dbfs);
}

// NULL routing (the Dart side passes nullptr for an empty map) must
// behave as identity — same result as an explicit {0, 1}.
TEST(MixRendererFfiTest, NullRoutingIsIdentity) {
  const std::string src = test_wav::temp_dir() + "/ffi_identity_src.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(src, 2, kSampleRate, 16, 997.0f,
                                          kSampleRate, 0.1f));

  auto measure = [&](const int32_t* routing, int32_t len) {
    Scalars s;
    eclipsa_studio_mix_renderer_t* r = eclipsa_studio_mix_renderer_create(
        kSampleRate, kBufferSize, kStereoLayout);
    EXPECT_NE(r, nullptr);
    EXPECT_EQ(eclipsa_studio_mix_renderer_add_element(
                  r, src.c_str(), 1, 0, kStereoLayout, 2, 0.0f, 1, 0, 0.0f,
                  routing, len, 0, 0),
              0);
    EXPECT_EQ(eclipsa_studio_mix_renderer_measure(r, &s.lufs, &s.tp, &s.dp), 0);
    eclipsa_studio_mix_renderer_destroy(r);
    return s;
  };

  const int32_t identity[2] = {0, 1};
  const Scalars with_null = measure(nullptr, 0);
  const Scalars with_map = measure(identity, 2);
  ASSERT_GT(with_null.lufs, -60.0f);
  EXPECT_FLOAT_EQ(with_null.lufs, with_map.lufs);
  EXPECT_FLOAT_EQ(with_null.tp, with_map.tp);
  EXPECT_FLOAT_EQ(with_null.dp, with_map.dp);
}

// An object element positioned through the exported symbol must render
// (and measure) as non-silent on a loudspeaker layout — the QC item
// behind the eclipsa_studio_mix_renderer_set_object_position .def fix. The
// offline render pushes the configured position every block, so a
// silent result here means the object path or the position plumbing
// broke.
TEST(MixRendererFfiTest, PositionedObjectMeasuresNonSilent) {
  const std::string src = test_wav::temp_dir() + "/ffi_object_src.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(src, 1, kSampleRate, 16, 997.0f,
                                          kSampleRate, 0.25f));

  eclipsa_studio_mix_renderer_t* r = eclipsa_studio_mix_renderer_create(
      kSampleRate, kBufferSize, kStereoLayout);
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(eclipsa_studio_mix_renderer_add_element(
                r, src.c_str(), /*element_id=*/1, /*element_type=*/2,
                /*element_sub_type=*/1, /*channels=*/1, 0.0f, 1, 0, 0.0f,
                nullptr, 0, 0, 0),
            0);
  eclipsa_studio_mix_renderer_set_object_position(r, 1, 1, 30.0f, 0.0f, 1.0f,
                                                  0.0f, 0.0f, 1.0f);
  Scalars s;
  ASSERT_EQ(eclipsa_studio_mix_renderer_measure(r, &s.lufs, &s.tp, &s.dp), 0);
  eclipsa_studio_mix_renderer_destroy(r);

  EXPECT_GT(s.lufs, -60.0f);
  EXPECT_GT(s.dp, -60.0f);
}

// ES-470: the per-element overload-stats symbol — the call shape the
// measure isolate uses after a successful measure. Class-level stats
// semantics live in offline_mix_renderer_test.cc.
TEST(MixRendererFfiTest, ElementClipStatsMarshal) {
  const std::string src = test_wav::temp_dir() + "/ffi_clip_src.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(src, 2, kSampleRate, 16, 997.0f,
                                          kSampleRate, 0.5f));

  eclipsa_studio_mix_renderer_t* r = eclipsa_studio_mix_renderer_create(
      kSampleRate, kBufferSize, kStereoLayout);
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(eclipsa_studio_mix_renderer_add_element(
                r, src.c_str(), 1, 0, kStereoLayout, 2, 0.0f, 1, 0,
                /*gain_db=*/12.0f, nullptr, 0, 0, 0),
            0);

  // Before a successful measure: -1, out values untouched.
  uint64_t clipped = 123;
  float peak = -1.0f;
  EXPECT_EQ(
      eclipsa_studio_mix_renderer_element_clip_stats(r, 1, &clipped, &peak),
      -1);
  EXPECT_EQ(clipped, 123u);
  EXPECT_FLOAT_EQ(peak, -1.0f);

  Scalars s;
  ASSERT_EQ(eclipsa_studio_mix_renderer_measure(r, &s.lufs, &s.tp, &s.dp), 0);

  EXPECT_EQ(
      eclipsa_studio_mix_renderer_element_clip_stats(r, 1, &clipped, &peak), 0);
  EXPECT_GT(clipped, 0u);
  EXPECT_GT(peak, 1.5f);

  // Unknown id, null handle, and NULL out-pointer tolerance.
  EXPECT_EQ(
      eclipsa_studio_mix_renderer_element_clip_stats(r, 99, &clipped, &peak),
      -1);
  EXPECT_EQ(eclipsa_studio_mix_renderer_element_clip_stats(nullptr, 1, &clipped,
                                                           &peak),
            -1);
  EXPECT_EQ(
      eclipsa_studio_mix_renderer_element_clip_stats(r, 1, nullptr, nullptr),
      0);
  eclipsa_studio_mix_renderer_destroy(r);
}

TEST(MixRendererFfiTest, NullArgumentsReturnErrors) {
  EXPECT_EQ(
      eclipsa_studio_mix_renderer_add_element(
          nullptr, "x.wav", 1, 0, 2, 2, 0.0f, 1, 0, 0.0f, nullptr, 0, 0, 0),
      -1);
  eclipsa_studio_mix_renderer_t* r = eclipsa_studio_mix_renderer_create(
      kSampleRate, kBufferSize, kStereoLayout);
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(eclipsa_studio_mix_renderer_add_element(
                r, nullptr, 1, 0, 2, 2, 0.0f, 1, 0, 0.0f, nullptr, 0, 0, 0),
            -1);
  float f;
  EXPECT_EQ(eclipsa_studio_mix_renderer_measure(nullptr, &f, &f, &f), -1);
  eclipsa_studio_mix_renderer_destroy(r);
}

// A failed measure must be distinguishable from a silent program: the
// FFI returns -2 and leaves the out values untouched, instead of
// "succeeding" with the -120 LUFS defaults that then ship as loudness
// metadata in the exported IAMF. Exercised here via an unreadable
// source WAV and via a measure with no elements.
TEST(MixRendererFfiTest, FailedMeasureReturnsErrorNotSilence) {
  eclipsa_studio_mix_renderer_t* r = eclipsa_studio_mix_renderer_create(
      kSampleRate, kBufferSize, kStereoLayout);
  ASSERT_NE(r, nullptr);

  // No elements added: nothing to render is a caller bug, not silence.
  Scalars s{1.0f, 2.0f, 3.0f};
  EXPECT_EQ(eclipsa_studio_mix_renderer_measure(r, &s.lufs, &s.tp, &s.dp), -2);
  EXPECT_FLOAT_EQ(s.lufs, 1.0f);  // out values untouched on failure
  EXPECT_FLOAT_EQ(s.tp, 2.0f);
  EXPECT_FLOAT_EQ(s.dp, 3.0f);

  // An element whose source WAV cannot be opened fails the measure.
  const std::string missing = test_wav::temp_dir() + "/ffi_missing_src.wav";
  std::remove(missing.c_str());  // independence from the shared temp dir
  ASSERT_EQ(eclipsa_studio_mix_renderer_add_element(r, missing.c_str(), 1, 0,
                                                    kStereoLayout, 2, 0.0f, 1,
                                                    0, 0.0f, nullptr, 0, 0, 0),
            0);
  EXPECT_EQ(eclipsa_studio_mix_renderer_measure(r, &s.lufs, &s.tp, &s.dp), -2);
  eclipsa_studio_mix_renderer_destroy(r);
}

}  // namespace
