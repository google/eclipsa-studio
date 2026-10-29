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

  /// Azimuth of the virtual loudspeaker OBR renders this channel from on
  /// the binaural monitoring target, when it differs from [azDeg].
  final double? binauralAzDeg;

  /// Elevation of that virtual loudspeaker, when it differs from
  /// [elDeg].
  final double? binauralElDeg;

  const Speaker({
    required this.azDeg,
    required this.elDeg,
    this.distance = 1.0,
    required this.label,
    this.isLFE = false,
    this.binauralAzDeg,
    this.binauralElDeg,
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

  static final _binauralGeometry = Expando<SpeakerLayout>();

  /// This layout with every speaker at the virtual loudspeaker OBR
  /// renders the channel from on the binaural monitoring target. Same
  /// id, labels and channel order.
  SpeakerLayout get binauralGeometry =>
      _binauralGeometry[this] ??= SpeakerLayout(
        name: name,
        id: id,
        speakers: [
          for (final s in speakers)
            Speaker(
              azDeg: s.binauralAzDeg ?? s.azDeg,
              elDeg: s.binauralElDeg ?? s.elDeg,
              distance: s.distance,
              label: s.label,
              isLFE: s.isLFE,
            ),
        ],
      );

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
    layout7154,
    layout10293,
  ];

  /// Look up by name (e.g. "5.1", "7.1.4", "Stereo", "Binaural").
  static SpeakerLayout? byName(String name) {
    final n = name.toLowerCase().trim();
    if (n == 'binaural') return stereo; // binaural renders to 2ch
    if (n == layout916Iamf.id) return layout916Iamf;
    for (final l in all) {
      if (l.id.toLowerCase() == n || l.name.toLowerCase() == n) return l;
    }
    return null;
  }

  /// The layout name to show for an element whose layout is
  /// [layoutId]: the file's own name for [layout916Iamf], else the id.
  static String displayName(String layoutId) =>
      layoutId == layout916Iamf.id ? layout916Iamf.name : layoutId;

  static const mono = SpeakerLayout(
    name: 'Mono',
    id: 'mono',
    speakers: [Speaker(azDeg: 0, elDeg: 0, label: 'C')],
  );

  // IAMF channel ordering per OBR loudspeaker_layouts.h. Label
  // vocabulary matches `standardChannelLabel` / `iamfChannelLabels`
  // (the meters, routing matrix, and timeline), so one physical
  // channel wears one name everywhere (ES-552). 9.1.6 uses the familiar
  // names in OBR's alt order (models/layout_916.dart).
  //
  // Geometry (azimuth/elevation) follows the loudspeaker renderer —
  // OLR / ITU-R BS.2051 nominal, upper layer at +30° (ES-588), LFE at
  // (45, -30) in every layout. On the binaural monitoring target OBR
  // renders the channels from its own virtual loudspeakers instead: the
  // upper layer at 45°, 5.1.4's top pairs at ±45° and ±135°, and the LFE
  // at azimuth 0 except in 9.1.6 and 10.2.9.3. [Speaker.binauralAzDeg]
  // and [Speaker.binauralElDeg] carry those positions where they differ,
  // and [binauralGeometry] applies them (ES-595).
  //
  // Order, geometry and labels are pinned per layout against
  // `engine/renderer/channel_layouts.txt` in
  // `test/renderer/channel_layouts_test.dart`, alongside
  // `iamfChannelLabels` and `channelFullName` — so one channel carries
  // one name across the meters, the routing matrix, the timeline and
  // this scene; the binaural positions are pinned against the table's
  // binaural sections. That table is in turn pinned against what OAR
  // and OBR render by `engine/test/channel_layouts_test.cc`, so an OAR
  // pin bump that reorders a layout or moves a speaker fails there and
  // here rather than silently mislabelling these rows (ES-592).
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
      Speaker(
        azDeg: 45,
        elDeg: -30,
        label: 'LFE',
        isLFE: true,
        binauralAzDeg: 0,
      ),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf', binauralElDeg: 45),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf', binauralElDeg: 45),
    ],
  );

  static const layout51 = SpeakerLayout(
    name: '5.1',
    id: '5.1',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(
        azDeg: 45,
        elDeg: -30,
        label: 'LFE',
        isLFE: true,
        binauralAzDeg: 0,
      ),
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
      Speaker(
        azDeg: 45,
        elDeg: -30,
        label: 'LFE',
        isLFE: true,
        binauralAzDeg: 0,
      ),
      Speaker(azDeg: 110, elDeg: 0, label: 'Ls'),
      Speaker(azDeg: -110, elDeg: 0, label: 'Rs'),
      Speaker(azDeg: 30, elDeg: 30, label: 'Ltf', binauralElDeg: 45),
      Speaker(azDeg: -30, elDeg: 30, label: 'Rtf', binauralElDeg: 45),
    ],
  );

  static const layout514 = SpeakerLayout(
    name: '5.1.4',
    id: '5.1.4',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(
        azDeg: 45,
        elDeg: -30,
        label: 'LFE',
        isLFE: true,
        binauralAzDeg: 0,
      ),
      Speaker(azDeg: 110, elDeg: 0, label: 'Ls'),
      Speaker(azDeg: -110, elDeg: 0, label: 'Rs'),
      Speaker(
        azDeg: 30,
        elDeg: 30,
        label: 'Ltf',
        binauralAzDeg: 45,
        binauralElDeg: 45,
      ),
      Speaker(
        azDeg: -30,
        elDeg: 30,
        label: 'Rtf',
        binauralAzDeg: -45,
        binauralElDeg: 45,
      ),
      Speaker(
        azDeg: 110,
        elDeg: 30,
        label: 'Ltr',
        binauralAzDeg: 135,
        binauralElDeg: 45,
      ),
      Speaker(
        azDeg: -110,
        elDeg: 30,
        label: 'Rtr',
        binauralAzDeg: -135,
        binauralElDeg: 45,
      ),
    ],
  );

  static const layout71 = SpeakerLayout(
    name: '7.1',
    id: '7.1',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(
        azDeg: 45,
        elDeg: -30,
        label: 'LFE',
        isLFE: true,
        binauralAzDeg: 0,
      ),
      Speaker(azDeg: 90, elDeg: 0, label: 'Lss'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rss'),
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
      Speaker(
        azDeg: 45,
        elDeg: -30,
        label: 'LFE',
        isLFE: true,
        binauralAzDeg: 0,
      ),
      Speaker(azDeg: 90, elDeg: 0, label: 'Lss'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rss'),
      Speaker(azDeg: 135, elDeg: 0, label: 'Lrs'),
      Speaker(azDeg: -135, elDeg: 0, label: 'Rrs'),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf', binauralElDeg: 45),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf', binauralElDeg: 45),
    ],
  );

  static const layout714 = SpeakerLayout(
    name: '7.1.4',
    id: '7.1.4',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(
        azDeg: 45,
        elDeg: -30,
        label: 'LFE',
        isLFE: true,
        binauralAzDeg: 0,
      ),
      Speaker(azDeg: 90, elDeg: 0, label: 'Lss'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rss'),
      Speaker(azDeg: 135, elDeg: 0, label: 'Lrs'),
      Speaker(azDeg: -135, elDeg: 0, label: 'Rrs'),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf', binauralElDeg: 45),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf', binauralElDeg: 45),
      Speaker(azDeg: 135, elDeg: 30, label: 'Ltr', binauralElDeg: 45),
      Speaker(azDeg: -135, elDeg: 30, label: 'Rtr', binauralElDeg: 45),
    ],
  );

  // 9.1.6 in the app's order, OBR's alt order (models/layout_916.dart),
  // with the familiar names: the channel order of a 9.1.6 element and
  // of the 9.1.6 monitoring target (ES-960). OAR's order (the IAMF
  // bitstream order) is Lw Rw C LFE Lrs Rrs L R Lss Rss Ltf Rtf Ltr Rtr
  // Lts Rts; the engine converts at its boundaries.
  static const layout916 = SpeakerLayout(
    name: '9.1.6',
    id: '9.1.6',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 60, elDeg: 0, label: 'Lw'),
      Speaker(azDeg: -60, elDeg: 0, label: 'Rw'),
      Speaker(azDeg: 90, elDeg: 0, label: 'Lss'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rss'),
      Speaker(azDeg: 135, elDeg: 0, label: 'Lrs'),
      Speaker(azDeg: -135, elDeg: 0, label: 'Rrs'),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf', binauralElDeg: 45),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf', binauralElDeg: 45),
      Speaker(azDeg: 90, elDeg: 30, label: 'Lts', binauralElDeg: 45),
      Speaker(azDeg: -90, elDeg: 30, label: 'Rts', binauralElDeg: 45),
      Speaker(azDeg: 135, elDeg: 30, label: 'Ltr', binauralElDeg: 45),
      Speaker(azDeg: -135, elDeg: 30, label: 'Rtr', binauralElDeg: 45),
    ],
  );

  // 9.1.6 in OAR's order (the IAMF bitstream order), for the elements
  // of a Playback file: the engine feeds those to OAR without the
  // alt-order permutation, so their meters and stats arrive in this
  // order. Same names and positions as [layout916]; not in [all].
  static const layout916Iamf = SpeakerLayout(
    name: '9.1.6',
    id: '9.1.6-iamf',
    speakers: [
      Speaker(azDeg: 60, elDeg: 0, label: 'Lw'),
      Speaker(azDeg: -60, elDeg: 0, label: 'Rw'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 135, elDeg: 0, label: 'Lrs'),
      Speaker(azDeg: -135, elDeg: 0, label: 'Rrs'),
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 90, elDeg: 0, label: 'Lss'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rss'),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf', binauralElDeg: 45),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf', binauralElDeg: 45),
      Speaker(azDeg: 135, elDeg: 30, label: 'Ltr', binauralElDeg: 45),
      Speaker(azDeg: -135, elDeg: 30, label: 'Rtr', binauralElDeg: 45),
      Speaker(azDeg: 90, elDeg: 30, label: 'Lts', binauralElDeg: 45),
      Speaker(azDeg: -90, elDeg: 30, label: 'Rts', binauralElDeg: 45),
    ],
  );

  // 7.1.5.4 and 10.2.9.3 are element layouts only (no monitoring
  // target); the scene draws them in OAR's order from
  // engine/renderer/channel_layouts.txt (ES-596).
  static const layout7154 = SpeakerLayout(
    name: '7.1.5.4',
    id: '7.1.5.4',
    speakers: [
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(
        azDeg: 45,
        elDeg: -30,
        label: 'LFE',
        isLFE: true,
        binauralAzDeg: 0,
      ),
      Speaker(azDeg: 90, elDeg: 0, label: 'Lss'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rss'),
      Speaker(azDeg: 135, elDeg: 0, label: 'Lrs'),
      Speaker(azDeg: -135, elDeg: 0, label: 'Rrs'),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf', binauralElDeg: 45),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf', binauralElDeg: 45),
      Speaker(azDeg: 0, elDeg: 90, label: 'Tc'),
      Speaker(azDeg: 135, elDeg: 30, label: 'Ltr', binauralElDeg: 45),
      Speaker(azDeg: -135, elDeg: 30, label: 'Rtr', binauralElDeg: 45),
      Speaker(azDeg: 45, elDeg: -30, label: 'Lbf'),
      Speaker(azDeg: -45, elDeg: -30, label: 'Rbf'),
      Speaker(azDeg: 135, elDeg: -30, label: 'Lbr'),
      Speaker(azDeg: -135, elDeg: -30, label: 'Rbr'),
    ],
  );

  static const layout10293 = SpeakerLayout(
    name: '10.2.9.3',
    id: '10.2.9.3',
    speakers: [
      Speaker(azDeg: 60, elDeg: 0, label: 'Lw'),
      Speaker(azDeg: -60, elDeg: 0, label: 'Rw'),
      Speaker(azDeg: 0, elDeg: 0, label: 'C'),
      Speaker(azDeg: 45, elDeg: -30, label: 'LFE', isLFE: true),
      Speaker(azDeg: 135, elDeg: 0, label: 'Lrs'),
      Speaker(azDeg: -135, elDeg: 0, label: 'Rrs'),
      Speaker(azDeg: 30, elDeg: 0, label: 'L'),
      Speaker(azDeg: -30, elDeg: 0, label: 'R'),
      Speaker(azDeg: 180, elDeg: 0, label: 'Cs'),
      Speaker(azDeg: -45, elDeg: -30, label: 'LFE2', isLFE: true),
      Speaker(azDeg: 90, elDeg: 0, label: 'Lss'),
      Speaker(azDeg: -90, elDeg: 0, label: 'Rss'),
      Speaker(azDeg: 45, elDeg: 30, label: 'Ltf', binauralElDeg: 45),
      Speaker(azDeg: -45, elDeg: 30, label: 'Rtf', binauralElDeg: 45),
      Speaker(azDeg: 0, elDeg: 30, label: 'Ctf', binauralElDeg: 45),
      Speaker(azDeg: 0, elDeg: 90, label: 'Tc'),
      Speaker(azDeg: 135, elDeg: 30, label: 'Ltr', binauralElDeg: 45),
      Speaker(azDeg: -135, elDeg: 30, label: 'Rtr', binauralElDeg: 45),
      Speaker(azDeg: 90, elDeg: 30, label: 'Lts', binauralElDeg: 45),
      Speaker(azDeg: -90, elDeg: 30, label: 'Rts', binauralElDeg: 45),
      Speaker(azDeg: 180, elDeg: 30, label: 'Ctr', binauralElDeg: 45),
      Speaker(azDeg: 0, elDeg: -30, label: 'Cbf'),
      Speaker(azDeg: 45, elDeg: -30, label: 'Lbf'),
      Speaker(azDeg: -45, elDeg: -30, label: 'Rbf'),
    ],
  );
}
