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

#include "meters/live_loudness_meter.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

#include "engine_log.h"

namespace {

// Ring capacity: at least half a second of frames at the meter's sample
// rate, rounded up to a power of two (32768 frames at 44.1 and 48 kHz,
// 65536 at 96 kHz), and never less than one analyzer chunk. The meter
// thread drains every 20 ms, so the ring only fills if that thread is
// held off for about 0.7 s.
uint32_t RingCapacityFrames(uint32_t sample_rate) {
  const uint32_t wanted =
      std::max(sample_rate / 2, LiveLoudnessMeter::kChunkFrames);
  uint32_t cap = 1;
  while (cap < wanted) cap <<= 1;
  return cap;
}

// Shortest interval between two "ring full" log lines.
constexpr auto kDropLogInterval = std::chrono::seconds(1);

}  // namespace

LiveLoudnessMeter::LiveLoudnessMeter(uint32_t sample_rate,
                                     uint32_t num_channels, uint32_t layout,
                                     EclipsaStudioLoudnessData* out)
    : out_(out),
      meter_(sample_rate, num_channels, layout),
      sample_rate_(sample_rate) {
  {
    std::lock_guard<std::mutex> lock(mu_);
    configure_ring_locked();
  }
  thread_ = std::thread([this] { run(); });
}

LiveLoudnessMeter::~LiveLoudnessMeter() {
  {
    std::lock_guard<std::mutex> lock(thread_mu_);
    stop_ = true;
  }
  thread_cv_.notify_one();
  thread_.join();
}

void LiveLoudnessMeter::push(const AudioBuffer& buffer, uint32_t frames) {
  if (frames == 0 || channels_ == 0) return;
  if (buffer.channels != channels_) {
    mismatched_blocks_.fetch_add(1, std::memory_order_relaxed);
    if (!mismatch_logged_) {
      mismatch_logged_ = true;
      char buf[128];
      snprintf(buf, sizeof(buf),
               "live loudness: skipping %u-channel blocks, configured for "
               "%u channels (layout=%u)",
               buffer.channels, channels_, layout_);
      engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "meters", buf);
    }
    return;
  }

  // head_ is ours; tail_ is the consumer's.
  const uint64_t head = head_.load(std::memory_order_relaxed);
  const uint64_t tail = tail_.load(std::memory_order_acquire);
  const uint64_t free_frames = capacity_ - (head - tail);
  if (frames > free_frames) {
    dropped_frames_.fetch_add(frames, std::memory_order_relaxed);
    return;
  }

  const uint32_t start = static_cast<uint32_t>(head) & mask_;
  const uint32_t first = std::min(frames, capacity_ - start);
  for (uint32_t c = 0; c < channels_; ++c) {
    float* plane = ring_.data() + static_cast<size_t>(c) * capacity_;
    const float* src = buffer.channel(c);
    std::memcpy(plane + start, src, first * sizeof(float));
    std::memcpy(plane, src + first, (frames - first) * sizeof(float));
  }
  head_.store(head + frames, std::memory_order_release);
}

void LiveLoudnessMeter::drain() {
  std::lock_guard<std::mutex> lock(mu_);
  drain_locked();
}

void LiveLoudnessMeter::drain_locked() {
  // tail_ is ours (under mu_); head_ is the producer's.
  uint64_t tail = tail_.load(std::memory_order_relaxed);
  const uint64_t head = head_.load(std::memory_order_acquire);
  bool fed = false;
  while (tail < head) {
    const auto n =
        static_cast<uint32_t>(std::min<uint64_t>(head - tail, kChunkFrames));
    const uint32_t start = static_cast<uint32_t>(tail) & mask_;
    const uint32_t first = std::min(n, capacity_ - start);
    // Feed the analyzer straight from the ring: an AudioBuffer's channel
    // stride is capacity_frames, which here is the plane length. A chunk
    // that crosses the end of the planes goes in two parts.
    AudioBuffer part;
    part.data = ring_.data() + start;
    part.channels = channels_;
    part.frames = first;
    part.capacity_frames = capacity_;
    fed = meter_.feed(part, first) || fed;
    if (n > first) {
      part.data = ring_.data();
      part.frames = n - first;
      fed = meter_.feed(part, n - first) || fed;
    }
    tail += n;
    // The analyzer has read the frames: hand their space back to push().
    tail_.store(tail, std::memory_order_release);
  }
  if (fed) meter_.publish(*out_);

  const uint64_t dropped = dropped_frames_.load(std::memory_order_relaxed);
  const auto now = std::chrono::steady_clock::now();
  if (dropped != dropped_logged_ && now - last_drop_log_ >= kDropLogInterval) {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "live loudness: ring full, %llu frames dropped in total; the "
             "readings miss that audio",
             static_cast<unsigned long long>(dropped));
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "meters", buf);
    dropped_logged_ = dropped;
    last_drop_log_ = now;
  }
}

void LiveLoudnessMeter::reset() {
  std::lock_guard<std::mutex> lock(mu_);
  meter_.reset();
  configure_ring_locked();
}

void LiveLoudnessMeter::reconfigure(uint32_t num_channels, uint32_t layout) {
  std::lock_guard<std::mutex> lock(mu_);
  meter_.reconfigure(num_channels, layout);
  configure_ring_locked();
}

void LiveLoudnessMeter::set_sample_rate(uint32_t sample_rate) {
  std::lock_guard<std::mutex> lock(mu_);
  meter_.set_sample_rate(sample_rate);
  sample_rate_ = sample_rate;
  configure_ring_locked();
}

void LiveLoudnessMeter::configure_ring_locked() {
  capacity_ = RingCapacityFrames(sample_rate_);
  mask_ = capacity_ - 1;
  channels_ = meter_.num_channels();
  layout_ = meter_.layout();
  // Reallocate only when the size changes (a new channel count or sample
  // rate); a reset rewinds the indices over the same storage.
  const size_t samples = static_cast<size_t>(channels_) * capacity_;
  if (ring_.size() != samples) ring_.assign(samples, 0.0f);
  head_.store(0, std::memory_order_relaxed);
  tail_.store(0, std::memory_order_relaxed);
  mismatch_logged_ = false;
  *out_ = EclipsaStudioLoudnessData{};
}

void LiveLoudnessMeter::run() {
  std::unique_lock<std::mutex> lock(thread_mu_);
  while (!stop_) {
    thread_cv_.wait_for(lock, kPollInterval, [this] { return stop_; });
    if (stop_) break;
    lock.unlock();
    drain();
    lock.lock();
  }
}
