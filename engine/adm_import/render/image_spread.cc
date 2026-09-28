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

#include "adm_import/render/image_spread.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <utility>
#include <vector>

#include "adm_import/scene/layouts.h"

namespace adm2iamf {
namespace {

// Frames per measurement block. Only the settled gain is read and OLR's gain
// crossfade completes within one block whatever its length, so this is as
// small as the renderer accepts; image_spread_test pins the figure against
// the 1024-frame blocks RenderChannelBed uses.
constexpr uint32_t kBlock = 64;

// Blocks rendered per position. The first carries OLR's crossfade from the
// previous position, the second is settled.
constexpr int kBlocks = 2;

// Gains do not depend on the rate (the crossfade is per block), but the
// renderer needs one; this is the rate the bake runs at.
constexpr uint32_t kSampleRate = 48000;

constexpr uint32_t kElemId = 1;

constexpr double kPi = 3.14159265358979323846;

}  // namespace

std::unique_ptr<ImageSpreadMeter> ImageSpreadMeter::Create(
    const Layout& layout) {
  const int num_out = layout.num_channels();
  if (num_out <= 0) return nullptr;

  oar_config_t cfg = {};
  cfg.target_layout = layout.oar_layout;
  cfg.samples_per_channel = kBlock;
  cfg.sampling_rate = kSampleRate;
  oar_t* oar = oar_create(&cfg);
  if (oar == nullptr) return nullptr;

  const int gid = oar_add_audio_group(oar);
  if (gid < 0) {
    oar_destroy(oar);
    return nullptr;
  }
  oar_audio_element_config_t ecfg;
  std::memset(&ecfg, 0, sizeof(ecfg));
  ecfg.type = ck_object_based;
  ecfg.obc.num_objects = 1;
  if (oar_add_audio_element(oar, static_cast<uint32_t>(gid), kElemId, &ecfg) !=
          0 ||
      oar_get_number_of_audio_element_channels(oar, kElemId) != 1 ||
      static_cast<int>(oar_get_number_of_output_channels(oar)) != num_out) {
    oar_destroy(oar);
    return nullptr;
  }

  std::vector<MeteredSpeaker> speakers;
  for (int ch = 0; ch < num_out; ++ch) {
    const Speaker& s = layout.speakers[ch];
    if (s.is_lfe) continue;
    const double az = s.azimuth * kPi / 180.0;
    const double el = s.elevation * kPi / 180.0;
    MeteredSpeaker m;
    m.channel = ch;
    m.x = static_cast<float>(std::cos(el) * std::cos(az));
    m.y = static_cast<float>(std::cos(el) * std::sin(az));
    m.z = static_cast<float>(std::sin(el));
    speakers.push_back(m);
  }
  if (speakers.empty()) {
    oar_destroy(oar);
    return nullptr;
  }
  return std::unique_ptr<ImageSpreadMeter>(
      new ImageSpreadMeter(oar, num_out, std::move(speakers)));
}

ImageSpreadMeter::ImageSpreadMeter(oar_t* oar, int num_channels,
                                   std::vector<MeteredSpeaker> speakers)
    : oar_(oar),
      num_channels_(num_channels),
      speakers_(std::move(speakers)),
      in_(kBlock, 1.0f),
      out_(static_cast<size_t>(num_channels) * kBlock, 0.0f) {}

ImageSpreadMeter::~ImageSpreadMeter() { oar_destroy(oar_); }

ImageSpread ImageSpreadMeter::Measure(const Polar& position) {
  for (int b = 0; b < kBlocks; ++b) {
    oar_audio_block_t ib = {in_.data(), 1, kBlock};
    if (oar_update_audio_element_data(oar_, kElemId, &ib) != 0) return {};

    oar_metadata_t md;
    std::memset(&md, 0, sizeof(md));
    md.type = ck_metadata_object_positions;
    md.duration = static_cast<int>(kBlock);
    md.object_positions.param_type = ck_param_constant;
    md.object_positions.position_type = ck_polar;
    md.object_positions.num_objects = 1;
    md.object_positions.polar_positions[0].azimuth = position.azimuth;
    md.object_positions.polar_positions[0].elevation = position.elevation;
    md.object_positions.polar_positions[0].distance = position.distance;
    if (oar_update_audio_element_metadata(oar_, kElemId, &md) != 0) return {};

    std::fill(out_.begin(), out_.end(), 0.0f);
    oar_audio_block_t ob = {out_.data(), static_cast<uint32_t>(num_channels_),
                            kBlock};
    if (oar_render(oar_, &ob) != 0) return {};
  }

  // The block's last sample is the settled gain: the input is DC 1.0 and the
  // crossfade to this position finished in the block before.
  const auto gain = [&](const MeteredSpeaker& s) {
    return static_cast<double>(
        out_[static_cast<size_t>(s.channel) * kBlock + (kBlock - 1)]);
  };

  double energy = 0;
  double ex = 0, ey = 0, ez = 0;
  for (const MeteredSpeaker& s : speakers_) {
    const double g = gain(s);
    const double p = g * g;
    energy += p;
    ex += p * s.x;
    ey += p * s.y;
    ez += p * s.z;
  }
  // Written as a negation so a non-finite gain takes this path too: a NaN
  // would otherwise pass every ordered guard below and print as `nan` in
  // the probe JSON, which fails the whole import over a drawing detail.
  if (!(energy > 1e-12)) return {};  // Silence, or a gain that is not finite.
  ex /= energy;
  ey /= energy;
  ez /= energy;

  // The energy vector's direction is the image's centre. Its length is zero
  // only when the driven speakers cancel exactly, which no layout the import
  // targets produces: an even drive of 7.1.4's mid ring, whose seven
  // speakers are not evenly spaced, still sums to 0.19 toward az 0
  // (image_spread_test pins that). The branch is defensive.
  const double mag = std::sqrt(ex * ex + ey * ey + ez * ez);
  if (mag <= 1e-9) return {90.0f, 1.0f, 0.0f, 0.0f};
  ex /= mag;
  ey /= mag;
  ez /= mag;

  // A basis for the tangent plane at that centre. e1 is the horizontal one --
  // perpendicular to the world's vertical, so an angle measured against it
  // reads as "across" rather than "up". A centre on the vertical axis has no
  // horizontal tangent to prefer; any basis does, because the image around it
  // is round.
  double e1x = -ey, e1y = ex, e1z = 0;
  const double n1 = std::sqrt(e1x * e1x + e1y * e1y);
  if (n1 < 1e-9) {
    e1x = 1;
    e1y = 0;
  } else {
    e1x /= n1;
    e1y /= n1;
  }
  const double e2x = ey * e1z - ez * e1y;
  const double e2y = ez * e1x - ex * e1z;
  const double e2z = ex * e1y - ey * e1x;

  // Two accumulations over the same gains. `spread_sq` is the plain
  // energy-weighted mean square angle -- the width, over every speaker. The
  // moment is the shape, and takes only the speakers that have a direction
  // to contribute.
  double spread_sq = 0;
  double mhh = 0, mvv = 0, mhv = 0;
  for (const MeteredSpeaker& s : speakers_) {
    const double g = gain(s);
    const double dot = std::clamp(ex * s.x + ey * s.y + ez * s.z, -1.0, 1.0);
    const double theta = std::acos(dot) * 180.0 / kPi;
    const double p = g * g / energy;
    spread_sq += p * theta * theta;

    // The offset's direction in the tangent plane. A speaker on the centre,
    // or directly opposite it, has none: it is the same angle whichever way
    // you leave the centre. Such a speaker still carries width -- an
    // antipodal one carries theta = 180, most of the total when the render
    // wraps the room -- but it must not carry shape. Splitting it evenly
    // between the axes would give a mid-ring pan at az 180 a vertical
    // extent of 29 degrees, on a ring whose speakers all sit at elevation
    // 0.
    const double wx = s.x - dot * ex;
    const double wy = s.y - dot * ey;
    const double wz = s.z - dot * ez;
    const double wn = std::sqrt(wx * wx + wy * wy + wz * wz);
    if (wn <= 1e-9) continue;
    const double vh = theta * (wx * e1x + wy * e1y + wz * e1z) / wn;
    const double vv = theta * (wx * e2x + wy * e2y + wz * e2z) / wn;
    mhh += p * vh * vh;
    mvv += p * vv * vv;
    mhv += p * vh * vv;
  }

  const double trace = mhh + mvv;
  const double det = mhh * mvv - mhv * mhv;
  const double disc = std::sqrt(std::max(0.0, trace * trace / 4 - det));
  const double major = std::sqrt(std::max(0.0, trace / 2 + disc));
  const double minor = std::sqrt(std::max(0.0, trace / 2 - disc));

  ImageSpread out;
  out.rms_deg = static_cast<float>(std::sqrt(spread_sq));
  out.focus = static_cast<float>(std::min(1.0, mag));
  // No speaker had a direction (everything on the centre or opposite it):
  // nothing says the image is narrower one way than the other.
  out.ratio = major > 1e-9 ? static_cast<float>(minor / major) : 1.0f;
  // The principal axis of a symmetric 2x2. Halved because the moment is
  // quadratic in the angle, and folded into [0, 180) because an axis has no
  // side. A tilt within rounding of 180 is the horizontal axis and reads
  // as 0: a flat image whose cross moment is a vanishing negative must not
  // report 180 where the same image with a vanishing positive reports 0.
  double tilt = 0.5 * std::atan2(2 * mhv, mhh - mvv) * 180.0 / kPi;
  if (tilt < 0) tilt += 180.0;
  if (tilt >= 180.0 - 1e-4) tilt = 0.0;
  out.tilt_deg = out.ratio >= 1.0f ? 0.0f : static_cast<float>(tilt);
  if (!std::isfinite(out.rms_deg)) return {};
  return out;
}

}  // namespace adm2iamf
