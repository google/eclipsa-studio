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

// IamfExporter::EncodePush (ES-480): drives the golden multi_mix textproto
// (the app builder's exact output) through the push-PCM export path.
// Rendered-PCM correctness of the encoded bitstream is pinned by
// iamf_round_trip_test, which encodes through this same path; this
// suite covers the exporter's own contract — the short-final-unit
// padding path, element/UserMetadata mismatch rejections, mid-encode
// cancel, and the stale-cancel reset.
// (Byte-for-byte equivalence with the deleted TestMain path was pinned
// while both paths coexisted, before the legacy path's removal.)

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "google/protobuf/text_format.h"
#include "gtest/gtest.h"
#include "iamf/cli/proto/user_metadata.pb.h"
#include "iamf/iamf_exporter.h"
#include "iamf/include/iamf_tools/iamf_encoder_factory.h"
#include "iamf/include/iamf_tools/iamf_encoder_interface.h"
#include "test/test_wav_helper.h"

namespace {

constexpr uint32_t kSampleRate = 48000;
// A multiple of the 1024-sample coded frame, like the dialog guarantees.
constexpr int kSourceFrames = 1024 * 12;

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

std::string ReadFileOrEmpty(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return {};
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

std::string GoldenTextproto() {
  const std::string path = FindFixture("golden/multi_mix.textproto");
  EXPECT_FALSE(path.empty()) << "golden fixture missing";
  return ReadFileOrEmpty(path);
}

std::string OpusGoldenTextproto() {
  const std::string path = FindFixture("golden/multi_mix_opus.textproto");
  EXPECT_FALSE(path.empty()) << "opus golden fixture missing";
  return ReadFileOrEmpty(path);
}

class IamfPushExportTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = test_wav::temp_dir();
    ASSERT_TRUE(test_wav::write_sine_frames(dir_ + "/bed.wav", 2, kSampleRate,
                                            16, 440.0f, kSourceFrames, 0.25f));
    ASSERT_TRUE(test_wav::write_sine_frames(dir_ + "/vocal.wav", 2, kSampleRate,
                                            16, 2000.0f, kSourceFrames, 0.25f));
  }

  // Push-path element inputs matching the golden's audio_frame_metadata.
  std::vector<eclipsa_studio::IamfExporter::PushElement> PushElements(
      uint64_t pad_to_frames) {
    std::vector<eclipsa_studio::IamfExporter::PushElement> elements(2);
    elements[0].wav_basename = "bed.wav";
    elements[0].stream.input_wav_path = dir_ + "/bed.wav";
    elements[0].stream.pad_to_frames = pad_to_frames;
    elements[0].stream.output_sample_rate = kSampleRate;
    elements[1].wav_basename = "vocal.wav";
    elements[1].stream.input_wav_path = dir_ + "/vocal.wav";
    elements[1].stream.pad_to_frames = pad_to_frames;
    elements[1].stream.output_sample_rate = kSampleRate;
    return elements;
  }

  std::string dir_;
};

TEST_F(IamfPushExportTest, EncodesGoldenSession) {
  const std::string config = GoldenTextproto();
  ASSERT_FALSE(config.empty());

  const std::string push_path = dir_ + "/multi_mix_push.iamf";
  eclipsa_studio::IamfExporter exporter;
  ASSERT_EQ(exporter.EncodePush(config, push_path, PushElements(kSourceFrames)),
            0);
  EXPECT_FLOAT_EQ(exporter.Progress(), 1.0f);
  EXPECT_FALSE(ReadFileOrEmpty(push_path).empty());
}

TEST_F(IamfPushExportTest, HandlesProgramNotMultipleOfFrameSize) {
  // 1000 trailing frames short of a frame boundary: the encoder must
  // auto-pad the final frame (samples_to_trim_at_end_includes_padding:
  // false, the proto's recommended mode) instead of failing.
  std::string config = GoldenTextproto();
  ASSERT_FALSE(config.empty());
  size_t pos = 0;
  int patched = 0;
  const std::string needle = "samples_to_trim_at_end: 0";
  while ((pos = config.find(needle, pos)) != std::string::npos) {
    config.replace(pos, needle.size(),
                   "samples_to_trim_at_end: 0\n"
                   "  samples_to_trim_at_end_includes_padding: false");
    pos += needle.size();
    ++patched;
  }
  ASSERT_EQ(patched, 2) << "golden layout changed";

  const uint64_t odd_frames = 1024 * 4 + 24;
  const std::string push_path = dir_ + "/multi_mix_odd.iamf";
  eclipsa_studio::IamfExporter exporter;
  ASSERT_EQ(exporter.EncodePush(config, push_path, PushElements(odd_frames)),
            0);
  EXPECT_FALSE(ReadFileOrEmpty(push_path).empty());
}

TEST_F(IamfPushExportTest, OpusOddLengthUsesDelayAwarePadTarget) {
  // ES-485: iamf-tools prepends and start-trims the 312-sample libopus
  // lookahead, which shifts the substream off the 960 grid and adds
  // the shift remainder to the end trim. The dialog therefore pads an
  // Opus program so length + delay lands on the grid
  // (exportPadTarget): for the 12288-frame sources here that is
  // ceil((12288 + 312) / 960) * 960 - 312 = 13128, trim 840. The
  // declared trim alone is then the whole end trim — 840 < 960 encodes
  // fine, where a plain frame-multiple pad with trim >= 312 was
  // rejected ("the spec disallows trimming multiple frames from the
  // end").
  std::string config = OpusGoldenTextproto();
  ASSERT_FALSE(config.empty());
  size_t pos = 0;
  int patched = 0;
  const std::string needle = "samples_to_trim_at_end: 0";
  while ((pos = config.find(needle, pos)) != std::string::npos) {
    config.replace(pos, needle.size(), "samples_to_trim_at_end: 840");
    pos += needle.size();
    ++patched;
  }
  ASSERT_EQ(patched, 2) << "opus golden layout changed";

  constexpr uint64_t kOpusDelay = 312;
  constexpr uint64_t kOpusFrame = 960;
  const uint64_t pad_target =
      (kSourceFrames + kOpusDelay + kOpusFrame - 1) / kOpusFrame * kOpusFrame -
      kOpusDelay;
  ASSERT_EQ(pad_target, 13128u);
  ASSERT_EQ(pad_target - kSourceFrames, 840u);

  const std::string push_path = dir_ + "/multi_mix_opus_odd.iamf";
  eclipsa_studio::IamfExporter exporter;
  ASSERT_EQ(exporter.EncodePush(config, push_path, PushElements(pad_target)),
            0);
  EXPECT_FALSE(ReadFileOrEmpty(push_path).empty());
}

TEST_F(IamfPushExportTest, OpusEncoderDelayMatchesAppPadConstant) {
  // ES-503: the app's delay-aware pad target (exportPadTarget in
  // app/lib/export/iamf_export_config.dart) bakes in
  // kOpusEncoderDelay = 312 — the lookahead the iamf-tools Opus
  // encoder reports at 48 kHz and start-trims from the first frames.
  // The stamped pre_skip is replaced by the encoder's real value
  // (automatically_override_codec_delay defaults true), so nothing
  // else would fail if a libopus or iamf-tools bump changed it: the
  // pad math silently drifts and the end trim comes out mis-sized.
  // Pin the reported delay here so such a bump fails CI instead;
  // update kOpusEncoderDelay in lockstep with this expectation.
  iamf_tools_cli_proto::UserMetadata user_metadata;
  google::protobuf::TextFormat::Parser parser;
  ASSERT_TRUE(parser.ParseFromString(OpusGoldenTextproto(), &user_metadata));
  std::string serialized;
  ASSERT_TRUE(user_metadata.SerializeToString(&serialized));

  auto encoder_or =
      iamf_tools::api::IamfEncoderFactory::CreateFileGeneratingIamfEncoder(
          serialized, dir_ + "/delay_pin.iamf");
  ASSERT_TRUE(encoder_or.ok()) << encoder_or.status().message();
  EXPECT_EQ((*encoder_or)->GetEncoderDelay(), 312u)
      << "the iamf-tools Opus encoder no longer reports a 312-sample "
         "lookahead at 48 kHz; update kOpusEncoderDelay in "
         "app/lib/export/iamf_export_config.dart (and this test) in "
         "lockstep, or the Opus pad/trim math drifts";
}

TEST_F(IamfPushExportTest, RejectsUnknownBasename) {
  const std::string config = GoldenTextproto();
  auto elements = PushElements(kSourceFrames);
  elements[0].wav_basename = "nope.wav";
  eclipsa_studio::IamfExporter exporter;
  EXPECT_EQ(exporter.EncodePush(config, dir_ + "/reject.iamf", elements), -12);
}

TEST_F(IamfPushExportTest, RejectsDuplicateResolvedElementId) {
  // Two elements naming the same wav_basename both join to the first
  // audio_frame_metadata match, i.e. the same audio_element_id — the
  // session shape produced by two UI elements sharing one source WAV.
  // Silently collapsing them would feed one element's PCM twice and
  // starve the other id inside iamf-tools; it must be a named -12.
  const std::string config = GoldenTextproto();
  auto elements = PushElements(kSourceFrames);
  elements[1].wav_basename = elements[0].wav_basename;
  elements[1].stream.input_wav_path = elements[0].stream.input_wav_path;
  eclipsa_studio::IamfExporter exporter;
  EXPECT_EQ(exporter.EncodePush(config, dir_ + "/reject_dup.iamf", elements),
            -12);
}

TEST_F(IamfPushExportTest, RejectsChannelCountMismatch) {
  const std::string config = GoldenTextproto();
  auto elements = PushElements(kSourceFrames);
  // Route to mono: one channel where the UserMetadata labels two.
  elements[0].stream.routing = {0};
  eclipsa_studio::IamfExporter exporter;
  EXPECT_EQ(exporter.EncodePush(config, dir_ + "/reject2.iamf", elements), -12);
}

TEST_F(IamfPushExportTest, RejectsLengthMismatch) {
  const std::string config = GoldenTextproto();
  auto elements = PushElements(kSourceFrames);
  elements[1].stream.pad_to_frames = kSourceFrames + 1024;
  eclipsa_studio::IamfExporter exporter;
  EXPECT_EQ(exporter.EncodePush(config, dir_ + "/reject3.iamf", elements), -14);
}

TEST_F(IamfPushExportTest, CancelMidEncodeAbortsAndRemovesOutput) {
  // Cancel is checked once per temporal unit, so a cancel raised from
  // another thread while the unit loop runs must abort with -99 and
  // remove the partial output. The program is sized (3000 units) so the
  // canceller — polling every 1 ms and firing once progress shows the
  // loop running (~unit 180 of 3000) — lands long before completion.
  constexpr int kLongFrames = 1024 * 3000;
  ASSERT_TRUE(
      test_wav::write_silence(dir_ + "/bed_long.wav", 2, kSampleRate, 16,
                              static_cast<float>(kLongFrames) / kSampleRate));
  ASSERT_TRUE(
      test_wav::write_silence(dir_ + "/vocal_long.wav", 2, kSampleRate, 16,
                              static_cast<float>(kLongFrames) / kSampleRate));
  auto elements = PushElements(kLongFrames);
  elements[0].stream.input_wav_path = dir_ + "/bed_long.wav";
  elements[1].stream.input_wav_path = dir_ + "/vocal_long.wav";

  const std::string config = GoldenTextproto();
  const std::string push_path = dir_ + "/cancel_mid.iamf";
  eclipsa_studio::IamfExporter exporter;

  std::atomic<bool> done{false};
  std::thread canceller([&exporter, &done]() {
    // Fire as soon as the unit loop reports progress past setup; the
    // deadline guards against hanging the test if the encode errors out
    // before ever reaching the loop.
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (!done.load(std::memory_order_relaxed) &&
           exporter.Progress() < 0.06f &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    exporter.Cancel();
  });
  const int32_t rc = exporter.EncodePush(config, push_path, elements);
  done.store(true, std::memory_order_relaxed);
  canceller.join();

  EXPECT_EQ(rc, -99);
  EXPECT_LT(exporter.Progress(), 1.0f);
  EXPECT_TRUE(ReadFileOrEmpty(push_path).empty())
      << "partial output survived the cancel";

  // ES-470: the scope-exit capture must snapshot stats on the cancel
  // path too — that partial-run capture is the guard's whole reason
  // for existing. The silence sources cannot clip, but the entries
  // must exist and cover only what was actually pulled.
  uint64_t clipped = 99;
  float peak = -1.0f;
  ASSERT_TRUE(exporter.GetElementClipStats(0, &clipped, &peak))
      << "no stats captured on the cancelled run";
  EXPECT_EQ(clipped, 0u);
  EXPECT_GE(peak, 0.0f);
  EXPECT_TRUE(exporter.GetElementClipStats(1, nullptr, nullptr));
}

TEST_F(IamfPushExportTest, ElementClipStatsPerIndexAndResetOnBegin) {
  // ES-470: overload stats are counted on the PCM actually fed to the
  // encoder, keyed by add order, and live until ResetForNewRequest()
  // (the FFI begin). The hot element's +15 dB pushes the 0.25 sine to
  // ~1.4; the other element stays in range.
  const std::string config = GoldenTextproto();
  ASSERT_FALSE(config.empty());

  eclipsa_studio::IamfExporter exporter;
  EXPECT_FALSE(exporter.GetElementClipStats(0, nullptr, nullptr))
      << "stats available before any run";

  auto elements = PushElements(kSourceFrames);
  elements[0].stream.gain_db = 15.0f;
  const std::string push_path = dir_ + "/clip_stats.iamf";
  ASSERT_EQ(exporter.EncodePush(config, push_path, elements), 0);

  uint64_t clipped = 0;
  float peak = 0.0f;
  ASSERT_TRUE(exporter.GetElementClipStats(0, &clipped, &peak));
  EXPECT_GT(clipped, 0u);
  EXPECT_GT(peak, 1.2f);

  ASSERT_TRUE(exporter.GetElementClipStats(1, &clipped, &peak));
  EXPECT_EQ(clipped, 0u);
  EXPECT_LE(peak, 0.25f);

  EXPECT_FALSE(exporter.GetElementClipStats(2, &clipped, &peak))
      << "index out of range";

  exporter.ResetForNewRequest();
  EXPECT_FALSE(exporter.GetElementClipStats(0, nullptr, nullptr))
      << "stats survived the begin boundary";
}

TEST_F(IamfPushExportTest, FailedRunClearsPreviousStats) {
  // A direct EncodePush that fails before its streams open (no begin /
  // ResetForNewRequest in between) must not leave the previous run's
  // stats readable as if they were fresh — EncodePush entry clears
  // them, keeping GetElementClipStats' "before any run reached its
  // streams" contract self-enforcing.
  const std::string config = GoldenTextproto();
  ASSERT_FALSE(config.empty());
  const std::string push_path = dir_ + "/stale_stats.iamf";
  eclipsa_studio::IamfExporter exporter;
  ASSERT_EQ(exporter.EncodePush(config, push_path, PushElements(kSourceFrames)),
            0);
  ASSERT_TRUE(exporter.GetElementClipStats(0, nullptr, nullptr));

  EXPECT_EQ(exporter.EncodePush("not a textproto", push_path,
                                PushElements(kSourceFrames)),
            -10);
  EXPECT_FALSE(exporter.GetElementClipStats(0, nullptr, nullptr))
      << "failed run left the previous run's stats readable";
}

TEST_F(IamfPushExportTest, CancelResetBoundaryIsResetForNewRequest) {
  // The cancel flag's reset boundary is ResetForNewRequest() — the FFI
  // begin — not EncodePush entry. Two sides of the contract:
  //
  // 1. A cancel raised before the reset (e.g. during the app's measure
  //    phase) is stale: ResetForNewRequest() drops it and the encode
  //    completes.
  // 2. A cancel raised after the reset but before EncodePush (the
  //    begin→run window: the dialog awaits config staging and isolate
  //    spawn in between) stays armed and aborts the run with -99 — it
  //    used to be swallowed by an EncodePush-entry reset, leaving the
  //    UI on "Cancelling…" while the export completed as success.
  const std::string config = GoldenTextproto();
  const std::string push_path = dir_ + "/cancelled.iamf";
  eclipsa_studio::IamfExporter exporter;

  exporter.Cancel();  // stale: pre-begin
  exporter.ResetForNewRequest();
  ASSERT_EQ(exporter.EncodePush(config, push_path, PushElements(kSourceFrames)),
            0);
  EXPECT_FALSE(ReadFileOrEmpty(push_path).empty());
  std::remove(push_path.c_str());

  exporter.ResetForNewRequest();
  exporter.Cancel();  // begin→run window: must abort the run
  EXPECT_EQ(exporter.EncodePush(config, push_path, PushElements(kSourceFrames)),
            -99);
  EXPECT_TRUE(ReadFileOrEmpty(push_path).empty())
      << "output survived a pre-run cancel";
}

}  // namespace
