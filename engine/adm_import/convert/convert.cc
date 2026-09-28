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

#include "adm_import/convert/convert.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"
#include "absl/types/span.h"
#include "adm_import/adm/adm_model.h"
#include "adm_import/adm/adm_parser.h"
#include "adm_import/adm/common_definitions.h"
#include "adm_import/render/channel_renderer.h"
#include "adm_import/scene/adm_adapter.h"
#include "adm_import/scene/layouts.h"
#include "adm_import/scene/scene.h"
#include "adm_import/wav/bw64_reader.h"
#include "dsp/resampler.h"
#include "graph/audio_buffer.h"

namespace adm2iamf {
namespace {

// The render front-end: open the BW64, parse axml + chna into the ADM
// model, build the canonical scene, and read the PCM.
struct LoadedAdm {
  Scene scene;
  std::vector<std::vector<float>> tracks;
  uint32_t sample_rate = 0;
};

absl::StatusOr<LoadedAdm> LoadAdm(absl::string_view input_path) {
  auto reader = Bw64Reader::Open(std::string(input_path));
  if (!reader.ok()) return reader.status();
  if ((*reader)->axml().empty()) {
    return absl::InvalidArgumentError(
        "Input has no `axml` chunk; not an ADM-BWF file.");
  }

  auto model = adm::ParseAxml((*reader)->axml());
  if (!model.ok()) return model.status();

  if (!(*reader)->chna().empty()) {
    auto chna = adm::ParseChna(absl::MakeConstSpan((*reader)->chna()));
    if (!chna.ok()) return chna.status();
    model->chna = *chna;
  }

  // Resolve any BS.2094 common-definition beds the axml references but does not
  // inline (EBU/ITU files carry beds this way).
  adm::ResolveCommonDefinitions(*model);

  auto scene = BuildSceneFromAdm(*model);
  if (!scene.ok()) return scene.status();

  LoadedAdm loaded;
  loaded.scene = *std::move(scene);
  loaded.sample_rate = (*reader)->format().sample_rate;
  auto frames =
      (*reader)->ReadPlanarFloat(0, (*reader)->num_frames(), loaded.tracks);
  if (!frames.ok()) return frames.status();
  return loaded;
}

// Resamples the rendered bed (planar, all channels equal length) from
// `in_rate` to `out_rate` through dsp::Resampler at the export tier, the
// engine's single libsamplerate entry point. The output is trimmed or
// zero-padded to the source duration at the new rate, as the export bounce
// (ElementStream) does, so every channel keeps one length. `progress`, when
// non-null, receives (frames consumed, frames total) and is polled for
// cancellation.
absl::StatusOr<std::vector<std::vector<float>>> ResampleBed(
    const std::vector<std::vector<float>>& in, uint32_t in_rate,
    uint32_t out_rate, const RenderProgress* progress) {
  const uint32_t channels = static_cast<uint32_t>(in.size());
  const uint64_t in_frames = in.empty() ? 0 : in[0].size();
  const uint64_t out_frames = (in_frames * out_rate + in_rate / 2) / in_rate;
  std::vector<std::vector<float>> out(channels);
  if (channels == 0 || in_frames == 0) {
    for (auto& ch : out) ch.assign(static_cast<size_t>(out_frames), 0.0f);
    return out;
  }

  constexpr uint32_t kChunk = 4096;  // Output frames per consume().
  dsp::Resampler rs;
  if (!rs.init(in_rate, out_rate, channels, kChunk,
               dsp::Resampler::Quality::kExport)) {
    return absl::InternalError(absl::StrCat("resampler init failed (", in_rate,
                                            " -> ", out_rate, " Hz, ", channels,
                                            " ch)."));
  }
  std::vector<float> scratch(static_cast<size_t>(channels) * kChunk, 0.0f);
  AudioBuffer ob;
  ob.data = scratch.data();
  ob.channels = channels;
  ob.frames = 0;
  ob.capacity_frames = kChunk;
  for (auto& ch : out) ch.reserve(static_cast<size_t>(out_frames) + kChunk);

  const auto append = [&](uint32_t got) {
    for (uint32_t ch = 0; ch < channels; ++ch) {
      const float* src = ob.channel(ch);
      out[ch].insert(out[ch].end(), src, src + got);
    }
  };

  uint64_t consumed = 0;
  while (consumed < in_frames) {
    AudioBuffer& rin = rs.input_buffer();
    const uint64_t want_in =
        std::min<uint64_t>(rs.required_input(kChunk), rin.capacity_frames);
    const uint32_t got_in = static_cast<uint32_t>(
        std::min<uint64_t>(want_in, in_frames - consumed));
    for (uint32_t ch = 0; ch < channels; ++ch) {
      std::copy_n(in[ch].data() + consumed, got_in, rin.channel(ch));
    }
    rin.frames = got_in;
    consumed += got_in;
    const uint32_t got = rs.consume(ob, got_in, kChunk);
    append(got);
    // No input taken and nothing produced: the converter is stalled (cannot
    // happen with required_input()'s headroom); drain what it holds.
    if (got_in == 0 && got == 0) break;
    if (progress != nullptr) {
      progress->Report(consumed, in_frames);
      if (progress->ShouldCancel()) {
        return absl::CancelledError("render cancelled");
      }
    }
  }
  for (;;) {
    const uint32_t got = rs.flush(ob, kChunk);
    if (got == 0) break;
    append(got);
  }
  for (auto& ch : out) ch.resize(static_cast<size_t>(out_frames), 0.0f);
  return out;
}

}  // namespace

absl::StatusOr<ConvertResult> ConvertAdmFileToChannelBed(
    absl::string_view input_path, int min_importance,
    const RenderProgress* progress) {
  auto loaded = LoadAdm(input_path);
  if (!loaded.ok()) return loaded.status();

  const uint32_t source_rate = loaded->sample_rate;
  const bool resample = source_rate != kBedSampleRate;

  // Progress: with a resample pass to follow, the render owns the first 80%
  // of the range and the resample the last 20%; otherwise the render reports
  // straight through. Cancellation is shared.
  RenderProgress render_progress;
  RenderProgress resample_progress;
  if (progress != nullptr) {
    render_progress.should_cancel = progress->should_cancel;
    resample_progress.should_cancel = progress->should_cancel;
    render_progress.report = [progress, resample](uint64_t done,
                                                  uint64_t total) {
      if (resample) {
        progress->Report(done * 4, total * 5);
      } else {
        progress->Report(done, total);
      }
    };
    resample_progress.report = [progress](uint64_t done, uint64_t total) {
      progress->Report(total * 4 + done, total * 5);
    };
  }

  ConvertResult result;
  auto channels =
      RenderChannelBed(loaded->scene, ImportLayout(), loaded->tracks,
                       source_rate, min_importance, &result.stats,
                       progress != nullptr ? &render_progress : nullptr);
  if (!channels.ok()) return channels.status();
  result.channels = *std::move(channels);
  result.sample_rate = source_rate;

  if (resample) {
    auto resampled =
        ResampleBed(result.channels, source_rate, kBedSampleRate,
                    progress != nullptr ? &resample_progress : nullptr);
    if (!resampled.ok()) return resampled.status();
    result.channels = *std::move(resampled);
    result.sample_rate = kBedSampleRate;
  }
  return result;
}

}  // namespace adm2iamf
