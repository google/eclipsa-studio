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

#include "io/wav_stream.h"

#include <algorithm>

bool WavStream::open(const char* path, uint32_t max_channels) {
  if (!reader_.open(path, wav::OpenMode::kLenient)) return false;
  channels_ = std::min(reader_.channels(), max_channels);
  sample_rate_ = reader_.sample_rate();
  total_frames_ = reader_.total_frames();
  chunk_.assign(static_cast<size_t>(channels_) * kChunkFrames, 0.0f);
  ring_.configure(channels_, kRingFrames);
  // No disk thread holds the stream yet, so this thread may service it:
  // the first chunk is ready before the audio thread sees it, and the
  // disk thread fills the rest of the ring within kIdleInterval.
  service(1);
  return true;
}

uint32_t WavStream::read(AudioBuffer& out, uint32_t frames) {
  if (channels_ == 0 || frames == 0) {
    out.frames = 0;
    return 0;
  }
  return ring_.read_planar(out, frames);
}

void WavStream::post_seek_rt(uint64_t frame_pos) {
  seek_target_.store(frame_pos, std::memory_order_release);
  seeks_posted_ = seeks_requested_.fetch_add(1, std::memory_order_acq_rel) + 1;
}

bool WavStream::primed(uint32_t min_frames) const {
  // Until the disk thread has applied the seek, buffered_frames() still
  // counts the frames read before it.
  if (!seek_applied()) return false;
  return ring_.buffered_frames() >= min_frames || ring_.eof();
}

bool WavStream::service(uint32_t max_chunks) {
  if (stalled_for_testing_.load(std::memory_order_relaxed)) return false;
  bool worked = false;
  if (seek_pending()) {
    const uint64_t requested = seeks_requested_.load(std::memory_order_acquire);
    const uint64_t target = seek_target_.load(std::memory_order_acquire);
    reader_.seek(target);  // Clamps to the file's length.
    ring_.clear_eof();
    // Everything buffered so far precedes the seek.
    ring_.publish_discard_to(ring_.head_pos());
    seeks_seen_ = requested;
    // Release after the floor, so primed() sees the floor too.
    seeks_applied_.store(requested, std::memory_order_release);
    worked = true;
  }

  AudioBuffer chunk;
  chunk.data = chunk_.data();
  chunk.channels = channels_;
  chunk.capacity_frames = kChunkFrames;
  // Stop at a new seek, so it is applied before more of the old
  // position is read.
  for (uint32_t i = 0; i < max_chunks && !ring_.eof() && !seek_pending() &&
                       ring_.free_frames() >= kChunkFrames;
       ++i) {
    const uint32_t got = reader_.read(chunk, kChunkFrames);
    const uint32_t put = got > 0 ? ring_.write_planar(chunk, got) : 0;
    if (put > 0) worked = true;
    if (put < got) {
      // The write fell short: a read in flight held back a newly
      // published discard floor (see PcmRing::free_frames()). Rewind the
      // reader over the frames that did not fit and retry on the next
      // call.
      reader_.seek(reader_.cursor() - (got - put));
      break;
    }
    if (got < kChunkFrames) ring_.mark_eof();
  }
  return worked;
}

WavStreamer::WavStreamer() : thread_([this] { run(); }) {}

WavStreamer::~WavStreamer() {
  {
    std::lock_guard<std::mutex> lock(mu_);
    stop_ = true;
  }
  cv_.notify_one();
  thread_.join();
}

void WavStreamer::add(const std::shared_ptr<WavStream>& stream) {
  {
    std::lock_guard<std::mutex> lock(mu_);
    streams_.push_back(stream);
  }
  cv_.notify_one();
}

void WavStreamer::run() {
  // The streams locked for one pass, reused across passes. Released at
  // the end of each pass, so a stream its chain has dropped is destroyed
  // here at the latest.
  std::vector<std::shared_ptr<WavStream>> active;
  std::unique_lock<std::mutex> lock(mu_);
  while (!stop_) {
    active.clear();
    for (auto it = streams_.begin(); it != streams_.end();) {
      if (std::shared_ptr<WavStream> s = it->lock()) {
        active.push_back(std::move(s));
        ++it;
      } else {
        it = streams_.erase(it);
      }
    }
    lock.unlock();

    // One chunk per stream per pass, so every stream's pending seek is
    // applied in the first pass and the streams refill together.
    bool worked = false;
    for (bool pass_worked = true; pass_worked;) {
      pass_worked = false;
      for (const auto& s : active) pass_worked = s->service(1) || pass_worked;
      worked = worked || pass_worked;
    }
    active.clear();

    lock.lock();
    // Sleep only when every ring was full and no seek was pending;
    // otherwise go round again at once.
    if (!worked) {
      cv_.wait_for(lock, kIdleInterval, [this] { return stop_; });
    }
  }
}
