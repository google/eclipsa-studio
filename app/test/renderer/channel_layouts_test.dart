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

// Pins the app's channel tables to engine/renderer/channel_layouts.txt,
// the key to every channel name and order Eclipsa Studio puts over the
// IAMF and OAR layer (ES-592, ES-960).
//
// `SpeakerLayout` (the 3D scene), `OarLayout` (meters, routing matrix,
// Settings), `elementToOarType` (the engine registration of an element),
// `standardChannelLabel` and `iamfChannelLabels` (lanes, element meters,
// routing rows) and `channelFullName` (tooltips) each carry a copy of a
// layout's channel order or names. Before the key they were pinned
// against hand-transcribed copies of themselves, so an OAR_COMMIT bump
// that reordered a layout or moved a speaker left every Dart test green
// while the engine rendered something else: the ES-552 mislabels, and the
// ES-588 height ring drawn 15 degrees too high.
//
// All of them now read the key, which engine/test/channel_layouts_test.cc
// verifies against what OAR renders. A layout that moves upstream fails
// there first, and updating the key makes this test fail until the app
// tables follow. Each row carries the OAR code, the IAMF name and the
// short and long Eclipsa Studio labels; a section's roles say whether
// it is a monitoring target, an element layout or both; the [9.1.6-alt]
// section is the one reorder, Eclipsa Studio's 9.1.6 order, which the
// shared table in lib/models/layout_916.dart repeats. The binaural
// sections give the virtual loudspeaker OBR renders each channel of an
// element layout from on the binaural target, which the scene draws
// through SpeakerLayout.binauralGeometry.
//
// This supersedes the hand-transcribed test/renderer/
// speaker_layout_geometry_test.dart.

import 'dart:io';

import 'package:eclipsa_studio/models/audio_element_enums.dart';
import 'package:eclipsa_studio/models/layout_916.dart';
import 'package:eclipsa_studio/renderer/speaker_layout.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/views/renderer_view.dart'
    show channelCountForLayout, playbackChannelLayout;
import 'package:eclipsa_studio/waveform/multi_channel_waveform.dart'
    show channelFullName, channelLaneTooltips, standardChannelLabel;
import 'package:eclipsa_studio/widgets/routing_labels.dart'
    show iamfChannelLabels;
import 'package:flutter_test/flutter_test.dart';

/// One channel of a layout, as the key describes it.
class _Channel {
  const _Channel(
    this.oarCode,
    this.iamfName,
    this.label,
    this.azDeg,
    this.elDeg,
    this.isLFE,
    this.fullName,
  );

  /// OAR's own code for the speaker, e.g. `M+030`. Reported in failures.
  final String oarCode;

  /// The channel's IAMF name, e.g. `L`.
  final String iamfName;

  /// Eclipsa Studio's short label for the channel, e.g. `L`.
  final String label;
  final double azDeg;
  final double elDeg;
  final bool isLFE;

  /// Eclipsa Studio's long label, e.g. `Left`.
  final String fullName;
}

/// One row of an alt section: the OAR code of the layout row the channel
/// is taken from, with its names repeated.
class _AltChannel {
  const _AltChannel(this.oarCode, this.iamfName, this.label, this.fullName);
  final String oarCode;
  final String iamfName;
  final String label;
  final String fullName;
}

/// One layout section of the key.
class _Section {
  _Section(this.id, this.oarValue, this.monitoring, this.element);
  final String id;
  final int oarValue;

  /// A monitoring target: the rows are OAR's output order.
  final bool monitoring;

  /// An element layout: the rows are OAR's input order.
  final bool element;
  final List<_Channel> channels = [];
}

/// One alt section of the key (`<layout id>-alt`).
class _AltSection {
  _AltSection(this.layoutId, this.oarValue);
  final String layoutId;
  final int oarValue;
  final List<_AltChannel> channels = [];
}

/// One row of a binaural section: OBR's virtual loudspeaker for the
/// layout row of the same OAR code.
class _BinauralChannel {
  const _BinauralChannel(this.oarCode, this.azDeg, this.elDeg);
  final String oarCode;
  final double azDeg;
  final double elDeg;
}

/// One binaural section of the key (`<layout id>-binaural`), in the
/// layout section's order.
class _BinauralSection {
  _BinauralSection(this.layoutId, this.oarValue);
  final String layoutId;
  final int oarValue;
  final List<_BinauralChannel> channels = [];
}

const _altSuffix = '-alt';
const _binauralSuffix = '-binaural';

/// Parses `engine/renderer/channel_layouts.txt`; the format is documented
/// at the head of that file. Runs before any test body, so it reports
/// malformed input as a [FormatException] rather than a matcher.
({
  List<_Section> layouts,
  List<_AltSection> alts,
  List<_BinauralSection> binaurals,
})
_parseKey(String text) {
  final layouts = <_Section>[];
  final alts = <_AltSection>[];
  final binaurals = <_BinauralSection>[];
  var inAlt = false;
  var inBinaural = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final fields = line.split(RegExp(r'\s+'));
    if (line.startsWith('[')) {
      if (!fields[0].endsWith(']')) {
        throw FormatException('bad section header', line);
      }
      final id = fields[0].substring(1, fields[0].length - 1);
      inAlt = id.endsWith(_altSuffix);
      inBinaural = id.endsWith(_binauralSuffix);
      if (inBinaural) {
        if (fields.length != 2) {
          throw FormatException('bad binaural header', line);
        }
        binaurals.add(
          _BinauralSection(
            id.substring(0, id.length - _binauralSuffix.length),
            int.parse(fields[1]),
          ),
        );
        continue;
      }
      if (inAlt) {
        if (fields.length != 2) throw FormatException('bad alt header', line);
        alts.add(
          _AltSection(
            id.substring(0, id.length - _altSuffix.length),
            int.parse(fields[1]),
          ),
        );
        continue;
      }
      final roles = fields.sublist(2).toSet();
      if (fields.length < 3 ||
          roles.difference({'monitoring', 'element'}).isNotEmpty) {
        throw FormatException('bad header', line);
      }
      layouts.add(
        _Section(
          id,
          int.parse(fields[1]),
          roles.contains('monitoring'),
          roles.contains('element'),
        ),
      );
      continue;
    }
    if (inBinaural) {
      if (fields.length != 3) throw FormatException('bad binaural row', line);
      binaurals.last.channels.add(
        _BinauralChannel(
          fields[0],
          double.parse(fields[1]),
          double.parse(fields[2]),
        ),
      );
      continue;
    }
    // The long label runs to the end of the line: it has spaces.
    String rest(int from) => fields.sublist(from).join(' ');
    if (inAlt) {
      if (fields.length < 4) throw FormatException('bad alt row', line);
      alts.last.channels.add(
        _AltChannel(fields[0], fields[1], fields[2], rest(3)),
      );
      continue;
    }
    if (layouts.isEmpty) {
      throw FormatException('channel before a section', line);
    }
    if (fields.length < 7 || (fields[5] != 'lfe' && fields[5] != '-')) {
      throw FormatException('bad channel row', line);
    }
    layouts.last.channels.add(
      _Channel(
        fields[0],
        fields[1],
        fields[2],
        double.parse(fields[3]),
        double.parse(fields[4]),
        fields[5] == 'lfe',
        rest(6),
      ),
    );
  }
  return (layouts: layouts, alts: alts, binaurals: binaurals);
}

void main() {
  final key = _parseKey(
    File('../engine/renderer/channel_layouts.txt').readAsStringSync(),
  );
  final sections = key.layouts;

  // Section ids match SpeakerLayout.id; the monitoring targets' labels
  // and the element layouts' display names differ only in case.
  OarLayout? oarLayoutFor(String id) => OarLayout.values
      .where((l) => l.label.toLowerCase() == id.toLowerCase())
      .firstOrNull;
  LoudspeakerLayout? elementLayoutFor(String id) => LoudspeakerLayout.values
      .where((l) => l.displayName.toLowerCase() == id.toLowerCase())
      .firstOrNull;

  // A missing or malformed key throws out of _parseKey above, before any
  // test body runs, so this only has to cover what parses cleanly.
  test('the key covers every layout', () {
    expect(sections.map((s) => s.id), [
      'mono',
      'stereo',
      'binaural',
      '3.1.2',
      '5.1',
      '5.1.2',
      '5.1.4',
      '7.1',
      '7.1.2',
      '7.1.4',
      '7.1.5.4',
      '9.1.6',
      '10.2.9.3',
    ]);
    // The one reorder.
    expect(key.alts.map((s) => s.layoutId), ['9.1.6']);
    // OBR's geometry for every element layout; a Binaural element takes
    // the stereo rows.
    expect(key.binaurals.map((s) => s.layoutId), [
      for (final s in sections)
        if (s.element && s.id != 'binaural') s.id,
    ]);
    // Every scene layout is described, and nothing is described twice;
    // Binaural draws the stereo geometry.
    expect(SpeakerLayout.all.map((l) => l.id).toSet(), {
      ...sections.map((s) => s.id).where((id) => id != 'binaural'),
    });
    // The monitoring targets are exactly the monitoring sections, and
    // the element layouts exactly the element sections.
    expect(OarLayout.values.toSet(), {
      for (final s in sections.where((s) => s.monitoring)) oarLayoutFor(s.id),
    });
    expect(LoudspeakerLayout.values.toSet(), {
      for (final s in sections.where((s) => s.element)) elementLayoutFor(s.id),
    });
  });

  test('a short label has one long label, which channelFullName gives', () {
    final longLabels = <String, String>{};
    for (final section in sections) {
      for (final c in section.channels) {
        expect(c.fullName, isNotEmpty, reason: '${section.id} ${c.oarCode}');
        final seen = longLabels[c.label];
        if (seen != null) {
          expect(c.fullName, seen, reason: '${section.id} ${c.label}');
        }
        longLabels[c.label] = c.fullName;
      }
    }
    longLabels.forEach((label, fullName) {
      expect(channelFullName(label), fullName, reason: label);
      // The lanes' fallback tooltip is the same long label.
      expect(channelLaneTooltips('7.1.4', [label]), [fullName], reason: label);
    });
  });

  test('the labels differ from the IAMF names only where the key says', () {
    final differences = <String>{};
    for (final section in sections) {
      for (final c in section.channels) {
        if (c.label != c.iamfName) {
          differences.add('${section.id} ${c.iamfName}>${c.label}');
        }
      }
    }
    const familiar916 = {
      'FL': 'Lw', 'FR': 'Rw', 'FC': 'C', 'BL': 'Lrs', 'BR': 'Rrs', //
      'FLc': 'L', 'FRc': 'R', 'SiL': 'Lss', 'SiR': 'Rss', 'TpFL': 'Ltf',
      'TpFR': 'Rtf', 'TpBL': 'Ltr', 'TpBR': 'Rtr', 'TpSiL': 'Lts',
      'TpSiR': 'Rts',
    };
    expect(differences, {
      'mono M>C',
      '5.1.4 Ltb>Ltr',
      '5.1.4 Rtb>Rtr',
      '7.1.4 Ltb>Ltr',
      '7.1.4 Rtb>Rtr',
      '7.1.5.4 TpC>Tc',
      '7.1.5.4 Ltb>Ltr',
      '7.1.5.4 Rtb>Rtr',
      '7.1.5.4 BtFL>Lbf',
      '7.1.5.4 BtFR>Rbf',
      '7.1.5.4 BtBL>Lbr',
      '7.1.5.4 BtBR>Rbr',
      for (final e in familiar916.entries) '9.1.6 ${e.key}>${e.value}',
      for (final e in familiar916.entries) '10.2.9.3 ${e.key}>${e.value}',
      '10.2.9.3 LFE1>LFE',
      '10.2.9.3 BC>Cs',
      '10.2.9.3 TpFC>Ctf',
      '10.2.9.3 TpC>Tc',
      '10.2.9.3 TpBC>Ctr',
      '10.2.9.3 BtFC>Cbf',
      '10.2.9.3 BtFL>Lbf',
      '10.2.9.3 BtFR>Rbf',
    });
    // The 9.1.6 table in layout_916.dart is the same familiar naming.
    expect(
      {for (final c in kAlt916Channels) c.iamf: c.familiar}..remove('LFE'),
      familiar916,
    );
  });

  for (final section in sections) {
    group(section.id, () {
      final alt = key.alts.where((a) => a.layoutId == section.id);

      // A layout with an alt section is shown in that order; its geometry
      // and names come from the layout section's row of the same OAR
      // code.
      final shown = alt.isEmpty
          ? section.channels
          : [
              for (final a in alt.single.channels)
                section.channels.firstWhere((c) => c.oarCode == a.oarCode),
            ];

      test('SpeakerLayout matches the channel order and geometry', () {
        // Binaural draws the stereo geometry, under the stereo id.
        final layout = SpeakerLayout.byName(section.id)!;
        expect(layout.speakers, hasLength(shown.length));
        for (var i = 0; i < shown.length; i++) {
          final want = shown[i];
          final got = layout.speakers[i];
          final where = '${section.id}[$i] (${want.oarCode})';
          expect(got.isLFE, want.isLFE, reason: '$where LFE flag');
          expect(got.label, want.label, reason: '$where label');
          expect(
            (got.azDeg, got.elDeg),
            (want.azDeg, want.elDeg),
            reason: '$where position',
          );
        }
      });

      final binaural = key.binaurals.where((b) => b.layoutId == section.id);
      if (binaural.isNotEmpty) {
        test('binauralGeometry is the binaural section', () {
          final rows = binaural.single;
          expect(rows.oarValue, section.oarValue);
          expect(
            rows.channels.map((c) => c.oarCode),
            section.channels.map((c) => c.oarCode),
          );
          final layout = SpeakerLayout.byName(section.id)!.binauralGeometry;
          expect(layout.id, section.id);
          expect(layout.speakers, hasLength(shown.length));
          for (var i = 0; i < shown.length; i++) {
            final want = rows.channels.firstWhere(
              (c) => c.oarCode == shown[i].oarCode,
            );
            final got = layout.speakers[i];
            final where = '${section.id}[$i] (${want.oarCode})';
            expect(got.label, shown[i].label, reason: '$where label');
            expect(got.isLFE, shown[i].isLFE, reason: '$where LFE flag');
            expect(
              (got.azDeg, got.elDeg),
              (want.azDeg, want.elDeg),
              reason: '$where position',
            );
          }
        });
      }

      if (section.element) {
        // Passing a layout's own id as the hint must yield that layout's
        // labels, including for the counts that are ambiguous without
        // one (6ch is 5.1 or 3.1.2, 8ch is 7.1 or 5.1.2, 10ch is 5.1.4 or
        // 7.1.2). Mono is excluded: a 1-channel file reads "M" on the
        // timeline where the scene's mono layout says "C".
        if (section.id != 'mono') {
          test('iamfChannelLabels matches the channel order', () {
            expect(
              iamfChannelLabels(
                channelCount: shown.length,
                layoutHint: section.id,
              ),
              shown.map((c) => c.label).toList(),
            );
          });
        }

        test('the element registers with the key\'s layout and count', () {
          // A Binaural element is registered as a stereo element; OAR's
          // binaural value names the monitoring target only.
          if (section.id == 'binaural') return;
          final element = AudioElement(
            id: 1,
            name: 'E',
            type: 'Channel',
            layout: elementLayoutFor(section.id)!.displayName,
            codec: 'LPCM',
            color: 0,
          );
          final (oarType, oarLayout, channels) = elementToOarType(element);
          expect(oarType, 0);
          expect(oarLayout, section.oarValue, reason: 'oar_layout_t');
          expect(channels, section.channels.length);
          expect(
            elementLayoutFor(section.id)!.channelCount,
            section.channels.length,
          );
          expect(
            channelCountForLayout(element.layout),
            section.channels.length,
            reason: 'Renderer view channel count',
          );
        });
      }

      if (!section.monitoring) return;
      final oarLayout = oarLayoutFor(section.id)!;

      test('OarLayout matches the layout and channel order', () {
        expect(oarLayout.oarValue, section.oarValue, reason: 'oar_layout_t');
        expect(oarLayout.channels, shown.length);
        // The meters, routing matrix and Settings label channels through
        // speakerLabels; the scene labels the same channels through
        // SpeakerLayout. One physical channel wears one name (ES-552). 9.1.6
        // adds the IAMF name to speakerLabels and keeps the short label
        // for the meter, the matrix cells and the compact summary; its
        // cell tooltips name the IAMF bitstream channel.
        if (alt.isEmpty) {
          expect(oarLayout.speakerLabels, shown.map((c) => c.label).toList());
          expect(oarLayout.meterLabels, oarLayout.speakerLabels);
          expect(oarLayout.channelTooltips, isNull);
        } else {
          expect(oarLayout.speakerLabels, [
            for (final c in shown)
              c.iamfName == c.label ? c.label : '${c.label} (${c.iamfName})',
          ]);
          expect(oarLayout.meterLabels, shown.map((c) => c.label));
          final tooltips = oarLayout.channelTooltips!;
          for (var i = 0; i < shown.length; i++) {
            final c = shown[i];
            expect(
              tooltips[i],
              c.iamfName == c.label
                  ? isNull
                  : '${c.label} (IAMF bitstream ${c.iamfName})',
              reason: 'tooltip $i',
            );
          }
        }
        expect(
          oarLayout.meterLabels.indexOf('LFE'),
          shown.indexWhere((c) => c.isLFE),
        );
      });
    });
  }

  group('9.1.6-alt', () {
    final section = sections.firstWhere((s) => s.id == '9.1.6');
    final alt = key.alts.firstWhere((a) => a.layoutId == '9.1.6');
    _Channel sourceRow(_AltChannel c) =>
        section.channels.firstWhere((r) => r.oarCode == c.oarCode);

    test('is a permutation of the [9.1.6] section with its names', () {
      expect(alt.oarValue, section.oarValue);
      expect(alt.channels, hasLength(section.channels.length));
      expect(
        alt.channels.map((c) => c.oarCode).toSet(),
        section.channels.map((c) => c.oarCode).toSet(),
      );
      for (final c in alt.channels) {
        expect(c.iamfName, sourceRow(c).iamfName, reason: c.oarCode);
        expect(c.label, sourceRow(c).label, reason: c.oarCode);
        expect(c.fullName, sourceRow(c).fullName, reason: c.oarCode);
      }
    });

    test('a Playback file\'s 9.1.6 element is drawn in the [9.1.6] '
        'order', () {
      // The engine feeds a Playback element to OAR without the alt
      // permutation, so its meters arrive in the section's order.
      final id = playbackChannelLayout('9.1.6');
      expect(SpeakerLayout.displayName(id), '9.1.6');
      final layout = SpeakerLayout.byName(id)!;
      expect(layout, same(SpeakerLayout.layout916Iamf));
      expect(layout.speakers, hasLength(section.channels.length));
      for (var i = 0; i < section.channels.length; i++) {
        final want = section.channels[i];
        final got = layout.speakers[i];
        expect(got.label, want.label, reason: '[$i] ${want.oarCode}');
        expect(got.isLFE, want.isLFE, reason: '[$i] ${want.oarCode}');
        expect(
          (got.azDeg, got.elDeg),
          (want.azDeg, want.elDeg),
          reason: '[$i] ${want.oarCode}',
        );
      }
      // On the binaural target the same element is drawn at OBR's
      // positions, in the same order.
      final rows = key.binaurals.firstWhere((b) => b.layoutId == '9.1.6');
      final binaural = layout.binauralGeometry;
      for (var i = 0; i < rows.channels.length; i++) {
        final got = binaural.speakers[i];
        expect(got.label, section.channels[i].label, reason: 'binaural [$i]');
        expect(
          (got.azDeg, got.elDeg),
          (rows.channels[i].azDeg, rows.channels[i].elDeg),
          reason: 'binaural [$i] ${rows.channels[i].oarCode}',
        );
      }
      expect(playbackChannelLayout('7.1.4'), '7.1.4');
      expect(SpeakerLayout.displayName('7.1.4'), '7.1.4');
    });

    test('the shared table is the alt section', () {
      expect(kAlt916Channels, hasLength(alt.channels.length));
      for (var i = 0; i < alt.channels.length; i++) {
        expect(kAlt916Channels[i], (
          iamf: alt.channels[i].iamfName,
          familiar: alt.channels[i].label,
        ), reason: 'alt channel $i');
      }
      // OAR channel c is the alt channel whose row names its OAR code.
      for (var c = 0; c < section.channels.length; c++) {
        expect(
          kAlt916FromOar[c],
          alt.channels.indexWhere(
            (a) => a.oarCode == section.channels[c].oarCode,
          ),
          reason: 'OAR channel $c',
        );
      }
      expect(iamfOrder916IamfLabels, section.channels.map((c) => c.iamfName));
      expect(alt916Labels, alt.channels.map((c) => c.label));
      expect(alt916IamfLabels, alt.channels.map((c) => c.iamfName));
    });

    test('the lanes follow the alt order with the familiar names', () {
      final labels = alt.channels.map((c) => c.label).toList();
      expect(
        List.generate(
          alt.channels.length,
          (i) => standardChannelLabel(i, alt.channels.length),
        ),
        labels,
      );
      // Lane tooltips name the IAMF bitstream channel; LFE keeps its long
      // label.
      final tips = channelLaneTooltips('9.1.6', labels);
      for (var i = 0; i < alt.channels.length; i++) {
        final c = alt.channels[i];
        expect(
          tips[i],
          c.iamfName == c.label
              ? c.fullName
              : '${c.label} (IAMF bitstream ${c.iamfName})',
          reason: 'lane $i',
        );
      }
    });
  });
}
