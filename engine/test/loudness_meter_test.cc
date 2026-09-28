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

// Tests for the BS.1770-4 loudness meter that wraps google/loudness_ebur128.
//
// These tests cover the LoudnessMeter wrapper itself: that it copies the
// AudioBuffer correctly, that it routes the analyzer's outputs into the
// EclipsaStudioMeterState fields, and that the BS.1770 numbers we surface line
// up with reference values for known signals (silence, 1 kHz sine at full scale
// and -6 dB).

#include "meters/loudness_meter.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "graph/audio_buffer.h"
#include "gtest/gtest.h"
#include "meters/meter_state.h"

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kChannels = 2;

// LongBuf owns the planar PCM storage and exposes an AudioBuffer view that
// LoudnessMeter::process() can consume directly.
struct LongBuf {
  std::vector<float> storage;
  AudioBuffer buf;
  uint32_t frames;

  explicit LongBuf(uint32_t n_frames)
      : storage(static_cast<size_t>(kChannels) * n_frames, 0.0f),
        frames(n_frames) {
    buf.data = storage.data();
    buf.channels = kChannels;
    buf.frames = n_frames;
    buf.capacity_frames = n_frames;
  }

  void zero() { std::fill(storage.begin(), storage.end(), 0.0f); }

  // Fill all channels with a sine wave at the given frequency / amplitude.
  void fill_sine(float freq_hz, float amplitude) {
    constexpr float kPi = 3.14159265358979323846f;
    const float dt = 1.0f / static_cast<float>(kSampleRate);
    for (uint32_t ch = 0; ch < kChannels; ++ch) {
      float* d = buf.channel(ch);
      for (uint32_t f = 0; f < frames; ++f) {
        d[f] = amplitude *
               std::sin(2.0f * kPi * freq_hz * static_cast<float>(f) * dt);
      }
    }
  }

  // Fill all channels with a constant value (DC).
  void fill_constant(float v) {
    for (uint32_t ch = 0; ch < kChannels; ++ch) {
      float* d = buf.channel(ch);
      for (uint32_t f = 0; f < frames; ++f) d[f] = v;
    }
  }
};

// Convenience: convert a duration in milliseconds to a frame count.
constexpr uint32_t Ms(uint32_t ms) { return (kSampleRate * ms) / 1000u; }

// ── Silence ───────────────────────────────────────────────────────────────
//
// With pure silence the analyzer reports a very-low loudness sentinel
// (kMinDBFS ≈ -10000 LKFS) for every loudness field — it does NOT return
// nullopt the way one might expect from the absolute -70 LKFS gate. Our
// wrapper passes that sentinel through unchanged, so the -120 fallback in
// LoudnessMeter::update_state() is effectively unreachable for steady
// silence. We just assert each field is quieter than -50 LKFS, which is
// well below any musical signal but well above the sentinel.

TEST(LoudnessMeterTest, SilenceProducesVeryLowReadings) {
  LongBuf b(Ms(1000));  // 1 s of silence — past the 400 ms momentary gate.
  b.zero();

  EclipsaStudioMeterState state{};
  LoudnessMeter meter(kSampleRate, kChannels);
  meter.process(b.buf, b.frames, state);

  EXPECT_LT(state.loudness.lufs_integrated, -50.0f);
  EXPECT_LT(state.loudness.lufs_momentary, -50.0f);
  // True peak of zeros is 0 linear → -inf dBTP, which the analyzer clamps.
  EXPECT_LT(state.loudness.true_peak, -50.0f);
}

// ── Full-scale 1 kHz sine ────────────────────────────────────────────────
//
// Reference for stereo with equal channel weights [1, 1]:
//   power per channel  = 0.5
//   weighted sum       = 1.0 × 0.5 + 1.0 × 0.5 = 1.0
//   LKFS               = -0.691 + 10·log10(1.0) ≈ -0.69 LKFS
//
// K-weighting at 1 kHz adds well under 1 dB of variation, so we allow ±1.5
// LU of slack. The result must also exceed the noise floor (i.e. the integrated
// value must actually be valid, not the -120 sentinel).
TEST(LoudnessMeterTest, FullScaleSineMatchesBs1770Reference) {
  LongBuf b(Ms(1000));
  b.fill_sine(/*freq_hz=*/1000.0f, /*amplitude=*/1.0f);

  EclipsaStudioMeterState state{};
  LoudnessMeter meter(kSampleRate, kChannels);
  meter.process(b.buf, b.frames, state);

  EXPECT_NEAR(state.loudness.lufs_integrated, -0.69f, 1.5f);
  EXPECT_NEAR(state.loudness.lufs_momentary, -0.69f, 1.5f);
  // True peak of a sample-aligned 1 kHz sine at full scale should sit
  // basically at 0 dBTP (with possible small intersample overshoot).
  EXPECT_NEAR(state.loudness.true_peak, 0.0f, 1.0f);
}

// ── -6 dB sine should read 6 LU lower (relative check) ────────────────────
//
// LU is a power-domain dB scale, so a 6 dB amplitude reduction must produce
// exactly a 6 LU reduction in integrated loudness regardless of the absolute
// reference. This is the most robust BS.1770 check.
TEST(LoudnessMeterTest, SixDbAmplitudeDropProducesSixLuDrop) {
  LongBuf full(Ms(1000));
  full.fill_sine(1000.0f, 1.0f);
  LongBuf half(Ms(1000));
  half.fill_sine(1000.0f, 0.5f);

  EclipsaStudioMeterState state_full{}, state_half{};
  LoudnessMeter meter_full(kSampleRate, kChannels);
  LoudnessMeter meter_half(kSampleRate, kChannels);
  meter_full.process(full.buf, full.frames, state_full);
  meter_half.process(half.buf, half.frames, state_half);

  const float delta_lu =
      state_full.loudness.lufs_integrated - state_half.loudness.lufs_integrated;
  EXPECT_NEAR(delta_lu, 6.02f, 0.2f);

  // True peak should also drop by 6 dB.
  const float delta_tp =
      state_full.loudness.true_peak - state_half.loudness.true_peak;
  EXPECT_NEAR(delta_tp, 6.02f, 0.2f);
}

// ── Momentary loudness needs ≥ 400 ms before it becomes valid ─────────────
//
// EBU TECH 3341: momentary loudness is computed over a 400 ms window. The
// analyzer only reports momentary measurements once a full 400 ms of audio
// has been processed. With less than that, ungated_momentary_lkfs() is empty
// and our wrapper writes the -120 sentinel.
TEST(LoudnessMeterTest, MomentaryRequires400Ms) {
  LongBuf short_buf(Ms(200));  // 200 ms — below the 400 ms gate.
  short_buf.fill_sine(1000.0f, 1.0f);

  EclipsaStudioMeterState state{};
  LoudnessMeter meter(kSampleRate, kChannels);
  meter.process(short_buf.buf, short_buf.frames, state);

  EXPECT_FLOAT_EQ(state.loudness.lufs_momentary, -120.0f);

  // Now feed another 400 ms — total ≥ 400 ms — momentary should appear.
  LongBuf more(Ms(400));
  more.fill_sine(1000.0f, 1.0f);
  meter.process(more.buf, more.frames, state);

  EXPECT_GT(state.loudness.lufs_momentary, -10.0f);
}

// ── Short-term loudness needs ≥ 3 s ──────────────────────────────────────
TEST(LoudnessMeterTest, ShortTermRequires3Seconds) {
  // 1 second is below the 3 s window — short-term should still be -120.
  LongBuf one_sec(Ms(1000));
  one_sec.fill_sine(1000.0f, 1.0f);

  EclipsaStudioMeterState state{};
  LoudnessMeter meter(kSampleRate, kChannels);
  meter.process(one_sec.buf, one_sec.frames, state);
  EXPECT_FLOAT_EQ(state.loudness.lufs_short_term, -120.0f);

  // Push another 2.5 s — total 3.5 s — short-term should now be valid.
  LongBuf more(Ms(2500));
  more.fill_sine(1000.0f, 1.0f);
  meter.process(more.buf, more.frames, state);
  EXPECT_GT(state.loudness.lufs_short_term, -10.0f);
}

// ── Reset re-initializes the analyzer's accumulators ─────────────────────
//
// reset() rebuilds the underlying EbuR128Analyzer, which throws away every
// accumulated momentary block. The test feeds 1 s of full-scale sine
// (integrated ≈ -0.7 LKFS), resets, then feeds 1 s of silence. If reset
// worked, the new integrated reading reflects only the silence and is
// far below any musical level. If it didn't, the loud blocks would still
// dominate the gated integration.
TEST(LoudnessMeterTest, ResetReinitializesAccumulators) {
  LongBuf loud(Ms(1000));
  loud.fill_sine(1000.0f, 1.0f);

  EclipsaStudioMeterState state{};
  LoudnessMeter meter(kSampleRate, kChannels);
  meter.process(loud.buf, loud.frames, state);

  // Sanity: there's something there to clear.
  EXPECT_GT(state.loudness.lufs_integrated, -10.0f);

  meter.reset();

  LongBuf zeros(Ms(1000));
  zeros.zero();
  meter.process(zeros.buf, zeros.frames, state);

  // Loud blocks must be gone — silence-only reading is far below the
  // earlier ~-0.7 LKFS measurement.
  EXPECT_LT(state.loudness.lufs_integrated, -50.0f);
  EXPECT_LT(state.loudness.lufs_momentary, -50.0f);
}

// ── Sample rate change rebuilds the analyzer cleanly ─────────────────────
//
// Switching sample rate must throw away the old analyzer (its biquad
// coefficients are sample-rate-specific) and start fresh, otherwise we'd
// produce garbage measurements after a device change.
TEST(LoudnessMeterTest, SetSampleRateRebuildsAnalyzer) {
  LongBuf b48(Ms(1000));
  b48.fill_sine(1000.0f, 1.0f);

  EclipsaStudioMeterState state{};
  LoudnessMeter meter(48000, kChannels);
  meter.process(b48.buf, b48.frames, state);
  const float lufs_48k = state.loudness.lufs_integrated;
  EXPECT_NEAR(lufs_48k, -0.69f, 1.5f);

  // Switch to 44.1 kHz. Old buffer's geometry no longer matches; allocate
  // a 1 second buffer at the new rate.
  meter.set_sample_rate(44100);
  std::vector<float> storage(2u * 44100u, 0.0f);
  AudioBuffer buf44{storage.data(), 2, 44100, 44100};
  constexpr float kPi = 3.14159265358979323846f;
  for (uint32_t ch = 0; ch < 2; ++ch) {
    float* d = buf44.channel(ch);
    for (uint32_t f = 0; f < 44100; ++f) {
      d[f] = std::sin(2.0f * kPi * 1000.0f * static_cast<float>(f) / 44100.0f);
    }
  }
  // Reset state since the integrated reading from the previous run is gone
  // (rebuild_analyzer() drops the old accumulators).
  state.loudness = {};
  meter.process(buf44, 44100, state);
  const float lufs_44k = state.loudness.lufs_integrated;
  EXPECT_NEAR(lufs_44k, -0.69f, 1.5f);
}

// ── Empty buffer is a no-op (must not crash or write garbage) ────────────
TEST(LoudnessMeterTest, EmptyBufferIsNoOp) {
  EclipsaStudioMeterState state{};
  LoudnessMeter meter(kSampleRate, kChannels);

  // Pre-populate sentinel so we can check process() left state alone.
  state.loudness.lufs_integrated = -42.0f;
  state.loudness.lufs_momentary = -43.0f;
  state.loudness.lufs_short_term = -44.0f;
  state.loudness.true_peak = -45.0f;

  LongBuf b(1024);
  meter.process(b.buf, /*frames=*/0, state);

  EXPECT_FLOAT_EQ(state.loudness.lufs_integrated, -42.0f);
  EXPECT_FLOAT_EQ(state.loudness.lufs_momentary, -43.0f);
  EXPECT_FLOAT_EQ(state.loudness.lufs_short_term, -44.0f);
  EXPECT_FLOAT_EQ(state.loudness.true_peak, -45.0f);
}

// ── DC offset is high-pass filtered by K-weighting ───────────────────────
//
// The K-weighting filter chain has an RLB high-pass stage that removes
// DC. A constant 0.5 input must therefore measure many LU below the
// equivalent power level of an unfiltered DC signal (which would be
// around -3 LKFS for a 0.5 stereo level). We just assert it's well below
// -10 LKFS to confirm the filter is doing its job.
TEST(LoudnessMeterTest, DcOffsetIsHighPassFiltered) {
  LongBuf b(Ms(1000));
  b.fill_constant(0.5f);

  EclipsaStudioMeterState state{};
  LoudnessMeter meter(kSampleRate, kChannels);
  meter.process(b.buf, b.frames, state);

  // Digital signal level is non-trivial, so true peak should reflect it
  // (true peak doesn't care about K-weighting).
  EXPECT_NEAR(state.loudness.true_peak, -6.02f, 1.0f);
  // But K-weighted loudness must be much lower than the equivalent steady
  // tone of the same amplitude (-6.7 LKFS) — DC is suppressed.
  EXPECT_LT(state.loudness.lufs_integrated, -20.0f);
}

// ── Channel-count mismatch is skipped (issue ES-833) ───────────────────────
//
// The analyzer walks one channel pointer per configured channel. A block
// with fewer channels than configured used to hand it a shorter pointer
// table, and it read past the end (heap-buffer-overflow under
// --config=asan). process() now skips any block whose channel count
// differs from the configured count and counts it.

// Planar sine buffer with an arbitrary channel count.
struct PlanarSine {
  std::vector<float> storage;
  AudioBuffer buf;

  PlanarSine(uint32_t channels, uint32_t frames)
      : storage(static_cast<size_t>(channels) * frames) {
    buf.data = storage.data();
    buf.channels = channels;
    buf.frames = frames;
    buf.capacity_frames = frames;
    constexpr float kPi = 3.14159265358979323846f;
    for (uint32_t c = 0; c < channels; ++c) {
      float* d = buf.channel(c);
      for (uint32_t f = 0; f < frames; ++f) {
        d[f] = 0.5f * std::sin(2.0f * kPi * 1000.0f * static_cast<float>(f) /
                               static_cast<float>(kSampleRate));
      }
    }
  }
};

void ExpectSentinelsUntouched(const EclipsaStudioMeterState& state) {
  EXPECT_FLOAT_EQ(state.loudness.lufs_integrated, -42.0f);
  EXPECT_FLOAT_EQ(state.loudness.lufs_momentary, -43.0f);
  EXPECT_FLOAT_EQ(state.loudness.lufs_short_term, -44.0f);
  EXPECT_FLOAT_EQ(state.loudness.true_peak, -45.0f);
}

void SetSentinels(EclipsaStudioMeterState& state) {
  state.loudness.lufs_integrated = -42.0f;
  state.loudness.lufs_momentary = -43.0f;
  state.loudness.lufs_short_term = -44.0f;
  state.loudness.true_peak = -45.0f;
}

TEST(LoudnessMeterTest, NarrowerBufferThanConfiguredIsSkipped) {
  constexpr uint32_t k714 = 8;  // ck_oar_layout_714, 12 channels
  LoudnessMeter meter(kSampleRate, /*num_channels=*/12, k714);
  EclipsaStudioMeterState state{};
  SetSentinels(state);

  // A stereo block reaching a meter still configured for 7.1.4: the
  // monitoring layout-switch window.
  PlanarSine stereo(/*channels=*/2, Ms(500));
  meter.process(stereo.buf, stereo.buf.frames, state);

  ExpectSentinelsUntouched(state);
  EXPECT_EQ(meter.mismatched_blocks(), 1u);
}

TEST(LoudnessMeterTest, WiderBufferThanConfiguredIsSkipped) {
  LoudnessMeter meter(kSampleRate, /*num_channels=*/2);
  EclipsaStudioMeterState state{};
  SetSentinels(state);

  PlanarSine wide(/*channels=*/12, Ms(500));
  meter.process(wide.buf, wide.buf.frames, state);

  ExpectSentinelsUntouched(state);
  EXPECT_EQ(meter.mismatched_blocks(), 1u);
}

TEST(LoudnessMeterTest, ReconfigureAcceptsTheNewChannelCount) {
  LoudnessMeter meter(kSampleRate, /*num_channels=*/12);
  meter.reconfigure(/*num_channels=*/2, /*layout=*/2);
  EXPECT_EQ(meter.num_channels(), 2u);
  EXPECT_EQ(meter.layout(), 2u);

  EclipsaStudioMeterState state{};
  PlanarSine stereo(/*channels=*/2, Ms(500));
  meter.process(stereo.buf, stereo.buf.frames, state);

  EXPECT_EQ(meter.mismatched_blocks(), 0u);
  EXPECT_GT(state.loudness.lufs_momentary, -20.0f);
}

// ── Long blocks are fed in chunks ────────────────────────────────────────
//
// process() splits blocks longer than kMaxBlockFrames into chunks so its
// scratch stays within the capacity reserved at configure time. The
// analyzer is a streaming filter, so one long block and the same signal in
// device-sized blocks must measure the same.
TEST(LoudnessMeterTest, LongBlockMatchesDeviceSizedBlocks) {
  LongBuf b(Ms(5000));
  b.fill_sine(1000.0f, 0.5f);

  EclipsaStudioMeterState whole{};
  LoudnessMeter meter_whole(kSampleRate, kChannels);
  meter_whole.process(b.buf, b.frames, whole);

  EclipsaStudioMeterState chunked{};
  LoudnessMeter meter_chunked(kSampleRate, kChannels);
  constexpr uint32_t kBlock = 512;
  for (uint32_t off = 0; off < b.frames; off += kBlock) {
    const uint32_t n = std::min(kBlock, b.frames - off);
    AudioBuffer view;
    view.data = b.storage.data() + off;
    view.channels = kChannels;
    view.frames = n;
    view.capacity_frames = b.frames;  // channel stride of the backing store
    meter_chunked.process(view, n, chunked);
  }

  EXPECT_NEAR(whole.loudness.lufs_integrated, chunked.loudness.lufs_integrated,
              1e-3f);
  EXPECT_NEAR(whole.loudness.lufs_momentary, chunked.loudness.lufs_momentary,
              1e-3f);
  EXPECT_NEAR(whole.loudness.true_peak, chunked.loudness.true_peak, 1e-3f);
}

}  // namespace
