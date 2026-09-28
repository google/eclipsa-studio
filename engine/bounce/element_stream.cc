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

#include "bounce/element_stream.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "engine_log.h"

namespace eclipsa_studio {

namespace {
constexpr uint32_t kMaxChannels = 32;
}  // namespace

bool ElementStream::Open(const Config& config) {
  if (!reader_.open(config.input_wav_path.c_str())) {
    char buf[256];
    snprintf(buf, sizeof(buf), "ElementStream: cannot open input: %s",
             config.input_wav_path.c_str());
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "bounce", buf);
    return false;
  }

  in_channels_ = reader_.channels();
  in_rate_ = reader_.sample_rate();
  source_frames_ = reader_.total_frames();

  // Determine output channel count from routing or passthrough.
  routing_ = config.routing;
  out_channels_ =
      routing_.empty() ? in_channels_ : static_cast<uint32_t>(routing_.size());

  if (out_channels_ > kMaxChannels || in_channels_ > kMaxChannels) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "bounce",
               "ElementStream: channel count exceeds limit");
    return false;
  }

  // ── Resampler (source rate -> output rate) ────────────────────────
  // The output rate is the IAMF target rate, a property of the
  // deliverable — sources at any rate converge on it here so the
  // Codec Config OBU and every bounced block agree.
  out_rate_ =
      config.output_sample_rate != 0 ? config.output_sample_rate : in_rate_;
  if (out_rate_ != in_rate_) {
    resampler_ = std::make_unique<dsp::Resampler>();
    // Export tier: SINC_BEST_QUALITY — transparent conversion for the
    // deliverable; the extra CPU is irrelevant offline.
    if (!resampler_->init(in_rate_, out_rate_, in_channels_, kMaxPullFrames,
                          dsp::Resampler::Quality::kExport)) {
      char buf[160];
      snprintf(buf, sizeof(buf),
               "ElementStream: resampler init failed (%u -> %u Hz, ch=%u)",
               in_rate_, out_rate_, in_channels_);
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "bounce", buf);
      return false;
    }
  }

  // ── Working buffer (heap) ─────────────────────────────────────────
  // Sized to the actual channel count, not kMaxChannels, to keep the
  // footprint modest. Streaming runs on a control thread so heap
  // allocation is fine here; Pull() itself never allocates.
  read_storage_.assign(static_cast<size_t>(in_channels_) * kMaxPullFrames,
                       0.0f);
  read_buf_.data = read_storage_.data();
  read_buf_.channels = in_channels_;
  read_buf_.frames = 0;
  read_buf_.capacity_frames = kMaxPullFrames;

  gain_linear_ =
      (config.gain_db == 0.0f) ? 1.0f : std::pow(10.0f, config.gain_db / 20.0f);

  // target_frames_ is in OUTPUT-rate frames; without an explicit pad
  // target it is the source length converted to the output rate, so a
  // resampled stream still lands at the expected duration (the
  // resampler's filter latency tail is made up by the pad stage).
  const uint64_t scaled_total =
      resampler_ ? (source_frames_ * out_rate_ + in_rate_ / 2) / in_rate_
                 : source_frames_;
  target_frames_ =
      config.pad_to_frames > 0 ? config.pad_to_frames : scaled_total;
  delivered_ = 0;
  clipped_samples_ = 0;
  peak_linear_ = 0.0f;
  draining_ = false;
  exhausted_ = false;

  reader_.seek(0);
  return true;
}

uint32_t ElementStream::Produce(uint32_t want) {
  if (exhausted_) return 0;
  uint32_t got = 0;
  if (resampler_) {
    if (!draining_) {
      // Pull enough source frames to produce `want` output frames.
      // required_input() is clamped to the input view's capacity so
      // the read can never overrun the resampler's scratch.
      AudioBuffer& rin = resampler_->input_buffer();
      const uint64_t in_needed_raw = resampler_->required_input(want);
      const uint32_t in_needed = static_cast<uint32_t>(
          std::min<uint64_t>(in_needed_raw, rin.capacity_frames));
      const uint32_t got_in = reader_.read(rin, in_needed);
      if (in_needed > 0 && got_in == 0) {
        // Source EOF — stop pulling and drain the filter tail below
        // instead of dropping it onto the silence pad.
        draining_ = true;
      } else {
        // Pass got_in, not rin.frames: WavReader::read leaves the
        // buffer's frame count untouched on its early-return paths, so
        // rin.frames could re-present a stale count when in_needed == 0.
        got = resampler_->consume(read_buf_, got_in, want);
        if (got == 0) {
          // consume() emitted nothing. A short read (got_in <
          // in_needed) means the reader hit EOF: the frames fed this
          // call now live only in the sinc filter, so switch to
          // draining and let flush() push them out. Without this a
          // source shorter than the filter's priming length (~143
          // frames at SINC_BEST_QUALITY) — whose first consume() never
          // primes — would bounce to total silence (ES-83). A full read
          // that still yields nothing means the filter under-primed
          // despite required_input()'s headroom; stop defensively.
          if (got_in < in_needed) {
            draining_ = true;
          } else {
            exhausted_ = true;
            return 0;
          }
        }
      }
    }
    if (draining_ && got == 0) {
      got = resampler_->flush(read_buf_, want);
      // Tail exhausted — any remaining length is topped up by the pad
      // stage in Pull() (now only genuine trailing silence).
      if (got == 0) exhausted_ = true;
    }
  } else {
    got = reader_.read(read_buf_, want);
    if (got == 0) exhausted_ = true;
  }
  return got;
}

uint32_t ElementStream::Pull(AudioBuffer& out, uint32_t want) {
  want = std::min(want, kMaxPullFrames);
  const uint64_t remaining = target_frames_ - delivered_;
  const uint32_t to_fill =
      static_cast<uint32_t>(std::min<uint64_t>(want, remaining));

  uint32_t filled = 0;
  while (filled < to_fill) {
    const uint32_t chunk_want = to_fill - filled;
    const uint32_t got = Produce(chunk_want);
    if (got == 0) break;

    read_buf_.frames = got;

    // ── Channel routing + gain ──────────────────────────────────
    for (uint32_t ch = 0; ch < out_channels_; ++ch) {
      float* dst = out.channel(ch) + filled;
      const int src = routing_.empty() ? static_cast<int>(ch) : routing_[ch];
      if (src >= 0 && static_cast<uint32_t>(src) < in_channels_) {
        const float* s = read_buf_.channel(static_cast<uint32_t>(src));
        if (gain_linear_ != 1.0f) {
          for (uint32_t f = 0; f < got; ++f) dst[f] = s[f] * gain_linear_;
        } else {
          std::memcpy(dst, s, got * sizeof(float));
        }
      } else {
        // Silence this channel (-1 or out-of-range).
        std::memset(dst, 0, got * sizeof(float));
      }
    }
    filled += got;
  }

  // ── Signal-overload scan ──────────────────────────────────────────
  // One pass over what this Pull delivered, after gain/routing so all
  // three fill branches above (multiply, unity memcpy, silence memset)
  // are covered. The pad below is zeros and cannot clip. Strictly
  // > 1.0: full-scale integer sources hit exactly -1.0 legitimately,
  // and a downstream ±1.0 clamp maps exactly ±1.0 to itself.
  // Accumulate in locals: member stores inside the loop would alias
  // the input for all the compiler knows and keep the loop scalar.
  float peak = peak_linear_;
  uint64_t clipped = clipped_samples_;
  for (uint32_t ch = 0; ch < out_channels_; ++ch) {
    const float* ch_data = out.channel(ch);
    for (uint32_t f = 0; f < filled; ++f) {
      const float a = std::fabs(ch_data[f]);
      if (a > peak) peak = a;
      if (a > 1.0f) ++clipped;
    }
  }
  peak_linear_ = peak;
  clipped_samples_ = clipped;

  // ── Pad with silence up to the target ─────────────────────────────
  // Runs for an explicit pad request, and for the resampling case tops
  // the stream up to the exact scaled length the export math promised.
  // The resampler's filter tail is drained as real audio above, so for
  // a plain resample this typically pads only a frame or two of
  // genuine rounding slack rather than the whole ~3 ms tail.
  if (filled < to_fill) {
    for (uint32_t ch = 0; ch < out_channels_; ++ch) {
      std::memset(out.channel(ch) + filled, 0,
                  (to_fill - filled) * sizeof(float));
    }
    filled = to_fill;
  }

  delivered_ += filled;
  out.frames = filled;
  return filled;
}

}  // namespace eclipsa_studio
