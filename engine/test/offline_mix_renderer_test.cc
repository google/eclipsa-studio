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

// Tests for OfflineMixRenderer: post-measurement trace access (the
// momentary / short-term time series, LRA, and their lifecycle around
// RenderAndMeasure()) plus the stream-fed input path — equivalence with
// the historical bounced-WAV measurement, the declared-channel check,
// and ragged source lengths. Loudness *math* is covered by
// loudness_meter_test and the export round-trip tests; here we assert
// the plumbing — availability, lengths, dB conversion, consistency —
// plus the setup cost (no audio-thread wait spins, ES-515).

#include "mix_renderer/offline_mix_renderer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <optional>
#include <string>
#include <vector>

#include "bounce/element_bouncer.h"
#include "gtest/gtest.h"
#include "test_wav_helper.h"

namespace eclipsa_studio {
namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kBufferSize = 1024;
constexpr uint32_t kStereoLayout = 2;  // oar_layout_t stereo
constexpr int kSeconds = 6;
constexpr float kAmplitude = 0.1f;  // sine peak = -20 dBFS

// One 100 ms trace step per kTraceStepMs; a 6 s program yields 60 steps.
constexpr uint32_t kTotalSteps =
    kSeconds * 1000 / OfflineMixRenderer::kTraceStepMs;

// Renders a 6 s stereo sine through a stereo-layout renderer and
// measures. The sine is steady, so every loudness series should sit
// near the integrated value.
class OfflineMixRendererTraceTest : public ::testing::Test {
 protected:
  void SetUp() override {
    wav_path_ = test_wav::temp_dir() + "/trace_test_stereo.wav";
    ASSERT_TRUE(test_wav::write_sine_frames(wav_path_, 2, kSampleRate, 16,
                                            997.0f, kSeconds * kSampleRate,
                                            kAmplitude));
    ASSERT_TRUE(renderer_.Init(kSampleRate, kBufferSize, kStereoLayout));
    MixElementConfig cfg;
    cfg.element_id = 1;
    cfg.stream.input_wav_path = wav_path_;
    cfg.element_type = 0;  // channel bed
    cfg.element_sub_type = kStereoLayout;
    cfg.channels = 2;
    ASSERT_TRUE(renderer_.AddElement(cfg));
  }

  std::string wav_path_;
  OfflineMixRenderer renderer_;
};

TEST_F(OfflineMixRendererTraceTest, NoTracesBeforeMeasure) {
  EXPECT_EQ(renderer_.TraceLength(kTraceMomentaryLufs), 0u);
  EXPECT_EQ(renderer_.TraceLength(kTraceShortTermLufs), 0u);
  EXPECT_EQ(renderer_.TraceLength(kTraceLimiterGrDb), 0u);
  float out[4];
  EXPECT_EQ(renderer_.CopyTrace(kTraceMomentaryLufs, out, 4), 0u);
  EXPECT_EQ(renderer_.CopyTrace(kTraceLimiterGrDb, out, 4), 0u);
  EXPECT_FALSE(renderer_.GetLoudnessRange(nullptr, nullptr));
}

// A run that fails leaves nothing of the previous run readable: the
// series and the loudness range are reset at the start of every run,
// before the failure points.
TEST_F(OfflineMixRendererTraceTest, FailedRemeasureClearsTraces) {
  ASSERT_TRUE(renderer_.RenderAndMeasure().has_value());
  ASSERT_GT(renderer_.TraceLength(kTraceLimiterGrDb), 0u);
  ASSERT_TRUE(renderer_.GetLoudnessRange(nullptr, nullptr));

  MixElementConfig missing;
  missing.element_id = 2;
  missing.stream.input_wav_path = test_wav::temp_dir() + "/does_not_exist.wav";
  missing.element_sub_type = kStereoLayout;
  missing.channels = 2;
  ASSERT_TRUE(renderer_.AddElement(missing));
  EXPECT_FALSE(renderer_.RenderAndMeasure().has_value());
  EXPECT_EQ(renderer_.TraceLength(kTraceMomentaryLufs), 0u);
  EXPECT_EQ(renderer_.TraceLength(kTraceLimiterGrDb), 0u);
  EXPECT_FALSE(renderer_.GetLoudnessRange(nullptr, nullptr));
}

TEST_F(OfflineMixRendererTraceTest, TracesAfterMeasure) {
  const std::optional<LoudnessResult> measured = renderer_.RenderAndMeasure();
  ASSERT_TRUE(measured.has_value());
  const LoudnessResult result = *measured;
  ASSERT_GT(result.integrated_lufs, -30.0f);  // measurement actually ran

  // Momentary entries start once the 400 ms window fills (3 steps
  // skipped); short-term once the 3 s window fills (29 skipped). Allow
  // slack for edge handling, but the ordering must hold.
  const uint32_t momentary = renderer_.TraceLength(kTraceMomentaryLufs);
  const uint32_t short_term = renderer_.TraceLength(kTraceShortTermLufs);
  EXPECT_GE(momentary, kTotalSteps - 5);
  EXPECT_LE(momentary, kTotalSteps);
  EXPECT_GE(short_term, kTotalSteps - 31);
  EXPECT_LE(short_term, kTotalSteps - 25);
  EXPECT_GT(momentary, short_term);

  // Peaks and PSR ride the same short-term block cadence.
  EXPECT_EQ(renderer_.TraceLength(kTraceShortTermPeakDbfs), short_term);
  EXPECT_EQ(renderer_.TraceLength(kTraceShortTermPsrDb), short_term);

  // Steady tone: every momentary / short-term entry sits near the
  // integrated loudness.
  std::vector<float> trace(momentary);
  ASSERT_EQ(renderer_.CopyTrace(kTraceMomentaryLufs, trace.data(), momentary),
            momentary);
  for (const float v : trace) {
    EXPECT_NEAR(v, result.integrated_lufs, 1.0f);
  }
  trace.resize(short_term);
  ASSERT_EQ(renderer_.CopyTrace(kTraceShortTermLufs, trace.data(), short_term),
            short_term);
  for (const float v : trace) {
    EXPECT_NEAR(v, result.integrated_lufs, 1.0f);
  }

  // Peak series is converted to dBFS on copy and must sit near the
  // program's digital peak; PSR must equal peak minus short-term.
  std::vector<float> peaks(short_term);
  std::vector<float> psr(short_term);
  ASSERT_EQ(
      renderer_.CopyTrace(kTraceShortTermPeakDbfs, peaks.data(), short_term),
      short_term);
  ASSERT_EQ(renderer_.CopyTrace(kTraceShortTermPsrDb, psr.data(), short_term),
            short_term);
  for (uint32_t i = 0; i < short_term; ++i) {
    EXPECT_NEAR(peaks[i], result.digital_peak_dbfs, 1.0f);
    EXPECT_NEAR(psr[i], peaks[i] - trace[i], 0.1f);
  }
}

// ES-517: the limiter GR series has no warmup window — one entry per
// 100 ms step from t=0 — and a -20 dBFS program never touches the
// -1 dBFS ceiling, so every entry is exactly 0 (the limiter idles and
// its envelope stays at 1.0).
TEST_F(OfflineMixRendererTraceTest, LimiterGrTraceIsZeroBelowCeiling) {
  ASSERT_TRUE(renderer_.RenderAndMeasure().has_value());

  const uint32_t len = renderer_.TraceLength(kTraceLimiterGrDb);
  EXPECT_EQ(len, kTotalSteps);  // full length, no warmup skip

  std::vector<float> gr(len);
  ASSERT_EQ(renderer_.CopyTrace(kTraceLimiterGrDb, gr.data(), len), len);
  for (const float v : gr) {
    EXPECT_EQ(v, 0.0f);
  }
}

// ES-517: a full-scale sine (~ -0.0003 dBFS, above the -1 dBFS ceiling
// but never > 1.0) keeps the limiter engaged for the whole program, so
// the GR trace must show sustained reduction — the disclosure that the
// unlimited render (what the exported file ships) exceeds -1 dBFS.
TEST(OfflineMixRendererLimiterGrTest, HotProgramShowsSustainedReduction) {
  const std::string src = test_wav::temp_dir() + "/limiter_gr_hot.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(src, 2, kSampleRate, 16, 997.0f,
                                          kSeconds * kSampleRate, 1.0f));

  OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream.input_wav_path = src;
  cfg.element_type = 0;  // channel bed
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;
  ASSERT_TRUE(renderer.AddElement(cfg));
  ASSERT_TRUE(renderer.RenderAndMeasure().has_value());

  const uint32_t len = renderer.TraceLength(kTraceLimiterGrDb);
  ASSERT_EQ(len, kTotalSteps);

  std::vector<float> gr(len);
  ASSERT_EQ(renderer.CopyTrace(kTraceLimiterGrDb, gr.data(), len), len);
  float max_gr = 0.0f;
  for (uint32_t i = 0; i < len; ++i) {
    EXPECT_TRUE(std::isfinite(gr[i])) << "step " << i;
    // The limiter's 1 ms attack completes inside the first 1024-frame
    // block and the sine re-peaks every half cycle, so every step
    // carries reduction — no settling to skip.
    EXPECT_GT(gr[i], 0.0f) << "step " << i;
    max_gr = std::max(max_gr, gr[i]);
  }
  // ~1 dB of reduction on a near-full-scale sine against -1 dBFS.
  EXPECT_GT(max_gr, 0.5f);
}

// Turned off after a limited pass on the same renderer, the limiter
// reports no reduction in the next pass. A disabled OAR limiter keeps
// the envelope it ended the last pass with, which would read as
// reduction in every step.
TEST(OfflineMixRendererLimiterGrTest, LimiterOffAfterLimitedPassReadsNone) {
  const std::string src = test_wav::temp_dir() + "/limiter_gr_off_after.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(src, 2, kSampleRate, 16, 997.0f,
                                          kSeconds * kSampleRate, 1.0f));

  OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream.input_wav_path = src;
  cfg.element_type = 0;  // channel bed
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;
  ASSERT_TRUE(renderer.AddElement(cfg));
  ASSERT_TRUE(renderer.RenderAndMeasure().has_value());
  std::vector<float> gr(renderer.TraceLength(kTraceLimiterGrDb));
  ASSERT_EQ(renderer.CopyTrace(kTraceLimiterGrDb, gr.data(),
                               static_cast<uint32_t>(gr.size())),
            gr.size());
  ASSERT_GT(gr.back(), 0.0f);  // engaged when the limited pass ends

  ASSERT_TRUE(renderer.SetLimiterEnabled(false));
  const std::optional<LoudnessResult> unlimited = renderer.RenderAndMeasure();
  ASSERT_TRUE(unlimited.has_value());
  EXPECT_GT(unlimited->digital_peak_dbfs, -0.5f);  // not limited to -1
  gr.assign(renderer.TraceLength(kTraceLimiterGrDb), -1.0f);
  ASSERT_EQ(gr.size(), kTotalSteps);
  ASSERT_EQ(renderer.CopyTrace(kTraceLimiterGrDb, gr.data(),
                               static_cast<uint32_t>(gr.size())),
            gr.size());
  for (uint32_t i = 0; i < gr.size(); ++i) {
    EXPECT_EQ(gr[i], 0.0f) << "step " << i;
  }
}

// ES-517: a program that is not a whole number of 100 ms steps must
// still cover its tail — the trailing partial bucket is flushed, so
// the series length is ceil(program / step).
TEST(OfflineMixRendererLimiterGrTest, PartialFinalBucketIsFlushed) {
  constexpr uint32_t kFrames = 122400;  // 2.55 s -> 25 full steps + tail
  static_assert(kFrames % (kSampleRate / 10) != 0, "tail must be partial");
  const std::string src = test_wav::temp_dir() + "/limiter_gr_ragged.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(src, 2, kSampleRate, 16, 997.0f,
                                          kFrames, kAmplitude));

  OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream.input_wav_path = src;
  cfg.element_type = 0;  // channel bed
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;
  ASSERT_TRUE(renderer.AddElement(cfg));
  ASSERT_TRUE(renderer.RenderAndMeasure().has_value());

  EXPECT_EQ(renderer.TraceLength(kTraceLimiterGrDb), 26u);
}

TEST_F(OfflineMixRendererTraceTest, CopyRespectsCapAndUnknownSeries) {
  ASSERT_TRUE(renderer_.RenderAndMeasure().has_value());
  float out[5];
  EXPECT_EQ(renderer_.CopyTrace(kTraceMomentaryLufs, out, 5), 5u);
  EXPECT_EQ(renderer_.TraceLength(99), 0u);
  EXPECT_EQ(renderer_.CopyTrace(99, out, 5), 0u);
}

TEST_F(OfflineMixRendererTraceTest, LoudnessRangeOfSteadyToneIsSmall) {
  ASSERT_TRUE(renderer_.RenderAndMeasure().has_value());
  float lra = -1.0f;
  bool stable = true;
  ASSERT_TRUE(renderer_.GetLoudnessRange(&lra, &stable));
  EXPECT_GE(lra, 0.0f);
  EXPECT_LT(lra, 3.0f);  // steady tone has (near) zero loudness range
  EXPECT_FALSE(stable);  // 6 s program: EBU 3341 needs 60 s for "stable"
}

// Regression test for the final-partial-block stride bug: OAR packs its
// planar render output tightly with stride `block` (the frames of the
// current render call), but the measurement loop used to index it with
// the configured buffer size. On the final partial block that read
// stale samples for every channel >= 1. Program length is deliberately
// not a multiple of the buffer size, and the only loud content is a
// -6 dBFS burst confined to channel 1's final partial block — with the
// stride bug the burst is invisible and the reported digital peak drops
// to the bed's -26 dBFS.
TEST(OfflineMixRendererStrideTest, PeakInFinalPartialBlockOnSecondChannel) {
  constexpr uint32_t kFrames = 144000;  // 140 * 1024 + a 640-frame tail
  constexpr uint32_t kTailStart = kFrames - (kFrames % kBufferSize);
  static_assert(kFrames % kBufferSize != 0, "tail block must be partial");
  constexpr float kBedAmp = 0.05f;   // ~ -26 dBFS
  constexpr float kBurstAmp = 0.5f;  // ~ -6 dBFS

  std::vector<int16_t> frames(static_cast<size_t>(kFrames) * 2);
  for (uint32_t i = 0; i < kFrames; ++i) {
    const float t = static_cast<float>(i) / kSampleRate;
    const float s = std::sin(2.0f * 3.14159265f * 997.0f * t);
    const bool in_tail = i >= kTailStart;
    frames[i * 2 + 0] = static_cast<int16_t>(s * kBedAmp * 32767.0f);
    frames[i * 2 + 1] =
        static_cast<int16_t>(s * (in_tail ? kBurstAmp : kBedAmp) * 32767.0f);
  }
  const std::string path = test_wav::temp_dir() + "/stride_tail_burst.wav";
  ASSERT_TRUE(test_wav::write_frames_s16(path, 2, kSampleRate, frames));

  OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream.input_wav_path = path;
  cfg.element_type = 0;  // channel bed
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;
  ASSERT_TRUE(renderer.AddElement(cfg));

  const std::optional<LoudnessResult> result = renderer.RenderAndMeasure();
  ASSERT_TRUE(result.has_value());
  const float expected_peak_dbfs =
      20.0f * std::log10(kBurstAmp * 32767.0f / 32768.0f);
  EXPECT_NEAR(result->digital_peak_dbfs, expected_peak_dbfs, 1.0f);
}

// Regression test for non-finite trace entries: the analyzer emits NaN
// momentary values over a padded silence tail and +inf PSR over leading
// silence. Those used to reach callers verbatim through CopyTrace and a
// single NaN blanks the Loudness Report chart (its axis range poisons).
// CopyTrace now clamps non-finite entries to the -120 floor, so every
// copied value is finite and <= -120 uniformly means silence / no data.
TEST(OfflineMixRendererTraceSanitizeTest, PaddedSilenceYieldsFiniteTraces) {
  // 1 s digital silence, then 2 s of tone; padded to 5 s so the render
  // also has a 2 s silence tail.
  constexpr uint32_t kToneStart = 1 * kSampleRate;
  constexpr uint32_t kFrames = 3 * kSampleRate;
  std::vector<int16_t> frames(static_cast<size_t>(kFrames) * 2, 0);
  for (uint32_t i = kToneStart; i < kFrames; ++i) {
    const float t = static_cast<float>(i) / kSampleRate;
    const float s = std::sin(2.0f * 3.14159265f * 997.0f * t) * kAmplitude;
    frames[i * 2 + 0] = static_cast<int16_t>(s * 32767.0f);
    frames[i * 2 + 1] = static_cast<int16_t>(s * 32767.0f);
  }
  const std::string path = test_wav::temp_dir() + "/trace_sanitize.wav";
  ASSERT_TRUE(test_wav::write_frames_s16(path, 2, kSampleRate, frames));

  OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream.input_wav_path = path;
  cfg.stream.pad_to_frames = 5 * kSampleRate;
  cfg.element_type = 0;  // channel bed
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;
  ASSERT_TRUE(renderer.AddElement(cfg));
  const std::optional<LoudnessResult> result = renderer.RenderAndMeasure();
  ASSERT_TRUE(result.has_value());
  ASSERT_GT(result->integrated_lufs, -60.0f);  // the tone was measured

  for (const uint32_t series :
       {kTraceMomentaryLufs, kTraceShortTermLufs, kTraceShortTermPeakDbfs,
        kTraceShortTermPsrDb}) {
    const uint32_t len = renderer.TraceLength(series);
    ASSERT_GT(len, 0u) << "series " << series;
    std::vector<float> values(len);
    ASSERT_EQ(renderer.CopyTrace(series, values.data(), len), len);
    float finite_above_floor = 0;
    for (const float v : values) {
      EXPECT_TRUE(std::isfinite(v)) << "series " << series;
      if (std::isfinite(v) && v > -120.0f) finite_above_floor++;
    }
    // The tone's portion of every series survives the sanitize.
    EXPECT_GT(finite_above_floor, 0) << "series " << series;
  }
}

// Measures one stereo bed at the stereo layout and returns the result.
LoudnessResult MeasureStereoBed(const ElementStream::Config& stream) {
  OfflineMixRenderer renderer;
  EXPECT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream = stream;
  cfg.element_type = 0;  // channel bed
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;
  EXPECT_TRUE(renderer.AddElement(cfg));
  const std::optional<LoudnessResult> result = renderer.RenderAndMeasure();
  EXPECT_TRUE(result.has_value());
  return result.value_or(LoudnessResult{});
}

// The headline ES-484 equivalence: measuring straight from the source
// through the full stream config (gain + routing + resample + pad)
// must match measuring the ElementBouncer output of the same config —
// the historical scratch-WAV path. A 24-bit source keeps the bounce
// file's quantization far below the tolerance.
TEST(OfflineMixRendererStreamTest, StreamFedMeasureMatchesBouncedFileMeasure) {
  const std::string src = test_wav::temp_dir() + "/stream_equiv_src.wav";
  ASSERT_TRUE(
      test_wav::write_sine_frames(src, 2, 44100, 24, 997.0f, 3 * 44100, 0.25f));

  ElementStream::Config stream;
  stream.input_wav_path = src;
  stream.gain_db = -6.0f;
  stream.routing = {1, 0};  // channel swap
  stream.pad_to_frames = 4 * kSampleRate;
  stream.output_sample_rate = kSampleRate;

  ElementBouncer::Config bounce;
  bounce.input_wav_path = stream.input_wav_path;
  bounce.output_wav_path = test_wav::temp_dir() + "/stream_equiv_bounced.wav";
  bounce.gain_db = stream.gain_db;
  bounce.routing = stream.routing;
  bounce.pad_to_frames = stream.pad_to_frames;
  bounce.output_sample_rate = stream.output_sample_rate;
  ASSERT_EQ(ElementBouncer::Bounce(bounce), 0);

  ElementStream::Config bounced_identity;
  bounced_identity.input_wav_path = bounce.output_wav_path;

  const LoudnessResult reference = MeasureStereoBed(bounced_identity);
  const LoudnessResult streamed = MeasureStereoBed(stream);

  ASSERT_GT(reference.integrated_lufs, -60.0f);  // both actually measured
  ASSERT_GT(streamed.integrated_lufs, -60.0f);
  EXPECT_NEAR(streamed.integrated_lufs, reference.integrated_lufs, 0.1f);
  EXPECT_NEAR(streamed.true_peak_dbtp, reference.true_peak_dbtp, 0.1f);
  EXPECT_NEAR(streamed.digital_peak_dbfs, reference.digital_peak_dbfs, 0.1f);
}

// Measurement runs the same limiter as live monitoring, whose 5 ms
// look-ahead delays the output by limiter_delay() frames. The render
// loop drains that delay past the program end, so content in the last
// 5 ms is measured. A click 50 frames before the end of a 1 s source
// comes out 190 frames after the end; without the drain the digital
// peak reads the -120 dBFS floor.
TEST(OfflineMixRendererStreamTest, MeasureDrainsTheLimiterDelay) {
  const std::string src = test_wav::temp_dir() + "/tail_click_src.wav";
  std::vector<float> samples(kSampleRate, 0.0f);
  samples[kSampleRate - 50] = 0.5f;
  ASSERT_TRUE(test_wav::write_float32_frames(src, 2, kSampleRate, samples));

  ElementStream::Config stream;
  stream.input_wav_path = src;
  const LoudnessResult result = MeasureStereoBed(stream);
  EXPECT_NEAR(result.digital_peak_dbfs, 20.0f * std::log10(0.5f), 0.1f)
      << "tail click lost in the limiter delay";
}

// The start of the program: the first output frames are the limiter's
// priming delay, so a click on frame 0 appears `delay` frames into the
// render. Measurement must start at that offset: the click is still
// measured, and the GR trace keeps one entry per 100 ms of program
// (10 for 1 s) instead of gaining an entry for the priming frames.
TEST(OfflineMixRendererStreamTest, MeasureSkipsTheLimiterPriming) {
  const std::string src = test_wav::temp_dir() + "/head_click_src.wav";
  std::vector<float> samples(kSampleRate, 0.0f);
  samples[0] = 0.5f;
  ASSERT_TRUE(test_wav::write_float32_frames(src, 2, kSampleRate, samples));

  OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream.input_wav_path = src;
  cfg.element_type = 0;  // channel bed
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;
  ASSERT_TRUE(renderer.AddElement(cfg));
  const std::optional<LoudnessResult> result = renderer.RenderAndMeasure();
  ASSERT_TRUE(result.has_value());
  EXPECT_NEAR(result->digital_peak_dbfs, 20.0f * std::log10(0.5f), 0.1f)
      << "head click lost in the limiter delay";
  EXPECT_EQ(renderer.TraceLength(kTraceLimiterGrDb), 10u);
}

// ES-491/ES-492: offline measurement runs through OAR's -1 dBFS peak
// limiter, which is on by default and in every app path, as in live
// monitoring; only the measure CLI's --no-limiter turns it off. A
// full-scale sine pushed +6 dB past full scale must therefore come back
// clamped at the ceiling, not at ~+6 dBFS. If the offline limiter's
// default is ever off again, this fails. It is the regression pin for
// the decision and the counterpart of the shipped-side pin in
// iamf_loudness_agreement_test (the shipped values stay unlimited).
TEST(OfflineMixRendererStreamTest, MeasureIsPostLimiter) {
  const std::string src = test_wav::temp_dir() + "/post_limiter_src.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(src, 2, kSampleRate, 16, 997.0f,
                                          2 * kSampleRate, 1.0f));

  ElementStream::Config stream;
  stream.input_wav_path = src;
  stream.gain_db = 6.0f;

  const LoudnessResult result = MeasureStereoBed(stream);
  ASSERT_GT(result.integrated_lufs, -60.0f);  // actually measured
  // Pre-limiter this reads ~+6 dBFS; the limiter clamps sample peaks
  // to the -1 dBFS ceiling (slack in case it overshoots on attack).
  EXPECT_LE(result.digital_peak_dbfs, -0.8f);
  EXPECT_GT(result.digital_peak_dbfs, -3.0f);  // engaged, not silent
  // The limiter detects SAMPLE peaks: the 4x-oversampled true peak
  // sits above the clamped digital peak, so a -1 dBFS ceiling does
  // NOT guarantee -1 dBTP — pin that, it is user-visible in the
  // report and the Inspector.
  EXPECT_GT(result.true_peak_dbtp, result.digital_peak_dbfs);
}

// Measures one stereo bed at the stereo layout with the limiter off, set
// before or after Init(), and copies the limiter GR trace into `gr`.
LoudnessResult MeasureStereoBedUnlimited(const ElementStream::Config& stream,
                                         bool set_before_init,
                                         std::vector<float>* gr) {
  OfflineMixRenderer renderer;
  if (set_before_init) EXPECT_TRUE(renderer.SetLimiterEnabled(false));
  EXPECT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  if (!set_before_init) EXPECT_TRUE(renderer.SetLimiterEnabled(false));
  MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream = stream;
  cfg.element_type = 0;  // channel bed
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;
  EXPECT_TRUE(renderer.AddElement(cfg));
  const std::optional<LoudnessResult> result = renderer.RenderAndMeasure();
  EXPECT_TRUE(result.has_value());
  gr->assign(renderer.TraceLength(kTraceLimiterGrDb), -1.0f);
  renderer.CopyTrace(kTraceLimiterGrDb, gr->data(),
                     static_cast<uint32_t>(gr->size()));
  return result.value_or(LoudnessResult{});
}

// SetLimiterEnabled(false) measures the unlimited render. The +6 dB
// sine of MeasureIsPostLimiter keeps its +6 dBFS sample peak, its
// loudness reads 20 dB above the same sine at -14 dB (which the limiter
// leaves alone), and the GR trace is all zeros.
TEST(OfflineMixRendererStreamTest, LimiterOffMeasuresTheUnlimitedRender) {
  const std::string src = test_wav::temp_dir() + "/limiter_off_src.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(src, 2, kSampleRate, 16, 997.0f,
                                          2 * kSampleRate, 1.0f));

  ElementStream::Config hot;
  hot.input_wav_path = src;
  hot.gain_db = 6.0f;
  ElementStream::Config quiet = hot;
  quiet.gain_db = -14.0f;

  const LoudnessResult limited = MeasureStereoBed(hot);
  const LoudnessResult quiet_limited = MeasureStereoBed(quiet);
  ASSERT_LT(quiet_limited.digital_peak_dbfs, -13.0f);  // limiter idle

  for (const bool before_init : {true, false}) {
    std::vector<float> gr;
    const LoudnessResult unlimited =
        MeasureStereoBedUnlimited(hot, before_init, &gr);
    EXPECT_NEAR(unlimited.digital_peak_dbfs, 6.0f, 0.05f) << before_init;
    EXPECT_NEAR(unlimited.integrated_lufs,
                quiet_limited.integrated_lufs + 20.0f, 0.02f)
        << before_init;
    EXPECT_GT(unlimited.integrated_lufs, limited.integrated_lufs + 1.0f)
        << before_init;
    EXPECT_EQ(gr.size(), 20u) << before_init;  // 2 s of 100 ms steps
    for (const float v : gr) EXPECT_EQ(v, 0.0f) << before_init;
  }
}

// With the limiter off the render has no look-ahead delay, and the pass
// measures the program frames without it: a click on the first and one
// on the last frame of a 1 s source are measured, and the GR trace keeps
// one entry per 100 ms of program.
TEST(OfflineMixRendererStreamTest, LimiterOffMeasuresFirstAndLastFrame) {
  for (const uint32_t frame : {0u, kSampleRate - 1}) {
    const std::string src = test_wav::temp_dir() + "/limiter_off_click.wav";
    std::vector<float> samples(kSampleRate, 0.0f);
    samples[frame] = 0.5f;
    ASSERT_TRUE(test_wav::write_float32_frames(src, 2, kSampleRate, samples));

    ElementStream::Config stream;
    stream.input_wav_path = src;
    std::vector<float> gr;
    const LoudnessResult result =
        MeasureStereoBedUnlimited(stream, /*set_before_init=*/true, &gr);
    EXPECT_NEAR(result.digital_peak_dbfs, 20.0f * std::log10(0.5f), 0.1f)
        << "click on frame " << frame << " lost";
    EXPECT_EQ(gr.size(), 10u) << frame;
  }
}

// ES-470: per-element overload stats are counted on each element's own
// stream output (pre-mix, pre-limiter — the PCM the IAMF export would
// encode), so a hot element is visible even though MeasureIsPostLimiter
// above shows the measured mix peaks clamped at the ceiling.
TEST(OfflineMixRendererStreamTest, ElementClipStatsPerElement) {
  const std::string src = test_wav::temp_dir() + "/clip_stats_src.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(src, 2, kSampleRate, 16, 997.0f,
                                          2 * kSampleRate, 0.5f));

  OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));

  MixElementConfig hot;
  hot.element_id = 7;
  hot.stream.input_wav_path = src;
  hot.stream.gain_db = 12.0f;  // 0.5 * ~3.98 => peaks ~2.0
  hot.element_type = 0;
  hot.element_sub_type = kStereoLayout;
  hot.channels = 2;
  ASSERT_TRUE(renderer.AddElement(hot));

  MixElementConfig quiet = hot;
  quiet.element_id = 8;
  quiet.stream.gain_db = 0.0f;
  ASSERT_TRUE(renderer.AddElement(quiet));

  // Nothing before a successful measure.
  EXPECT_FALSE(renderer.GetElementClipStats(7, nullptr, nullptr));

  ASSERT_TRUE(renderer.RenderAndMeasure().has_value());

  uint64_t clipped = 0;
  float peak = 0.0f;
  ASSERT_TRUE(renderer.GetElementClipStats(7, &clipped, &peak));
  EXPECT_GT(clipped, 0u);
  EXPECT_GT(peak, 1.5f);

  ASSERT_TRUE(renderer.GetElementClipStats(8, &clipped, &peak));
  EXPECT_EQ(clipped, 0u);
  EXPECT_GT(peak, 0.4f);
  EXPECT_LE(peak, 0.5f);

  // Unknown id and null out-pointers.
  EXPECT_FALSE(renderer.GetElementClipStats(99, &clipped, &peak));
  EXPECT_TRUE(renderer.GetElementClipStats(7, nullptr, nullptr));

  // A second run repopulates (same config, same result).
  ASSERT_TRUE(renderer.RenderAndMeasure().has_value());
  ASSERT_TRUE(renderer.GetElementClipStats(7, &clipped, nullptr));
  EXPECT_GT(clipped, 0u);
}

// Found via iamf_loudness_agreement_test (ES-492): OAR gain metadata is
// an animated segment covering `frames` frames, after which the value
// reverts to the 0 dB default — the old one-shot push before the render
// loop applied the IAMF mix faders to the first ~21 ms only, and the
// rest of the program measured unity. Gains are now re-pushed every
// block like the live audio thread. Pin: a -6 dB element mix gain plus
// a -4 dB output mix gain must move the WHOLE measurement by 10 dB.
TEST(OfflineMixRendererStreamTest, MixGainsApplyForTheWholeProgram) {
  const std::string src = test_wav::temp_dir() + "/mix_gain_src.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(src, 2, kSampleRate, 16, 997.0f,
                                          2 * kSampleRate, 0.25f));

  ElementStream::Config stream;
  stream.input_wav_path = src;

  auto measure = [&](float mix_gain_db, float output_gain_db) {
    OfflineMixRenderer renderer;
    EXPECT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
    MixElementConfig cfg;
    cfg.element_id = 1;
    cfg.stream = stream;
    cfg.element_type = 0;
    cfg.element_sub_type = kStereoLayout;
    cfg.channels = 2;
    cfg.mix_gain_db = mix_gain_db;
    EXPECT_TRUE(renderer.AddElement(cfg));
    renderer.SetOutputMixGain(output_gain_db);
    const std::optional<LoudnessResult> result = renderer.RenderAndMeasure();
    EXPECT_TRUE(result.has_value());
    return result.value_or(LoudnessResult{});
  };

  const LoudnessResult reference = measure(0.0f, 0.0f);
  const LoudnessResult gained = measure(-6.0f, -4.0f);

  ASSERT_GT(reference.integrated_lufs, -60.0f);
  ASSERT_GT(gained.integrated_lufs, -60.0f);
  EXPECT_NEAR(gained.integrated_lufs, reference.integrated_lufs - 10.0f, 0.1f);
  // Digital peak moves by the full 10 dB too — with the old one-shot
  // push, the gainless majority of the program set the peak and this
  // read equal to the reference.
  EXPECT_NEAR(gained.digital_peak_dbfs, reference.digital_peak_dbfs - 10.0f,
              0.1f);
}

// A stream whose routing delivers fewer channels than declared must
// fail the measure (nullopt, no traces) instead of feeding OAR a
// mismatched buffer.
TEST(OfflineMixRendererStreamTest, DeclaredChannelsMismatchFails) {
  const std::string src = test_wav::temp_dir() + "/stream_mismatch_src.wav";
  ASSERT_TRUE(
      test_wav::write_sine_frames(src, 2, kSampleRate, 16, 997.0f, 48000));

  OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream.input_wav_path = src;
  cfg.stream.routing = {0};  // stream delivers 1 channel...
  cfg.element_type = 0;
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;  // ...but 2 are declared to OAR
  ASSERT_TRUE(renderer.AddElement(cfg));

  EXPECT_FALSE(renderer.RenderAndMeasure().has_value());
  EXPECT_EQ(renderer.TraceLength(kTraceMomentaryLufs), 0u);
}

// With pad_to_frames = 0 (the CLI's configuration) sources of different
// lengths must still measure: the longest stream drives the loop and
// shorter elements trail in silence — the historical max-frames
// semantics of the bounced-WAV path.
TEST(OfflineMixRendererStreamTest, RaggedLengthsStillMeasure) {
  const std::string long_src = test_wav::temp_dir() + "/stream_ragged_2s.wav";
  const std::string short_src = test_wav::temp_dir() + "/stream_ragged_1s.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(long_src, 2, kSampleRate, 16, 997.0f,
                                          2 * kSampleRate, kAmplitude));
  ASSERT_TRUE(test_wav::write_sine_frames(short_src, 2, kSampleRate, 16, 499.0f,
                                          kSampleRate, kAmplitude));

  OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  for (uint32_t id = 1; id <= 2; ++id) {
    MixElementConfig cfg;
    cfg.element_id = id;
    cfg.stream.input_wav_path = id == 1 ? long_src : short_src;
    cfg.element_type = 0;
    cfg.element_sub_type = kStereoLayout;
    cfg.channels = 2;
    ASSERT_TRUE(renderer.AddElement(cfg));
  }

  const std::optional<LoudnessResult> result = renderer.RenderAndMeasure();
  ASSERT_TRUE(result.has_value());
  EXPECT_GT(result->integrated_lufs, -30.0f);
  // The 2 s program yields the full momentary series (400 ms window →
  // first ~3 steps skipped), proving the loop ran to the longest source.
  EXPECT_GE(renderer.TraceLength(kTraceMomentaryLufs),
            2000 / OfflineMixRenderer::kTraceStepMs - 5);
}

// ES-515: an offline instance has no audio thread, so OAR's fade-out and
// reconfigure-ack waits can never be satisfied — every AddElement
// rebuild used to busy-spin ~0.55 s to their timeouts (~1.1 s with a
// non-default rendering config, which rebuilds twice), and the
// destructor's shutdown wait another 50 ms. The waits now short-circuit
// (OarRenderer::set_no_audio_thread). Two elements with non-default
// configs used to spin >= 2.2 s; bound the whole setup far below that.
// The bound is generous for slow CI — the real cost is a few OAR
// instance creates, single-digit milliseconds. The wait semantics
// themselves are pinned deterministically in oar_fade_test.cc
// (NoAudioThreadShortCircuitsWaits); this is the end-to-end smoke
// check.
// Absurd sample rates must fail Init instead of reaching the render
// loop: below 10 Hz the GR-trace step truncates to zero frames and the
// bucket-advance loop would push entries until allocation failure.
// Reachable from the C ABI (eclipsa_studio_mix_renderer_create).
TEST(OfflineMixRendererSetupTest, InitRejectsAbsurdSampleRate) {
  OfflineMixRenderer renderer;
  EXPECT_FALSE(renderer.Init(8, kBufferSize, kStereoLayout));
  EXPECT_FALSE(renderer.Init(7999, kBufferSize, kStereoLayout));
}

TEST(OfflineMixRendererSetupTest, AddElementDoesNotSpinOnAudioThreadWaits) {
  constexpr int64_t kSetupBudgetMs = 1000;
  const auto start = std::chrono::steady_clock::now();
  {
    OfflineMixRenderer renderer;
    ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
    for (uint32_t id = 1; id <= 2; ++id) {
      MixElementConfig cfg;
      cfg.element_id = id;
      cfg.element_type = 0;
      cfg.element_sub_type = kStereoLayout;
      cfg.channels = 2;
      cfg.headphones_mode = 0;  // non-default: forces a second rebuild
      ASSERT_TRUE(renderer.AddElement(cfg));
    }
  }
  const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::steady_clock::now() - start)
                              .count();
  EXPECT_LT(elapsed_ms, kSetupBudgetMs);
}

}  // namespace
}  // namespace eclipsa_studio
