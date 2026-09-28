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

#ifndef ECLIPSA_STUDIO_DSP_SH_DECODE_H_
#define ECLIPSA_STUDIO_DSP_SH_DECODE_H_

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque SH decode handle.  NOLINT(modernize-use-using)
typedef struct EclipsaStudioShDecoder EclipsaStudioShDecoder;

/// Create a decoder for a fixed set of probe directions.
///
/// @param num_probes  Number of probe directions.
/// @param probe_az    Azimuth per probe (radians, ADM convention).
/// @param probe_el    Elevation per probe (radians).
/// @param order       Ambisonic order (1-7).
/// @param directivity 0=basic, 1=maxRe, 2=inPhase.
/// @return Opaque handle, or NULL on failure.
EclipsaStudioShDecoder* eclipsa_studio_sh_decoder_create(uint32_t num_probes,
                                                         const float* probe_az,
                                                         const float* probe_el,
                                                         uint32_t order,
                                                         uint32_t directivity);

/// Decode SH coefficients into per-probe squared energies.
///
/// @param decoder      Handle from eclipsa_studio_sh_decoder_create().
/// @param coeffs       SH coefficients (ACN/SN3D), length = (order+1)^2.
/// @param out_energies Output buffer, length = num_probes. Caller-allocated.
void eclipsa_studio_sh_decode(const EclipsaStudioShDecoder* decoder,
                              const float* coeffs, float* out_energies);

/// Destroy a decoder and free its memory.
void eclipsa_studio_sh_decoder_destroy(EclipsaStudioShDecoder* decoder);

#ifdef __cplusplus
}
#endif

#endif  // ECLIPSA_STUDIO_DSP_SH_DECODE_H_
