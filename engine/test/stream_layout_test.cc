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

#include "io/stream_layout.h"

#include <cstdint>
#include <vector>

#include "gtest/gtest.h"

namespace {

using stream_layout::MakeStreamLayout;
using stream_layout::ScatterToStreams;
using stream_layout::StreamLayout;

// The MOTU MicroBook II shape that motivated the CoreAudio backend
// (ES-334): four stereo streams covering eight device channels.
TEST(MakeStreamLayout, MicroBookFourStereoStreams) {
  const StreamLayout layout = MakeStreamLayout({2, 2, 2, 2});
  EXPECT_EQ(layout.total, 8u);
  EXPECT_EQ(layout.offsets, (std::vector<uint32_t>{0, 2, 4, 6}));
  EXPECT_EQ(layout.counts, (std::vector<uint32_t>{2, 2, 2, 2}));
}

// Single interleaved multichannel stream — the common case (built-in
// output, aggregates) degenerates to offset 0 / total == count.
TEST(MakeStreamLayout, SingleStream) {
  const StreamLayout layout = MakeStreamLayout({12});
  EXPECT_EQ(layout.total, 12u);
  EXPECT_EQ(layout.offsets, (std::vector<uint32_t>{0}));
}

// Mixed stream widths keep a running channel offset, and zero-channel
// streams hold their slot without advancing it, so stream indices stay
// aligned with the device's stream list.
TEST(MakeStreamLayout, MixedWidthsAndZeroChannelStream) {
  const StreamLayout layout = MakeStreamLayout({2, 0, 6, 1});
  EXPECT_EQ(layout.total, 9u);
  EXPECT_EQ(layout.offsets, (std::vector<uint32_t>{0, 2, 2, 8}));
}

TEST(MakeStreamLayout, EmptyIsZeroTotal) {
  const StreamLayout layout = MakeStreamLayout({});
  EXPECT_EQ(layout.total, 0u);
  EXPECT_TRUE(layout.offsets.empty());
}

// Scatter must be a bit-exact redistribution: every interleaved source
// sample lands at the right (stream, frame, channel) slot.
TEST(ScatterToStreams, RoundTripsInterleavedSamples) {
  const StreamLayout layout = MakeStreamLayout({2, 2});
  const uint32_t frames = 3;
  // src[f * 4 + ch] = ch * 100 + f, unique per slot.
  std::vector<float> src(frames * layout.total);
  for (uint32_t f = 0; f < frames; ++f) {
    for (uint32_t ch = 0; ch < layout.total; ++ch) {
      src[f * layout.total + ch] = static_cast<float>(ch * 100 + f);
    }
  }
  std::vector<float> stream0(frames * 2, -1.0f);
  std::vector<float> stream1(frames * 2, -1.0f);
  float* dsts[] = {stream0.data(), stream1.data()};

  ScatterToStreams(src.data(), frames, layout, dsts);

  for (uint32_t f = 0; f < frames; ++f) {
    // Stream 0 carries device channels 0-1, stream 1 channels 2-3.
    EXPECT_EQ(stream0[f * 2 + 0], static_cast<float>(0 * 100 + f));
    EXPECT_EQ(stream0[f * 2 + 1], static_cast<float>(1 * 100 + f));
    EXPECT_EQ(stream1[f * 2 + 0], static_cast<float>(2 * 100 + f));
    EXPECT_EQ(stream1[f * 2 + 1], static_cast<float>(3 * 100 + f));
  }
}

// A null destination (stream buffer rejected at callback time, e.g.
// undersized) is skipped without disturbing the other streams.
TEST(ScatterToStreams, SkipsNullDestinations) {
  const StreamLayout layout = MakeStreamLayout({2, 2});
  const uint32_t frames = 2;
  std::vector<float> src(frames * layout.total, 7.0f);
  std::vector<float> stream1(frames * 2, -1.0f);
  float* dsts[] = {nullptr, stream1.data()};

  ScatterToStreams(src.data(), frames, layout, dsts);

  for (float v : stream1) EXPECT_EQ(v, 7.0f);
}

}  // namespace
