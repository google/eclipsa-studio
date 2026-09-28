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

#include "io/wav_writer.h"

#include <utility>

bool WavWriter::open(const char* path, uint32_t channels, uint32_t sample_rate,
                     wav::WriteFormat format) {
  if (open_) close();
  if (path == nullptr || channels == 0 || sample_rate == 0) return false;
  if (channels > kMaxScratchChannels) return false;

  wav::WriterOptions opt;
  opt.channels = static_cast<uint16_t>(channels);
  opt.sample_rate = sample_rate;
  opt.format = format;

  auto w = wav::Writer::Create(path, opt);
  if (!w.ok()) return false;
  writer_.emplace(std::move(*w));

  open_ = true;
  channels_ = channels;
  frames_written_ = 0;
  return true;
}

uint32_t WavWriter::write(const AudioBuffer& buffer, uint32_t frames) {
  if (!open_ || frames == 0) return 0;

  const float* srcs[kMaxScratchChannels];
  for (uint32_t c = 0; c < channels_; ++c) {
    srcs[c] = buffer.channel(c);
  }
  if (!writer_->PushPlanarFloat(srcs, frames).ok()) {
    // Disk full or I/O error. The library commits complete interleave
    // blocks before failing, so part of this write may be on disk —
    // resync our count to the writer's authoritative one and report the
    // partial progress.
    const uint64_t on_disk = writer_->frames_written();
    const auto partial = static_cast<uint32_t>(on_disk - frames_written_);
    frames_written_ = on_disk;
    return partial;
  }
  frames_written_ += frames;
  return frames;
}

void WavWriter::close() {
  if (!open_) return;
  writer_->Finalize();  // Best-effort; errors surface on the next open().
  writer_.reset();
  open_ = false;
}
