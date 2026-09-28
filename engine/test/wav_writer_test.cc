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

#include <cstdint>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "io/wav_reader.h"
#include "test/test_wav_helper.h"
#include "wav/writer.h"

namespace {

// Round-trip helper: write `values` (one mono channel of float samples)
// as integer PCM at `bits`, read the file back as f32, and return the
// decoded samples.
std::vector<float> RoundTrip(const std::string& path,
                             const std::vector<float>& values, uint32_t bits) {
  const auto frames = static_cast<uint32_t>(values.size());

  AudioBuffer buf;
  std::vector<float> storage = values;
  buf.data = storage.data();
  buf.channels = 1;
  buf.frames = frames;
  buf.capacity_frames = frames;

  const wav::WriteFormat fmt = bits == 16   ? wav::WriteFormat::kPcm16
                               : bits == 24 ? wav::WriteFormat::kPcm24
                                            : wav::WriteFormat::kPcm32;
  WavWriter w;
  EXPECT_TRUE(w.open(path.c_str(), 1, 48000, fmt));
  EXPECT_EQ(w.write(buf, frames), frames);
  w.close();

  WavReader r;
  EXPECT_TRUE(r.open(path.c_str()));
  EXPECT_EQ(r.bit_depth(), bits);
  EXPECT_EQ(r.total_frames(), frames);

  std::vector<float> out_storage(frames, 0.0f);
  AudioBuffer out;
  out.data = out_storage.data();
  out.channels = 1;
  out.frames = 0;
  out.capacity_frames = frames;
  EXPECT_EQ(r.read(out, frames), frames);
  return out_storage;
}

// Every 16-bit code must survive write → read unchanged (issue ES-40:
// dr_wav's truncating converter shifted the whole signal down 1 LSB).
TEST(WavWriterTest, S16RoundTripIsBitTransparent) {
  std::vector<float> in;
  std::vector<int32_t> codes = {-32768, -32767, -2, -1, 0, 1, 2, 32766, 32767};
  for (int32_t v = -512; v <= 512; ++v) codes.push_back(v);
  in.reserve(codes.size());
  for (int32_t v : codes) in.push_back(static_cast<float>(v) / 32768.0f);

  const std::string path = test_wav::temp_dir() + "/rt16.wav";
  const std::vector<float> out = RoundTrip(path, in, 16);

  ASSERT_EQ(out.size(), in.size());
  for (size_t i = 0; i < in.size(); ++i) {
    EXPECT_EQ(out[i], in[i]) << "code " << codes[i];
  }
}

TEST(WavWriterTest, S16SilenceEncodesAsZero) {
  const std::vector<float> in(256, 0.0f);
  const std::string path = test_wav::temp_dir() + "/silence16.wav";
  const std::vector<float> out = RoundTrip(path, in, 16);
  for (float s : out) ASSERT_EQ(s, 0.0f);
}

TEST(WavWriterTest, S16ClampsBeyondFullScale) {
  const std::vector<float> in = {2.0f, -2.0f};
  const std::string path = test_wav::temp_dir() + "/clip16.wav";
  const std::vector<float> out = RoundTrip(path, in, 16);
  EXPECT_EQ(out[0], 32767.0f / 32768.0f);
  EXPECT_EQ(out[1], -1.0f);
}

TEST(WavWriterTest, S24RoundTripIsBitTransparent) {
  std::vector<int32_t> codes = {-8388608, -8388607, -2,      -1,     0,
                                1,        2,        8388606, 8388607};
  for (int32_t v = -512; v <= 512; ++v) codes.push_back(v * 12289);
  std::vector<float> in;
  in.reserve(codes.size());
  for (int32_t v : codes) in.push_back(static_cast<float>(v) / 8388608.0f);

  const std::string path = test_wav::temp_dir() + "/rt24.wav";
  const std::vector<float> out = RoundTrip(path, in, 24);

  ASSERT_EQ(out.size(), in.size());
  for (size_t i = 0; i < in.size(); ++i) {
    EXPECT_EQ(out[i], in[i]) << "code " << codes[i];
  }
}

// IEEE float output is already exact by construction; this guards the
// WavReader format-tag check (issue ES-41) against rejecting float WAVs.
TEST(WavWriterTest, FloatWavRoundTripsAndOpens) {
  const std::vector<float> in = {0.0f, 0.25f, -0.5f, 1.0f, -1.0f, 1.5f};
  const auto frames = static_cast<uint32_t>(in.size());

  AudioBuffer buf;
  std::vector<float> storage = in;
  buf.data = storage.data();
  buf.channels = 1;
  buf.frames = frames;
  buf.capacity_frames = frames;

  const std::string path = test_wav::temp_dir() + "/rt_f32.wav";
  WavWriter w;
  ASSERT_TRUE(w.open(path.c_str(), 1, 48000, wav::WriteFormat::kFloat32));
  EXPECT_EQ(w.write(buf, frames), frames);
  w.close();

  WavReader r;
  ASSERT_TRUE(r.open(path.c_str()));

  std::vector<float> out_storage(frames, -7.0f);
  AudioBuffer out;
  out.data = out_storage.data();
  out.channels = 1;
  out.frames = 0;
  out.capacity_frames = frames;
  ASSERT_EQ(r.read(out, frames), frames);
  for (size_t i = 0; i < in.size(); ++i) {
    EXPECT_EQ(out_storage[i], in[i]);  // float path stores unclamped
  }
}

// 32-bit codes with ≤ 24 significant bits are exactly representable as
// float on both sides of the round trip, so equality must be exact.
TEST(WavWriterTest, S32RoundTripIsExactForFloatRepresentableCodes) {
  const std::vector<int64_t> codes = {-2147483648LL, -8388608, -256,        0,
                                      256,           8388608,  2147483392LL};
  std::vector<float> in;
  in.reserve(codes.size());
  for (int64_t v : codes) {
    in.push_back(static_cast<float>(static_cast<double>(v) / 2147483648.0));
  }

  const std::string path = test_wav::temp_dir() + "/rt32.wav";
  const std::vector<float> out = RoundTrip(path, in, 32);

  ASSERT_EQ(out.size(), in.size());
  for (size_t i = 0; i < in.size(); ++i) {
    EXPECT_EQ(out[i], in[i]) << "code " << codes[i];
  }
}

}  // namespace
