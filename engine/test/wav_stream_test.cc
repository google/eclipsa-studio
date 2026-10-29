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

// Tests for WavStream and WavStreamer: the disk thread fills each
// stream's ring, the audio thread reads it and posts seeks (ES-836).
//
// The fixture file carries a distinct value per frame, so every read
// checks which file frame it returned. AudioThreadCallsDoNotAllocate
// counts allocations through the sanitizer malloc hooks
// (test/alloc_counter.h) and runs in the asan and tsan builds only.

#include "io/wav_stream.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "graph/audio_buffer.h"
#include "gtest/gtest.h"
#include "test/alloc_counter.h"
#include "test/test_wav_helper.h"

namespace {

constexpr uint32_t kRate = 48000;
constexpr uint32_t kBlock = 480;
// Three rings and a bit, so the disk thread must refill the ring.
constexpr uint32_t kFileFrames = 3 * WavStream::kRingFrames + 1234;
constexpr auto kTimeout = std::chrono::seconds(5);

// The value of file frame `f`: exact in float32, and distinct for every
// frame below 2^17 (the fixture has kFileFrames < 2^17).
float FrameValue(uint32_t f) {
  return static_cast<float>(f) / 131072.0f - 0.5f;
}
static_assert(kFileFrames < (1u << 17), "FrameValue must stay distinct");

std::string WriteFixture(const std::string& name, int channels) {
  const std::string path = test_wav::temp_dir() + "/" + name;
  std::vector<float> samples(kFileFrames);
  for (uint32_t f = 0; f < kFileFrames; ++f) samples[f] = FrameValue(f);
  EXPECT_TRUE(test_wav::write_float32_frames(path, channels, kRate, samples));
  return path;
}

// Planar destination of `channels` channels and kBlock frames.
struct Block {
  explicit Block(uint32_t channels)
      : storage(static_cast<size_t>(channels) * kBlock, 0.0f) {
    buf.data = storage.data();
    buf.channels = channels;
    buf.capacity_frames = kBlock;
  }
  std::vector<float> storage;
  AudioBuffer buf;
};

// Waits until `stream` is primed with `min_frames`, or the timeout.
bool WaitPrimed(const WavStream& stream, uint32_t min_frames) {
  const auto deadline = std::chrono::steady_clock::now() + kTimeout;
  while (!stream.primed(min_frames)) {
    if (std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return true;
}

// Reads `frames` frames from `stream`, waiting while the disk thread
// catches up, and checks each against the file from `first_frame`.
// Returns the frames read (fewer only at the end of the file).
uint32_t ReadAndCheck(WavStream& stream, uint32_t first_frame,
                      uint32_t frames) {
  Block block(stream.channels());
  uint32_t done = 0;
  const auto deadline = std::chrono::steady_clock::now() + kTimeout;
  while (done < frames) {
    const uint32_t want = std::min(kBlock, frames - done);
    const uint32_t got = stream.read(block.buf, want);
    for (uint32_t c = 0; c < stream.channels(); ++c) {
      for (uint32_t f = 0; f < got; ++f) {
        const uint32_t file_frame = first_frame + done + f;
        if (block.buf.channel(c)[f] != FrameValue(file_frame)) {
          ADD_FAILURE() << "channel " << c << " file frame " << file_frame
                        << ": got " << block.buf.channel(c)[f];
          return done;
        }
      }
    }
    done += got;
    if (got == want) continue;
    if (stream.eof() && stream.read(block.buf, 1) == 0) break;
    if (std::chrono::steady_clock::now() >= deadline) {
      ADD_FAILURE() << "disk thread stalled at " << first_frame + done;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return done;
}

TEST(WavStreamTest, OpenFailsForAMissingFile) {
  WavStream stream;
  EXPECT_FALSE(stream.open("/nonexistent/no.wav", 28));
}

// open() reads the first chunk on the calling thread, before any disk
// thread holds the stream.
TEST(WavStreamTest, OpenReadsTheFirstChunk) {
  const std::string path = WriteFixture("wav_stream_open.wav", 2);
  WavStream stream;
  ASSERT_TRUE(stream.open(path.c_str(), 28));
  EXPECT_EQ(stream.channels(), 2u);
  EXPECT_EQ(stream.sample_rate(), kRate);
  EXPECT_EQ(stream.total_frames(), kFileFrames);
  EXPECT_TRUE(stream.primed(WavStream::kChunkFrames));
  EXPECT_EQ(ReadAndCheck(stream, 0, WavStream::kChunkFrames),
            WavStream::kChunkFrames);
  // Nothing refills it without a WavStreamer.
  Block block(2);
  EXPECT_EQ(stream.read(block.buf, 1), 0u);
  EXPECT_FALSE(stream.eof());
}

// service() applies a pending seek before it reads, and reads at most
// the chunks it is given: a seek waits for one chunk of each other
// stream, not for their whole rings.
TEST(WavStreamTest, ServiceAppliesTheSeekThenReadsAtMostMaxChunks) {
  const std::string path = WriteFixture("wav_stream_service.wav", 1);
  WavStream stream;
  ASSERT_TRUE(stream.open(path.c_str(), 28));
  stream.post_seek_rt(20000);
  EXPECT_FALSE(stream.seek_applied());
  EXPECT_FALSE(stream.primed(1));

  ASSERT_TRUE(stream.service(1));
  EXPECT_TRUE(stream.seek_applied());
  EXPECT_TRUE(stream.primed(WavStream::kChunkFrames));
  EXPECT_FALSE(stream.primed(WavStream::kChunkFrames + 1));
  EXPECT_EQ(ReadAndCheck(stream, 20000, WavStream::kChunkFrames),
            WavStream::kChunkFrames);

  ASSERT_TRUE(stream.service(2));
  EXPECT_TRUE(stream.primed(2 * WavStream::kChunkFrames));
  EXPECT_FALSE(stream.primed(2 * WavStream::kChunkFrames + 1));
}

// The test seam: a stalled stream applies no seek and reads nothing
// until it is released.
TEST(WavStreamTest, StalledStreamIsNotServiced) {
  const std::string path = WriteFixture("wav_stream_stalled.wav", 1);
  WavStream stream;
  ASSERT_TRUE(stream.open(path.c_str(), 28));
  stream.set_stalled_for_testing(true);
  stream.post_seek_rt(20000);
  EXPECT_FALSE(stream.service(1));
  EXPECT_FALSE(stream.seek_applied());
  EXPECT_FALSE(stream.primed(1));

  stream.set_stalled_for_testing(false);
  ASSERT_TRUE(stream.service(1));
  EXPECT_TRUE(stream.seek_applied());
  EXPECT_EQ(ReadAndCheck(stream, 20000, WavStream::kChunkFrames),
            WavStream::kChunkFrames);
}

TEST(WavStreamTest, StreamerDeliversTheWholeFileInOrder) {
  const std::string path = WriteFixture("wav_stream_order.wav", 2);
  auto stream = std::make_shared<WavStream>();
  ASSERT_TRUE(stream->open(path.c_str(), 28));
  WavStreamer streamer;
  streamer.add(stream);
  EXPECT_EQ(ReadAndCheck(*stream, 0, kFileFrames), kFileFrames);
  EXPECT_TRUE(stream->eof());
}

TEST(WavStreamTest, SeekContinuesFromTheTargetAfterTheRefill) {
  const std::string path = WriteFixture("wav_stream_seek.wav", 2);
  auto stream = std::make_shared<WavStream>();
  ASSERT_TRUE(stream->open(path.c_str(), 28));
  WavStreamer streamer;
  streamer.add(stream);
  ASSERT_EQ(ReadAndCheck(*stream, 0, 10 * kBlock), 10 * kBlock);

  // The ring still holds frames from before the seek; primed() turns
  // true only once the disk thread has discarded them and refilled.
  constexpr uint32_t kTarget = 70000;
  stream->post_seek_rt(kTarget);
  ASSERT_TRUE(WaitPrimed(*stream, 1024));
  EXPECT_EQ(ReadAndCheck(*stream, kTarget, 20 * kBlock), 20 * kBlock);

  // Backwards, into the part of the file the ring held at first.
  stream->post_seek_rt(100);
  ASSERT_TRUE(WaitPrimed(*stream, 1024));
  EXPECT_EQ(ReadAndCheck(*stream, 100, 4 * kBlock), 4 * kBlock);
}

// Seeks posted faster than the disk thread applies them coalesce: the
// stream continues from the last target.
TEST(WavStreamTest, SeveralSeeksLandOnTheLast) {
  const std::string path = WriteFixture("wav_stream_seeks.wav", 1);
  auto stream = std::make_shared<WavStream>();
  ASSERT_TRUE(stream->open(path.c_str(), 28));
  WavStreamer streamer;
  streamer.add(stream);
  for (uint32_t target : {5000u, 60000u, 41000u}) stream->post_seek_rt(target);
  ASSERT_TRUE(WaitPrimed(*stream, 1024));
  EXPECT_EQ(ReadAndCheck(*stream, 41000, 8 * kBlock), 8 * kBlock);
}

TEST(WavStreamTest, SeekPastTheEndIsPrimedAtEof) {
  const std::string path = WriteFixture("wav_stream_past_end.wav", 1);
  auto stream = std::make_shared<WavStream>();
  ASSERT_TRUE(stream->open(path.c_str(), 28));
  WavStreamer streamer;
  streamer.add(stream);
  stream->post_seek_rt(kFileFrames + 1000);
  ASSERT_TRUE(WaitPrimed(*stream, 1024));
  EXPECT_TRUE(stream->eof());
  Block block(1);
  EXPECT_EQ(stream->read(block.buf, kBlock), 0u);
}

TEST(WavStreamTest, ChannelsBeyondTheLimitAreDropped) {
  const std::string path = WriteFixture("wav_stream_4ch.wav", 4);
  WavStream stream;
  ASSERT_TRUE(stream.open(path.c_str(), 2));
  EXPECT_EQ(stream.channels(), 2u);
  EXPECT_EQ(ReadAndCheck(stream, 0, 4 * kBlock), 4 * kBlock);
}

// The streamer holds weak references: releasing the last strong one
// destroys the stream while the disk thread keeps running.
TEST(WavStreamTest, StreamReleasedWhileTheStreamerRuns) {
  const std::string path = WriteFixture("wav_stream_release.wav", 1);
  WavStreamer streamer;
  std::weak_ptr<WavStream> weak;
  {
    auto stream = std::make_shared<WavStream>();
    ASSERT_TRUE(stream->open(path.c_str(), 28));
    streamer.add(stream);
    weak = stream;
    stream->post_seek_rt(1000);
    ASSERT_TRUE(WaitPrimed(*stream, 1024));
  }
  const auto deadline = std::chrono::steady_clock::now() + kTimeout;
  while (!weak.expired() && std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  EXPECT_TRUE(weak.expired());

  // The streamer still services a stream added afterwards.
  auto next = std::make_shared<WavStream>();
  ASSERT_TRUE(next->open(path.c_str(), 28));
  streamer.add(next);
  next->post_seek_rt(2000);
  ASSERT_TRUE(WaitPrimed(*next, 1024));
  EXPECT_EQ(ReadAndCheck(*next, 2000, 4 * kBlock), 4 * kBlock);
}

// read(), eof(), post_seek_rt() and primed() run on the audio thread
// and must not allocate, while the disk thread refills concurrently.
TEST(WavStreamTest, AudioThreadCallsDoNotAllocate) {
  if (!alloc_counter::kAvailable) {
    GTEST_SKIP() << "allocation counts need an asan or tsan build";
  }
  const std::string path = WriteFixture("wav_stream_alloc.wav", 2);
  auto stream = std::make_shared<WavStream>();
  ASSERT_TRUE(stream->open(path.c_str(), 28));
  WavStreamer streamer;
  streamer.add(stream);
  Block block(2);

  const bool probe_counted = alloc_counter::Start();
  uint32_t read_frames = 0;
  for (int i = 0; i < 200; ++i) {
    read_frames += stream->read(block.buf, kBlock);
    if (i % 50 == 49) stream->post_seek_rt(static_cast<uint64_t>(i) * 100);
    (void)stream->primed(1024);
    (void)stream->eof();
    if (i % 4 == 3) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  const uint64_t allocations = alloc_counter::Stop();

  EXPECT_TRUE(probe_counted);
  EXPECT_EQ(allocations, 0u);
  EXPECT_GT(read_frames, 0u);
}

}  // namespace
