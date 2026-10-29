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

/// The 9.1.6 channel order and channel names (ES-960).
///
/// Eclipsa Studio's 9.1.6 order is OBR's "IAMF 9.1.6 Alt" order
/// (`kLayout9_1_6_ch_alt` in the `oar` module's
/// `obr/docs/loudspeaker_layouts.md`): FLc FRc FC LFE FL FR SiL SiR BL
/// BR TpFL TpFR TpSiL TpSiR TpBL TpBR in IAMF names. The ±30° pair comes
/// first, where L/R sit in every other layout; FL/FR at ±60° are the
/// wides. It is the order of a 9.1.6 monitoring target's output
/// channels and of a 9.1.6 audio element's WAV channels.
///
/// OAR renders 9.1.6, and takes a 9.1.6 element, in Sound System H
/// order (FL FR FC LFE BL BR FLc FRc SiL SiR TpFL TpFR TpBL TpBR TpSiL
/// TpSiR), which is also the IAMF bitstream order. The engine converts
/// at both OAR boundaries (`engine/renderer/channel_order.h`); IAMF
/// export lists the channel labels per WAV channel instead. A WAV in
/// the bitstream order needs its channels reordered before use.
///
/// Each channel has two names: the familiar name the other layouts use
/// for the same speaker (L, Lw, Lss, Lts, ...) and the IAMF name (FLc,
/// FL, SiL, TpSiL, ...). The familiar name is the short label, as in
/// 7.1.4, and the display form adds the IAMF name: "L (FLc)". A
/// per-channel tooltip names the IAMF bitstream channel: "L (IAMF
/// bitstream FLc)". The familiar names are also other layouts' labels,
/// so the tooltips are looked up by channel index within the layout
/// ([layout916Tooltips]), never by label text. The table is pinned
/// against the [9.1.6-alt] section of
/// `engine/renderer/channel_layouts.txt` in
/// `test/renderer/channel_layouts_test.dart`.
library;

/// Layout id of a 9.1.6 element and of the 9.1.6 monitoring target.
const String kLayout916 = '9.1.6';

/// Whether [layout] is the 9.1.6 element layout.
bool isLayout916(String layout) => layout.toLowerCase() == kLayout916;

/// One 9.1.6 channel: its IAMF name and the familiar name the other
/// layouts use for the same speaker.
typedef Channel916 = ({String iamf, String familiar});

/// The 9.1.6 channels in Eclipsa Studio's order.
const List<Channel916> kAlt916Channels = [
  (iamf: 'FLc', familiar: 'L'),
  (iamf: 'FRc', familiar: 'R'),
  (iamf: 'FC', familiar: 'C'),
  (iamf: 'LFE', familiar: 'LFE'),
  (iamf: 'FL', familiar: 'Lw'),
  (iamf: 'FR', familiar: 'Rw'),
  (iamf: 'SiL', familiar: 'Lss'),
  (iamf: 'SiR', familiar: 'Rss'),
  (iamf: 'BL', familiar: 'Lrs'),
  (iamf: 'BR', familiar: 'Rrs'),
  (iamf: 'TpFL', familiar: 'Ltf'),
  (iamf: 'TpFR', familiar: 'Rtf'),
  (iamf: 'TpSiL', familiar: 'Lts'),
  (iamf: 'TpSiR', familiar: 'Rts'),
  (iamf: 'TpBL', familiar: 'Ltr'),
  (iamf: 'TpBR', familiar: 'Rtr'),
];

/// OAR (IAMF bitstream) channel c is Eclipsa Studio channel
/// [kAlt916FromOar]`[c]`.
const List<int> kAlt916FromOar = [
  4, 5, 2, 3, // FL FR FC LFE
  8, 9, 0, 1, // BL BR FLc FRc
  6, 7, 10, 11, // SiL SiR TpFL TpFR
  14, 15, 12, 13, // TpBL TpBR TpSiL TpSiR
];

/// The short labels of a 9.1.6 element's channels and of the 9.1.6
/// monitoring channels: the familiar names (L R C LFE Lw Rw Lss Rss Lrs
/// Rrs Ltf Rtf Lts Rts Ltr Rtr).
final List<String> alt916Labels = List.unmodifiable([
  for (final c in kAlt916Channels) c.familiar,
]);

/// The IAMF names in Eclipsa Studio's order (FLc FRc FC LFE FL FR SiL
/// SiR BL BR TpFL TpFR TpSiL TpSiR TpBL TpBR), as the type tooltip lists
/// them.
final List<String> alt916IamfLabels = List.unmodifiable([
  for (final c in kAlt916Channels) c.iamf,
]);

/// The IAMF names in the IAMF bitstream order (FL FR FC LFE BL BR FLc
/// FRc SiL SiR TpFL TpFR TpBL TpBR TpSiL TpSiR), as the type tooltip
/// lists them.
final List<String> iamfOrder916IamfLabels = List.unmodifiable([
  for (final a in kAlt916FromOar) kAlt916Channels[a].iamf,
]);

/// `familiar (IAMF)`, `LFE` alone: the display form of the 9.1.6
/// channels (the Settings routing summary, `OarLayout.speakerLabels`).
final List<String> alt916DisplayLabels = List.unmodifiable([
  for (final c in kAlt916Channels) _display(c),
]);

/// Per-channel tooltips, by channel index: the label and its IAMF
/// bitstream name ("L (IAMF bitstream FLc)"); null for LFE, which has
/// one name.
final List<String?> alt916Tooltips = List.unmodifiable([
  for (final c in kAlt916Channels)
    c.iamf == c.familiar ? null : '${c.familiar} (IAMF bitstream ${c.iamf})',
]);

String _display(Channel916 c) =>
    c.iamf == c.familiar ? c.iamf : '${c.familiar} (${c.iamf})';

/// The per-channel tooltips of the 9.1.6 element layout, by channel
/// index, or null for any other [layout].
List<String?>? layout916Tooltips(String layout) =>
    isLayout916(layout) ? alt916Tooltips : null;

/// The full name a tooltip shows for each 9.1.6 label no other layout
/// uses: the wides and the top sides.
const Map<String, String> k916ChannelFullNames = {
  'Lw': 'Left wide',
  'Rw': 'Right wide',
  'Lts': 'Left top side',
  'Rts': 'Right top side',
};

/// The tooltip of the 9.1.6 element type in the type pickers: the
/// channel order the WAV is read in, where the ±30° and ±60° pairs sit
/// in it, and that it is not the IAMF bitstream order. Null for any
/// other [layout].
String? layout916OrderTooltip(String layout) {
  if (!isLayout916(layout)) return null;
  return 'Channels in this order: ${alt916Labels.join(', ')} (IAMF names '
      '${alt916IamfLabels.join(', ')}). L and R (channels 1 and 2) are at '
      '±30°, as in 7.1.4. Lw and Rw (channels 5 and 6) are the wides at '
      '±60°. A WAV in the IAMF bitstream order '
      '(${iamfOrder916IamfLabels.join(', ')}) needs its channels '
      'reordered first.';
}

/// Engine value of `eclipsa_studio_element_set_channel_order()`:
/// the element is fed to OAR as it is.
const int kChannelOrderOar = 0;

/// Engine value of `eclipsa_studio_element_set_channel_order()`: a
/// 9.1.6 element in the alt order, permuted into OAR's order at the
/// feed.
const int kChannelOrder916Alt = 1;

/// The engine channel order of a channel element with [layout]:
/// [kChannelOrder916Alt] for 9.1.6, [kChannelOrderOar] for every other
/// layout.
int channelOrderForLayout(String layout) =>
    isLayout916(layout) ? kChannelOrder916Alt : kChannelOrderOar;
