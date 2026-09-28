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

#include "dsp/resampler.h"

#include <samplerate.h>

#include <algorithm>
#include <cstring>
#include <new>

namespace dsp {

namespace {

// Sinc-filter wing length in input frames at unit ratio, from the coeff
// tables in libsamplerate 0.2.2 (half_length / increment):
// SINC_MEDIUM_QUALITY 22437/491 ≈ 46, SINC_BEST_QUALITY ≈ 143. When
// downsampling the filter is stretched by in_rate/out_rate, so the
// priming headroom scales with the ratio.
constexpr uint32_t kWingFramesLive = 46;
constexpr uint32_t kWingFramesExport = 143;

// Extra slack on top of the wing so a conservative libsamplerate
// internal estimate never leaves consume() short of input mid-stream.
constexpr uint32_t kHeadroomFrames = 32;

SRC_STATE* as_src(void* p) { return static_cast<SRC_STATE*>(p); }

}  // namespace

Resampler::Resampler() = default;

Resampler::~Resampler() {
  if (src_state_ != nullptr) {
    src_delete(as_src(src_state_));
    src_state_ = nullptr;
  }
}

bool Resampler::init(uint32_t in_rate, uint32_t out_rate, uint32_t channels,
                     uint32_t max_out_frames, Quality quality) {
  if (in_rate == 0 || out_rate == 0 || channels == 0 || max_out_frames == 0) {
    return false;
  }

  // Re-init: tear down any prior instance first so init() is idempotent.
  if (src_state_ != nullptr) {
    src_delete(as_src(src_state_));
    src_state_ = nullptr;
  }
  in_planar_storage_.reset();
  in_il_storage_.reset();
  out_il_storage_.reset();
  carry_frames_ = 0;
  initialized_ = false;

  const int converter = quality == Quality::kExport ? SRC_SINC_BEST_QUALITY
                                                    : SRC_SINC_MEDIUM_QUALITY;
  int err = 0;
  SRC_STATE* state = src_new(converter, static_cast<int>(channels), &err);
  if (state == nullptr) return false;

  // Worst-case fresh input for the largest output block: the rate-ratio
  // share plus the sinc wing (ratio-stretched when downsampling) plus
  // slack. required_input() asks for at most this much, and the carry
  // is bounded by it as well.
  const uint32_t wing =
      quality == Quality::kExport ? kWingFramesExport : kWingFramesLive;
  const uint64_t ratio_frames =
      (static_cast<uint64_t>(max_out_frames) * in_rate + out_rate - 1) /
      out_rate;
  const uint64_t stretched_wing =
      (static_cast<uint64_t>(wing) * in_rate + out_rate - 1) / out_rate;
  const uint64_t priming =
      std::max<uint64_t>(wing, stretched_wing) + kHeadroomFrames;
  const uint64_t max_in = ratio_frames + priming;

  const size_t in_samples = static_cast<size_t>(max_in) * channels;
  const size_t out_samples = static_cast<size_t>(max_out_frames) * channels;
  in_planar_storage_.reset(new (std::nothrow) float[in_samples]());
  // The interleaved input buffer holds carry + fresh input.
  in_il_storage_.reset(new (std::nothrow) float[2 * in_samples]());
  out_il_storage_.reset(new (std::nothrow) float[out_samples]());
  if (in_planar_storage_ == nullptr || in_il_storage_ == nullptr ||
      out_il_storage_ == nullptr) {
    src_delete(state);
    in_planar_storage_.reset();
    in_il_storage_.reset();
    out_il_storage_.reset();
    return false;
  }

  in_rate_ = in_rate;
  out_rate_ = out_rate;
  channels_ = channels;
  max_in_frames_ = static_cast<uint32_t>(max_in);
  max_out_frames_ = max_out_frames;
  priming_frames_ = static_cast<uint32_t>(priming);
  ratio_ = static_cast<double>(out_rate) / static_cast<double>(in_rate);
  src_state_ = state;

  // Wire up the caller-facing AudioBuffer view. The planar layout
  // matches AudioBuffer's convention: data[channel * capacity + frame].
  input_view_.data = in_planar_storage_.get();
  input_view_.channels = channels;
  input_view_.frames = 0;
  input_view_.capacity_frames = max_in_frames_;

  initialized_ = true;
  return true;
}

uint64_t Resampler::required_input(uint64_t out_frames) const {
  if (!initialized_) return 0;
  // Rate-ratio share of the request plus filter priming, minus what is
  // already sitting in the carry from the previous consume().
  const uint64_t need =
      (out_frames * in_rate_ + out_rate_ - 1) / out_rate_ + priming_frames_;
  const uint64_t fresh = need > carry_frames_ ? need - carry_frames_ : 0;
  return std::min<uint64_t>(fresh, max_in_frames_);
}

uint32_t Resampler::consume(AudioBuffer& out_planar, uint32_t in_frames,
                            uint32_t out_frames_wanted) {
  if (!initialized_) {
    out_planar.frames = 0;
    return 0;
  }
  const uint32_t in_n = std::min(in_frames, max_in_frames_);
  const uint32_t out_n = std::min(out_frames_wanted, max_out_frames_);
  const uint32_t ch = channels_;

  // Planar input → interleaved scratch, appended after the carry.
  float* il_in = in_il_storage_.get();
  float* il_fresh = il_in + static_cast<size_t>(carry_frames_) * ch;
  for (uint32_t c = 0; c < ch; ++c) {
    const float* src = input_view_.channel(c);
    for (uint32_t f = 0; f < in_n; ++f) {
      il_fresh[f * ch + c] = src[f];
    }
  }
  const uint32_t total_in = carry_frames_ + in_n;

  SRC_DATA data{};
  data.data_in = il_in;
  data.input_frames = static_cast<long>(total_in);
  data.data_out = out_il_storage_.get();
  data.output_frames = static_cast<long>(out_n);
  data.src_ratio = ratio_;
  data.end_of_input = 0;
  if (src_process(as_src(src_state_), &data) != 0) {
    carry_frames_ = 0;
    out_planar.frames = 0;
    return 0;
  }

  // Frames libsamplerate didn't need yet stay at the head of the
  // interleaved buffer for the next call. required_input() subtracts
  // them, so the carry stays bounded by priming_frames_ + slack; the
  // min() is a belt-and-suspenders clamp that keeps the newest frames
  // if a caller ever overfeeds.
  const uint32_t used = static_cast<uint32_t>(data.input_frames_used);
  const uint32_t leftover = std::min(total_in - used, max_in_frames_);
  std::memmove(il_in, il_in + static_cast<size_t>(total_in - leftover) * ch,
               static_cast<size_t>(leftover) * ch * sizeof(float));
  carry_frames_ = leftover;

  // Interleaved output → planar.
  const uint32_t produced = static_cast<uint32_t>(data.output_frames_gen);
  write_planar_output(out_planar, produced);
  return produced;
}

uint32_t Resampler::flush(AudioBuffer& out_planar, uint32_t out_frames_wanted) {
  if (!initialized_) {
    out_planar.frames = 0;
    return 0;
  }
  const uint32_t out_n = std::min(out_frames_wanted, max_out_frames_);
  const uint32_t ch = channels_;

  // Feed end_of_input so libsamplerate emits the sinc filter's history.
  // Any frames still carried at the head of the interleaved buffer are
  // the input for the first flush call; later calls feed nothing and
  // keep draining until output_frames_gen hits zero.
  float* il_in = in_il_storage_.get();
  const uint32_t total_in = carry_frames_;

  SRC_DATA data{};
  data.data_in = il_in;
  data.input_frames = static_cast<long>(total_in);
  data.data_out = out_il_storage_.get();
  data.output_frames = static_cast<long>(out_n);
  data.src_ratio = ratio_;
  data.end_of_input = 1;
  if (src_process(as_src(src_state_), &data) != 0) {
    carry_frames_ = 0;
    out_planar.frames = 0;
    return 0;
  }

  // Mirror consume()'s carry bookkeeping: with end_of_input set
  // libsamplerate consumes everything, so leftover is normally zero, but
  // keep the newest frames if it ever holds some back.
  const uint32_t used = static_cast<uint32_t>(data.input_frames_used);
  const uint32_t leftover = std::min(total_in - used, max_in_frames_);
  std::memmove(il_in, il_in + static_cast<size_t>(total_in - leftover) * ch,
               static_cast<size_t>(leftover) * ch * sizeof(float));
  carry_frames_ = leftover;

  const uint32_t produced = static_cast<uint32_t>(data.output_frames_gen);
  write_planar_output(out_planar, produced);
  return produced;
}

void Resampler::write_planar_output(AudioBuffer& out_planar,
                                    uint32_t produced) const {
  const uint32_t ch = channels_;
  const float* il_out = out_il_storage_.get();
  const uint32_t out_ch = std::min<uint32_t>(out_planar.channels, ch);
  for (uint32_t c = 0; c < out_ch; ++c) {
    float* dst = out_planar.channel(c);
    for (uint32_t f = 0; f < produced; ++f) {
      dst[f] = il_out[f * ch + c];
    }
  }
  // Caller-allocated channels beyond `ch` get zeroed so the downstream
  // mute / metering passes don't read stale data.
  for (uint32_t c = out_ch; c < out_planar.channels; ++c) {
    std::memset(out_planar.channel(c), 0,
                static_cast<size_t>(produced) * sizeof(float));
  }
  out_planar.frames = produced;
}

void Resampler::reset() {
  if (!initialized_) return;
  src_reset(as_src(src_state_));
  carry_frames_ = 0;
}

}  // namespace dsp
