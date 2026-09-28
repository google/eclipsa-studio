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

// End-to-end ADM-BWF -> channel-bed pipeline, shared by the CLI and tests.
//
// Open BW64 -> parse axml + chna -> build canonical scene -> render to the
// requested loudspeaker layout. Output PCM is left in memory for the caller to
// write (CLI) or assert on (tests). Channel beds are the importer's only
// output; the retired binaural/ambisonic bakes are parked in adm-lab (ES-569).

#ifndef ADM2IAMF_CONVERT_CONVERT_H_
#define ADM2IAMF_CONVERT_CONVERT_H_

#include <cstdint>
#include <string>
#include <vector>

#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "adm_import/render/channel_renderer.h"
#include "adm_import/render/render_progress.h"
#include "adm_import/scene/layouts.h"

namespace adm2iamf {

// Every imported bed is written at this rate. A master at another rate is
// rendered at its own rate and the 7.1.4 bed is then resampled once, through
// dsp::Resampler at the export tier (SINC_BEST_QUALITY).
constexpr uint32_t kBedSampleRate = 48000;

struct ConvertResult {
  std::vector<std::vector<float>> channels;  // Planar, ImportLayout() order.
  uint32_t sample_rate = 0;                  // Always kBedSampleRate.
  RenderStats stats;
};

// Reads `input_path` (an ADM-BWF WAV), renders its bed + objects to
// ImportLayout() (7.1.4) and resamples the result to kBedSampleRate when the
// master's rate differs. Objects with ADM importance < `min_importance` are
// skipped. Returns an error for missing ADM metadata or an empty scene.
// `progress`, when non-null, is reported during the render (and the resample
// pass, which owns the last 20% of the range when it runs) and polled for
// cancellation (returns `absl::CancelledError` if cancelled).
absl::StatusOr<ConvertResult> ConvertAdmFileToChannelBed(
    absl::string_view input_path, int min_importance = 0,
    const RenderProgress* progress = nullptr);

}  // namespace adm2iamf

#endif  // ADM2IAMF_CONVERT_CONVERT_H_
