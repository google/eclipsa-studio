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

#include "dsp/sh_decode.h"

#include <cmath>
#include <cstdint>
#include <vector>

#include "Eigen/Core"
#include "obr/ambisonic_encoder/associated_legendre_polynomials_generator.h"
#include "obr/common/ambisonic_utils.h"

namespace {

constexpr float kPi = 3.14159265358979323846f;

/// Legendre polynomial P_n(x) via recurrence.
float LegendreP(int n, float x) {
  if (n == 0) return 1.0f;
  if (n == 1) return x;
  float prev2 = 1.0f;
  float prev1 = x;
  float pn = 0.0f;
  for (int k = 2; k <= n; ++k) {
    pn = ((2.0f * k - 1.0f) * x * prev1 - (k - 1.0f) * prev2) /
         static_cast<float>(k);
    prev2 = prev1;
    prev1 = pn;
  }
  return pn;
}

/// Compute per-order directivity weights.
std::vector<float> ComputeWeights(int max_order, uint32_t type) {
  std::vector<float> w(max_order + 1);
  switch (type) {
    case 0:  // Basic
      for (int n = 0; n <= max_order; ++n) w[n] = 1.0f;
      break;

    case 1: {  // MaxRe
      float x_max =
          std::cos(kPi / (2.0f * static_cast<float>(max_order) + 3.0f));
      for (int n = 0; n <= max_order; ++n) {
        w[n] = LegendreP(n, x_max);
      }
      break;
    }

    case 2:  // InPhase
      for (int n = 0; n <= max_order; ++n) {
        if (n == 0) {
          w[n] = 1.0f;
          continue;
        }
        float wt = 1.0f;
        for (int k = 1; k <= n; ++k) {
          wt *= static_cast<float>((max_order - k + 1) * (max_order - k + 2)) /
                static_cast<float>((max_order + k) * (max_order + k + 1));
        }
        w[n] = wt;
      }
      break;

    default:
      for (int n = 0; n <= max_order; ++n) w[n] = 1.0f;
      break;
  }
  return w;
}

/// Angular component for real SH: cos(m*az) for m>0, sin(|m|*az) for m<0.
float AngularComponent(int m, float azimuth) {
  if (m > 0) return std::cos(static_cast<float>(m) * azimuth);
  if (m < 0) return std::sin(static_cast<float>(-m) * azimuth);
  return 1.0f;
}

}  // namespace

struct EclipsaStudioShDecoder {
  Eigen::MatrixXf decode_matrix;  // [num_probes x num_channels]
  uint32_t num_probes;
  uint32_t num_channels;
};

EclipsaStudioShDecoder* eclipsa_studio_sh_decoder_create(uint32_t num_probes,
                                                         const float* probe_az,
                                                         const float* probe_el,
                                                         uint32_t order,
                                                         uint32_t directivity) {
  if (num_probes == 0 || order == 0 || order > 7 || !probe_az || !probe_el) {
    return nullptr;
  }

  const auto num_channels = static_cast<uint32_t>(
      obr::GetNumPeriphonicComponents(static_cast<int>(order)));
  const auto weights = ComputeWeights(static_cast<int>(order), directivity);

  // ALP generator without Condon-Shortley phase (ambiX convention).
  obr::AssociatedLegendrePolynomialsGenerator alp_gen(
      static_cast<int>(order), /*condon_shortley_phase=*/false,
      /*compute_negative_order=*/false);

  Eigen::MatrixXf mat(num_probes, num_channels);

  for (uint32_t p = 0; p < num_probes; ++p) {
    const float az = probe_az[p];
    const float el = probe_el[p];
    const auto alps = alp_gen.Generate(std::sin(el));

    for (int l = 0; l <= static_cast<int>(order); ++l) {
      const float w = weights[l];
      for (int m = -l; m <= l; ++m) {
        const int idx = obr::AcnSequence(l, m);
        const float norm = obr::Sn3dNormalization(l, m);
        const float legendre = alps[alp_gen.GetIndex(l, std::abs(m))];
        const float angular = AngularComponent(m, az);
        mat(p, idx) = w * norm * legendre * angular;
      }
    }
  }

  auto* decoder = new EclipsaStudioShDecoder();
  decoder->decode_matrix = std::move(mat);
  decoder->num_probes = num_probes;
  decoder->num_channels = num_channels;
  return decoder;
}

void eclipsa_studio_sh_decode(const EclipsaStudioShDecoder* decoder,
                              const float* coeffs, float* out_energies) {
  if (!decoder || !coeffs || !out_energies) return;

  const Eigen::Map<const Eigen::VectorXf> c(coeffs, decoder->num_channels);
  Eigen::Map<Eigen::VectorXf> out(out_energies, decoder->num_probes);
  out = (decoder->decode_matrix * c).array().square();
}

void eclipsa_studio_sh_decoder_destroy(EclipsaStudioShDecoder* decoder) {
  delete decoder;
}
