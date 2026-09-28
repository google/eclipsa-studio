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

// ES-492: the loudness_info that ships in an exported .iamf is iamf-tools'
// own measurement (its EAR-based renderer, no limiter) — it always
// overwrites the values Eclipsa Studio stamps into the UserMetadata.
// That overwrite is accepted by decision. Eclipsa Studio's own
// OfflineMixRenderer measurement (the Loudness Report / export measure
// pass) runs POST-limiter (ES-491's "for now" decision), so the two sides
// agree only while the program stays below the -1 dBFS ceiling — the
// mild cell pins that agreement (residual is the OAR-vs-EAR renderer
// gap, ~zero for stereo, plus Q7.8 coding at ~0.004 dB) and the hot
// cell pins the expected DIVERGENCE (measured clamped, shipped
// unlimited). Both scream on any iamf-tools bump that changes the
// shipped measurement.
//
// Encodes the golden multi_mix textproto (the app builder's exact
// output: two stereo sine beds; MP "Main" = bed at -3 dB + vocal at
// 0 dB, output -1.5 dB; MP "Vocal Only" = vocal at +2 dB, output 0 dB),
// probes the shipped per-MP loudness with iamf-tools' ProbeFile, and
// measures the same programs with OfflineMixRenderer at the same stereo
// layout.
//
// The multichannel cell (ES-514) does the same over the bed714 golden —
// a 7.1.4 bed with distinct per-channel content, loudness declared on
// both a Stereo and a 7.1.4 layout — covering the downmix, weighting,
// and channel-ordering paths the stereo cells cannot reach, and
// pinning absolute LUFS for both layouts.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "iamf/cli/probe.h"
#include "iamf/iamf_exporter.h"
#include "mix_renderer/offline_mix_renderer.h"
#include "test/test_wav_helper.h"

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kBufferSize = 1024;
constexpr uint32_t kStereoLayout = 2;  // ck_oar_layout_stereo
constexpr int kSourceFrames = 1024 * 144;

// Agreement tolerance between Eclipsa Studio's measurement and the
// shipped loudness_info, in dB/LU. Observed residual on this content:
// < 0.004 dB on every scalar of both MPs — pure Q7.8 coding noise
// (1/256 dB); the OAR-vs-EAR renderer term is ~zero for stereo beds.
// 0.1 is ~30x the observed gap yet still catches any real renderer,
// weighting, or dependency regression.
constexpr float kAgreementTolerance = 0.1f;

// Tolerance for the multichannel cell's ABSOLUTE pinned-LUFS values —
// a different concept from renderer agreement: it bounds drift of both
// sides together against a value recorded at authoring time and
// re-derived by hand (see the cell). Same magnitude as the agreement
// tolerance; kept separate so the two ideas don't share one constant.
constexpr float kAbsoluteLufsTolerance = 0.1f;

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

class IamfLoudnessAgreementTest : public ::testing::Test {
 protected:
  void SetUp() override {
    const std::string golden = FindFixture("golden/multi_mix.textproto");
    ASSERT_FALSE(golden.empty()) << "golden fixture missing";
    std::ifstream f(golden);
    std::stringstream config;
    config << f.rdbuf();
    config_ = config.str();
    dir_ = test_wav::temp_dir();
  }

  // Writes bed_<tag>.wav / vocal_<tag>.wav at [amplitude] and encodes
  // them through the golden config into [out_iamf]. The basenames fed
  // to the exporter stay "bed.wav"/"vocal.wav" — they are metadata keys
  // into the golden's audio_frame_metadata, independent of the source
  // file names.
  void EncodeGolden(float amplitude, const std::string& tag,
                    const std::string& out_iamf) {
    const std::string bed = dir_ + "/bed_" + tag + ".wav";
    const std::string vocal = dir_ + "/vocal_" + tag + ".wav";
    ASSERT_TRUE(test_wav::write_sine_frames(bed, 2, kSampleRate, 16, 440.0f,
                                            kSourceFrames, amplitude));
    ASSERT_TRUE(test_wav::write_sine_frames(vocal, 2, kSampleRate, 16, 2000.0f,
                                            kSourceFrames, amplitude));

    std::vector<eclipsa_studio::IamfExporter::PushElement> elements(2);
    elements[0].wav_basename = "bed.wav";
    elements[0].stream.input_wav_path = bed;
    elements[0].stream.pad_to_frames = kSourceFrames;
    elements[0].stream.output_sample_rate = kSampleRate;
    elements[1].wav_basename = "vocal.wav";
    elements[1].stream.input_wav_path = vocal;
    elements[1].stream.pad_to_frames = kSourceFrames;
    elements[1].stream.output_sample_rate = kSampleRate;
    eclipsa_studio::IamfExporter exporter;
    ASSERT_EQ(exporter.EncodePush(config_, out_iamf, elements), 0);
  }

  // One element of the golden program, measured through the same
  // stream-fed path the export measure phase uses.
  struct Element {
    const char* wav;
    float mix_gain_db;
  };

  eclipsa_studio::LoudnessResult Measure(const std::vector<Element>& elements,
                                         float output_mix_gain_db) {
    eclipsa_studio::OfflineMixRenderer renderer;
    EXPECT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
    uint32_t id = 1;
    for (const auto& e : elements) {
      eclipsa_studio::MixElementConfig cfg;
      cfg.element_id = id++;
      cfg.stream.input_wav_path = dir_ + "/" + e.wav;
      cfg.stream.pad_to_frames = kSourceFrames;
      cfg.stream.output_sample_rate = kSampleRate;
      cfg.element_type = 0;  // channel bed
      cfg.element_sub_type = kStereoLayout;
      cfg.channels = 2;
      cfg.mix_gain_db = e.mix_gain_db;
      EXPECT_TRUE(renderer.AddElement(cfg));
    }
    renderer.SetOutputMixGain(output_mix_gain_db);
    const std::optional<eclipsa_studio::LoudnessResult> result =
        renderer.RenderAndMeasure();
    EXPECT_TRUE(result.has_value());
    return result.value_or(eclipsa_studio::LoudnessResult{});
  }

  std::string dir_;
  std::string config_;
};

TEST_F(IamfLoudnessAgreementTest, MildMixMeasuredMatchesShipped) {
  // 0.25 amplitude like iamf_round_trip_test: the summed program stays
  // clear of the -1 dBFS ceiling, so the (hardwired-on) measurement
  // limiter never engages and the post-limiter measured values equal
  // the unlimited render that iamf-tools measures for the file.
  const std::string iamf_path = dir_ + "/agreement_mild.iamf";
  EncodeGolden(0.25f, "mild", iamf_path);

  const auto probe = iamf_tools::ProbeFile(iamf_path);
  ASSERT_TRUE(probe.ok()) << probe.status().message();
  ASSERT_EQ(probe->mix_presentations.size(), 2u);

  // MP 400 "Main": bed -3 dB + vocal 0 dB, output -1.5 dB.
  // MP 401 "Vocal Only": vocal +2 dB, output 0 dB.
  const struct {
    uint32_t mix_presentation_id;
    std::vector<Element> elements;
    float output_mix_gain_db;
  } programs[] = {
      {400, {{"bed_mild.wav", -3.0f}, {"vocal_mild.wav", 0.0f}}, -1.5f},
      {401, {{"vocal_mild.wav", 2.0f}}, 0.0f},
  };

  for (const auto& program : programs) {
    const auto* shipped = [&]() -> const iamf_tools::MixPresentationReport* {
      for (const auto& mp : probe->mix_presentations) {
        if (mp.id == program.mix_presentation_id) return &mp;
      }
      return nullptr;
    }();
    ASSERT_NE(shipped, nullptr) << "MP " << program.mix_presentation_id;
    ASSERT_TRUE(shipped->integrated_loudness_lkfs.has_value());
    ASSERT_TRUE(shipped->digital_peak_dbfs.has_value());
    ASSERT_TRUE(shipped->true_peak_dbfs.has_value());

    const eclipsa_studio::LoudnessResult measured =
        Measure(program.elements, program.output_mix_gain_db);
    ASSERT_GT(measured.integrated_lufs, -60.0f);  // actually measured

    SCOPED_TRACE(
        ::testing::Message()
        << "MP " << program.mix_presentation_id << ": measured "
        << measured.integrated_lufs << " LUFS / " << measured.digital_peak_dbfs
        << " dBFS / " << measured.true_peak_dbtp << " dBTP, shipped "
        << *shipped->integrated_loudness_lkfs << " / "
        << *shipped->digital_peak_dbfs << " / " << *shipped->true_peak_dbfs);
    EXPECT_NEAR(measured.integrated_lufs, *shipped->integrated_loudness_lkfs,
                kAgreementTolerance);
    EXPECT_NEAR(measured.digital_peak_dbfs, *shipped->digital_peak_dbfs,
                kAgreementTolerance);
    EXPECT_NEAR(measured.true_peak_dbtp, *shipped->true_peak_dbfs,
                kAgreementTolerance);
  }

  // The golden's placeholder user loudness (-18 LUFS / -2 dBFS peak on
  // MP 400) must NOT have survived: iamf-tools replaces it with its own
  // measurement, which for this program lands far from the placeholder.
  // This is the "overwrite is real" half of the ES-492 finding.
  const auto& main_mp = probe->mix_presentations[0];
  ASSERT_EQ(main_mp.id, 400u);  // guard the positional read above
  EXPECT_GT(std::abs(*main_mp.digital_peak_dbfs - (-2.0f)), 0.5f)
      << "placeholder digital_peak survived — did iamf-tools stop "
         "overwriting loudness_info? Revisit ES-492's decision record.";
}

// Two pins on hot content, where the two sides deliberately differ:
//
// 1. The SHIPPED measurement is unlimited today (iamf-tools' EAR
//    renderer has no limiter). Tripwire for the expected future:
//    iamf-tools is expected to move its measurement onto OAR *with
//    default settings*, and OAR's defaults include the -1 dBFS peak
//    limiter — the shipped values would then clamp like ours and the
//    first EXPECT below fails. At that point the two sides CONVERGE
//    (Eclipsa Studio already measures post-limiter): update this test
//    and the docs' "Future direction" section; no engine change is
//    needed.
// 2. The MEASURED side is post-limiter by decision (ES-491, "for now"),
//    so on this program it must clamp at the ceiling while the
//    shipped value sails past it — the divergence the export dialog's
//    read-back panel exists to surface.
//
// The substreams themselves stay unclipped (0.9 amplitude per
// element); only the RENDERED mix exceeds full scale, via the golden's
// element/output mix gains applied at render time.
TEST_F(IamfLoudnessAgreementTest, ShippedUnlimitedMeasuredLimited) {
  const std::string iamf_path = dir_ + "/agreement_hot.iamf";
  EncodeGolden(0.9f, "hot", iamf_path);

  const auto probe = iamf_tools::ProbeFile(iamf_path);
  ASSERT_TRUE(probe.ok()) << probe.status().message();
  ASSERT_EQ(probe->mix_presentations.size(), 2u);

  // MP 400 "Main": 0.9*10^(-3/20) + 0.9 summed, output -1.5 dB —
  // the unlimited render peaks near +2.2 dBFS.
  const auto& shipped = probe->mix_presentations[0];
  ASSERT_EQ(shipped.id, 400u);  // guard the positional read above
  ASSERT_TRUE(shipped.digital_peak_dbfs.has_value());
  EXPECT_GT(*shipped.digital_peak_dbfs, -1.0f)
      << "shipped digital peak clamped at/below -1 dBFS — iamf-tools "
         "appears to measure through a peak limiter now (the expected "
         "OAR-with-defaults migration?). Measured and shipped now "
         "converge: update this test, which assumes the measurement is "
         "post-limiter and the shipped file is unlimited.";
  EXPECT_GT(*shipped.digital_peak_dbfs, 1.5f)
      << "program no longer renders hot — the tripwire above loses its "
         "meaning; check the golden gains / source amplitude";

  // The measured side clamps at the -1 dBFS ceiling on the same
  // program (slack in case the limiter overshoots on attack) —
  // divergence on hot content is real and expected, not a bug.
  const eclipsa_studio::LoudnessResult measured =
      Measure({{"bed_hot.wav", -3.0f}, {"vocal_hot.wav", 0.0f}}, -1.5f);
  ASSERT_GT(measured.integrated_lufs, -60.0f);
  EXPECT_LE(measured.digital_peak_dbfs, -0.8f);
  // Integrated diverges by the limiter's gain reduction: the shipped
  // (unlimited) value reads higher than the measured (limited) one.
  ASSERT_TRUE(shipped.integrated_loudness_lkfs.has_value());
  EXPECT_GT(*shipped.integrated_loudness_lkfs, measured.integrated_lufs);
}

// ES-514: the stereo cells above are near-tautological — a stereo bed
// rendered to a stereo layout is an identity render for both OAR and
// iamf-tools' EAR renderer (observed residual <= 0.003 dB, pure Q7.8
// coding noise). This cell encodes a 7.1.4 bed carrying a DISTINCT
// sine per channel (frequency and amplitude) through the bed714
// golden, whose mix presentation declares loudness on BOTH layouts
// where the renderers can genuinely diverge:
//   - Stereo: a real 12->2 downmix — downmix coefficients and channel
//     ordering matter.
//   - 7.1.4: identity placement, but the per-layout BS.1770 weights
//     (surrounds at 1.41, LFE excluded) and channel ordering matter.
// An OAR bump, an iamf-tools renderer change, or a drift in
// meters/bs1770_weights.cc shows up here, not in the stereo cells.
// The program stays far below the -1 dBFS ceiling so the measurement
// limiter never engages and the post-limiter measured values are
// comparable with the unlimited shipped ones.
TEST_F(IamfLoudnessAgreementTest, MultichannelBedAgreesPerLayout) {
  // WAV channel order L R C LFE Lss Rss Lrs Rrs Ltf Rtf Ltb Rtb (the
  // app's 7.1.4 label order in user_metadata_builder.dart). Every
  // channel gets its own frequency and amplitude, so a swapped pair, a
  // dropped channel, or a wrong weight shifts the result instead of
  // cancelling out.
  constexpr int kCh = 12;
  constexpr float kFreq[kCh] = {397.0f,  499.0f,  601.0f,  59.0f,
                                701.0f,  797.0f,  907.0f,  997.0f,
                                1103.0f, 1201.0f, 1301.0f, 1399.0f};
  constexpr float kAmp[kCh] = {0.08f, 0.06f, 0.07f, 0.04f, 0.06f, 0.05f,
                               0.05f, 0.04f, 0.04f, 0.03f, 0.03f, 0.05f};
  std::vector<int16_t> frames(static_cast<size_t>(kSourceFrames) * kCh);
  for (int i = 0; i < kSourceFrames; ++i) {
    const float t = static_cast<float>(i) / kSampleRate;
    for (int c = 0; c < kCh; ++c) {
      const float s = std::sin(2.0f * 3.14159265358979323846f * kFreq[c] * t);
      frames[static_cast<size_t>(i) * kCh + c] =
          static_cast<int16_t>(s * kAmp[c] * 32767.0f);
    }
  }
  const std::string wav = dir_ + "/bed714.wav";
  ASSERT_TRUE(test_wav::write_frames_s16(wav, kCh, kSampleRate, frames));

  const std::string golden = FindFixture("golden/bed714.textproto");
  ASSERT_FALSE(golden.empty()) << "bed714 golden fixture missing";
  std::ifstream f(golden);
  std::stringstream config;
  config << f.rdbuf();

  const std::string iamf_path = dir_ + "/agreement_714.iamf";
  std::vector<eclipsa_studio::IamfExporter::PushElement> elements(1);
  elements[0].wav_basename = "bed714.wav";
  elements[0].stream.input_wav_path = wav;
  elements[0].stream.pad_to_frames = kSourceFrames;
  elements[0].stream.output_sample_rate = kSampleRate;
  eclipsa_studio::IamfExporter exporter;
  ASSERT_EQ(exporter.EncodePush(config.str(), iamf_path, elements), 0);

  const auto probe = iamf_tools::ProbeFile(iamf_path);
  ASSERT_TRUE(probe.ok()) << probe.status().message();
  ASSERT_EQ(probe->mix_presentations.size(), 1u);
  const auto& mp = probe->mix_presentations[0];
  ASSERT_EQ(mp.id, 400u);
  ASSERT_EQ(mp.sub_mixes.size(), 1u);
  const auto& layouts = mp.sub_mixes[0].layouts;
  ASSERT_EQ(layouts.size(), 2u);

  // expected_lufs pins the ABSOLUTE integrated loudness (the doc's
  // Testing section's known-LUFS fixtures): agreement alone cannot
  // catch a coordinated drift where both sides move together (e.g. a
  // conceptual weight error mirrored into meters/bs1770_weights.cc
  // from iamf-tools). The 7.1.4 value can be re-derived from the
  // source: sum the per-channel mean squares (amp^2/2) with the
  // BS.1770 weights applied to the POWER (LFE excluded, Lss/Rss
  // weighted 1.41 — that is +1.5 dB on the mean square, NOT 1.41^2),
  // apply the -3 dB total mix gain and the K pre-filter gain at each
  // channel's frequency (the high shelf is NOT flat here: +0.5 to
  // +1.8 dB over 900-1400 Hz, ~+0.44 dB net for this program), then
  // -0.691 + 10*log10(power) = -21.016 — matching the shipped
  // -5380/256 = -21.015625 exactly. Observed: -21.019 (7.1.4),
  // -22.506 (Stereo); agreement residuals <= 0.004 dB on every scalar
  // of both cells — same Q7.8 coding noise as stereo, i.e. OAR and
  // EAR agree even on a genuine downmix.
  const struct {
    const char* sound_system;  // display label, for failure messages
    uint8_t sound_system_raw;  // probe's stable LayoutReport key
    uint32_t target_layout;    // oar_layout_t to measure at
    float expected_lufs;       // recorded at authoring, re-derived
  } cells[] = {
      {"Stereo", 0, 2, -22.51f},  // SOUND_SYSTEM_A_0_2_0
      {"7.1.4", 9, 8, -21.02f},   // SOUND_SYSTEM_J_4_7_0
  };

  for (const auto& cell : cells) {
    SCOPED_TRACE(cell.sound_system);
    const auto shipped_it =
        std::find_if(layouts.begin(), layouts.end(), [&](const auto& layout) {
          return layout.loudness_layout.sound_system_raw ==
                 cell.sound_system_raw;
        });
    ASSERT_NE(shipped_it, layouts.end());
    const auto* shipped = &*shipped_it;
    ASSERT_TRUE(shipped->loudness.true_peak.has_value());

    // Measure the same program through the export measure path at the
    // same layout, with the golden's gains (-2 dB element, -1 dB
    // output).
    eclipsa_studio::OfflineMixRenderer renderer;
    ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, cell.target_layout));
    eclipsa_studio::MixElementConfig cfg;
    cfg.element_id = 1;
    cfg.stream.input_wav_path = wav;
    cfg.stream.pad_to_frames = kSourceFrames;
    cfg.stream.output_sample_rate = kSampleRate;
    cfg.element_type = 0;      // channel bed
    cfg.element_sub_type = 8;  // oar_layout_t 7.1.4
    cfg.channels = kCh;
    cfg.mix_gain_db = -2.0f;
    ASSERT_TRUE(renderer.AddElement(cfg));
    renderer.SetOutputMixGain(-1.0f);
    const std::optional<eclipsa_studio::LoudnessResult> measured =
        renderer.RenderAndMeasure();
    ASSERT_TRUE(measured.has_value());
    ASSERT_GT(measured->integrated_lufs, -60.0f);  // actually measured

    SCOPED_TRACE(::testing::Message()
                 << cell.sound_system << ": measured "
                 << measured->integrated_lufs << " LUFS / "
                 << measured->digital_peak_dbfs << " dBFS / "
                 << measured->true_peak_dbtp << " dBTP, shipped "
                 << shipped->loudness.integrated_loudness << " / "
                 << shipped->loudness.digital_peak << " / "
                 << *shipped->loudness.true_peak);
    EXPECT_NEAR(measured->integrated_lufs,
                shipped->loudness.integrated_loudness, kAgreementTolerance);
    EXPECT_NEAR(measured->digital_peak_dbfs, shipped->loudness.digital_peak,
                kAgreementTolerance);
    EXPECT_NEAR(measured->true_peak_dbtp, *shipped->loudness.true_peak,
                kAgreementTolerance);
    EXPECT_NEAR(measured->integrated_lufs, cell.expected_lufs,
                kAbsoluteLufsTolerance);
  }
}

}  // namespace
