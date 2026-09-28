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

//
// The canonical sample conversions. Everything that quantizes, normalizes or
// justifies a sample goes through these — there is exactly one quantizer in
// the library.
//
// Float → integer quantization: round-to-nearest (`llrint` under the default
// FE_TONEAREST mode, so exact ties round to even) at the symmetric 2^(bits-1)
// scale, with the positive edge clamped (where +1.0 would overflow by one
// code) and NaN mapped to 0. A dequantized integer sample round-trips to the
// same code, so integer → float → integer passthrough is bit-transparent.
//
// Integer → float normalization divides by 2^(bits-1), matching the
// quantizer's scale.
//
// Left-justified int32 places a sample's significant bits at the top of an
// int32 (the iamf-tools `WavReader` convention): uint8 → (v-128)<<24,
// int16 → v<<16, int24 → v<<8, int32 as-is, float → quantized at 2^31.

#ifndef ECLIPSA_STUDIO_WAV_CONVERT_H_
#define ECLIPSA_STUDIO_WAV_CONVERT_H_

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

namespace wav {

// ── Float → integer codes (the quantizer) ─────────────────────────────────

namespace internal {

// The one quantizer skeleton (not part of the public API — call the named
// per-width converters below): NaN → 0, clamp to ±1.0, round-to-nearest at
// the symmetric 2^(bits-1) scale, positive edge clamped to the max code
// (where +1.0 would overflow by one code). The math runs in double for
// every width — float input promotes exactly, and a power-of-two multiply
// is exact in both float and double, so this is bit-identical to per-width
// float math. llrint (not lrint): the pre-clamp value at s = 1.0 is
// +2^(bits-1), which for 32-bit codes overflows `long` on Windows (32-bit
// there). Deriving scale and max code from one `bits` makes mismatched
// pairings unrepresentable.
inline int32_t QuantizeToCode(double s, int bits) {
  if (std::isnan(s)) return 0;
  if (s > 1.0) s = 1.0;
  if (s < -1.0) s = -1.0;
  const int64_t v =
      std::llrint(s * static_cast<double>(int64_t{1} << (bits - 1)));
  return static_cast<int32_t>(std::min(v, (int64_t{1} << (bits - 1)) - 1));
}

}  // namespace internal

inline int32_t FloatToInt16Code(float s) {
  return internal::QuantizeToCode(s, 16);
}

inline int32_t FloatToInt24Code(float s) {
  return internal::QuantizeToCode(s, 24);
}

inline int32_t FloatToInt32Code(float s) {
  return internal::QuantizeToCode(s, 32);
}

inline int32_t DoubleToInt32Code(double s) {
  return internal::QuantizeToCode(s, 32);
}

// ── IEEE-float sources → finite float32 ───────────────────────────────────
// Float WAVs legitimately carry headroom (values beyond ±1.0 in mix stems
// and bounces), so float delivery preserves magnitudes verbatim. What it
// does guarantee is *finiteness*: NaN maps to 0 and ±inf — plus float64
// magnitudes beyond FLT_MAX, where a bare double → float narrowing is
// undefined behavior — saturate to ±FLT_MAX.

inline float SanitizeFloatSample(float v) {
  if (std::isnan(v)) return 0.0f;
  if (v > std::numeric_limits<float>::max()) {
    return std::numeric_limits<float>::max();
  }
  if (v < std::numeric_limits<float>::lowest()) {
    return std::numeric_limits<float>::lowest();
  }
  return v;
}

inline float SanitizeDoubleSample(double v) {
  if (std::isnan(v)) return 0.0f;
  if (v > static_cast<double>(std::numeric_limits<float>::max())) {
    return std::numeric_limits<float>::max();
  }
  if (v < static_cast<double>(std::numeric_limits<float>::lowest())) {
    return std::numeric_limits<float>::lowest();
  }
  return static_cast<float>(v);
}

// ── Integer codes → normalized float ──────────────────────────────────────

inline float Uint8CodeToFloat(uint8_t v) {
  return (static_cast<int>(v) - 128) / 128.0f;
}

inline float Int16CodeToFloat(int16_t v) { return v / 32768.0f; }

// `v` holds a sign-extended 24-bit code.
inline float Int24CodeToFloat(int32_t v) { return v / 8388608.0f; }

inline float Int32CodeToFloat(int32_t v) {
  // Divide in double (int32 doesn't fit float exactly), then narrow once.
  return static_cast<float>(v / 2147483648.0);
}

// ── → left-justified int32 (iamf-tools delivery convention) ───────────────

inline int32_t Uint8ToInt32Lj(uint8_t v) {
  // (v - 128) << 24, via unsigned arithmetic to avoid signed-shift UB.
  return static_cast<int32_t>((static_cast<uint32_t>(v) ^ 0x80u) << 24);
}

inline int32_t Int16ToInt32Lj(int16_t v) {
  return static_cast<int32_t>(static_cast<uint32_t>(static_cast<uint16_t>(v))
                              << 16);
}

// `v` holds a sign-extended 24-bit code.
inline int32_t Int24ToInt32Lj(int32_t v) {
  return static_cast<int32_t>(static_cast<uint32_t>(v) << 8);
}

inline int32_t FloatToInt32Lj(float s) { return FloatToInt32Code(s); }
inline int32_t DoubleToInt32Lj(double s) { return DoubleToInt32Code(s); }

// ── Left-justified int32 → narrower codes (writer input path) ─────────────

namespace internal {

// The one re-quantizer skeleton (not public API; `bits` < 32): round-to-
// nearest on the discarded low bits, positive edge clamped, so a left-
// justified code with zero low bits converts exactly. Note: exact
// half-LSB ties round toward +infinity here, unlike QuantizeToCode's
// ties-to-even — an intentional trade for branch-free integer math,
// pinned by convert_test.cc. Don't "fix" one path to match the other.
inline int32_t Int32LjToCode(int32_t v, int bits) {
  const int drop_bits = 32 - bits;
  const int64_t r =
      (static_cast<int64_t>(v) + (int64_t{1} << (drop_bits - 1))) >> drop_bits;
  return static_cast<int32_t>(std::min(r, (int64_t{1} << (bits - 1)) - 1));
}

}  // namespace internal

inline int32_t Int32LjToInt16Code(int32_t v) {
  return internal::Int32LjToCode(v, 16);
}

inline int32_t Int32LjToInt24Code(int32_t v) {
  return internal::Int32LjToCode(v, 24);
}

inline float Int32LjToFloat(int32_t v) { return Int32CodeToFloat(v); }

}  // namespace wav

#endif  // ECLIPSA_STUDIO_WAV_CONVERT_H_
