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

#ifndef ECLIPSA_STUDIO_RENDERER_CHANNEL_ORDER_H_
#define ECLIPSA_STUDIO_RENDERER_CHANNEL_ORDER_H_

#include <array>
#include <cstdint>

// The 9.1.6 channel order the host uses on both sides of OAR (ES-960).
//
// OLR renders 9.1.6, and takes a 9.1.6 channel element, in Sound System
// H order: L60 R60 C LFE1 L135 R135 L30 R30 L90 R90 UL45 UR45 UL135
// UR135 UL90 UR90 (the [9.1.6] section of renderer/channel_layouts.txt,
// the key to every channel name and order). The host's 9.1.6 order is OBR's
// "IAMF 9.1.6 Alt" order (kLayout9_1_6_ch_alt in the oar module's
// obr/docs/loudspeaker_layouts.md): FLc FRc FC LFE FL FR SiL SiR BL BR
// TpFL TpFR TpSiL TpSiR TpBL TpBR, the ±30° pair first, where
// L/R sit in every other layout.
// The engine converts at the two OAR boundaries:
//
//  * Monitoring output: the live path permutes the rendered block into
//    the alt order before the routing scatter and the output meters, so
//    the identity patch sends that order to device channels 1 to 16.
//    The mix-bus loudness meter keeps reading OLR's order, which its
//    BS.1770 channel weights follow (meters/bs1770_weights.cc).
//  * Element input: a 9.1.6 channel element whose channels are in the
//    alt order (ECLIPSA_STUDIO_CHANNEL_ORDER_916_ALT) is permuted into
//    OLR's order as it is fed to OAR, after the element's own routing,
//    gain and meters, so the host sees the element's channels in the
//    alt order everywhere. An element in OLR's order (the IAMF bitstream
//    order, ECLIPSA_STUDIO_CHANNEL_ORDER_OAR) is fed as it is.
//
// Offline render and measure feed OAR through the same element input
// order; IAMF export does not pass through OAR and lists the channel
// labels per WAV channel instead.
// engine/test/channel_layouts_test.cc pins both tables against the
// [9.1.6-alt] section of renderer/channel_layouts.txt, which
// app/test/renderer/channel_layouts_test.dart reads for the app's
// labels.

namespace eclipsa_studio {

// A fixed channel permutation: channel c of the destination takes
// channel source[c] of the origin.
struct ChannelOrder {
  const uint8_t* source;
  uint32_t channels;
};

// Channel count of the tables below: the size of the audio thread's
// monitoring reorder scratch.
inline constexpr uint32_t kChannelOrderMaxChannels = 16;

// oar_layout_t value of 9.1.6 (ck_oar_layout_916).
inline constexpr uint32_t kOarLayout916 = 10;

// Element channel orders, the values of the C ABI's
// eclipsa_studio_element_set_channel_order() and
// eclipsa_studio_mix_renderer_set_element_channel_order().
inline constexpr uint32_t kChannelOrderOar = 0;
inline constexpr uint32_t kChannelOrder916Alt = 1;

// Alt output channel a takes OLR channel kOlrFromAlt916[a].
inline constexpr std::array<uint8_t, 16> kOlrFromAlt916 = {
    6,  7,  2,  3,   // FLc FRc FC LFE     <- L30 R30 C LFE1
    0,  1,  8,  9,   // FL FR SiL SiR      <- L60 R60 L90 R90
    4,  5,  10, 11,  // BL BR TpFL TpFR    <- L135 R135 UL45 UR45
    14, 15, 12, 13,  // TpSiL TpSiR TpBL TpBR <- UL90 UR90 UL135 UR135
};

constexpr std::array<uint8_t, 16> InvertOrder(
    const std::array<uint8_t, 16>& order) {
  std::array<uint8_t, 16> inverse = {};
  for (uint8_t i = 0; i < 16; ++i) inverse[order[i]] = i;
  return inverse;
}

// OLR input channel c takes alt element channel kAltFromOlr916[c]: the
// inverse permutation, so both directions come from one table.
inline constexpr std::array<uint8_t, 16> kAltFromOlr916 =
    InvertOrder(kOlrFromAlt916);

inline constexpr ChannelOrder kMonitoring916Order = {kOlrFromAlt916.data(), 16};
inline constexpr ChannelOrder kElementInput916Alt = {kAltFromOlr916.data(), 16};

// The monitoring reorder for `layout` (an oar_layout_t value), or
// nullptr for a layout the monitoring path sends as OLR renders it.
// Safe from any thread: reads constants only.
inline const ChannelOrder* MonitoringChannelOrder(uint32_t layout) {
  if (layout == kOarLayout916) return &kMonitoring916Order;
  return nullptr;
}

// The table to feed OAR from an element in channel order `order` with
// `channels` channels, or nullptr when the element is fed as it is
// (OLR's order, an unknown order value, or a channel count the order
// does not cover). Safe from any thread: reads constants only.
inline const ChannelOrder* ElementInputOrder(uint32_t order,
                                             uint32_t channels) {
  if (order == kChannelOrder916Alt &&
      channels == kElementInput916Alt.channels) {
    return &kElementInput916Alt;
  }
  return nullptr;
}

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_RENDERER_CHANNEL_ORDER_H_
