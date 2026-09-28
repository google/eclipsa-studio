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

#include "waveform/peak_compute.h"

#include <algorithm>
#include <cassert>
#include <cfloat>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "wav/reader.h"

namespace {

/// Total byte budget for the planar read scratch; the per-channel chunk
/// length is derived from this, so the footprint stays flat regardless
/// of channel count (ES-505). The previous flat 1 Mi-frame chunk cost
/// 4 MiB per channel — 128 MiB at the 32-channel cap, multiplied by
/// concurrent worker isolates during session load. 8 MiB keeps the
/// stereo chunk at the same 1 Mi frames as before; the read is
/// sequential and the level-0 accumulation single-pass either way, so
/// smaller chunks at high channel counts cost only a few more reads.
static constexpr size_t kChunkByteBudget = 8u * 1024 * 1024;

/// Same channel ceiling as playback (io/wav_reader.h) — going through the
/// shared wav library restores the format gate and channel cap that the
/// old bare-drwav path skipped (ES-41, ES-478).
static constexpr uint32_t kMaxChannels = 32;

/// Clamp num_levels to the supported maximum.
uint32_t clamp_levels(uint32_t n) {
  return std::min(n, static_cast<uint32_t>(kPeakMaxLevels));
}

/// Number of float arrays stored per (level, channel) bin: mins, maxs, rms.
static constexpr uint32_t kArraysPerBin = 3;

/// Compute the byte offset of the float data for (level, channel) within
/// the allocation that follows the EclipsaStudioPeakData header.
size_t data_offset_floats(const EclipsaStudioPeakData* h, uint32_t level,
                          uint32_t channel) {
  size_t off = 0;
  for (uint32_t l = 0; l < level; ++l) {
    // Each level contributes num_peaks[l] * kArraysPerBin per channel.
    off +=
        static_cast<size_t>(h->num_peaks[l]) * kArraysPerBin * h->num_channels;
  }
  // Within the target level, skip earlier channels (mins+maxs+rms).
  off += static_cast<size_t>(channel) * h->num_peaks[level] * kArraysPerBin;
  return off;
}

/// Number of frames covered by bin [p] at the given samples-per-peak. The
/// last bin may be partial; all other bins contain exactly `spp` frames.
inline uint64_t bin_sample_count(uint32_t p, uint32_t spp,
                                 uint64_t total_frames) {
  const uint64_t start = static_cast<uint64_t>(p) * spp;
  const uint64_t end = std::min(start + spp, total_frames);
  return end > start ? end - start : 0;
}

}  // namespace

// static
EclipsaStudioPeakData* PeakCompute::compute(const char* wav_path,
                                            uint32_t samples_per_peak,
                                            uint32_t num_levels) {
  if (!wav_path || samples_per_peak == 0 || num_levels == 0) return nullptr;
  num_levels = clamp_levels(num_levels);

  // ── Open WAV ──────────────────────────────────────────────────────────
  // Lenient: the waveform should show whatever prefix of a damaged file
  // is playable — playback (audio_graph) opens the same way.
  auto reader = wav::Reader::Open(wav_path, wav::OpenMode::kLenient);
  if (!reader.ok()) return nullptr;

  const uint32_t channels = reader->info().channels;
  const uint32_t sample_rate = reader->info().sample_rate;
  const uint64_t total_frames = reader->info().num_frames;

  if (channels == 0 || channels > kMaxChannels || total_frames == 0) {
    return nullptr;
  }

  // ── Build per-level metadata ──────────────────────────────────────────
  EclipsaStudioPeakData hdr{};
  hdr.num_channels = channels;
  hdr.num_levels = num_levels;
  hdr.sample_rate = sample_rate;
  hdr.total_samples = static_cast<uint32_t>(
      std::min(total_frames, static_cast<uint64_t>(UINT32_MAX)));

  for (uint32_t l = 0; l < num_levels; ++l) {
    // Level 0 = base resolution; each subsequent level doubles spp.
    hdr.samples_per_peak[l] = samples_per_peak << l;
    hdr.num_peaks[l] = static_cast<uint32_t>(
        (total_frames + hdr.samples_per_peak[l] - 1) / hdr.samples_per_peak[l]);
  }

  // ── Allocate output buffer ────────────────────────────────────────────
  // Layout: EclipsaStudioPeakData header + contiguous float arrays.
  size_t total_floats = 0;
  for (uint32_t l = 0; l < num_levels; ++l) {
    total_floats +=
        static_cast<size_t>(hdr.num_peaks[l]) * kArraysPerBin * channels;
  }

  const size_t alloc_size =
      sizeof(EclipsaStudioPeakData) + total_floats * sizeof(float);
  auto* raw = static_cast<uint8_t*>(std::calloc(1, alloc_size));
  if (!raw) return nullptr;

  auto* out = reinterpret_cast<EclipsaStudioPeakData*>(raw);
  *out = hdr;
  auto* float_base =
      reinterpret_cast<float*>(raw + sizeof(EclipsaStudioPeakData));

  // Convenience: pointer to (level l, channel ch) mins/maxs/rms arrays.
  auto level_mins = [&](uint32_t l, uint32_t ch) -> float* {
    return float_base + data_offset_floats(out, l, ch);
  };
  auto level_maxs = [&](uint32_t l, uint32_t ch) -> float* {
    return level_mins(l, ch) + out->num_peaks[l];
  };
  auto level_rms = [&](uint32_t l, uint32_t ch) -> float* {
    return level_mins(l, ch) + 2u * out->num_peaks[l];
  };

  // ── Initialise level-0 min/max arrays ────────────────────────────────
  // Start mins at +inf and maxs at -inf so that any real sample beats them.
  for (uint32_t ch = 0; ch < channels; ++ch) {
    float* mn = level_mins(0, ch);
    float* mx = level_maxs(0, ch);
    for (uint32_t p = 0; p < out->num_peaks[0]; ++p) {
      mn[p] = FLT_MAX;   // will be pushed down by actual samples
      mx[p] = -FLT_MAX;  // will be pushed up
    }
  }

  // ── Chunked read & level-0 peak computation ───────────────────────────
  // The level-0 rms array is used as a sum-of-squares accumulator during
  // streaming, then finalised to sqrt(mean) below. Per-channel base
  // pointers are hoisted out of the hot loop — they're stable for the
  // duration of compute() and resolving them via lambdas inside the
  // inner per-frame loop adds avoidable function-call overhead.
  std::vector<float*> chan_mins(channels);
  std::vector<float*> chan_maxs(channels);
  std::vector<float*> chan_sq(channels);
  for (uint32_t ch = 0; ch < channels; ++ch) {
    chan_mins[ch] = level_mins(0, ch);
    chan_maxs[ch] = level_maxs(0, ch);
    chan_sq[ch] = level_rms(0, ch);
  }

  // Planar chunk scratch: one block of chunk_frames floats per channel,
  // kChunkByteBudget in total (≥ 64 Ki frames at the kMaxChannels cap).
  const uint32_t chunk_frames = static_cast<uint32_t>(
      kChunkByteBudget / (static_cast<size_t>(channels) * sizeof(float)));
  std::vector<float> scratch(static_cast<size_t>(chunk_frames) * channels);
  std::vector<float*> chunk_ptrs(channels);
  for (uint32_t ch = 0; ch < channels; ++ch) {
    chunk_ptrs[ch] = scratch.data() + static_cast<size_t>(ch) * chunk_frames;
  }

  uint64_t frame_cursor = 0;
  while (frame_cursor < total_frames) {
    const uint32_t frames_to_read = static_cast<uint32_t>(std::min(
        static_cast<uint64_t>(chunk_frames), total_frames - frame_cursor));

    auto got = reader->ReadPlanarFloatInto(frame_cursor, frames_to_read,
                                           chunk_ptrs.data());
    if (!got.ok() || *got == 0) break;

    // Accumulate into level-0 peaks. The bin index advances
    // monotonically with the frame cursor, so track the next bin
    // boundary incrementally — one division per channel per chunk
    // instead of one per sample (which dominated the profile on long
    // multichannel files).
    for (uint32_t ch = 0; ch < channels; ++ch) {
      const float* src = chunk_ptrs[ch];
      float* mins = chan_mins[ch];
      float* maxs = chan_maxs[ch];
      float* sq = chan_sq[ch];
      uint64_t abs_frame = frame_cursor;
      auto peak_idx = static_cast<uint32_t>(abs_frame / samples_per_peak);
      uint64_t next_bin =
          (static_cast<uint64_t>(peak_idx) + 1) * samples_per_peak;
      for (uint32_t f = 0; f < static_cast<uint32_t>(*got); ++f, ++abs_frame) {
        if (abs_frame >= next_bin) {
          ++peak_idx;
          next_bin += samples_per_peak;
        }
        if (peak_idx >= out->num_peaks[0]) break;
        const float s = src[f];
        if (s < mins[peak_idx]) mins[peak_idx] = s;
        if (s > maxs[peak_idx]) maxs[peak_idx] = s;
        sq[peak_idx] += s * s;
      }
    }
    frame_cursor += *got;
  }

  // Finalise level-0: clamp empty bins (sentinel-only mins/maxs) to zero,
  // and convert sum-of-squares accumulators to RMS.
  for (uint32_t ch = 0; ch < channels; ++ch) {
    float* mn = level_mins(0, ch);
    float* mx = level_maxs(0, ch);
    float* rms = level_rms(0, ch);
    for (uint32_t p = 0; p < out->num_peaks[0]; ++p) {
      if (mn[p] > mx[p]) {
        mn[p] = 0.0f;
        mx[p] = 0.0f;
      }
      const uint64_t count =
          bin_sample_count(p, samples_per_peak, total_frames);
      rms[p] = count > 0 ? std::sqrt(rms[p] / static_cast<float>(count)) : 0.0f;
    }
  }

  // ── Build pyramid levels 1..num_levels-1 from level 0 ────────────────
  // RMS combines as the energy average over the merged child bins,
  // weighted by each child's sample count:
  //     rms = sqrt((Σ rms_i² · n_i) / Σ n_i)
  // Sample-count weighting matters for the last bin of each level, which
  // may be partial. Without it, the partial bin's contribution propagates
  // and compounds at every higher level.
  for (uint32_t l = 1; l < num_levels; ++l) {
    const uint32_t factor = 2;  // each level halves resolution
    const uint32_t prev_spp = out->samples_per_peak[l - 1];
    for (uint32_t ch = 0; ch < channels; ++ch) {
      const float* prev_mn = level_mins(l - 1, ch);
      const float* prev_mx = level_maxs(l - 1, ch);
      const float* prev_rms = level_rms(l - 1, ch);
      float* cur_mn = level_mins(l, ch);
      float* cur_mx = level_maxs(l, ch);
      float* cur_rms = level_rms(l, ch);
      const uint32_t prev_peaks = out->num_peaks[l - 1];

      for (uint32_t p = 0; p < out->num_peaks[l]; ++p) {
        const uint32_t start = p * factor;
        const uint32_t end = std::min(start + factor, prev_peaks);
        float lo = prev_mn[start], hi = prev_mx[start];
        const uint64_t n_start =
            bin_sample_count(start, prev_spp, total_frames);
        float weighted_sum_sq =
            prev_rms[start] * prev_rms[start] * static_cast<float>(n_start);
        uint64_t total_count = n_start;
        for (uint32_t i = start + 1; i < end; ++i) {
          if (prev_mn[i] < lo) lo = prev_mn[i];
          if (prev_mx[i] > hi) hi = prev_mx[i];
          const uint64_t n_i = bin_sample_count(i, prev_spp, total_frames);
          weighted_sum_sq +=
              prev_rms[i] * prev_rms[i] * static_cast<float>(n_i);
          total_count += n_i;
        }
        cur_mn[p] = lo;
        cur_mx[p] = hi;
        cur_rms[p] =
            total_count > 0
                ? std::sqrt(weighted_sum_sq / static_cast<float>(total_count))
                : 0.0f;
      }
    }
  }

  return out;
}

// static
void PeakCompute::destroy(const EclipsaStudioPeakData* data) {
  std::free(const_cast<EclipsaStudioPeakData*>(data));
}

// static
const float* PeakCompute::level_data(const EclipsaStudioPeakData* data,
                                     uint32_t level, uint32_t channel) {
  if (!data || level >= data->num_levels || channel >= data->num_channels) {
    return nullptr;
  }
  const auto* raw = reinterpret_cast<const uint8_t*>(data);
  const auto* float_base =
      reinterpret_cast<const float*>(raw + sizeof(EclipsaStudioPeakData));
  return float_base + data_offset_floats(data, level, channel);
}

// ── C FFI wrappers ────────────────────────────────────────────────────────

extern "C" {

const EclipsaStudioPeakData* eclipsa_studio_peaks_compute(
    const char* wav_path, uint32_t samples_per_peak, uint32_t num_levels) {
  return PeakCompute::compute(wav_path, samples_per_peak, num_levels);
}

void eclipsa_studio_peaks_free(const EclipsaStudioPeakData* data) {
  PeakCompute::destroy(data);
}

const float* eclipsa_studio_peaks_level_data(const EclipsaStudioPeakData* data,
                                             uint32_t level, uint32_t channel) {
  return PeakCompute::level_data(data, level, channel);
}

}  // extern "C"
