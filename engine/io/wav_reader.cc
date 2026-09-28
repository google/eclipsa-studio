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

#include "io/wav_reader.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <utility>

#include "engine_log.h"

bool WavReader::open(const char* path, wav::OpenMode mode) {
  close();
  if (path == nullptr) return false;

  auto r = wav::Reader::Open(path, mode);
  if (!r.ok()) return false;
  // Copy (not bind a reference): the Reader is moved from two lines
  // down, and a reference into it would dangle the day wav::Info grows
  // a non-trivially-copyable member.
  const wav::Info info = r->info();
  if (r->recovered()) {
    char buf[400];
    snprintf(buf, sizeof(buf),
             "damaged WAV recovered (truncated/malformed tail), "
             "%llu whole frames readable: %s",
             static_cast<unsigned long long>(info.num_frames), path);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "audio", buf);
  }

  // Cap channels to scratch capacity so the planar decode of dropped
  // channels can't overflow (mirrors the pre-library 32-channel cap).
  if (info.channels > kMaxScratchChannels) return false;

  reader_.emplace(std::move(*r));
  // Preallocate the library's raw-byte scratch so audio-thread reads
  // never allocate.
  reader_->ReserveReadScratch(kMaxScratchFrames);

  channels_ = info.channels;
  sample_rate_ = info.sample_rate;
  bit_depth_ = static_cast<uint32_t>(info.bits_per_sample());
  total_frames_ = info.num_frames;
  cursor_ = 0;
  open_ = true;
  return true;
}

void WavReader::close() {
  if (open_) {
    reader_.reset();
    open_ = false;
    channels_ = 0;
    sample_rate_ = 0;
    bit_depth_ = 0;
    total_frames_ = 0;
    cursor_ = 0;
  }
}

uint32_t WavReader::read(AudioBuffer& out_buffer, uint32_t frames) {
  // Every exit must publish the produced count: callers (the resample
  // path in AudioGraph::process) consume out_buffer.frames, and a
  // stale count from the previous read would re-feed already-consumed
  // samples into the resampler — an audible click per occurrence.
  out_buffer.frames = 0;
  if (!open_ || frames == 0) return 0;

  const uint32_t ch = std::min(channels_, out_buffer.channels);
  // Min in 64-bit before narrowing: an RF64 file can hold > 2^32 frames,
  // and truncating the remainder first could yield a spurious 0.
  const auto remaining64 = std::min<uint64_t>(frames, total_frames_ - cursor_);
  auto remaining = static_cast<uint32_t>(remaining64);
  if (remaining == 0) return 0;

  uint32_t total_read = 0;
  while (remaining > 0) {
    const uint32_t batch = std::min(remaining, kMaxScratchFrames);

    // Wanted channels decode straight into the destination buffer;
    // file channels beyond it land in scratch and are dropped.
    float* dsts[kMaxScratchChannels];
    for (uint32_t c = 0; c < channels_; ++c) {
      dsts[c] = c < ch ? out_buffer.channel(c) + total_read
                       : scratch_ + static_cast<size_t>(c) * kMaxScratchFrames;
    }
    auto got = reader_->ReadPlanarFloatInto(cursor_, batch, dsts);
    if (!got.ok() || *got == 0) break;

    const auto n = static_cast<uint32_t>(*got);
    total_read += n;
    remaining -= n;
    cursor_ += n;
    if (n < batch) break;
  }

  // Destination channels the file doesn't carry stay silent.
  for (uint32_t c = ch; c < out_buffer.channels; ++c) {
    std::memset(out_buffer.channel(c), 0, total_read * sizeof(float));
  }

  out_buffer.frames = total_read;
  return total_read;
}

bool WavReader::seek(uint64_t frame_pos) {
  if (!open_) return false;
  // Reads are positioned per call, so a seek is just a cursor move.
  cursor_ = std::min(frame_pos, total_frames_);
  return true;
}
