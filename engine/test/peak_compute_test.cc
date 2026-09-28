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

#include "waveform/peak_compute.h"

#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "test_wav_helper.h"

namespace {

// ── Helpers ────────────────────────────────────────────────────────────────

// Verify the struct invariants every valid result must satisfy.
void check_invariants(const EclipsaStudioPeakData* d,
                      uint32_t expected_channels, uint32_t expected_levels,
                      uint32_t base_spp) {
  ASSERT_NE(d, nullptr);
  EXPECT_EQ(d->num_channels, expected_channels);
  EXPECT_EQ(d->num_levels, expected_levels);
  EXPECT_GT(d->sample_rate, 0u);
  EXPECT_GT(d->total_samples, 0u);

  for (uint32_t l = 0; l < expected_levels; ++l) {
    const uint32_t expected_spp = base_spp << l;
    EXPECT_EQ(d->samples_per_peak[l], expected_spp) << "level " << l;

    const uint32_t expected_peaks =
        (d->total_samples + expected_spp - 1) / expected_spp;
    EXPECT_EQ(d->num_peaks[l], expected_peaks) << "level " << l;

    // Each successive level should have roughly half the peaks.
    if (l > 0) {
      const uint32_t prev = d->num_peaks[l - 1];
      const uint32_t cur = d->num_peaks[l];
      EXPECT_LE(cur, (prev + 1) / 2 + 1)
          << "level " << l << " should have ~half of level " << (l - 1);
    }
  }
}

}  // namespace

// ── Basic construction ──────────────────────────────────────────────────────

TEST(PeakCompute, ReturnNullForMissingFile) {
  const EclipsaStudioPeakData* d =
      PeakCompute::compute("/does/not/exist.wav", 256, 4);
  EXPECT_EQ(d, nullptr);
}

TEST(PeakCompute, ReturnNullForNullPath) {
  const EclipsaStudioPeakData* d = PeakCompute::compute(nullptr, 256, 4);
  EXPECT_EQ(d, nullptr);
}

// ── Mono sine wave ──────────────────────────────────────────────────────────

TEST(PeakCompute, MonoSine_ChannelCountAndLevels) {
  const std::string path = test_wav::temp_dir() + "/mono_sine.wav";
  ASSERT_TRUE(test_wav::write_sine(path, 1, 48000, 16, 440.0f, 1.0f));

  const EclipsaStudioPeakData* d = PeakCompute::compute(path.c_str(), 256, 4);
  check_invariants(d, 1, 4, 256);
  EXPECT_EQ(d->sample_rate, 48000u);
  EXPECT_EQ(d->total_samples, 48000u);  // 1 second at 48 kHz
  PeakCompute::destroy(d);
}

TEST(PeakCompute, MonoSine_PeakAmplitudeNearOne) {
  // Full-scale 440 Hz sine; max abs value should be close to 1.0.
  const std::string path = test_wav::temp_dir() + "/sine_peak.wav";
  ASSERT_TRUE(test_wav::write_sine(path, 1, 48000, 16, 440.0f, 1.0f));

  const EclipsaStudioPeakData* d = PeakCompute::compute(path.c_str(), 256, 4);
  ASSERT_NE(d, nullptr);

  const float* data = PeakCompute::level_data(d, 0, 0);
  ASSERT_NE(data, nullptr);

  // Scan all peaks at level 0 for the global max amplitude.
  float max_amp = 0.0f;
  for (uint32_t p = 0; p < d->num_peaks[0]; ++p) {
    const float mn = data[p];
    const float mx = data[d->num_peaks[0] + p];
    const float amp = std::max(std::fabs(mn), std::fabs(mx));
    if (amp > max_amp) max_amp = amp;
  }
  // A full-scale 16-bit sine has amplitude 32767/32768 ≈ 0.9999695.
  EXPECT_GT(max_amp, 0.99f)
      << "Expected near-full-scale amplitude for full-scale sine";

  PeakCompute::destroy(d);
}

// ── Silence ─────────────────────────────────────────────────────────────────

TEST(PeakCompute, SilenceProducesZeroPeaks) {
  const std::string path = test_wav::temp_dir() + "/silence.wav";
  ASSERT_TRUE(test_wav::write_silence(path, 1, 48000, 16, 0.5f));

  const EclipsaStudioPeakData* d = PeakCompute::compute(path.c_str(), 256, 4);
  ASSERT_NE(d, nullptr);

  for (uint32_t l = 0; l < d->num_levels; ++l) {
    const float* data = PeakCompute::level_data(d, l, 0);
    ASSERT_NE(data, nullptr);
    for (uint32_t p = 0; p < d->num_peaks[l]; ++p) {
      EXPECT_FLOAT_EQ(data[p], 0.0f)
          << "min[" << l << "][" << p << "] should be 0 for silence";
      EXPECT_FLOAT_EQ(data[d->num_peaks[l] + p], 0.0f)
          << "max[" << l << "][" << p << "] should be 0 for silence";
    }
  }

  PeakCompute::destroy(d);
}

// ── Pyramid level counts ─────────────────────────────────────────────────────

TEST(PeakCompute, PyramidLevelsHaveHalvingPeakCounts) {
  const std::string path = test_wav::temp_dir() + "/halving.wav";
  // 4096 frames — divisible by 256 so level counts are exact.
  ASSERT_TRUE(
      test_wav::write_sine(path, 1, 48000, 16, 440.0f, 4096.0f / 48000.0f));

  const EclipsaStudioPeakData* d = PeakCompute::compute(path.c_str(), 256, 4);
  ASSERT_NE(d, nullptr);

  // level 0: 4096 / 256   = 16 peaks
  // level 1: 4096 / 512   = 8  peaks
  // level 2: 4096 / 1024  = 4  peaks
  // level 3: 4096 / 2048  = 2  peaks
  EXPECT_EQ(d->num_peaks[0], 16u);
  EXPECT_EQ(d->num_peaks[1], 8u);
  EXPECT_EQ(d->num_peaks[2], 4u);
  EXPECT_EQ(d->num_peaks[3], 2u);

  PeakCompute::destroy(d);
}

// ── Multi-channel ────────────────────────────────────────────────────────────

TEST(PeakCompute, StereoSine_PerChannelData) {
  const std::string path = test_wav::temp_dir() + "/stereo.wav";
  ASSERT_TRUE(test_wav::write_sine(path, 2, 48000, 16, 440.0f, 1.0f));

  const EclipsaStudioPeakData* d = PeakCompute::compute(path.c_str(), 256, 4);
  ASSERT_NE(d, nullptr);
  EXPECT_EQ(d->num_channels, 2u);

  for (uint32_t ch = 0; ch < 2; ++ch) {
    const float* data = PeakCompute::level_data(d, 0, ch);
    ASSERT_NE(data, nullptr) << "channel " << ch;

    float max_amp = 0.0f;
    for (uint32_t p = 0; p < d->num_peaks[0]; ++p) {
      const float mn = data[p];
      const float mx = data[d->num_peaks[0] + p];
      const float amp = std::max(std::fabs(mn), std::fabs(mx));
      if (amp > max_amp) max_amp = amp;
    }
    EXPECT_GT(max_amp, 0.99f) << "channel " << ch;
  }

  // Verify channels have separate data pointers.
  const float* ch0 = PeakCompute::level_data(d, 0, 0);
  const float* ch1 = PeakCompute::level_data(d, 0, 1);
  EXPECT_NE(ch0, ch1);

  PeakCompute::destroy(d);
}

// ── RMS values ──────────────────────────────────────────────────────────────

TEST(PeakCompute, RmsForFullScaleSineApproximatesSqrt2Inverse) {
  // Full-scale sine should have RMS ≈ 1/√2 ≈ 0.7071 over each bin.
  const std::string path = test_wav::temp_dir() + "/rms_sine.wav";
  ASSERT_TRUE(test_wav::write_sine(path, 1, 48000, 16, 440.0f, 1.0f));

  const EclipsaStudioPeakData* d = PeakCompute::compute(path.c_str(), 256, 4);
  ASSERT_NE(d, nullptr);

  const float* data = PeakCompute::level_data(d, 0, 0);
  ASSERT_NE(data, nullptr);
  const uint32_t nPeaks = d->num_peaks[0];

  // RMS lives at offset 2*nPeaks after mins/maxs.
  float min_rms = 1e9, max_rms = 0.0f;
  for (uint32_t p = 0; p < nPeaks; ++p) {
    const float r = data[2 * nPeaks + p];
    if (r < min_rms) min_rms = r;
    if (r > max_rms) max_rms = r;
  }
  // Allow some slack: 16-bit quantisation + the ~5 ms window cuts into the
  // theoretical 0.7071. Practical floor for 440 Hz @ 48k is ~0.68.
  EXPECT_GT(min_rms, 0.65f);
  EXPECT_LT(max_rms, 0.75f);

  PeakCompute::destroy(d);
}

TEST(PeakCompute, StereoChannelIsolationDifferentContent) {
  // Hand-build a stereo WAV: ch0 = full-scale sine (loud), ch1 = silence.
  // After compute, ch0 should show large min/max/rms while ch1 should be
  // ~zero across all three.
  const std::string path = test_wav::temp_dir() + "/stereo_iso.wav";
  const int frames = 48000;  // 1 second
  std::vector<int16_t> buf(frames * 2);
  for (int i = 0; i < frames; ++i) {
    const float t = static_cast<float>(i) / 48000.0f;
    const float s = std::sin(2.0f * 3.14159265358979323846f * 440.0f * t);
    buf[i * 2 + 0] = static_cast<int16_t>(s * 32767.0f);  // ch0 loud
    buf[i * 2 + 1] = 0;                                   // ch1 silent
  }
  ASSERT_TRUE(test_wav::write_frames_s16(path, 2, 48000, buf));

  const EclipsaStudioPeakData* d = PeakCompute::compute(path.c_str(), 256, 4);
  ASSERT_NE(d, nullptr);
  const uint32_t nPeaks = d->num_peaks[0];

  const float* ch0 = PeakCompute::level_data(d, 0, 0);
  const float* ch1 = PeakCompute::level_data(d, 0, 1);
  ASSERT_NE(ch0, nullptr);
  ASSERT_NE(ch1, nullptr);

  // ch0: should see big amplitude / RMS
  float ch0_max_amp = 0, ch0_max_rms = 0;
  for (uint32_t p = 0; p < nPeaks; ++p) {
    const float amp = std::max(std::fabs(ch0[p]), std::fabs(ch0[nPeaks + p]));
    if (amp > ch0_max_amp) ch0_max_amp = amp;
    const float r = ch0[2 * nPeaks + p];
    if (r > ch0_max_rms) ch0_max_rms = r;
  }
  EXPECT_GT(ch0_max_amp, 0.99f) << "ch0 should be at full scale";
  EXPECT_GT(ch0_max_rms, 0.65f) << "ch0 RMS should be near 1/sqrt(2)";

  // ch1: should be all zeros for min/max/rms (silence)
  for (uint32_t p = 0; p < nPeaks; ++p) {
    EXPECT_FLOAT_EQ(ch1[p], 0.0f) << "ch1 min[" << p << "] should be 0";
    EXPECT_FLOAT_EQ(ch1[nPeaks + p], 0.0f)
        << "ch1 max[" << p << "] should be 0";
    EXPECT_FLOAT_EQ(ch1[2 * nPeaks + p], 0.0f)
        << "ch1 rms[" << p << "] should be 0";
  }

  PeakCompute::destroy(d);
}

TEST(PeakCompute, RmsPerChannelMatchesIndependentlyForStereo) {
  // Stereo sine — both channels have identical samples, so both must show
  // identical RMS values at every bin.
  const std::string path = test_wav::temp_dir() + "/rms_stereo.wav";
  ASSERT_TRUE(test_wav::write_sine(path, 2, 48000, 16, 440.0f, 1.0f));

  const EclipsaStudioPeakData* d = PeakCompute::compute(path.c_str(), 256, 4);
  ASSERT_NE(d, nullptr);

  const float* ch0 = PeakCompute::level_data(d, 0, 0);
  const float* ch1 = PeakCompute::level_data(d, 0, 1);
  ASSERT_NE(ch0, nullptr);
  ASSERT_NE(ch1, nullptr);
  const uint32_t nPeaks = d->num_peaks[0];

  for (uint32_t p = 0; p < nPeaks; ++p) {
    EXPECT_FLOAT_EQ(ch0[p], ch1[p]) << "min[" << p << "] differs";
    EXPECT_FLOAT_EQ(ch0[nPeaks + p], ch1[nPeaks + p])
        << "max[" << p << "] differs";
    EXPECT_FLOAT_EQ(ch0[2 * nPeaks + p], ch1[2 * nPeaks + p])
        << "rms[" << p << "] differs";
  }

  PeakCompute::destroy(d);
}

// ── Out-of-range level_data ──────────────────────────────────────────────────

TEST(PeakCompute, LevelDataReturnsNullForOutOfRange) {
  const std::string path = test_wav::temp_dir() + "/oob.wav";
  ASSERT_TRUE(test_wav::write_sine(path, 1, 48000, 16, 440.0f, 0.1f));

  const EclipsaStudioPeakData* d = PeakCompute::compute(path.c_str(), 256, 4);
  ASSERT_NE(d, nullptr);

  EXPECT_EQ(PeakCompute::level_data(d, 99, 0), nullptr);       // bad level
  EXPECT_EQ(PeakCompute::level_data(d, 0, 99), nullptr);       // bad channel
  EXPECT_EQ(PeakCompute::level_data(nullptr, 0, 0), nullptr);  // null data

  PeakCompute::destroy(d);
}

TEST(PeakCompute, MultiChunkScanAtChannelCapIsolatesChannels) {
  // ES-505: the read chunk is sized by a flat byte budget, so at the
  // 32-channel cap the per-channel chunk is 65536 frames and this
  // 150k-frame file crosses two chunk boundaries — with the previous
  // flat 1 Mi-frame chunk, the multi-chunk path needed a >1 Mi-frame
  // fixture to exercise at all. Each channel carries a distinct DC
  // level (s16 codes are exact through the writer/reader), so any
  // cross-chunk cursor slip or per-channel scratch-pointer mixup shows
  // up as a wrong min/max/rms in some bin.
  const std::string path = test_wav::temp_dir() + "/chunk_cap.wav";
  constexpr int kChannels = 32;
  constexpr uint32_t kFrames = 150000;
  constexpr uint32_t kSpp = 4096;
  std::vector<int16_t> buf(static_cast<size_t>(kFrames) * kChannels);
  for (uint32_t f = 0; f < kFrames; ++f) {
    for (int c = 0; c < kChannels; ++c) {
      buf[static_cast<size_t>(f) * kChannels + static_cast<size_t>(c)] =
          static_cast<int16_t>((c + 1) * 512);
    }
  }
  ASSERT_TRUE(test_wav::write_frames_s16(path, kChannels, 48000, buf));

  const EclipsaStudioPeakData* d = PeakCompute::compute(path.c_str(), kSpp, 2);
  ASSERT_NE(d, nullptr);
  EXPECT_EQ(d->num_channels, static_cast<uint32_t>(kChannels));
  EXPECT_EQ(d->total_samples, kFrames);
  const uint32_t peaks = d->num_peaks[0];
  EXPECT_EQ(peaks, (kFrames + kSpp - 1) / kSpp);
  for (int c = 0; c < kChannels; ++c) {
    const float expected = static_cast<float>((c + 1) * 512) / 32768.0f;
    const float* mins = PeakCompute::level_data(d, 0, static_cast<uint32_t>(c));
    ASSERT_NE(mins, nullptr);
    const float* maxs = mins + peaks;
    const float* rms = mins + 2u * peaks;
    for (uint32_t p = 0; p < peaks; ++p) {
      ASSERT_EQ(mins[p], expected) << "ch " << c << " bin " << p;
      ASSERT_EQ(maxs[p], expected) << "ch " << c << " bin " << p;
      ASSERT_NEAR(rms[p], expected, 1e-4f) << "ch " << c << " bin " << p;
    }
  }
  PeakCompute::destroy(d);
}

// ── FFI surface (C linkage functions) ────────────────────────────────────────

TEST(PeakCompute, FfiFunctionsExist) {
  const std::string path = test_wav::temp_dir() + "/ffi_test.wav";
  ASSERT_TRUE(test_wav::write_sine(path, 1, 48000, 16, 440.0f, 0.1f));

  const EclipsaStudioPeakData* d =
      eclipsa_studio_peaks_compute(path.c_str(), 256, 4);
  ASSERT_NE(d, nullptr);
  EXPECT_EQ(d->num_channels, 1u);
  EXPECT_EQ(d->num_levels, 4u);

  const float* data = eclipsa_studio_peaks_level_data(d, 0, 0);
  EXPECT_NE(data, nullptr);

  eclipsa_studio_peaks_free(d);  // must not crash
}
