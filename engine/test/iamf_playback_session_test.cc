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

// Tests for IamfPlaybackSession + IamfRingSource against a real
// two-AE fixture.
//
// Fixture: engine/test/fixtures/tones_100ms_3OA_stereo_opus.iamf —
// roughly 100 ms of tones, two Audio Elements:
//   AE 0: 3rd-order ambisonics (scene-based, 16 channels)
//   AE 1: stereo (channel-based, 2 channels)
//
// The tests don't assert on exact frame counts (pre-skip / end-trim
// varies by upstream generation); they verify the coordination
// behaviour: two ring sources sharing one session, consistent seek,
// drain-in-lockstep reads, EOF, and the WavReader-shaped surface on
// the ring source.

#include "iamf/iamf_playback_session.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#include "graph/audio_buffer.h"
#include "gtest/gtest.h"
#include "iamf/iamf_ring_source.h"
#include "iamf/pcm_ring.h"

namespace {

constexpr uint32_t kExpectedSampleRate = 48000;
constexpr uint32_t kExpectedAeCount = 2;
constexpr uint32_t kMaxFrames = 4096;

// AE kind constants matching IamfPlaybackSession::AeInfo::kind.
constexpr int32_t kKindChannel = 0;
constexpr int32_t kKindScene = 1;

std::string FindFixture(const char* name) {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir == nullptr) srcdir = ".";
  const std::string candidates[] = {
      std::string(srcdir) + "/_main/test/fixtures/" + name,
      std::string(srcdir) + "/_main/engine/test/fixtures/" + name,
      std::string(srcdir) + "/eclipsa_studio_engine/test/fixtures/" + name,
      std::string("test/fixtures/") + name,
      std::string("engine/test/fixtures/") + name,
  };
  for (const auto& c : candidates) {
    std::ifstream probe(c, std::ios::binary);
    if (probe) return c;
  }
  return {};
}

std::vector<uint8_t> LoadFixture(const char* name) {
  const std::string path = FindFixture(name);
  if (path.empty()) return {};
  std::ifstream in(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

struct ScratchBuffer {
  explicit ScratchBuffer(uint32_t ch) : storage(ch * kMaxFrames, 0.0f) {
    buf.data = storage.data();
    buf.channels = ch;
    buf.capacity_frames = kMaxFrames;
    buf.frames = 0;
  }
  std::vector<float> storage;
  AudioBuffer buf;
};

constexpr char kTwoAeFixture[] = "tones_100ms_3OA_stereo_opus.iamf";

// Default timeout (ms) for `wait_for_buffered` calls in these
// tests. The I/O thread fills rings asynchronously, so reads issued
// immediately after `open()` race with the pump. 2 s is plenty for
// the 100 ms fixture even on a loaded build machine.
constexpr uint32_t kBufferTimeoutMs = 2000;

// Helpers to locate each AE by kind (fixture's AE ordering is not
// guaranteed and varies by how upstream generated the file).
uint32_t FindAeIndexByKind(const IamfPlaybackSession& session, int32_t kind) {
  for (uint32_t i = 0; i < session.num_audio_elements(); ++i) {
    if (session.ae_info(i).kind == kind) return i;
  }
  return UINT32_MAX;
}

TEST(IamfPlaybackSessionTest, OpensAndExposesDescriptors) {
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty()) << "fixture missing";

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()))
      << session.last_error();
  EXPECT_TRUE(session.is_open());
  EXPECT_EQ(session.sample_rate(), kExpectedSampleRate);
  EXPECT_EQ(session.num_audio_elements(), kExpectedAeCount);
  // Open is lazy under the new upstream API: total_frames is published
  // asynchronously by the temporal-unit scan worker. Block until the
  // scan finishes before asserting on duration.
  ASSERT_TRUE(session.wait_for_scan_complete()) << session.last_error();
  EXPECT_GT(session.total_frames(), 0u);

  // Both AEs should be supported (Phase A covers channel + scene).
  const auto ae0 = session.ae_info(0);
  const auto ae1 = session.ae_info(1);
  EXPECT_TRUE(ae0.supported);
  EXPECT_TRUE(ae1.supported);

  // Exactly one channel AE and one scene AE in this fixture.
  const uint32_t channel_idx = FindAeIndexByKind(session, kKindChannel);
  const uint32_t scene_idx = FindAeIndexByKind(session, kKindScene);
  ASSERT_NE(channel_idx, UINT32_MAX);
  ASSERT_NE(scene_idx, UINT32_MAX);
  EXPECT_NE(channel_idx, scene_idx);
  EXPECT_EQ(session.ae_info(channel_idx).num_channels, 2u);  // stereo
  EXPECT_GT(session.ae_info(scene_idx).num_channels, 0u);
}

TEST(IamfPlaybackSessionTest, RejectsEmptyBuffer) {
  IamfPlaybackSession session;
  EXPECT_FALSE(session.open_from_memory(nullptr, 0));
  EXPECT_FALSE(session.is_open());
  EXPECT_NE(session.last_error().find("invalid_argument:"), std::string::npos);
}

TEST(IamfPlaybackSessionTest, RejectsMalformedBuffer) {
  const std::vector<uint8_t> garbage = {0xDE, 0xAD, 0xBE, 0xEF};
  IamfPlaybackSession session;
  EXPECT_FALSE(session.open_from_memory(garbage.data(), garbage.size()));
  EXPECT_FALSE(session.is_open());
  EXPECT_FALSE(session.last_error().empty());
}

TEST(IamfRingSourceTest, AttachSurfaceMatchesAe) {
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty());

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()));

  const uint32_t channel_idx = FindAeIndexByKind(session, kKindChannel);
  ASSERT_NE(channel_idx, UINT32_MAX);

  IamfRingSource stereo;
  ASSERT_TRUE(stereo.attach(&session, channel_idx));
  EXPECT_EQ(stereo.channels(), 2u);
  EXPECT_EQ(stereo.sample_rate(), kExpectedSampleRate);
  EXPECT_EQ(stereo.total_frames(), session.total_frames());
  EXPECT_EQ(stereo.cursor(), 0u);
  EXPECT_EQ(stereo.ae_index(), channel_idx);

  IamfRingSource scene;
  ASSERT_TRUE(scene.attach(&session, FindAeIndexByKind(session, kKindScene)));
  EXPECT_GT(scene.channels(), 0u);

  IamfRingSource too_far;
  EXPECT_FALSE(too_far.attach(&session, 99));
  EXPECT_FALSE(too_far.is_attached());
}

TEST(IamfRingSourceTest, TwoSourcesDrainInLockstep) {
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty());

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()));

  IamfRingSource s0, s1;
  ASSERT_TRUE(s0.attach(&session, 0));
  ASSERT_TRUE(s1.attach(&session, 1));

  ScratchBuffer s0_out(s0.channels());
  ScratchBuffer s1_out(s1.channels());

  const uint32_t want = 1500;  // crosses Opus TU boundary (960)
  ASSERT_TRUE(session.wait_for_buffered(0, want, kBufferTimeoutMs));
  ASSERT_TRUE(session.wait_for_buffered(1, want, kBufferTimeoutMs));
  const uint32_t got0 = s0.read(s0_out.buf, want);
  const uint32_t got1 = s1.read(s1_out.buf, want);
  EXPECT_EQ(got0, want);
  EXPECT_EQ(got1, want);
  EXPECT_EQ(s0.cursor(), want);
  EXPECT_EQ(s1.cursor(), want);
}

TEST(IamfRingSourceTest, InterleavedReadsShareDecoder) {
  // Alternate differently-sized small reads between the two sources;
  // neither should starve, and the underlying session should pump
  // TUs and buffer per-AE as needed.
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty());

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()));

  IamfRingSource s0, s1;
  ASSERT_TRUE(s0.attach(&session, 0));
  ASSERT_TRUE(s1.attach(&session, 1));

  ScratchBuffer s0_out(s0.channels());
  ScratchBuffer s1_out(s1.channels());

  // Pre-fill enough for the full sequence (5 × 300 and 5 × 400).
  ASSERT_TRUE(session.wait_for_buffered(0, 5u * 300u, kBufferTimeoutMs));
  ASSERT_TRUE(session.wait_for_buffered(1, 5u * 400u, kBufferTimeoutMs));

  uint64_t total0 = 0, total1 = 0;
  for (int i = 0; i < 5; ++i) {
    total0 += s0.read(s0_out.buf, 300);
    total1 += s1.read(s1_out.buf, 400);
  }
  EXPECT_EQ(total0, 5u * 300u);
  EXPECT_EQ(total1, 5u * 400u);
}

TEST(IamfRingSourceTest, SeekMovesAllSources) {
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty());

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()));
  ASSERT_TRUE(session.wait_for_scan_complete()) << session.last_error();
  const uint64_t total = session.total_frames();
  ASSERT_GT(total, 2000u);

  IamfRingSource s0, s1;
  ASSERT_TRUE(s0.attach(&session, 0));
  ASSERT_TRUE(s1.attach(&session, 1));

  ScratchBuffer s0_out(s0.channels());
  ScratchBuffer s1_out(s1.channels());
  ASSERT_TRUE(session.wait_for_buffered(0, 300u, kBufferTimeoutMs));
  ASSERT_TRUE(session.wait_for_buffered(1, 300u, kBufferTimeoutMs));
  ASSERT_EQ(s0.read(s0_out.buf, 300), 300u);
  ASSERT_EQ(s1.read(s1_out.buf, 300), 300u);

  const uint64_t target = total / 2;
  // Seek via one source repositions the shared decoder; the sibling
  // should still decode from the new position.
  ASSERT_TRUE(s0.seek(target)) << session.last_error();
  EXPECT_EQ(s0.cursor(), target);
  // Wait for the I/O thread to refill from the new position before
  // asserting the sibling can read.
  ASSERT_TRUE(session.wait_for_buffered(1, 256u, kBufferTimeoutMs));
  EXPECT_GT(s1.read(s1_out.buf, 256), 0u);
}

TEST(IamfPlaybackSessionTest, ReachesEofAndRefusesFurtherPumps) {
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty());

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()));
  ASSERT_TRUE(session.wait_for_scan_complete()) << session.last_error();
  const uint64_t total = session.total_frames();

  IamfRingSource s0, s1;
  ASSERT_TRUE(s0.attach(&session, 0));
  ASSERT_TRUE(s1.attach(&session, 1));

  ScratchBuffer s0_out(s0.channels());
  ScratchBuffer s1_out(s1.channels());

  // Drain both rings to completion. With the I/O-thread architecture,
  // a `read()` of 0 may simply mean "consumer caught up to producer";
  // wait briefly for the next pump before declaring EOF. Use the
  // session's `wait_for_buffered` which returns once the ring sees
  // EOF or has more data.
  uint64_t total0 = 0, total1 = 0;
  for (int spins = 0; spins < 10000; ++spins) {
    const uint32_t g0 = s0.read(s0_out.buf, kMaxFrames);
    const uint32_t g1 = s1.read(s1_out.buf, kMaxFrames);
    total0 += g0;
    total1 += g1;
    if (g0 == 0 && g1 == 0) {
      const bool eof_or_more_0 = session.wait_for_buffered(0, 1, 200);
      const bool eof_or_more_1 = session.wait_for_buffered(1, 1, 200);
      if (!eof_or_more_0 && !eof_or_more_1) break;
      if (session.buffered_frames(0) == 0 && session.buffered_frames(1) == 0) {
        break;
      }
    }
  }
  EXPECT_EQ(total0, total);
  EXPECT_EQ(total1, total);
  EXPECT_EQ(s0.read(s0_out.buf, kMaxFrames), 0u);
  EXPECT_EQ(s1.read(s1_out.buf, kMaxFrames), 0u);
}

TEST(IamfPlaybackSessionTest, SeekClearsEofPoisoning) {
  // After draining the whole stream, a seek back to 0 should reopen
  // the data path.
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty());

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()));

  IamfRingSource source;
  ASSERT_TRUE(source.attach(&session, 0));
  ScratchBuffer out(source.channels());
  // Drain to EOF, tolerating transient empty reads while the I/O
  // thread is mid-pump.
  for (int spins = 0; spins < 10000; ++spins) {
    const uint32_t g = source.read(out.buf, kMaxFrames);
    if (g == 0) {
      session.wait_for_buffered(0, 1, 200);
      if (session.buffered_frames(0) == 0) break;
    }
  }

  ASSERT_TRUE(source.seek(0));
  ASSERT_TRUE(session.wait_for_buffered(0, 512, kBufferTimeoutMs));
  const uint32_t got = source.read(out.buf, 512);
  EXPECT_GT(got, 0u);
}

// Blocks until the I/O thread has applied every posted seek.
bool WaitForSeeksApplied(const IamfPlaybackSession& session) {
  for (int i = 0; i < 2000; ++i) {
    if (session.seeks_applied() == session.seeks_requested()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return false;
}

// Reads exactly `frames` frames from `source` into `out`, waiting for the
// I/O thread as needed. Returns the frames read.
uint32_t ReadExactly(IamfPlaybackSession& session, IamfRingSource& source,
                     uint32_t frames, std::vector<float>* out) {
  ScratchBuffer scratch(source.channels());
  uint32_t total = 0;
  while (total < frames) {
    const uint32_t want = std::min(frames - total, kMaxFrames);
    if (!session.wait_for_buffered(source.ae_index(), want, kBufferTimeoutMs)) {
      break;
    }
    const uint32_t got = source.read(scratch.buf, want);
    for (uint32_t c = 0; c < source.channels(); ++c) {
      const float* ch = scratch.buf.channel(c);
      out->insert(out->end(), ch, ch + got);
    }
    total += got;
    if (got == 0) break;
  }
  return total;
}

// A seek to a frame the rings still hold is served from them (ES-920): the
// stream is not repositioned, and the frames read after it are the ones a
// straight read reaches at that position.
TEST(IamfPlaybackSessionTest, SeekWithinRingsKeepsBufferedAudio) {
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty());

  // Reference: read 600 frames, then the 256 at [600, 856).
  IamfPlaybackSession reference;
  ASSERT_TRUE(reference.open_from_memory(bytes.data(), bytes.size()));
  IamfRingSource ref_source;
  ASSERT_TRUE(ref_source.attach(&reference, 0));
  std::vector<float> skipped;
  ASSERT_EQ(ReadExactly(reference, ref_source, 600, &skipped), 600u);
  std::vector<float> expected;
  ASSERT_EQ(ReadExactly(reference, ref_source, 256, &expected), 256u);

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()));
  IamfRingSource source;
  ASSERT_TRUE(source.attach(&session, 0));
  std::vector<float> first;
  ASSERT_EQ(ReadExactly(session, source, 300, &first), 300u);
  ASSERT_TRUE(session.wait_for_buffered(0, 1024, kBufferTimeoutMs));

  // Forward within the buffered frames, then to the consumer's own
  // position: both from the rings.
  ASSERT_TRUE(source.seek(600));
  ASSERT_TRUE(WaitForSeeksApplied(session));
  EXPECT_EQ(session.seeks_served_from_rings(), 1u);
  EXPECT_TRUE(session.last_error().empty()) << session.last_error();
  ASSERT_TRUE(source.seek(600));
  ASSERT_TRUE(WaitForSeeksApplied(session));
  EXPECT_EQ(session.seeks_served_from_rings(), 2u);

  std::vector<float> actual;
  ASSERT_EQ(ReadExactly(session, source, 256, &actual), 256u);
  EXPECT_EQ(actual, expected);

  // Back past what the consumer has read: the rings no longer hold it, so
  // the stream seeks.
  ASSERT_TRUE(source.seek(0));
  ASSERT_TRUE(WaitForSeeksApplied(session));
  EXPECT_EQ(session.seeks_served_from_rings(), 2u);
  std::vector<float> restart;
  ASSERT_EQ(ReadExactly(session, source, 300, &restart), 300u);
  EXPECT_EQ(restart, first);
}

// After the pump reaches the end of the stream, a seek back into the frames
// the rings still hold is served from them and leaves the rings at EOF, so
// exactly the frames up to the end are readable and the prime check does
// not wait for a refill that never comes.
TEST(IamfPlaybackSessionTest, SeekWithinRingsAfterEndKeepsEof) {
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty());

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()));
  ASSERT_TRUE(session.wait_for_scan_complete()) << session.last_error();
  const uint64_t total = session.total_frames();
  ASSERT_GT(total, 2000u);
  // The 100 ms fixture fits the ring, so the pump reaches the end.
  for (int i = 0; i < 2000 && !session.ring(0)->eof(); ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  ASSERT_TRUE(session.ring(0)->eof());

  IamfRingSource source;
  ASSERT_TRUE(source.attach(&session, 0));
  ASSERT_TRUE(source.seek(total - 1000));
  ASSERT_TRUE(WaitForSeeksApplied(session));
  EXPECT_EQ(session.seeks_served_from_rings(), 1u);
  EXPECT_TRUE(session.last_error().empty()) << session.last_error();
  for (uint32_t i = 0; i < session.num_audio_elements(); ++i) {
    EXPECT_TRUE(session.ring(i)->eof()) << "AE " << i;
    EXPECT_EQ(session.buffered_frames(i), 1000u) << "AE " << i;
  }
}

// A seek to the end of a stream with a known duration empties the rings
// and marks them at end of stream, without an error (ES-921).
TEST(IamfPlaybackSessionTest, SeekToEndIsEndOfStreamNotAnError) {
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty());

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()));
  ASSERT_TRUE(session.wait_for_scan_complete()) << session.last_error();
  const uint64_t total = session.total_frames();
  ASSERT_GT(total, 0u);

  ASSERT_TRUE(session.seek_to_frame(total));
  ASSERT_TRUE(WaitForSeeksApplied(session));
  EXPECT_TRUE(session.last_error().empty()) << session.last_error();
  // Handled as end of stream, not replayed from the rings.
  EXPECT_EQ(session.seeks_served_from_rings(), 0u);
  for (uint32_t i = 0; i < session.num_audio_elements(); ++i) {
    EXPECT_EQ(session.buffered_frames(i), 0u) << "AE " << i;
    EXPECT_TRUE(session.ring(i)->eof()) << "AE " << i;
  }

  // A later seek back restarts the pump.
  IamfRingSource source;
  ASSERT_TRUE(source.attach(&session, 0));
  ASSERT_TRUE(source.seek(0));
  ASSERT_TRUE(WaitForSeeksApplied(session));
  std::vector<float> frames;
  EXPECT_EQ(ReadExactly(session, source, 256, &frames), 256u);
}

TEST(IamfPlaybackSessionTest, LatestMixGainTracksPump) {
  // Mix-gain values themselves are fixture-specific; we verify the
  // getter exposes finite values once the I/O thread has pumped at
  // least one TU.
  const auto bytes = LoadFixture(kTwoAeFixture);
  ASSERT_FALSE(bytes.empty());

  IamfPlaybackSession session;
  ASSERT_TRUE(session.open_from_memory(bytes.data(), bytes.size()));

  IamfRingSource source;
  ASSERT_TRUE(source.attach(&session, 0));
  ScratchBuffer out(source.channels());
  ASSERT_TRUE(session.wait_for_buffered(0, 128, kBufferTimeoutMs));
  ASSERT_GT(source.read(out.buf, 128), 0u);

  EXPECT_TRUE(std::isfinite(session.latest_mix_gain_db(0)));
  EXPECT_TRUE(std::isfinite(session.latest_mix_gain_db(1)));
}

}  // namespace
