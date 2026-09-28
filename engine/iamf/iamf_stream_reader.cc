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

#include "iamf/iamf_stream_reader.h"

#include <algorithm>
#include <string>

#include "iamf/include/iamf_tools/iamf_stream_factory.h"
#include "iamf/include/iamf_tools/iamf_tools_api_types.h"

using iamf_tools::api::IamfStatus;
using iamf_tools::api::IamfStreamFactory;
using iamf_tools::api::IamfStreamInterface;

namespace {

constexpr uint32_t kDefaultSampleRate = 48000;

}  // namespace

IamfStreamReader::IamfStreamReader() = default;

IamfStreamReader::~IamfStreamReader() { close(); }

bool IamfStreamReader::open(const char* path, uint32_t ae_index) {
  close();
  if (path == nullptr || *path == '\0') {
    last_error_ = "invalid_argument: empty path";
    return false;
  }
  if (!map_file(path)) return false;  // last_error_ set inside map_file

  IamfStatus status = IamfStreamFactory::OpenFromBytes(
      mapped_bytes_, mapped_len_, IamfStreamFactory::Settings{}, stream_);
  if (!status.ok()) {
    last_error_ = status.error_message;
    stream_.reset();
    unmap_file();
    return false;
  }

  if (!configure_from_open_stream(ae_index)) {
    stream_.reset();
    unmap_file();
    return false;
  }
  return true;
}

bool IamfStreamReader::open_from_memory(const uint8_t* bytes, size_t len,
                                        uint32_t ae_index) {
  close();
  if (bytes == nullptr || len == 0) {
    last_error_ = "invalid_argument: empty buffer";
    return false;
  }

  owned_bytes_.assign(bytes, bytes + len);
  mapped_bytes_ = owned_bytes_.data();
  mapped_len_ = owned_bytes_.size();

  IamfStatus status = IamfStreamFactory::OpenFromBytes(
      mapped_bytes_, mapped_len_, IamfStreamFactory::Settings{}, stream_);
  if (!status.ok()) {
    last_error_ = status.error_message;
    stream_.reset();
    owned_bytes_.clear();
    mapped_bytes_ = nullptr;
    mapped_len_ = 0;
    return false;
  }

  if (!configure_from_open_stream(ae_index)) {
    stream_.reset();
    owned_bytes_.clear();
    mapped_bytes_ = nullptr;
    mapped_len_ = 0;
    return false;
  }
  return true;
}

bool IamfStreamReader::configure_from_open_stream(uint32_t ae_index) {
  const uint32_t num_ae = stream_->GetNumAudioElements();
  if (ae_index >= num_ae) {
    last_error_ = "invalid_argument: ae_index out of range";
    return false;
  }
  const auto ae = stream_->GetAudioElement(ae_index);
  if (!ae.supported) {
    last_error_ = "unsupported: requested AE is not decodable in this build";
    return false;
  }

  ae_index_ = ae_index;
  channels_ = ae.num_channels;
  sample_rate_ = stream_->GetSampleRate();
  if (sample_rate_ == 0) sample_rate_ = kDefaultSampleRate;
  total_frames_ = stream_->GetTotalSamples();
  cursor_ = 0;
  eof_ = false;
  tu_frame_offset_ = 0;
  tu_frames_remaining_ = 0;
  last_error_.clear();
  return true;
}

void IamfStreamReader::close() {
  // Destroy the stream before releasing its backing bytes — the upstream
  // contract requires bytes to outlive the stream.
  stream_.reset();
  unmap_file();
  owned_bytes_.clear();
  mapped_bytes_ = nullptr;
  mapped_len_ = 0;
  ae_index_ = 0;
  channels_ = 0;
  sample_rate_ = 0;
  total_frames_ = 0;
  cursor_ = 0;
  eof_ = false;
  last_error_.clear();
  tu_frame_offset_ = 0;
  tu_frames_remaining_ = 0;
  tu_.samples_per_ae.clear();
  tu_.mix_gain_db_per_ae.clear();
  tu_.frames_produced = 0;
}

uint32_t IamfStreamReader::read(AudioBuffer& out_buffer, uint32_t frames) {
  if (!stream_ || frames == 0 || eof_ || channels_ == 0) return 0;

  const uint32_t out_ch = std::min(channels_, out_buffer.channels);
  uint32_t produced = 0;

  while (produced < frames) {
    if (tu_frames_remaining_ == 0) {
      // Pump the next TU.
      const IamfStatus status = stream_->NextTemporalUnit(tu_);
      if (!status.ok()) {
        last_error_ = status.error_message;
        eof_ = true;  // poisoned; caller must Seek to clear (per contract)
        break;
      }
      if (tu_.frames_produced == 0) {
        eof_ = true;
        break;
      }
      if (ae_index_ >= tu_.samples_per_ae.size()) {
        last_error_ = "internal: AE index out of TU range";
        eof_ = true;
        break;
      }
      tu_frame_offset_ = 0;
      tu_frames_remaining_ = tu_.frames_produced;
    }

    const std::vector<float>& ae_samples = tu_.samples_per_ae[ae_index_];
    const uint32_t take = std::min(frames - produced, tu_frames_remaining_);

    // Interleaved (per-AE, frame * num_channels + ch) → planar output.
    const float* src_base =
        ae_samples.data() + static_cast<size_t>(tu_frame_offset_) * channels_;
    for (uint32_t c = 0; c < out_ch; ++c) {
      float* dst = out_buffer.channel(c) + produced;
      const float* src = src_base + c;
      for (uint32_t f = 0; f < take; ++f) {
        dst[f] = src[f * channels_];
      }
    }
    // Silence any output channels the AE doesn't fill.
    for (uint32_t c = out_ch; c < out_buffer.channels; ++c) {
      std::memset(out_buffer.channel(c) + produced, 0, take * sizeof(float));
    }

    tu_frame_offset_ += take;
    tu_frames_remaining_ -= take;
    produced += take;
    cursor_ += take;
  }

  out_buffer.frames = produced;
  return produced;
}

bool IamfStreamReader::seek(uint64_t frame_pos) {
  if (!stream_) return false;
  frame_pos = std::min(frame_pos, total_frames_);

  const IamfStatus status = stream_->Seek(frame_pos);
  if (!status.ok()) {
    last_error_ = status.error_message;
    return false;
  }
  cursor_ = frame_pos;
  eof_ = false;
  tu_frame_offset_ = 0;
  tu_frames_remaining_ = 0;
  last_error_.clear();
  return true;
}

bool IamfStreamReader::map_file(const char* path) {
  std::string err;
  if (!file_map_.open(path, &err)) {
    last_error_ = err;
    return false;
  }
  mapped_bytes_ = file_map_.data();
  mapped_len_ = file_map_.size();
  return true;
}

void IamfStreamReader::unmap_file() { file_map_.close(); }
