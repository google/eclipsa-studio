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

#ifndef ECLIPSA_STUDIO_METERS_BS1770_WEIGHTS_H_
#define ECLIPSA_STUDIO_METERS_BS1770_WEIGHTS_H_

#include <cstdint>
#include <vector>

namespace eclipsa_studio {

/// BS.1770 per-channel weights for an OAR output layout, mirrored from
/// iamf-tools' `GetItu1770_4ChannelWeights`
/// (iamf/cli/itu_1770_4/loudness_calculator_itu_1770_4.cc). Each weight
/// vector matches OAR's planar output channel order — verified against
/// liboar/src/renderer/ear/m2m_rdr.c.
///
/// @param layout  oar_layout_t value (2=stereo, 3=5.1, 8=7.1.4, …).
/// @returns weights ordered to match the layout's channels; empty vector
///          if the layout isn't in the table (callers fall back to
///          uniform 1.0).
std::vector<float> Bs1770WeightsForLayout(uint32_t layout);

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_METERS_BS1770_WEIGHTS_H_
