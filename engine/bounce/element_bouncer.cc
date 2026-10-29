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

#include "bounce/element_bouncer.h"

#include <cinttypes>
#include <cstdio>
#include <vector>

#include "bounce/element_stream.h"
#include "engine_log.h"
#include "graph/audio_buffer.h"
#include "io/wav_writer.h"
#include "wav/writer.h"

namespace eclipsa_studio {

int32_t ElementBouncer::Bounce(const Config& config) {
  // ── Open the streaming pipeline ───────────────────────────────────
  // ElementStream is the read → resample → route → gain → pad core;
  // this function is just its WAV-file sink.
  ElementStream stream;
  ElementStream::Config stream_config;
  stream_config.input_wav_path = config.input_wav_path;
  stream_config.gain_db = config.gain_db;
  stream_config.routing = config.routing;
  stream_config.pad_to_frames = config.pad_to_frames;
  stream_config.output_sample_rate = config.output_sample_rate;
  if (!stream.Open(stream_config)) {
    return -1;  // ElementStream logged the specifics.
  }

  // ── Open output ───────────────────────────────────────────────────
  // Match the source bit depth so downstream tools (notably
  // iamf-tools) get what they expect — iamf-tools refuses to encode
  // a higher-bit-depth WAV into a lower-bit-depth LPCM stream.
  // 16/24/32-bit sources write integer PCM at that depth; note that
  // float32 sources also report bit depth 32 and are therefore
  // quantized to PCM32 (headroom beyond ±1.0 clamps). 8-bit and
  // float64 sources fall back to 32-bit float.
  WavWriter writer;
  wav::WriteFormat out_format = wav::WriteFormat::kFloat32;
  switch (stream.source_bit_depth()) {
    case 16:
      out_format = wav::WriteFormat::kPcm16;
      break;
    case 24:
      out_format = wav::WriteFormat::kPcm24;
      break;
    case 32:
      out_format = wav::WriteFormat::kPcm32;
      break;
    default:
      break;
  }
  if (!writer.open(config.output_wav_path.c_str(), stream.channels(),
                   stream.sample_rate(), out_format)) {
    char buf[256];
    snprintf(buf, sizeof(buf), "Bounce: cannot open output: %s",
             config.output_wav_path.c_str());
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "bounce", buf);
    return -2;
  }

  // ── Stream to the file ────────────────────────────────────────────
  // Heap block, sized to the actual channel count. Bounce runs on a
  // control thread so heap allocation is fine; stack allocation would
  // need ~256 KiB at the channel cap and risks overflowing
  // worker-thread stacks.
  std::vector<float> out_storage(
      static_cast<size_t>(stream.channels()) * ElementStream::kMaxPullFrames,
      0.0f);
  AudioBuffer out_buf;
  out_buf.data = out_storage.data();
  out_buf.channels = stream.channels();
  out_buf.frames = 0;
  out_buf.capacity_frames = ElementStream::kMaxPullFrames;

  while (true) {
    const uint32_t got = stream.Pull(out_buf, ElementStream::kMaxPullFrames);
    if (got == 0) break;
    const uint32_t written = writer.write(out_buf, got);
    if (written < got) {
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "bounce",
                 "Bounce: short write (disk full?)");
      return -3;
    }
  }

  // A full disk often shows only when the buffered file is flushed here.
  if (!writer.close()) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "bounce",
               "Bounce: finalizing the output failed (disk full?)");
    return -3;
  }

  char buf[256];
  snprintf(buf, sizeof(buf),
           "Bounce complete: in=%" PRIu64 " out=%" PRIu64
           " frames, "
           "%u ch -> %u ch, %u -> %u Hz, gain=%.1f dB, pad_target=%" PRIu64,
           stream.source_total_frames(), writer.frames_written(),
           stream.source_channels(), stream.channels(),
           stream.source_sample_rate(), stream.sample_rate(), config.gain_db,
           config.pad_to_frames);
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "bounce", buf);
  return 0;
}

}  // namespace eclipsa_studio
