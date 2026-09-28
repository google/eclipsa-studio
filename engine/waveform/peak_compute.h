/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef ECLIPSA_STUDIO_WAVEFORM_PEAK_COMPUTE_H_
#define ECLIPSA_STUDIO_WAVEFORM_PEAK_COMPUTE_H_

#include <cstdint>

/// Maximum pyramid levels supported.
static constexpr uint32_t kPeakMaxLevels = 8;

/// Flat C struct returned by eclipsa_studio_peaks_compute().
///
/// The float data immediately follows this header in memory:
///   for each level l in [0, num_levels):
///     for each channel ch in [0, num_channels):
///       num_peaks[l] floats  (mins)
///       num_peaks[l] floats  (maxs)
///       num_peaks[l] floats  (rms)
///
/// Use eclipsa_studio_peaks_level_data() to get the pointer to a level/channel
/// pair. The returned pointer points at the mins array; maxs and rms follow at
/// offsets num_peaks[l] and 2*num_peaks[l] respectively.
typedef struct {
  uint32_t num_channels;
  uint32_t num_levels;
  uint32_t sample_rate;
  uint32_t total_samples;  ///< Total frames per channel.

  uint32_t samples_per_peak[kPeakMaxLevels];  ///< samplesPerPeak per level.
  uint32_t num_peaks[kPeakMaxLevels];         ///< Number of peaks per level.
} EclipsaStudioPeakData;

// ── C FFI API (callable from Dart via dart:ffi) ───────────────────────────

#ifdef __cplusplus
extern "C" {
#endif

/// Compute a multi-resolution peak pyramid for a WAV file.
/// Runs on the calling thread — never on the audio thread.
/// @returns Heap-allocated EclipsaStudioPeakData, or null on error.
///          Caller must free with eclipsa_studio_peaks_free().
const EclipsaStudioPeakData* eclipsa_studio_peaks_compute(
    const char* wav_path, uint32_t samples_per_peak, uint32_t num_levels);

/// Free peak data returned by eclipsa_studio_peaks_compute().
void eclipsa_studio_peaks_free(const EclipsaStudioPeakData* data);

/// Get a pointer to the float data for (level, channel).
/// Returns pointer to the mins array; maxs immediately follow (same size).
/// Returns null if data is null or indices are out of range.
const float* eclipsa_studio_peaks_level_data(const EclipsaStudioPeakData* data,
                                             uint32_t level, uint32_t channel);

#ifdef __cplusplus
}

// ── C++ class API ─────────────────────────────────────────────────────────

#include <memory>
#include <vector>

/// Peak pyramid computation for a WAV file.
///
/// Designed for the calling/UI thread — never runs on the audio thread.
/// Uses chunked reads to keep RAM usage bounded regardless of file size.
class PeakCompute {
 public:
  /// Compute a multi-resolution peak pyramid for a WAV file.
  ///
  /// @param wav_path          Path to the WAV file.
  /// @param samples_per_peak  Base resolution (e.g. 256).
  /// @param num_levels        Number of pyramid levels (each halves
  /// resolution).
  /// @returns Heap-allocated EclipsaStudioPeakData, or nullptr on error.
  ///          Caller must free with destroy().
  static EclipsaStudioPeakData* compute(const char* wav_path,
                                        uint32_t samples_per_peak,
                                        uint32_t num_levels);

  /// Free data returned by compute().
  static void destroy(const EclipsaStudioPeakData* data);

  /// Get a pointer to the mins array for (level, channel).
  /// The maxs array immediately follows (same size).
  static const float* level_data(const EclipsaStudioPeakData* data,
                                 uint32_t level, uint32_t channel);

 private:
  PeakCompute() = delete;
};

#endif  // __cplusplus

#endif  // ECLIPSA_STUDIO_WAVEFORM_PEAK_COMPUTE_H_
