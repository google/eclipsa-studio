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

#ifndef ECLIPSA_STUDIO_TEST_TEST_WAV_HELPER_H_
#define ECLIPSA_STUDIO_TEST_TEST_WAV_HELPER_H_

/// Test WAV file generation utilities.
///
/// Writes short WAV files to disk (using the in-house wav library) for use
/// in unit tests. All functions are inline so this header can be included
/// in multiple test TUs without linker conflicts.

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

#include "wav/writer.h"

namespace test_wav {

/// Returns the Bazel-provided temporary directory (TEST_TMPDIR env var),
/// or "/tmp" as a fallback.
inline std::string temp_dir() {
  const char* td = std::getenv("TEST_TMPDIR");
  if (td && td[0] != '\0') return std::string(td);
  return "/tmp";
}

namespace internal {

inline bool bits_to_format(int bits, wav::WriteFormat& out) {
  switch (bits) {
    case 16:
      out = wav::WriteFormat::kPcm16;
      return true;
    case 24:
      out = wav::WriteFormat::kPcm24;
      return true;
    case 32:
      out = wav::WriteFormat::kPcm32;
      return true;
    default:
      return false;
  }
}

/// Writes mono-source planar data duplicated across `channels`.
inline bool write_replicated(const std::string& path, int channels,
                             int sample_rate, int bits,
                             const std::vector<float>& samples) {
  wav::WriterOptions opt;
  opt.channels = static_cast<uint16_t>(channels);
  opt.sample_rate = static_cast<uint32_t>(sample_rate);
  if (!bits_to_format(bits, opt.format)) return false;

  auto w = wav::Writer::Create(path, opt);
  if (!w.ok()) return false;
  std::vector<const float*> ptrs(static_cast<size_t>(channels), samples.data());
  return w->PushPlanarFloat(ptrs.data(), samples.size()).ok() &&
         w->Finalize().ok();
}

}  // namespace internal

/// Write a sine-wave PCM WAV file with an exact frame count. Prefer
/// this over [write_sine] when the length matters (e.g. IAMF encode
/// inputs, which must be a multiple of the coded frame size —
/// seconds-to-frames float conversion can land one frame short).
/// `amplitude` in [0, 1] leaves headroom for level-comparison tests
/// (full-scale sources trip the output limiter when summed).
inline bool write_sine_frames(const std::string& path, int channels,
                              int sample_rate, int bits, float freq_hz,
                              int total_frames, float amplitude = 1.0f) {
  // Match the historical dr_wav-era sample values exactly: the sine is
  // quantized to int16 codes (truncation toward zero, ±32767 scale), then
  // dequantized — so 16-bit output is bit-identical to the old helper and
  // higher depths carry the same waveform.
  std::vector<float> samples(static_cast<size_t>(total_frames));
  for (int i = 0; i < total_frames; ++i) {
    float t = static_cast<float>(i) / static_cast<float>(sample_rate);
    float s = std::sin(2.0f * 3.14159265358979323846f * freq_hz * t);
    auto s16 = static_cast<int16_t>(s * amplitude * 32767.0f);
    samples[static_cast<size_t>(i)] = s16 / 32768.0f;
  }
  return internal::write_replicated(path, channels, sample_rate, bits, samples);
}

/// Write a sine-wave PCM WAV file.
///
/// @param path          Output file path.
/// @param channels      Number of audio channels (1 or 2).
/// @param sample_rate   Samples per second.
/// @param bits          Bit depth (16/24/32 integer PCM).
/// @param freq_hz       Sine frequency in Hz.
/// @param duration_sec  Duration in seconds.
/// @returns true on success.
inline bool write_sine(const std::string& path, int channels, int sample_rate,
                       int bits, float freq_hz, float duration_sec) {
  return write_sine_frames(path, channels, sample_rate, bits, freq_hz,
                           static_cast<int>(sample_rate * duration_sec));
}

/// Write pre-built interleaved 16-bit PCM frames verbatim. Use when a
/// test needs per-channel or time-varying content the sine/silence
/// helpers can't express (e.g. a peak confined to one channel's tail).
inline bool write_frames_s16(const std::string& path, int channels,
                             int sample_rate,
                             const std::vector<int16_t>& interleaved) {
  wav::WriterOptions opt;
  opt.channels = static_cast<uint16_t>(channels);
  opt.sample_rate = static_cast<uint32_t>(sample_rate);
  opt.format = wav::WriteFormat::kPcm16;

  auto w = wav::Writer::Create(path, opt);
  if (!w.ok()) return false;

  // De-interleave; dequantized int16 codes round-trip bit-exactly through
  // the canonical quantizer.
  const size_t frames = interleaved.size() / static_cast<size_t>(channels);
  std::vector<std::vector<float>> planar(static_cast<size_t>(channels),
                                         std::vector<float>(frames));
  for (size_t f = 0; f < frames; ++f) {
    for (int c = 0; c < channels; ++c) {
      planar[static_cast<size_t>(c)][f] =
          interleaved[f * static_cast<size_t>(channels) +
                      static_cast<size_t>(c)] /
          32768.0f;
    }
  }
  return w->PushPlanarFloat(planar).ok() && w->Finalize().ok();
}

/// Write mono-source float32 samples duplicated across `channels`,
/// verbatim — no quantization, and magnitudes above 1.0 are preserved
/// (the writer's float path only sanitizes NaN/inf). Use for sources
/// that must carry over-full-scale content, which the integer helpers
/// above cannot express.
inline bool write_float32_frames(const std::string& path, int channels,
                                 int sample_rate,
                                 const std::vector<float>& samples) {
  wav::WriterOptions opt;
  opt.channels = static_cast<uint16_t>(channels);
  opt.sample_rate = static_cast<uint32_t>(sample_rate);
  opt.format = wav::WriteFormat::kFloat32;

  auto w = wav::Writer::Create(path, opt);
  if (!w.ok()) return false;
  std::vector<const float*> ptrs(static_cast<size_t>(channels), samples.data());
  return w->PushPlanarFloat(ptrs.data(), samples.size()).ok() &&
         w->Finalize().ok();
}

/// Write a silence WAV file.
inline bool write_silence(const std::string& path, int channels,
                          int sample_rate, int bits, float duration_sec) {
  const int total_frames = static_cast<int>(sample_rate * duration_sec);
  std::vector<float> samples(static_cast<size_t>(total_frames), 0.0f);
  return internal::write_replicated(path, channels, sample_rate, bits, samples);
}

/// Write a single-impulse WAV file (one sample at max, rest silence).
inline bool write_impulse(const std::string& path, int sample_rate, int bits,
                          int total_frames = 4096) {
  std::vector<float> samples(static_cast<size_t>(total_frames), 0.0f);
  samples[0] = 32767.0f / 32768.0f;  // Full-scale int16 impulse at frame 0.
  return internal::write_replicated(path, 1, sample_rate, bits, samples);
}

}  // namespace test_wav

#endif  // ECLIPSA_STUDIO_TEST_TEST_WAV_HELPER_H_
