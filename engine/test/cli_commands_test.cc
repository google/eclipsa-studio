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

#include "tools/cli_commands.h"

#include <climits>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "gtest/gtest.h"
#include "io/wav_reader.h"
#include "test/test_wav_helper.h"

namespace {

using eclipsa_studio::cli::RunBounce;
using eclipsa_studio::cli::RunCli;
using eclipsa_studio::cli::RunEncode;
using eclipsa_studio::cli::RunMeasure;
using eclipsa_studio::cli::RunProbe;

std::string FixturePath(const char* name) {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir == nullptr) srcdir = ".";
  const std::string candidates[] = {
      std::string(srcdir) + "/_main/test/fixtures/" + name,
      std::string(srcdir) + "/_main/engine/test/fixtures/" + name,
      std::string("test/fixtures/") + name,
  };
  for (const auto& c : candidates) {
    std::ifstream probe(c, std::ios::binary);
    if (probe) return c;
  }
  return {};
}

struct CliRun {
  int rc;
  std::string out;
  std::string err;
};

CliRun RunCmd(int (*cmd)(const std::vector<std::string>&, std::ostream&,
                         std::ostream&),
              const std::vector<std::string>& args) {
  std::ostringstream out, err;
  const int rc = cmd(args, out, err);
  return {rc, out.str(), err.str()};
}

// ── dispatch / usage ──────────────────────────────────────────────────────

TEST(CliDispatch, NoArgsPrintsUsage) {
  std::ostringstream out, err;
  const char* argv[] = {"eclipsa_studio_cli"};
  EXPECT_EQ(RunCli(1, argv, out, err), 1);
  EXPECT_NE(err.str().find("usage:"), std::string::npos);
}

TEST(CliDispatch, UnknownSubcommandFails) {
  std::ostringstream out, err;
  const char* argv[] = {"eclipsa_studio_cli", "frobnicate"};
  EXPECT_EQ(RunCli(2, argv, out, err), 1);
  EXPECT_NE(err.str().find("unknown subcommand"), std::string::npos);
}

// ── bounce ────────────────────────────────────────────────────────────────

TEST(CliBounce, PassthroughBounceWritesOutput) {
  const std::string dir = test_wav::temp_dir();
  const std::string in = dir + "/cli_in.wav";
  const std::string out_wav = dir + "/cli_out.wav";
  ASSERT_TRUE(test_wav::write_sine(in, 2, 48000, 16, 440.f, 0.25f));

  const CliRun r = RunCmd(RunBounce, {in, out_wav});
  EXPECT_EQ(r.rc, 0) << r.err;
  EXPECT_EQ(r.out, "ok\n");

  WavReader reader;
  ASSERT_TRUE(reader.open(out_wav.c_str()));
  EXPECT_EQ(reader.channels(), 2u);
  EXPECT_EQ(reader.total_frames(), 12000u);
}

TEST(CliBounce, RoutingMinusOneSilencesChannel) {
  const std::string dir = test_wav::temp_dir();
  const std::string in = dir + "/cli_route_in.wav";
  const std::string out_wav = dir + "/cli_route_out.wav";
  ASSERT_TRUE(test_wav::write_sine(in, 2, 48000, 16, 440.f, 0.1f));

  const CliRun r = RunCmd(RunBounce, {in, out_wav, "--routing", "-1,1"});
  ASSERT_EQ(r.rc, 0) << r.err;

  WavReader reader;
  ASSERT_TRUE(reader.open(out_wav.c_str()));
  constexpr uint32_t kCap = 1024;
  float storage[2 * kCap] = {};
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = 2;
  buf.capacity_frames = kCap;
  ASSERT_GT(reader.read(buf, kCap), 0u);
  // Channel 0 silenced by routing -1; channel 1 carries the sine.
  bool ch1_nonzero = false;
  for (uint32_t i = 0; i < buf.frames; ++i) {
    EXPECT_EQ(buf.channel(0)[i], 0.0f);
    ch1_nonzero |= buf.channel(1)[i] != 0.0f;
  }
  EXPECT_TRUE(ch1_nonzero);
}

TEST(CliBounce, MissingInputFails) {
  const CliRun r =
      RunCmd(RunBounce, {"/no/such/input.wav", "/tmp/never_written.wav"});
  EXPECT_EQ(r.rc, 2);
  EXPECT_NE(r.err.find("failed to open input"), std::string::npos);
}

TEST(CliBounce, BadFlagValueFails) {
  const CliRun r = RunCmd(RunBounce, {"a.wav", "b.wav", "--gain-db", "loud"});
  EXPECT_EQ(r.rc, 1);
}

// Typo'd flags must be rejected, not silently swallow the next token.
TEST(CliBounce, UnknownFlagFails) {
  const CliRun r = RunCmd(RunBounce, {"a.wav", "b.wav", "--gaindb", "-6"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("unknown flag --gaindb"), std::string::npos);
}

TEST(CliProbe, UnknownFlagDoesNotSwallowPositional) {
  const CliRun r = RunCmd(RunProbe, {"--bogus", "file.iamf"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("unknown flag --bogus"), std::string::npos);
}

// ── measure ───────────────────────────────────────────────────────────────

// A full-scale 440 Hz sine on both stereo channels: BS.1770 channel
// powers sum, K-weighting at 440 Hz is within ~1 dB of unity, so the
// integrated loudness lands near 0 LUFS (one channel alone would be
// ~-3 LUFS). True/digital peak sit at full scale. Wide tolerances —
// this guards the wiring, not the meter (loudness_meter_test does).
TEST(CliMeasure, FullScaleStereoSineNearZeroLufs) {
  const std::string dir = test_wav::temp_dir();
  const std::string wav = dir + "/cli_measure.wav";
  ASSERT_TRUE(test_wav::write_sine(wav, 2, 48000, 16, 440.f, 1.0f));

  const CliRun r = RunCmd(RunMeasure, {wav, "--layout", "stereo"});
  ASSERT_EQ(r.rc, 0) << r.err;

  float lufs = -999, true_peak = -999, digital_peak = -999;
  std::istringstream lines(r.out);
  std::string line;
  while (std::getline(lines, line)) {
    sscanf(line.c_str(), "integrated_lufs=%f", &lufs);
    sscanf(line.c_str(), "true_peak_dbtp=%f", &true_peak);
    sscanf(line.c_str(), "digital_peak_dbfs=%f", &digital_peak);
  }
  // ±2 dB on all three: OAR's stereo passthrough applies ~-1 dB, so
  // the measured values sit near -1, not 0 — the tolerance covers
  // that plus any small future liboar gain drift.
  EXPECT_NEAR(lufs, 0.0f, 2.0f);
  EXPECT_NEAR(true_peak, 0.0f, 2.0f);
  EXPECT_NEAR(digital_peak, 0.0f, 2.0f);
}

TEST(CliMeasure, ChannelCountMismatchFails) {
  const std::string dir = test_wav::temp_dir();
  const std::string wav = dir + "/cli_measure_mono.wav";
  ASSERT_TRUE(test_wav::write_sine(wav, 1, 48000, 16, 440.f, 0.1f));

  const CliRun r = RunCmd(RunMeasure, {wav, "--layout", "5.1"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("channels"), std::string::npos);
}

TEST(CliMeasure, UnknownLayoutFails) {
  const CliRun r = RunCmd(RunMeasure, {"x.wav", "--layout", "22.2"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("unknown layout"), std::string::npos);
}

// ── probe ─────────────────────────────────────────────────────────────────

TEST(CliProbe, SummarizesFixture) {
  const std::string fixture = FixturePath("tones_100ms_3OA_stereo_opus.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  const CliRun r = RunCmd(RunProbe, {fixture});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_NE(r.out.find("sample_rate=48000"), std::string::npos);
  EXPECT_NE(r.out.find("audio_elements=2"), std::string::npos);
  EXPECT_NE(r.out.find("mix_presentations="), std::string::npos);
}

TEST(CliProbe, JsonOutputIsWellFormedish) {
  const std::string fixture = FixturePath("tones_100ms_3OA_stereo_opus.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  const CliRun r = RunCmd(RunProbe, {fixture, "--json"});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_EQ(r.out.front(), '{');
}

// FLAC carries a usable sample total in its STREAMINFO, so the
// descriptors-only probe can report a duration without a temporal-unit
// scan (unlike Opus, which reports total_samples=0 here).
TEST(CliProbe, FlacStructReportsDescriptorDuration) {
  const std::string fixture = FixturePath("noise_1024samp_stereo_flac.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  const CliRun r = RunCmd(RunProbe, {fixture});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_NE(r.out.find("sample_rate=48000"), std::string::npos);
  EXPECT_NE(r.out.find("total_samples=1024"), std::string::npos);
}

// The FLAC codec config the Dart Inspector parser depends on: it keys
// StreamInfo off block_type_raw == 0 (upstream drops a dedicated
// is_stream_info flag) and reads the descriptors-only total.
TEST(CliProbe, FlacJsonExposesStreamInfo) {
  const std::string fixture = FixturePath("noise_1024samp_stereo_flac.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  const CliRun r = RunCmd(RunProbe, {fixture, "--json"});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_NE(r.out.find("\"codec_id\": \"FLAC\""), std::string::npos);
  EXPECT_NE(r.out.find("\"block_type_raw\": 0"), std::string::npos);
  EXPECT_NE(r.out.find("\"total_samples_in_stream\": 1024"), std::string::npos);
  EXPECT_NE(r.out.find("\"descriptor_total_samples\": 1024"),
            std::string::npos);
}

TEST(CliProbe, MissingFileFails) {
  const CliRun r = RunCmd(RunProbe, {"/no/such/file.iamf"});
  EXPECT_EQ(r.rc, 2);
  EXPECT_FALSE(r.err.empty());
}

// ── encode ────────────────────────────────────────────────────────────────

TEST(CliEncode, MissingConfigFails) {
  const CliRun r = RunCmd(RunEncode, {"/no/such/config.textproto", "--wav-dir",
                                      "/tmp", "--out-dir", "/tmp"});
  EXPECT_EQ(r.rc, 2);
  EXPECT_NE(r.err.find("cannot read config"), std::string::npos);
}

TEST(CliEncode, GarbageConfigFailsParse) {
  const std::string dir = test_wav::temp_dir();
  const std::string cfg = dir + "/bad.textproto";
  {
    std::ofstream(cfg) << "this is { not a UserMetadata";
  }
  const CliRun r = RunCmd(RunEncode, {cfg, "--wav-dir", dir, "--out-dir", dir});
  EXPECT_EQ(r.rc, 2);
  EXPECT_NE(r.err.find("rc=-10"), std::string::npos);
}

// ── encode round trip (golden textprotos) ────────────────────────────────
//
// The goldens under fixtures/golden/ are produced by the app's
// UserMetadataBuilder (pinned byte-for-byte by
// app/test/export/user_metadata_golden_test.dart). Encoding them through
// the real iamf-tools encoder and probing the result guards the
// app-to-encoder contract: a proto field rename in an iamf-tools pin
// bump, or a builder emitting a field the encoder rejects, fails here
// instead of at user export time.

struct GoldenRoundTrip {
  std::string json;       // probe --json output; empty on failure
  std::string iamf_path;  // encoded file path
};

// Encode a golden config against WAVs staged in a fresh directory and
// probe the encoded file (json empty on any failure, with a gtest
// failure already recorded). Each WAV is `source_frames` long — an
// exact multiple of the golden's coded frame size, so the goldens'
// samples_to_trim_at_end: 0 holds (24576 = 24 x 1024 for the LPCM
// goldens; Opus goldens need a multiple of 960).
GoldenRoundTrip EncodeGoldenAndProbe(
    const char* golden_name, const char* output_name,
    const std::vector<std::pair<std::string, int>>& wavs,
    int source_frames = 24576) {
  const std::string cfg = FixturePath(golden_name);
  EXPECT_FALSE(cfg.empty()) << golden_name << " missing";
  if (cfg.empty()) return {};

  const std::string base =
      test_wav::temp_dir() + "/" +
      ::testing::UnitTest::GetInstance()->current_test_info()->name();
  const std::string wav_dir = base + "_wavs";
  const std::string out_dir = base + "_out";
  std::filesystem::create_directories(wav_dir);
  std::filesystem::create_directories(out_dir);
  const float duration_sec = static_cast<float>(source_frames) / 48000.0f;
  for (const auto& [name, channels] : wavs) {
    EXPECT_TRUE(test_wav::write_sine(wav_dir + "/" + name, channels, 48000, 16,
                                     440.f, duration_sec));
  }

  const CliRun enc =
      RunCmd(RunEncode, {cfg, "--wav-dir", wav_dir, "--out-dir", out_dir});
  EXPECT_EQ(enc.rc, 0) << enc.err;
  if (enc.rc != 0) return {};

  const std::string iamf = out_dir + "/" + output_name;
  const CliRun probe = RunCmd(RunProbe, {iamf, "--json"});
  EXPECT_EQ(probe.rc, 0) << probe.err;
  if (probe.rc != 0) return {};
  return {probe.out, iamf};
}

// Parse "descriptor_bytes_consumed" out of the probe JSON so the
// position byte search below can stay inside the descriptor OBUs
// (audio-frame PCM could otherwise false-positive a short pattern).
size_t DescriptorBytes(const std::string& json) {
  const char* key = "\"descriptor_bytes_consumed\": ";
  const size_t pos = json.find(key);
  if (pos == std::string::npos) return 0;
  return static_cast<size_t>(
      std::strtoul(json.c_str() + pos + std::strlen(key), nullptr, 10));
}

// Substring of `json` from `from` to `to` (empty `to` = to the end).
// Empty when `from` is missing — assertions on the window then fail
// loudly rather than match the whole document.
std::string Window(const std::string& json, const std::string& from,
                   const std::string& to = {}) {
  const size_t a = json.find(from);
  if (a == std::string::npos) return {};
  if (to.empty()) return json.substr(a);
  const size_t b = json.find(to, a + from.size());
  return json.substr(a, b == std::string::npos ? std::string::npos : b - a);
}

// The first default_mix_gain_q7_8 value after `anchor` inside `window`
// — the probe emits each element's element_mix_gain right after its
// localized annotation, so this ties a gain to a specific element (or,
// with an "output_mix_gain" anchor, to the sub-mix). INT_MIN when
// either is missing.
int GainQ78After(const std::string& window, const std::string& anchor) {
  const size_t a = window.find(anchor);
  if (a == std::string::npos) return INT_MIN;
  const char* key = "\"default_mix_gain_q7_8\": ";
  const size_t g = window.find(key, a);
  if (g == std::string::npos) return INT_MIN;
  return std::atoi(window.c_str() + g + std::strlen(key));
}

TEST(CliEncode, GoldenObjectsBinauralRoundTrip) {
  const GoldenRoundTrip rt = EncodeGoldenAndProbe(
      "golden/objects_binaural.textproto", "objects_binaural.iamf",
      {{"obj_mono.wav", 1}, {"obj_dual.wav", 2}});
  ASSERT_FALSE(rt.json.empty());

  // The binaural filter profile round-trips: direct on the mono object,
  // the ambient default on the dual.
  EXPECT_NE(rt.json.find("\"binaural_filter_profile\": \"direct\""),
            std::string::npos);
  EXPECT_NE(rt.json.find("\"binaural_filter_profile\": \"ambient\""),
            std::string::npos);
  // Both elements survive as object-based with exactly one substream
  // (iamf-tools rejects any other count — the dual is one coupled pair).
  EXPECT_NE(rt.json.find("\"type\": \"object_based\""), std::string::npos);
  EXPECT_NE(rt.json.find("\"num_substreams\": 1"), std::string::npos);
  EXPECT_EQ(rt.json.find("\"num_substreams\": 2"), std::string::npos);

  // The probe does not (yet) surface the rendering-config position
  // defaults, so assert them in the descriptor bytes. The polar
  // defaults start byte-aligned (the preceding param_definition ends
  // on a mode bit + 7 reserved bits) and pack as azimuth:9 elevation:8
  // distance:7.
  const size_t descriptor_bytes = DescriptorBytes(rt.json);
  ASSERT_GT(descriptor_bytes, 0u);
  std::ifstream f(rt.iamf_path, std::ios::binary);
  ASSERT_TRUE(f.good());
  std::string descriptors(descriptor_bytes, '\0');
  f.read(descriptors.data(), static_cast<std::streamsize>(descriptor_bytes));
  descriptors.resize(static_cast<size_t>(f.gcount()));

  // Each pattern is anchored on its full param_definition tail —
  // uleb128 parameter_rate 48000 (0x80 0xF7 0x02) + mode bit 1 with 7
  // reserved bits (0x80) — so a short position triple can't match
  // coincidental descriptor bytes. The mono pattern additionally leads
  // with its uleb128 parameter_id (100 = 0x64, fixed by the golden).
  //
  // Mono object az=30 el=10 dist=64 (0.5 * 127 rounded):
  // 000011110 00001010 1000000 -> 0x0F 0x05 0x40.
  const std::string mono_polar = "\x64\x80\xf7\x02\x80\x0f\x05\x40";
  EXPECT_NE(descriptors.find(mono_polar), std::string::npos);
  // Dual object center az=10 spread=60 el=-5 dist=127: first (channel
  // 0 = L) az=40, second az=-20 -> two 9/8/7-bit triples pack to
  // 0x14 0x7D 0xFF 0xF6 0x7D 0xFF.
  const std::string dual_polar = "\x80\xf7\x02\x80\x14\x7d\xff\xf6\x7d\xff";
  EXPECT_NE(descriptors.find(dual_polar), std::string::npos);
}

TEST(CliEncode, GoldenMultiMixRoundTrip) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.json.empty());

  // Slice the report per presentation so every gain assertion below is
  // tied to the right presentation AND element — a gain landing on the
  // wrong element would otherwise still satisfy a whole-document
  // substring search.
  const std::string main_mix =
      Window(rt.json, "\"label\": \"Main\"", "\"label\": \"Vocal Only\"");
  const std::string vocal_only = Window(rt.json, "\"label\": \"Vocal Only\"");
  ASSERT_FALSE(main_mix.empty());
  ASSERT_FALSE(vocal_only.empty());

  // "Main": Bed -3 dB (-768), Vocal 0 dB, output -1.5 dB (-384).
  EXPECT_EQ(GainQ78After(main_mix, "\"Bed\""), -768);
  EXPECT_EQ(GainQ78After(main_mix, "\"Vocal\""), 0);
  EXPECT_EQ(GainQ78After(main_mix, "\"output_mix_gain\""), -384);

  // "Vocal Only": the Bed is excluded entirely; Vocal +2 dB (512),
  // output 0 dB.
  EXPECT_EQ(vocal_only.find("\"Bed\""), std::string::npos);
  EXPECT_EQ(GainQ78After(vocal_only, "\"Vocal\""), 512);
  EXPECT_EQ(GainQ78After(vocal_only, "\"output_mix_gain\""), 0);
}

TEST(CliEncode, GoldenMultiMixOpusRoundTrip) {
  // The Opus leg of the export contract (ES-382): the app builder's Opus
  // codec config (960-sample frames, roll distance -4, per-channel
  // bitrate metadata) drives the real libopus encode. Sources are
  // 24000 frames — a multiple of the 960-sample Opus frame, keeping
  // samples_to_trim_at_end: 0 valid.
  const GoldenRoundTrip rt = EncodeGoldenAndProbe(
      "golden/multi_mix_opus.textproto", "multi_mix_opus.iamf",
      {{"bed.wav", 2}, {"vocal.wav", 2}}, /*source_frames=*/24000);
  ASSERT_FALSE(rt.json.empty());

  // The encoded stream is genuinely Opus, with exactly one codec
  // config shared by both elements.
  const char* codec_key = "\"codec_id\": \"Opus\"";
  size_t codec_count = 0;
  for (size_t pos = rt.json.find(codec_key); pos != std::string::npos;
       pos = rt.json.find(codec_key, pos + 1)) {
    ++codec_count;
  }
  EXPECT_EQ(codec_count, 1u);
  EXPECT_EQ(rt.json.find("\"codec_id\": \"LPCM\""), std::string::npos);

  // Both presentations survive the transcode, with the same gain
  // contract as the LPCM multi-mix golden.
  const std::string main_mix =
      Window(rt.json, "\"label\": \"Main\"", "\"label\": \"Vocal Only\"");
  const std::string vocal_only = Window(rt.json, "\"label\": \"Vocal Only\"");
  ASSERT_FALSE(main_mix.empty());
  ASSERT_FALSE(vocal_only.empty());

  // "Main": Bed -3 dB (-768), Vocal 0 dB, output -1.5 dB (-384).
  EXPECT_EQ(GainQ78After(main_mix, "\"Bed\""), -768);
  EXPECT_EQ(GainQ78After(main_mix, "\"Vocal\""), 0);
  EXPECT_EQ(GainQ78After(main_mix, "\"output_mix_gain\""), -384);

  // "Vocal Only": the Bed is excluded entirely; Vocal +2 dB (512),
  // output 0 dB.
  EXPECT_EQ(vocal_only.find("\"Bed\""), std::string::npos);
  EXPECT_EQ(GainQ78After(vocal_only, "\"Vocal\""), 512);
  EXPECT_EQ(GainQ78After(vocal_only, "\"output_mix_gain\""), 0);
}

}  // namespace
