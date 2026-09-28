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

#include "iamf/iamf_ring_source.h"

#include <algorithm>

#include "iamf/pcm_ring.h"

bool IamfRingSource::attach(IamfPlaybackSession* session, uint32_t ae_index) {
  detach();
  if (session == nullptr || !session->is_open()) return false;
  if (ae_index >= session->num_audio_elements()) return false;
  const auto info = session->ae_info(ae_index);
  if (!info.supported) return false;

  session_ = session;
  ae_index_ = ae_index;
  channels_ = info.num_channels;
  cursor_ = 0;
  ring_ = session_->ring(ae_index);
  return ring_ != nullptr;
}

void IamfRingSource::detach() {
  session_ = nullptr;
  ring_ = nullptr;
  ae_index_ = 0;
  channels_ = 0;
  cursor_ = 0;
}

uint32_t IamfRingSource::sample_rate() const {
  return session_ != nullptr ? session_->sample_rate() : 0;
}

uint64_t IamfRingSource::total_frames() const {
  return session_ != nullptr ? session_->total_frames() : 0;
}

uint32_t IamfRingSource::read(AudioBuffer& out, uint32_t frames) {
  if (ring_ == nullptr || frames == 0) {
    out.frames = 0;
    return 0;
  }
  const uint32_t got = ring_->read_planar(out, frames);
  cursor_ += got;
  return got;
}

bool IamfRingSource::eof() const { return ring_ != nullptr && ring_->eof(); }

bool IamfRingSource::seek(uint64_t frame_pos) {
  if (session_ == nullptr) return false;
  if (!session_->seek_to_frame(frame_pos)) return false;
  cursor_ = std::min(frame_pos, session_->total_frames());
  return true;
}
