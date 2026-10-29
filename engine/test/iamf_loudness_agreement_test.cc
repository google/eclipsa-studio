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
//
// The decoded cells (ES-520) close the loop for the QC Loudness Report:
// OfflineIamfMeasurer decodes the exported file itself and measures the
// render the same way. On LPCM goldens the decoded samples are the
// source samples, so decoded and WAV-side measurements must agree to
// float rounding, and the decoded measurement inherits the WAV-side
// agreement with the shipped loudness_info.

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
#include "mix_renderer/offline_iamf_measurer.h"
#include "mix_renderer/offline_mix_renderer.h"
#include "test/iamf_test_mux.h"
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

// Tolerance between the decoded-IAMF measurement and the WAV-side one
// of the same LPCM program, in dB/LU. The two paths feed the same
// samples through the same OAR pipeline and analyzer; only the block
// boundaries of the accumulation differ. Observed residual: 0.
constexpr float kDecodeParityTolerance = 0.01f;

// Channel count of the bed714 golden's source.
constexpr int kBed714Channels = 12;

// One included audio element of a decoded measurement.
struct DecodedElement {
  uint32_t audio_element_id;
  float mix_gain_db;
};

// Result of a decoded measurement plus the trace facts the parity cells
// compare against the WAV-side renderer.
struct DecodedMeasurement {
  eclipsa_studio::LoudnessResult result;
  uint64_t total_frames = 0;
  uint32_t momentary_len = 0;
  uint32_t gr_len = 0;
  float max_gr_db = 0.0f;
};

// Measure one sub-mix of `path` at `layout` through the QC decode path,
// in render blocks of `buffer_size` frames. Fails the calling test on
// any error.
DecodedMeasurement MeasureDecoded(const std::string& path, uint32_t layout,
                                  const std::vector<DecodedElement>& elements,
                                  float output_mix_gain_db,
                                  uint32_t buffer_size = kBufferSize) {
  DecodedMeasurement out;
  eclipsa_studio::OfflineIamfMeasurer measurer;
  EXPECT_TRUE(measurer.Open(path, buffer_size, layout))
      << measurer.last_error();
  out.total_frames = measurer.total_frames();
  for (const auto& e : elements) {
    EXPECT_TRUE(measurer.IncludeElement(e.audio_element_id, e.mix_gain_db,
                                        /*headphones_mode=*/1,
                                        /*binaural_profile=*/0))
        << measurer.last_error();
  }
  measurer.SetOutputMixGain(output_mix_gain_db);
  const std::optional<eclipsa_studio::LoudnessResult> result =
      measurer.Measure();
  EXPECT_TRUE(result.has_value()) << measurer.last_error();
  out.result = result.value_or(eclipsa_studio::LoudnessResult{});
  out.momentary_len = measurer.TraceLength(eclipsa_studio::kTraceMomentaryLufs);
  out.gr_len = measurer.TraceLength(eclipsa_studio::kTraceLimiterGrDb);
  std::vector<float> gr(out.gr_len);
  measurer.CopyTrace(eclipsa_studio::kTraceLimiterGrDb, gr.data(), out.gr_len);
  for (const float v : gr) out.max_gr_db = std::max(out.max_gr_db, v);
  return out;
}

void ExpectSameLoudness(const eclipsa_studio::LoudnessResult& a,
                        const eclipsa_studio::LoudnessResult& b,
                        float tolerance) {
  EXPECT_NEAR(a.integrated_lufs, b.integrated_lufs, tolerance);
  EXPECT_NEAR(a.digital_peak_dbfs, b.digital_peak_dbfs, tolerance);
  EXPECT_NEAR(a.true_peak_dbtp, b.true_peak_dbtp, tolerance);
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

  // The bed714 golden's source and its encode: a 7.1.4 bed carrying a
  // DISTINCT sine per channel (frequency and amplitude), so a swapped
  // pair, a dropped channel, or a wrong weight shifts the result instead
  // of cancelling out. WAV channel order L R C LFE Lss Rss Lrs Rrs Ltf
  // Rtf Ltb Rtb (the app's 7.1.4 label order in
  // user_metadata_builder.dart). Writes bed714_<tag>.wav and encodes it
  // into <tag>.iamf; both cells that use the golden share this so they
  // cannot drift onto different content.
  struct Bed714 {
    std::string wav;
    std::string iamf;
  };
  void EncodeBed714(const std::string& tag, Bed714* out) {
    constexpr int kCh = kBed714Channels;
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
    out->wav = dir_ + "/bed714_" + tag + ".wav";
    ASSERT_TRUE(test_wav::write_frames_s16(out->wav, kCh, kSampleRate, frames));

    const std::string golden = FindFixture("golden/bed714.textproto");
    ASSERT_FALSE(golden.empty()) << "bed714 golden fixture missing";
    std::ifstream f(golden);
    std::stringstream config;
    config << f.rdbuf();

    out->iamf = dir_ + "/" + tag + ".iamf";
    std::vector<eclipsa_studio::IamfExporter::PushElement> elements(1);
    elements[0].wav_basename = "bed714.wav";
    elements[0].stream.input_wav_path = out->wav;
    elements[0].stream.pad_to_frames = kSourceFrames;
    elements[0].stream.output_sample_rate = kSampleRate;
    eclipsa_studio::IamfExporter exporter;
    ASSERT_EQ(exporter.EncodePush(config.str(), out->iamf, elements), 0);
  }

  // One element of the golden program, measured through the same
  // stream-fed path the export measure phase uses.
  struct Element {
    const char* wav;
    float mix_gain_db;
  };

  // Result of a WAV-side measurement plus the trace lengths the
  // re-blocking cell compares against the decoded measurement.
  struct WavMeasurement {
    eclipsa_studio::LoudnessResult result;
    uint32_t momentary_len = 0;
    uint32_t gr_len = 0;
  };

  // Measure the golden program at the stereo layout in render blocks of
  // `buffer_size` frames.
  WavMeasurement MeasureWav(const std::vector<Element>& elements,
                            float output_mix_gain_db,
                            uint32_t buffer_size = kBufferSize) {
    eclipsa_studio::OfflineMixRenderer renderer;
    EXPECT_TRUE(renderer.Init(kSampleRate, buffer_size, kStereoLayout));
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
    WavMeasurement out;
    out.result = result.value_or(eclipsa_studio::LoudnessResult{});
    out.momentary_len =
        renderer.TraceLength(eclipsa_studio::kTraceMomentaryLufs);
    out.gr_len = renderer.TraceLength(eclipsa_studio::kTraceLimiterGrDb);
    return out;
  }

  eclipsa_studio::LoudnessResult Measure(const std::vector<Element>& elements,
                                         float output_mix_gain_db) {
    return MeasureWav(elements, output_mix_gain_db).result;
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
    ASSERT_GT(measured.integrated_lufs, -60.0f);  // the program is not silence

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
  Bed714 bed;
  EncodeBed714("agreement_714", &bed);

  const auto probe = iamf_tools::ProbeFile(bed.iamf);
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
    cfg.stream.input_wav_path = bed.wav;
    cfg.stream.pad_to_frames = kSourceFrames;
    cfg.stream.output_sample_rate = kSampleRate;
    cfg.element_type = 0;      // channel bed
    cfg.element_sub_type = 8;  // oar_layout_t 7.1.4
    cfg.channels = kBed714Channels;
    cfg.mix_gain_db = -2.0f;
    ASSERT_TRUE(renderer.AddElement(cfg));
    renderer.SetOutputMixGain(-1.0f);
    const std::optional<eclipsa_studio::LoudnessResult> measured =
        renderer.RenderAndMeasure();
    ASSERT_TRUE(measured.has_value());
    ASSERT_GT(measured->integrated_lufs, -60.0f);  // the program is not silence

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

// ── Decoded-IAMF cells (ES-520) ───────────────────────────────────────────

// The decoded measurement of each mix presentation equals the WAV-side
// one (same LPCM samples, same pipeline) and therefore agrees with the
// shipped loudness_info as MildMixMeasuredMatchesShipped does. The
// element ids and gains are the golden's: MP 400 = AE 300 at -3 dB +
// AE 301 at 0 dB, output -1.5 dB; MP 401 = AE 301 at +2 dB, output 0 dB.
TEST_F(IamfLoudnessAgreementTest, DecodedIamfMatchesWavMeasurement) {
  const std::string iamf_path = dir_ + "/decoded_mild.iamf";
  EncodeGolden(0.25f, "dmild", iamf_path);

  const auto probe = iamf_tools::ProbeFile(iamf_path);
  ASSERT_TRUE(probe.ok()) << probe.status().message();
  ASSERT_EQ(probe->mix_presentations.size(), 2u);

  const struct {
    uint32_t mix_presentation_id;
    std::vector<Element> wav_elements;
    std::vector<DecodedElement> decoded_elements;
    float output_mix_gain_db;
  } programs[] = {
      {400,
       {{"bed_dmild.wav", -3.0f}, {"vocal_dmild.wav", 0.0f}},
       {{300, -3.0f}, {301, 0.0f}},
       -1.5f},
      {401, {{"vocal_dmild.wav", 2.0f}}, {{301, 2.0f}}, 0.0f},
  };

  for (const auto& program : programs) {
    SCOPED_TRACE(::testing::Message() << "MP " << program.mix_presentation_id);
    const eclipsa_studio::LoudnessResult wav =
        Measure(program.wav_elements, program.output_mix_gain_db);
    const DecodedMeasurement decoded =
        MeasureDecoded(iamf_path, kStereoLayout, program.decoded_elements,
                       program.output_mix_gain_db);
    // The program is not silence.
    ASSERT_GT(decoded.result.integrated_lufs, -60.0f);
    EXPECT_EQ(decoded.total_frames, static_cast<uint64_t>(kSourceFrames));
    ExpectSameLoudness(decoded.result, wav, kDecodeParityTolerance);

    const auto* shipped = [&]() -> const iamf_tools::MixPresentationReport* {
      for (const auto& mp : probe->mix_presentations) {
        if (mp.id == program.mix_presentation_id) return &mp;
      }
      return nullptr;
    }();
    ASSERT_NE(shipped, nullptr);
    ASSERT_TRUE(shipped->integrated_loudness_lkfs.has_value());
    ASSERT_TRUE(shipped->digital_peak_dbfs.has_value());
    ASSERT_TRUE(shipped->true_peak_dbfs.has_value());
    EXPECT_NEAR(decoded.result.integrated_lufs,
                *shipped->integrated_loudness_lkfs, kAgreementTolerance);
    EXPECT_NEAR(decoded.result.digital_peak_dbfs, *shipped->digital_peak_dbfs,
                kAgreementTolerance);
    EXPECT_NEAR(decoded.result.true_peak_dbtp, *shipped->true_peak_dbfs,
                kAgreementTolerance);
  }

  // The trace series have the WAV-side lengths: a 3.072 s program gives
  // ceil(3072/100) = 31 GR steps and 400 ms fewer of momentary entries,
  // and the mild program never engages the limiter.
  eclipsa_studio::OfflineMixRenderer renderer;
  ASSERT_TRUE(renderer.Init(kSampleRate, kBufferSize, kStereoLayout));
  eclipsa_studio::MixElementConfig cfg;
  cfg.element_id = 1;
  cfg.stream.input_wav_path = dir_ + "/vocal_dmild.wav";
  cfg.stream.pad_to_frames = kSourceFrames;
  cfg.stream.output_sample_rate = kSampleRate;
  cfg.element_sub_type = kStereoLayout;
  cfg.channels = 2;
  cfg.mix_gain_db = 2.0f;
  ASSERT_TRUE(renderer.AddElement(cfg));
  ASSERT_TRUE(renderer.RenderAndMeasure().has_value());
  const DecodedMeasurement decoded =
      MeasureDecoded(iamf_path, kStereoLayout, {{301, 2.0f}}, 0.0f);
  EXPECT_EQ(decoded.momentary_len,
            renderer.TraceLength(eclipsa_studio::kTraceMomentaryLufs));
  EXPECT_EQ(decoded.gr_len,
            renderer.TraceLength(eclipsa_studio::kTraceLimiterGrDb));
  EXPECT_EQ(decoded.gr_len, 31u);
  EXPECT_EQ(decoded.max_gr_db, 0.0f);
}

// Re-blocking. The cells above render in 1024-frame blocks, the size of
// the goldens' temporal units, so each unit fills exactly one block. At
// a 1000-frame block the block and unit boundaries coincide once every
// 128 blocks (128000 frames = 125 units). Every other block starts
// inside a unit, takes the frames left of it and, when those are fewer
// than 1000, continues with the head of the next unit. The 147456-frame
// program is 147 blocks of 1000 frames and a last block of 456 program
// frames; the rest of that block is zeros. The reference is the
// WAV-side renderer at the same block size.
TEST_F(IamfLoudnessAgreementTest, DecodedIamfReblocksTemporalUnits) {
  constexpr uint32_t kOddBlock = 1000;
  static_assert(kSourceFrames % 1024 == 0, "whole temporal units");
  static_assert(kSourceFrames / kOddBlock == 147, "147 full render blocks");
  static_assert(kSourceFrames % kOddBlock == 456, "partial last block");

  const std::string iamf_path = dir_ + "/decoded_reblock.iamf";
  EncodeGolden(0.25f, "dreblock", iamf_path);

  // MP 400: two included elements, so the carry runs per element.
  const WavMeasurement wav =
      MeasureWav({{"bed_dreblock.wav", -3.0f}, {"vocal_dreblock.wav", 0.0f}},
                 -1.5f, kOddBlock);
  const DecodedMeasurement decoded = MeasureDecoded(
      iamf_path, kStereoLayout, {{300, -3.0f}, {301, 0.0f}}, -1.5f, kOddBlock);
  // The program is not silence.
  ASSERT_GT(decoded.result.integrated_lufs, -60.0f);
  EXPECT_EQ(decoded.total_frames, static_cast<uint64_t>(kSourceFrames));
  ExpectSameLoudness(decoded.result, wav.result, kDecodeParityTolerance);
  EXPECT_EQ(decoded.momentary_len, wav.momentary_len);
  EXPECT_EQ(decoded.gr_len, wav.gr_len);
  EXPECT_EQ(decoded.gr_len, 31u);
}

// The MP4 path reads the same IAMF track in place from the container;
// its measurement is the raw file's.
TEST_F(IamfLoudnessAgreementTest, DecodedIamfInMp4MatchesRawIamf) {
  const std::string iamf_path = dir_ + "/decoded_mp4.iamf";
  EncodeGolden(0.25f, "dmp4", iamf_path);
  const std::string mp4_path = dir_ + "/decoded_mp4.mp4";
  ASSERT_TRUE(iamf_test_mux::MuxIamfToMp4(iamf_path, mp4_path));

  const std::vector<DecodedElement> main_mix = {{300, -3.0f}, {301, 0.0f}};
  const DecodedMeasurement raw =
      MeasureDecoded(iamf_path, kStereoLayout, main_mix, -1.5f);
  const DecodedMeasurement mp4 =
      MeasureDecoded(mp4_path, kStereoLayout, main_mix, -1.5f);
  ASSERT_GT(raw.result.integrated_lufs, -60.0f);
  EXPECT_EQ(mp4.total_frames, raw.total_frames);
  ExpectSameLoudness(mp4.result, raw.result, 0.001f);
  EXPECT_EQ(mp4.momentary_len, raw.momentary_len);
  EXPECT_EQ(mp4.gr_len, raw.gr_len);
}

// The multichannel golden through the decode path: a 12-channel bed
// deinterleaved from the temporal units and rendered at Stereo (a real
// downmix) and 7.1.4 (identity, per-layout weights), against the shipped
// per-layout loudness and the pinned absolute values of
// MultichannelBedAgreesPerLayout.
TEST_F(IamfLoudnessAgreementTest, DecodedMultichannelBedAgreesPerLayout) {
  Bed714 bed;
  EncodeBed714("decoded_714", &bed);

  const auto probe = iamf_tools::ProbeFile(bed.iamf);
  ASSERT_TRUE(probe.ok()) << probe.status().message();
  ASSERT_EQ(probe->mix_presentations.size(), 1u);
  ASSERT_EQ(probe->mix_presentations[0].sub_mixes.size(), 1u);
  const auto& layouts = probe->mix_presentations[0].sub_mixes[0].layouts;
  ASSERT_EQ(layouts.size(), 2u);

  const struct {
    const char* sound_system;
    uint8_t sound_system_raw;
    uint32_t target_layout;
    float expected_lufs;
  } cells[] = {
      {"Stereo", 0, 2, -22.51f},
      {"7.1.4", 9, 8, -21.02f},
  };
  for (const auto& cell : cells) {
    SCOPED_TRACE(cell.sound_system);
    const auto shipped_it =
        std::find_if(layouts.begin(), layouts.end(), [&](const auto& layout) {
          return layout.loudness_layout.sound_system_raw ==
                 cell.sound_system_raw;
        });
    ASSERT_NE(shipped_it, layouts.end());
    ASSERT_TRUE(shipped_it->loudness.true_peak.has_value());

    // The golden's gains: -2 dB element, -1 dB output.
    const DecodedMeasurement decoded =
        MeasureDecoded(bed.iamf, cell.target_layout, {{300, -2.0f}}, -1.0f);
    ASSERT_GT(decoded.result.integrated_lufs, -60.0f);
    EXPECT_NEAR(decoded.result.integrated_lufs,
                shipped_it->loudness.integrated_loudness, kAgreementTolerance);
    EXPECT_NEAR(decoded.result.digital_peak_dbfs,
                shipped_it->loudness.digital_peak, kAgreementTolerance);
    EXPECT_NEAR(decoded.result.true_peak_dbtp, *shipped_it->loudness.true_peak,
                kAgreementTolerance);
    EXPECT_NEAR(decoded.result.integrated_lufs, cell.expected_lufs,
                kAbsoluteLufsTolerance);
  }
}

// The decode path measures post-limiter like the WAV path: on the hot
// program the digital peak clamps at the ceiling, the GR trace records
// the reduction, and the shipped (unlimited) integrated value reads
// higher.
TEST_F(IamfLoudnessAgreementTest, DecodedHotProgramIsLimited) {
  const std::string iamf_path = dir_ + "/decoded_hot.iamf";
  EncodeGolden(0.9f, "dhot", iamf_path);

  const auto probe = iamf_tools::ProbeFile(iamf_path);
  ASSERT_TRUE(probe.ok()) << probe.status().message();
  const auto& shipped = probe->mix_presentations[0];
  ASSERT_EQ(shipped.id, 400u);
  ASSERT_TRUE(shipped.integrated_loudness_lkfs.has_value());

  const DecodedMeasurement decoded = MeasureDecoded(
      iamf_path, kStereoLayout, {{300, -3.0f}, {301, 0.0f}}, -1.5f);
  ASSERT_GT(decoded.result.integrated_lufs, -60.0f);
  EXPECT_LE(decoded.result.digital_peak_dbfs, -0.8f);
  EXPECT_GT(decoded.max_gr_db, 1.0f);
  EXPECT_GT(*shipped.integrated_loudness_lkfs, decoded.result.integrated_lufs);

  const eclipsa_studio::LoudnessResult wav =
      Measure({{"bed_dhot.wav", -3.0f}, {"vocal_dhot.wav", 0.0f}}, -1.5f);
  ExpectSameLoudness(decoded.result, wav, kDecodeParityTolerance);
}

// Failure paths report a prefixed error and never a result.
TEST_F(IamfLoudnessAgreementTest, DecodedMeasurerRejectsBadInput) {
  eclipsa_studio::OfflineIamfMeasurer measurer;
  EXPECT_FALSE(
      measurer.Open(dir_ + "/does_not_exist.iamf", kBufferSize, kStereoLayout));
  EXPECT_FALSE(measurer.last_error().empty());
  EXPECT_FALSE(measurer.Measure().has_value());
  EXPECT_EQ(measurer.last_error().rfind("invalid_argument:", 0), 0u)
      << measurer.last_error();

  const std::string iamf_path = dir_ + "/decoded_reject.iamf";
  EncodeGolden(0.25f, "dreject", iamf_path);
  ASSERT_TRUE(measurer.Open(iamf_path, kBufferSize, kStereoLayout))
      << measurer.last_error();
  EXPECT_EQ(measurer.sample_rate(), kSampleRate);
  EXPECT_EQ(measurer.num_elements(), 2u);
  EXPECT_TRUE(measurer.element(0).renderable);
  EXPECT_FALSE(measurer.IncludeElement(999, 0.0f, 1, 0));
  EXPECT_EQ(measurer.last_error().rfind("invalid_argument:", 0), 0u)
      << measurer.last_error();
  // Nothing included: a failure, not a silent program.
  EXPECT_FALSE(measurer.Measure().has_value());
  EXPECT_EQ(measurer.last_error().rfind("invalid_argument:", 0), 0u)
      << measurer.last_error();
  // One pass per instance: the renderer keeps its state across calls,
  // so a second Measure() fails, and the failed run leaves none of the
  // first run's series readable.
  ASSERT_TRUE(measurer.IncludeElement(301, 2.0f, 1, 0));
  EXPECT_TRUE(measurer.last_error().empty());
  const std::optional<eclipsa_studio::LoudnessResult> first =
      measurer.Measure();
  ASSERT_TRUE(first.has_value()) << measurer.last_error();
  EXPECT_GT(measurer.TraceLength(eclipsa_studio::kTraceLimiterGrDb), 0u);
  EXPECT_FALSE(measurer.Measure().has_value());
  EXPECT_EQ(measurer.last_error().rfind("invalid_argument:", 0), 0u)
      << measurer.last_error();
  EXPECT_EQ(measurer.TraceLength(eclipsa_studio::kTraceLimiterGrDb), 0u);
  float lra = 0.0f;
  EXPECT_FALSE(measurer.GetLoudnessRange(&lra, nullptr));
}

}  // namespace
