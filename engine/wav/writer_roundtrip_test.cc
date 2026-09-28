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

//
// Writer → Reader round-trips: for every output format, write the reference
// ramp and read it back sample-exactly (bit-exactly for float32). Also the
// metadata chunks, the extensible-fmt policy, the valid-file-on-Flush
// contract and the trailing pad byte.

#include <cstdint>
#include <fstream>
#include <limits>
#include <string>
#include <utility>
#include <vector>

#include "gtest/gtest.h"
#include "wav/reader.h"
#include "wav/testing/fixture.h"
#include "wav/types.h"
#include "wav/writer.h"

namespace wav {
namespace {

namespace wt = wav::testing;

// Planar float input whose values are exact dequantized codes for the
// target depth, so the write → read trip must reproduce them exactly.
std::vector<std::vector<float>> RampInput(SampleFormat target,
                                          uint16_t channels, uint32_t frames,
                                          uint32_t start_frame = 0) {
  std::vector<std::vector<float>> in(channels);
  for (uint16_t c = 0; c < channels; ++c) {
    in[c].resize(frames);
    for (uint32_t n = 0; n < frames; ++n) {
      in[c][n] = wt::ExpectedFloat(target, start_frame + n, c);
    }
  }
  return in;
}

TEST(WriterRoundTrip, EveryFormatAndChannelCountIsSampleExact) {
  const WriteFormat formats[] = {WriteFormat::kPcm16, WriteFormat::kPcm24,
                                 WriteFormat::kPcm32, WriteFormat::kFloat32};
  const uint16_t channel_counts[] = {1, 2, 6, 16};
  int idx = 0;
  for (const WriteFormat wf : formats) {
    for (const uint16_t channels : channel_counts) {
      const SampleFormat sf = ToSampleFormat(wf);
      SCOPED_TRACE(std::string(SampleFormatName(sf)) + "/" +
                   std::to_string(channels) + "ch");
      const std::string path =
          wt::TempDir() + "/roundtrip_" + std::to_string(idx++) + ".wav";

      WriterOptions opt;
      opt.channels = channels;
      opt.sample_rate = 48000;
      opt.format = wf;
      auto w = Writer::Create(path, opt);
      ASSERT_TRUE(w.ok()) << w.error();

      // Two pushes, splitting mid-stream, to exercise chunked appends.
      const auto head = RampInput(sf, channels, 30, 0);
      const auto tail = RampInput(sf, channels, 18, 30);
      ASSERT_TRUE(w->PushPlanarFloat(head).ok());
      ASSERT_TRUE(w->PushPlanarFloat(tail).ok());
      EXPECT_EQ(w->frames_written(), 48u);
      ASSERT_TRUE(w->Finalize().ok());

      auto r = Reader::Open(path);
      ASSERT_TRUE(r.ok()) << r.error();
      const Info& info = r->info();
      EXPECT_EQ(info.container, Container::kRiff);
      EXPECT_EQ(info.format, sf);
      EXPECT_EQ(info.channels, channels);
      EXPECT_EQ(info.sample_rate, 48000u);
      EXPECT_EQ(info.num_frames, 48u);
      EXPECT_EQ(info.extensible, channels > 2);
      // No caller-supplied mask -> mask 0 ("unspecified"), never a
      // guessed loudspeaker layout: a 4/6-channel render can as easily
      // be ambisonic as quad/5.1.
      EXPECT_EQ(info.channel_mask, 0u);

      std::vector<std::vector<float>> out;
      auto n = r->ReadPlanarFloat(0, 48, out);
      ASSERT_TRUE(n.ok()) << n.error();
      ASSERT_EQ(*n, 48u);
      const auto want = RampInput(sf, channels, 48, 0);
      for (uint16_t c = 0; c < channels; ++c) {
        for (uint32_t i = 0; i < 48; ++i) {
          ASSERT_EQ(out[c][i], want[c][i]) << "frame " << i << " channel " << c;
        }
      }
    }
  }
}

TEST(WriterRoundTrip, PushLeftJustifiedInt32IsExact) {
  const std::string path = wt::TempDir() + "/roundtrip_lj.wav";
  WriterOptions opt;
  opt.channels = 2;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm24;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();

  // 24-bit-aligned left-justified codes convert exactly.
  std::vector<std::vector<int32_t>> in(2);
  for (uint16_t c = 0; c < 2; ++c) {
    in[c].resize(48);
    for (uint32_t n = 0; n < 48; ++n) {
      in[c][n] = wt::ExpectedInt32Lj(SampleFormat::kInt24, n, c);
    }
  }
  ASSERT_TRUE(w->PushPlanarInt32LeftJustified(in).ok());
  ASSERT_TRUE(w->Finalize().ok());

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  std::vector<std::vector<int32_t>> out;
  auto n = r->ReadPlanarInt32LeftJustified(0, 48, out);
  ASSERT_TRUE(n.ok());
  ASSERT_EQ(*n, 48u);
  EXPECT_EQ(out, in);
}

TEST(WriterRoundTrip, LeftJustifiedInputRoundsAndClamps) {
  const std::string path = wt::TempDir() + "/roundtrip_lj_round.wav";
  WriterOptions opt;
  opt.channels = 1;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm16;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();

  const std::vector<std::vector<int32_t>> in = {
      {(5 << 16) + 0x8000, (5 << 16) + 0x7FFF,
       std::numeric_limits<int32_t>::max(),
       std::numeric_limits<int32_t>::min()}};
  ASSERT_TRUE(w->PushPlanarInt32LeftJustified(in).ok());
  ASSERT_TRUE(w->Finalize().ok());

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  std::vector<std::vector<int32_t>> out;
  ASSERT_TRUE(r->ReadPlanarInt32LeftJustified(0, 4, out).ok());
  EXPECT_EQ(out[0][0], 6 << 16);      // Half-LSB rounds up.
  EXPECT_EQ(out[0][1], 5 << 16);      // Below half rounds down.
  EXPECT_EQ(out[0][2], 32767 << 16);  // Positive edge clamps.
  EXPECT_EQ(out[0][3], std::numeric_limits<int32_t>::min());
}

TEST(WriterRoundTrip, MetadataChunksRoundTrip) {
  const std::string path = wt::TempDir() + "/roundtrip_metadata.wav";
  WriterOptions opt;
  opt.channels = 2;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm16;
  opt.metadata.axml = wt::kFixtureAxml();
  opt.metadata.chna = wt::FixtureChna();
  opt.metadata.bext = wt::FixtureBext();
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();
  ASSERT_TRUE(w->PushPlanarFloat(RampInput(SampleFormat::kInt16, 2, 48)).ok());
  ASSERT_TRUE(w->Finalize().ok());

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  // Small file with kAuto policy: stays plain RIFF, metadata intact.
  EXPECT_EQ(r->info().container, Container::kRiff);
  EXPECT_EQ(r->axml(), wt::kFixtureAxml());
  EXPECT_EQ(r->chna(), wt::FixtureChna());
  EXPECT_EQ(r->bext(), wt::FixtureBext());
  // Layout: JUNK placeholder, then metadata, then fmt/data.
  ASSERT_EQ(r->chunks().size(), 6u);
  EXPECT_EQ(r->chunks()[0].id, "JUNK");
  EXPECT_EQ(r->chunks()[1].id, "bext");
  EXPECT_EQ(r->chunks()[2].id, "axml");
  EXPECT_EQ(r->chunks()[3].id, "chna");
  EXPECT_EQ(r->chunks()[4].id, "fmt ");
  EXPECT_EQ(r->chunks()[5].id, "data");
}

TEST(WriterRoundTrip, ForcedContainersStartAs64Bit) {
  for (const auto policy : {WriterOptions::ContainerPolicy::kRf64,
                            WriterOptions::ContainerPolicy::kBw64}) {
    const bool bw64 = policy == WriterOptions::ContainerPolicy::kBw64;
    const std::string path = wt::TempDir() + "/roundtrip_forced_" +
                             (bw64 ? std::string("bw64") : "rf64") + ".wav";
    WriterOptions opt;
    opt.channels = 1;
    opt.sample_rate = 44100;
    opt.format = WriteFormat::kPcm16;
    opt.container = policy;
    if (bw64) opt.metadata.axml = wt::kFixtureAxml();
    auto w = Writer::Create(path, opt);
    ASSERT_TRUE(w.ok()) << w.error();
    EXPECT_EQ(w->container(), bw64 ? Container::kBw64 : Container::kRf64);
    ASSERT_TRUE(
        w->PushPlanarFloat(RampInput(SampleFormat::kInt16, 1, 48)).ok());
    ASSERT_TRUE(w->Finalize().ok());

    auto r = Reader::Open(path);
    ASSERT_TRUE(r.ok()) << r.error();
    EXPECT_EQ(r->info().container, bw64 ? Container::kBw64 : Container::kRf64);
    EXPECT_EQ(r->info().num_frames, 48u);
    ASSERT_FALSE(r->chunks().empty());
    EXPECT_EQ(r->chunks()[0].id, "ds64");
    if (bw64) EXPECT_EQ(r->axml(), wt::kFixtureAxml());
  }
}

TEST(WriterRoundTrip, FileIsValidAfterEveryFlush) {
  const std::string path = wt::TempDir() + "/roundtrip_flush.wav";
  WriterOptions opt;
  opt.channels = 2;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kFloat32;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();

  ASSERT_TRUE(
      w->PushPlanarFloat(RampInput(SampleFormat::kFloat32, 2, 100)).ok());
  ASSERT_TRUE(w->Flush().ok());
  {
    auto r = Reader::Open(path);
    ASSERT_TRUE(r.ok()) << r.error();
    EXPECT_EQ(r->info().num_frames, 100u);
    std::vector<std::vector<float>> out;
    ASSERT_TRUE(r->ReadPlanarFloat(0, 100, out).ok());
    EXPECT_EQ(out[0][99], wt::ExpectedFloat(SampleFormat::kFloat32, 99, 0));
  }

  ASSERT_TRUE(
      w->PushPlanarFloat(RampInput(SampleFormat::kFloat32, 2, 50, 100)).ok());
  ASSERT_TRUE(w->Finalize().ok());
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_EQ(r->info().num_frames, 150u);
  std::vector<std::vector<float>> out;
  ASSERT_TRUE(r->ReadPlanarFloat(0, 150, out).ok());
  EXPECT_EQ(out[1][149], wt::ExpectedFloat(SampleFormat::kFloat32, 149, 1));
}

TEST(WriterRoundTrip, OddDataSizeGetsPadByte) {
  const std::string path = wt::TempDir() + "/roundtrip_odd.wav";
  WriterOptions opt;
  opt.channels = 1;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm24;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();
  // 33 mono 24-bit frames → 99 data bytes, odd.
  ASSERT_TRUE(w->PushPlanarFloat(RampInput(SampleFormat::kInt24, 1, 33)).ok());
  ASSERT_TRUE(w->Finalize().ok());

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  ASSERT_EQ(r->info().num_frames, 33u);
  std::vector<std::vector<float>> out;
  ASSERT_TRUE(r->ReadPlanarFloat(0, 33, out).ok());
  EXPECT_EQ(out[0][32], wt::ExpectedFloat(SampleFormat::kInt24, 32, 0));
}

TEST(WriterRoundTrip, ZeroFrameFileIsValid) {
  const std::string path = wt::TempDir() + "/roundtrip_zero.wav";
  WriterOptions opt;
  opt.channels = 2;
  opt.sample_rate = 96000;
  opt.format = WriteFormat::kPcm32;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();
  ASSERT_TRUE(w->Finalize().ok());

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_EQ(r->info().num_frames, 0u);
  EXPECT_EQ(r->info().sample_rate, 96000u);
}

TEST(WriterRoundTrip, ExplicitChannelMaskForcesExtensible) {
  const std::string path = wt::TempDir() + "/roundtrip_mask.wav";
  WriterOptions opt;
  opt.channels = 2;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm16;
  opt.channel_mask = 0x3;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();
  ASSERT_TRUE(w->PushPlanarFloat(RampInput(SampleFormat::kInt16, 2, 8)).ok());
  ASSERT_TRUE(w->Finalize().ok());

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_TRUE(r->info().extensible);
  EXPECT_EQ(r->info().channel_mask, 0x3u);
}

TEST(WriterRoundTrip, InvalidOptionsAndUsageAreErrors) {
  WriterOptions opt;
  opt.channels = 0;
  opt.sample_rate = 48000;
  EXPECT_FALSE(Writer::Create(wt::TempDir() + "/bad.wav", opt).ok());

  opt.channels = 2;
  opt.sample_rate = 0;
  EXPECT_FALSE(Writer::Create(wt::TempDir() + "/bad.wav", opt).ok());

  // nBlockAlign is u16: 30000 channels of 32-bit PCM cannot be expressed
  // and must be rejected instead of silently wrapping the fmt fields.
  opt.channels = 30000;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm32;
  EXPECT_FALSE(Writer::Create(wt::TempDir() + "/bad.wav", opt).ok());
  opt.format = WriteFormat::kPcm16;

  opt.sample_rate = 48000;
  auto w = Writer::Create(wt::TempDir() + "/usage.wav", opt);
  ASSERT_TRUE(w.ok());
  // Ragged / mismatched channel vectors.
  EXPECT_FALSE(w->PushPlanarFloat({{0.0f}}).ok());
  EXPECT_FALSE(w->PushPlanarFloat({{0.0f}, {0.0f, 0.1f}}).ok());
  ASSERT_TRUE(w->Finalize().ok());
  // Everything after Finalize fails.
  EXPECT_FALSE(w->PushPlanarFloat({{0.0f}, {0.0f}}).ok());
  EXPECT_FALSE(w->Flush().ok());
  EXPECT_TRUE(w->Finalize().ok());  // Finalize itself is idempotent.
}

TEST(WriterRoundTrip, Float32PushSanitizesNonFinite) {
  // The kFloat32 path copies bits to disk with no quantizer in between,
  // but the sanitize contract (NaN -> 0, ±inf saturated to ±FLT_MAX)
  // still applies: one NaN in a bounce would otherwise permanently
  // poison the deliverable. The reader also sanitizes on decode, which
  // would mask a writer bug — so this checks the raw on-disk bytes.
  const std::string path = wt::TempDir() + "/float32_nonfinite.wav";
  WriterOptions opt;
  opt.channels = 1;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kFloat32;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();
  const float nan = std::numeric_limits<float>::quiet_NaN();
  const float inf = std::numeric_limits<float>::infinity();
  ASSERT_TRUE(w->PushPlanarFloat({{nan, inf, -inf, 0.5f}}).ok());
  ASSERT_TRUE(w->Finalize().ok());

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  ASSERT_EQ(r->info().num_frames, 4u);

  std::ifstream file(path, std::ios::binary);
  ASSERT_TRUE(file.good());
  file.seekg(static_cast<std::streamoff>(r->data_offset()));
  float on_disk[4] = {};
  file.read(reinterpret_cast<char*>(on_disk), sizeof(on_disk));
  ASSERT_TRUE(file.good());
  EXPECT_EQ(on_disk[0], 0.0f);  // NaN -> 0
  EXPECT_EQ(on_disk[1], std::numeric_limits<float>::max());
  EXPECT_EQ(on_disk[2], -std::numeric_limits<float>::max());
  EXPECT_EQ(on_disk[3], 0.5f);
}

TEST(WriterRoundTrip, MoveConstructionTransfersOwnership) {
  const std::string path = wt::TempDir() + "/roundtrip_move.wav";
  WriterOptions opt;
  opt.channels = 1;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm16;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();
  ASSERT_TRUE(w->PushPlanarFloat(RampInput(SampleFormat::kInt16, 1, 8)).ok());

  Writer moved = std::move(*w);
  // The source is inert: pushes fail, Finalize is a no-op success.
  EXPECT_FALSE(w->PushPlanarFloat(RampInput(SampleFormat::kInt16, 1, 1)).ok());
  EXPECT_TRUE(w->Finalize().ok());
  // The destination carries on and produces a valid file.
  ASSERT_TRUE(
      moved.PushPlanarFloat(RampInput(SampleFormat::kInt16, 1, 4, 8)).ok());
  ASSERT_TRUE(moved.Finalize().ok());

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_EQ(r->info().num_frames, 12u);
}

}  // namespace
}  // namespace wav
