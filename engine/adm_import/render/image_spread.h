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

// How wide the target layout images a source, and in which direction,
// measured off the renderer.
//
// A panner that cannot put a source on one speaker splits it across several,
// and the render's image is then as wide as that split. ImageSpreadMeter
// measures that split directly: it drives OLR with DC at the position, reads
// the settled speaker gains, and takes the energy-weighted second moment of
// those gains about their energy-vector (Gerzon rE) direction.
//
// The width is the rms angle of that moment. Read it as the image's angular
// radius: 0 when one speaker carries everything (a source at a speaker
// angle, or a bed channel the renderer passes through); 15 for an even split
// between two speakers 30 degrees apart, where the rms angle is the angle to
// each of them; 60 for a source at the zenith on 7.1.4, which drives the
// four top speakers evenly at 30 degrees of elevation; about 88 for one at
// the centre of the mid ring, which drives all seven of its speakers evenly.
// It exceeds 90 in a narrow band around the centre of the room, where most
// of the energy sits further than a right angle from the (short) energy
// vector.
//
// The image is rarely round, which is why the moment is kept as a shape
// rather than collapsed to that one number. A source panned within one layer
// is split across speakers that share an elevation, so it has no vertical
// extent at all: a phantom between two mid-ring speakers measures 9.2
// degrees across and 0 up. A source between M+135 and U+135 is the same the
// other way. Only a source driving a whole ring around its own axis -- the
// zenith -- is round.
//
// The import preview draws the shape as the halo around a mark (ES-640), which
// is why it is measured per probed position rather than fitted to distance.
//
// Cost: two OLR blocks of 64 frames per position, about 22 us on an M-series
// Mac, so the whole probe budget (2048 trajectory points plus one position
// per source and object) measures in well under 100 ms.

#ifndef ADM2IAMF_RENDER_IMAGE_SPREAD_H_
#define ADM2IAMF_RENDER_IMAGE_SPREAD_H_

#include <memory>
#include <vector>

#include "adm_import/scene/layouts.h"

namespace adm2iamf {

// The measured shape of the render's image at one position.
struct ImageSpread {
  // The image's angular radius along its widest axis, in degrees: the
  // energy-weighted rms angle of the gains about the centre. 0 when one
  // speaker carries everything. Drawn as the semi-major axis, so the halo
  // keeps landing its edge on the speakers carrying the image -- 15 for an
  // even split between two 30 degrees apart, 60 at the zenith.
  float rms_deg = 0;
  // How much narrower the image is across that axis, in 0..1. 1 is round
  // (the zenith, driving four top speakers evenly around it); 0 is a line,
  // which is what a pan inside one layer produces, its speakers sharing an
  // elevation. Anything panned between the layers runs about 0.7.
  float ratio = 1;
  // The widest axis's direction in the tangent plane at the image's centre:
  // degrees anticlockwise from horizontal, in [0, 180). 0 is a horizontal
  // smear, 90 a vertical one. Meaningless when `ratio` is 1, and 0 there.
  float tilt_deg = 0;
  // How strongly the gains agree on a direction: the length of their energy
  // vector, 0 to 1. 0.99 when two speakers share a source, 0.5 at the
  // zenith, 0.19 when the whole mid ring is driven equally -- the case
  // where there is no direction to speak of and the image is a band around
  // the ring rather than a patch of it. The centre is still reported, but
  // it is an artefact of the arithmetic at that point.
  float focus = 1;
};

class ImageSpreadMeter {
 public:
  // Null when OAR cannot be configured for `layout` (allocation failure, or a
  // layout OLR does not render to). Holds one oar_t for its lifetime, so
  // measuring a whole probe costs one setup.
  static std::unique_ptr<ImageSpreadMeter> Create(const Layout& layout);

  ~ImageSpreadMeter();
  ImageSpreadMeter(const ImageSpreadMeter&) = delete;
  ImageSpreadMeter& operator=(const ImageSpreadMeter&) = delete;

  // The image's shape at `position`. Not thread-safe: calls share one
  // renderer and must be serialized. Returns a zero-width image if OLR
  // refuses the block, which is the same as "nothing to draw".
  //
  // `position` must be polar and already converted for the target layout
  // (ConvertObjectPosition), because that is the position the render pans to.
  ImageSpread Measure(const Polar& position);

 private:
  // A non-LFE output channel and its speaker direction as a unit vector.
  // LFE channels are left out: they carry no direction, and the renderer
  // routes to them rather than panning.
  struct MeteredSpeaker {
    int channel = 0;
    float x = 0, y = 0, z = 0;
  };

  ImageSpreadMeter(oar_t* oar, int num_channels,
                   std::vector<MeteredSpeaker> speakers);

  oar_t* oar_ = nullptr;
  int num_channels_ = 0;
  std::vector<MeteredSpeaker> speakers_;
  std::vector<float> in_;   // One block of DC.
  std::vector<float> out_;  // Planar render scratch.
};

}  // namespace adm2iamf

#endif  // ADM2IAMF_RENDER_IMAGE_SPREAD_H_
