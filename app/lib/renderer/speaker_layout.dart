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

/// A single speaker in a layout.
class Speaker {
  final double azDeg;
  final double elDeg;
  final double distance;
  final String label;
  final bool isLFE;

  const Speaker({
    required this.azDeg,
    required this.elDeg,
    this.distance = 1.0,
    required this.label,
    this.isLFE = false,
  });
}

/// ITU-R BS.2051-3 speaker layouts.
class SpeakerLayout {
  final String name;
  final String id;
  final List<Speaker> speakers;

  const SpeakerLayout({
    required this.name,
    required this.id,
    required this.speakers,
  });

  int get channelCount => speakers.length;

  /// All predefined layouts.
  static const List<SpeakerLayout> all = [
    mono,
    stereo,
    layout312,
    layout51,
    layout512,
    layout514,
    layout71,
    layout712,
    layout714,
    layout916,
  ];

  /// Look up by name (e.g. "5.1", "7.1.4", "Stereo", "Binaural").
  static SpeakerLayout? byName(String name) {
    final n = name.toLowerCase().trim();
    if (n == 'binaural') return stereo; // binaural renders to 2ch
    for (final l in all) {
      if (l.id.toLowerCase() == n || l.name.toLowerCase() == n) return l;
    }
    return null;
  }

  static const mono = SpeakerLayout(
    name: 'Mono',
    id: 'mono',
    speakers: [Speaker(azDeg: 0, elDeg: 0, label: 'C')],
  );

  // IAMF channel ordering per OBR loudspeaker_layouts.h. Label
  // vocabulary matches `standardChannelLabel` / `iamfChannelLabels`
  // (the meters, routing matrix, and timeline), so one physical
  // channel wears one name everywhere (ES-552) — e.g. 9.1.6's mains
  // are the L60/R60 pair ('L'/'R'), with L30/R30 as 'Lc'/'Rc'.
  //
  // Geometry (azimuth/elevation) follows the loudspeaker renderer —
  // OLR / ITU-R BS.2051 nominal, upper layer at +30° (ES-588: the scene
  // used to draw heights at OBR's 45°, 15° above where the loudspeaker
  // render actually places them; OBR's virtual 45° upper layer is a
  // property of binaural rendering, tracked fork-side). LFE sits at
  // (45, -30) in every layout.
  //
  // Order, geometry and labels are pinned per layout against
  // `engine/renderer/oar_output_channels.txt` in
  // `test/renderer/oar_output_channels_test.dart`, alongside
  // `iamfChannelLabels` and `channelFullName` — so one channel carries
  // one name across the meters, the routing matrix, the timeline and
  // this scene. That table is in turn pinned against what OAR renders
  // by `engine/test/oar_output_channels_test.cc`, so an OAR pin bump
  // that reorders a layout or moves a speaker fails there and here
  // rather than silently mislabelling these rows (ES-592).
  static const stereo = SpeakerLayout(
    name: 'Stereo',
    id: 'stereo',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
    ],
  );

  static const layout312 = SpeakerLayout(
    name: '3.1.2',
    id: '3.1.2',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf'),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf'),
    ],
  );

  static const layout51 = SpeakerLayout(
    name: '5.1',
    id: '5.1',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 110, elDeg: 0, label: 'Ls'),
      Speaker(azDeg: -110, elDeg: 0, label: 'Rs'),
    ],
  );

  static const layout512 = SpeakerLayout(
    name: '5.1.2',
    id: '5.1.2',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 110, elDeg: 0, label: 'Ls'),
      Speaker(azDeg: -110, elDeg: 0, label: 'Rs'),
      Speaker(azDeg: 30, elDeg: 30, label: 'Ltf'),
      Speaker(azDeg: -30, elDeg: 30, label: 'Rtf'),
    ],
  );

  static const layout514 = SpeakerLayout(
    name: '5.1.4',
    id: '5.1.4',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 110, elDeg: 0, label: 'Ls'),
      Speaker(azDeg: -110, elDeg: 0, label: 'Rs'),
      Speaker(azDeg: 30, elDeg: 30, label: 'Ltf'),
      Speaker(azDeg: -30, elDeg: 30, label: 'Rtf'),
      Speaker(azDeg: 110, elDeg: 30, label: 'Ltr'),
      Speaker(azDeg: -110, elDeg: 30, label: 'Rtr'),
    ],
  );

  static const layout71 = SpeakerLayout(
    name: '7.1',
    id: '7.1',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 90, elDeg: 0, label: 'Ls'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rs'),
      Speaker(azDeg: 135, elDeg: 0, label: 'Lrs'),
      Speaker(azDeg: -135, elDeg: 0, label: 'Rrs'),
    ],
  );

  static const layout712 = SpeakerLayout(
    name: '7.1.2',
    id: '7.1.2',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 90, elDeg: 0, label: 'Ls'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rs'),
      Speaker(azDeg: 135, elDeg: 0, label: 'Lrs'),
      Speaker(azDeg: -135, elDeg: 0, label: 'Rrs'),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf'),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf'),
    ],
  );

  static const layout714 = SpeakerLayout(
    name: '7.1.4',
    id: '7.1.4',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 90, elDeg: 0, label: 'Ls'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rs'),
      Speaker(azDeg: 135, elDeg: 0, label: 'Lrs'),
      Speaker(azDeg: -135, elDeg: 0, label: 'Rrs'),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf'),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf'),
      Speaker(azDeg: 135, elDeg: 30, label: 'Ltr'),
      Speaker(azDeg: -135, elDeg: 30, label: 'Rtr'),
    ],
  );

  static const layout916 = SpeakerLayout(
    name: '9.1.6',
    id: '9.1.6',
    speakers: [
      Speaker(azDeg: 60, elDeg: 0, label: 'L'),
      Speaker(azDeg: -60, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 135, elDeg: 0, label: 'Lrs'),
      Speaker(azDeg: -135, elDeg: 0, label: 'Rrs'),
      Speaker(azDeg: 30, elDeg: 0, label: 'Lc'),
      Speaker(azDeg: -30, elDeg: 0, label: 'Rc'),
      Speaker(azDeg: 90, elDeg: 0, label: 'Lss'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rss'),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf'),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf'),
      Speaker(azDeg: 135, elDeg: 30, label: 'Ltr'),
      Speaker(azDeg: -135, elDeg: 30, label: 'Rtr'),
      Speaker(azDeg: 90, elDeg: 30, label: 'Ltss'),
      Speaker(azDeg: -90, elDeg: 30, label: 'Rtss'),
    ],
  );
}
