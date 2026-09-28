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

// The import's loudspeaker layout and ADM speaker-label resolution.
//
// The importer renders to one layout, 7.1.4 (ImportLayout()). Its speaker
// order and angles mirror OAR's OLR layout table
// (oar/liboar/src/renderer/olr/object_audio_renderer/layout.c) exactly, so the
// channel order we write to WAV is the channel order OAR renders, and an OLR
// static source placed at a speaker's angle lands coincident on it (validated
// by the Phase 0 spike). Angle convention matches OAR: azimuth positive = left,
// elevation positive = up, degrees.

#ifndef ADM2IAMF_SCENE_LAYOUTS_H_
#define ADM2IAMF_SCENE_LAYOUTS_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "absl/strings/string_view.h"

// oar.h is a C header without its own `extern "C"` guard; wrap it so C++ TUs
// link against OAR's C symbols.
extern "C" {
#include "oar.h"
}

namespace adm2iamf {

struct Polar {
  float azimuth = 0.0f;    // Degrees, positive = left.
  float elevation = 0.0f;  // Degrees, positive = up.
  float distance = 1.0f;   // Normalized 0..1.
};

struct Speaker {
  std::string name;  // OAR/ITU label, e.g. "M+030", "U+045", "LFE1".
  float azimuth = 0.0f;
  float elevation = 0.0f;
  bool is_lfe = false;
};

// One loudspeaker layout: ordered output channels + the OAR target enum.
struct Layout {
  std::string name;  // Canonical short name, e.g. "7.1.4".
  oar_layout_t oar_layout = ck_oar_layout_none;
  std::vector<Speaker> speakers;

  int num_channels() const { return static_cast<int>(speakers.size()); }
  // Index of the (first) LFE channel, or -1 if the layout has none.
  int lfe_index() const;
};

// The fixed import target: 7.1.4 (12 channels, LFE at index 3).
const Layout& ImportLayout();

// Resolves a spec ADM `speakerLabel` to a canonical position: strips the
// BS.2094 URN wrapper, then the three LFE spellings (LFE/LFE1/LFE2), then
// Table 1B cube labels ("M_FL", ...; resolved to their general Table 2B
// direction), then structural BS.2051 labels ("M+030", "UH+180", "M+SC",
// "B-045", "T+000"). Returns nullopt for anything non-spec — the caller
// decides the fallback (cube position, physical direction, ...).
std::optional<Speaker> ResolveSpeakerLabel(absl::string_view label);

}  // namespace adm2iamf

#endif  // ADM2IAMF_SCENE_LAYOUTS_H_
