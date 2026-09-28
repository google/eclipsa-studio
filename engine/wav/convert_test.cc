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

//
// Pins the canonical quantizer's semantics: llrint round-to-nearest (ties to
// even under the default FE_TONEAREST mode), symmetric 2^(bits-1) scale,
// positive-edge clamp, NaN → 0, and exact round-trips for dequantized codes.

#include "wav/convert.h"

#include <cmath>
#include <cstdint>
#include <limits>

#include "gtest/gtest.h"

namespace wav {
namespace {

constexpr float kNanF = std::numeric_limits<float>::quiet_NaN();
constexpr double kNanD = std::numeric_limits<double>::quiet_NaN();

TEST(FloatToInt16Code, EdgesClampAndNan) {
  EXPECT_EQ(FloatToInt16Code(0.0f), 0);
  EXPECT_EQ(FloatToInt16Code(1.0f), 32767);    // +1.0 clamps by one code.
  EXPECT_EQ(FloatToInt16Code(-1.0f), -32768);  // -1.0 is exactly full scale.
  EXPECT_EQ(FloatToInt16Code(2.0f), 32767);
  EXPECT_EQ(FloatToInt16Code(-2.0f), -32768);
  EXPECT_EQ(FloatToInt16Code(kNanF), 0);
}

TEST(FloatToInt16Code, DequantizedCodesRoundTrip) {
  const int32_t codes[] = {-32768, -32767, -12345, -1, 0, 1, 12345, 32767};
  for (const int32_t code : codes) {
    EXPECT_EQ(FloatToInt16Code(code / 32768.0f), code) << code;
  }
}

TEST(FloatToInt16Code, HalfLsbTiesRoundToEven) {
  EXPECT_EQ(FloatToInt16Code(0.5f / 32768.0f), 0);
  EXPECT_EQ(FloatToInt16Code(1.5f / 32768.0f), 2);
  EXPECT_EQ(FloatToInt16Code(2.5f / 32768.0f), 2);
  EXPECT_EQ(FloatToInt16Code(-0.5f / 32768.0f), 0);
  EXPECT_EQ(FloatToInt16Code(-1.5f / 32768.0f), -2);
}

TEST(FloatToInt24Code, EdgesAndRoundTrip) {
  EXPECT_EQ(FloatToInt24Code(1.0f), 8388607);
  EXPECT_EQ(FloatToInt24Code(-1.0f), -8388608);
  EXPECT_EQ(FloatToInt24Code(kNanF), 0);
  const int32_t codes[] = {-8388608, -1, 0, 1, 4194304, 8388607};
  for (const int32_t code : codes) {
    EXPECT_EQ(FloatToInt24Code(code / 8388608.0f), code) << code;
  }
  EXPECT_EQ(FloatToInt24Code(0.5f / 8388608.0f), 0);  // Tie to even.
  EXPECT_EQ(FloatToInt24Code(1.5f / 8388608.0f), 2);
}

TEST(FloatToInt32Code, EdgesClampAndNan) {
  EXPECT_EQ(FloatToInt32Code(0.0f), 0);
  EXPECT_EQ(FloatToInt32Code(1.0f), 2147483647);
  EXPECT_EQ(FloatToInt32Code(-1.0f), std::numeric_limits<int32_t>::min());
  EXPECT_EQ(FloatToInt32Code(2.0f), 2147483647);
  EXPECT_EQ(FloatToInt32Code(kNanF), 0);
}

TEST(FloatToInt32Code, DequantizedCodesRoundTrip) {
  // Codes with <= 24 significant bits survive the trip through float32.
  const int32_t codes[] = {std::numeric_limits<int32_t>::min(),
                           -256,
                           0,
                           256,
                           123456 * 256,
                           8388607 * 256};
  for (const int32_t code : codes) {
    EXPECT_EQ(FloatToInt32Code(Int32CodeToFloat(code)), code) << code;
  }
}

TEST(DoubleToInt32Code, ExactForAllCodes) {
  // double carries int32 exactly, so every code round-trips.
  const int32_t codes[] = {
      std::numeric_limits<int32_t>::min(),    -3, -1, 0, 1, 7,
      std::numeric_limits<int32_t>::max() - 1};
  for (const int32_t code : codes) {
    EXPECT_EQ(DoubleToInt32Code(code / 2147483648.0), code) << code;
  }
  EXPECT_EQ(DoubleToInt32Code(1.0), 2147483647);
  EXPECT_EQ(DoubleToInt32Code(-1.0), std::numeric_limits<int32_t>::min());
  EXPECT_EQ(DoubleToInt32Code(kNanD), 0);
}

TEST(CodeToFloat, NormalizesAtTheQuantizerScale) {
  EXPECT_EQ(Uint8CodeToFloat(128), 0.0f);
  EXPECT_EQ(Uint8CodeToFloat(0), -1.0f);
  EXPECT_EQ(Uint8CodeToFloat(255), 127.0f / 128.0f);
  EXPECT_EQ(Int16CodeToFloat(-32768), -1.0f);
  EXPECT_EQ(Int16CodeToFloat(16384), 0.5f);
  EXPECT_EQ(Int24CodeToFloat(-8388608), -1.0f);
  EXPECT_EQ(Int32CodeToFloat(std::numeric_limits<int32_t>::min()), -1.0f);
}

TEST(Int32Lj, JustifiesSignificantBitsToTheTop) {
  EXPECT_EQ(Uint8ToInt32Lj(0), std::numeric_limits<int32_t>::min());
  EXPECT_EQ(Uint8ToInt32Lj(128), 0);
  EXPECT_EQ(Uint8ToInt32Lj(255), 127 << 24);
  EXPECT_EQ(Int16ToInt32Lj(-32768), std::numeric_limits<int32_t>::min());
  EXPECT_EQ(Int16ToInt32Lj(0), 0);
  EXPECT_EQ(Int16ToInt32Lj(32767), 32767 << 16);
  EXPECT_EQ(Int24ToInt32Lj(-8388608), std::numeric_limits<int32_t>::min());
  EXPECT_EQ(Int24ToInt32Lj(8388607), 8388607 * 256);
  EXPECT_EQ(FloatToInt32Lj(1.0f), 2147483647);
  EXPECT_EQ(FloatToInt32Lj(kNanF), 0);
  EXPECT_EQ(DoubleToInt32Lj(-1.0), std::numeric_limits<int32_t>::min());
}

TEST(Int32LjToNarrower, ExactWhenLowBitsAreZeroRoundedOtherwise) {
  EXPECT_EQ(Int32LjToInt16Code(5 << 16), 5);
  EXPECT_EQ(Int32LjToInt16Code(-5 * 65536), -5);
  // Half-LSB remainders round upward (toward +inf). The negative tie is
  // the case that separates toward-+inf from away-from-zero (which would
  // give -5) — the asymmetry the convert.h comment warns against "fixing".
  EXPECT_EQ(Int32LjToInt16Code((5 << 16) + 0x8000), 6);
  EXPECT_EQ(Int32LjToInt16Code((5 << 16) + 0x7FFF), 5);
  EXPECT_EQ(Int32LjToInt16Code(-5 * 65536 + 0x8000), -4);
  // The positive edge clamps instead of wrapping.
  EXPECT_EQ(Int32LjToInt16Code(std::numeric_limits<int32_t>::max()), 32767);
  EXPECT_EQ(Int32LjToInt16Code(std::numeric_limits<int32_t>::min()), -32768);

  EXPECT_EQ(Int32LjToInt24Code(7 * 256), 7);
  EXPECT_EQ(Int32LjToInt24Code((7 * 256) + 128), 8);
  EXPECT_EQ(Int32LjToInt24Code(std::numeric_limits<int32_t>::max()), 8388607);
  EXPECT_EQ(Int32LjToInt24Code(std::numeric_limits<int32_t>::min()), -8388608);

  EXPECT_EQ(Int32LjToFloat(std::numeric_limits<int32_t>::min()), -1.0f);
  EXPECT_EQ(Int32LjToFloat(1 << 30), 0.5f);
}

}  // namespace
}  // namespace wav
