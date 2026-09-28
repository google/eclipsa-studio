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

// Pins the app's speaker tables to the engine's output channel order
// (ES-592).
//
// `SpeakerLayout` (the 3D scene) and `OarLayout` (meters, routing matrix,
// Settings) each carry a copy of OAR's per-layout channel order. Both were
// previously pinned against hand-transcribed copies of themselves, so an
// OAR_COMMIT bump that reordered a layout or moved a speaker left every
// Dart test green while the engine rendered something else — the ES-552
// mislabels, and the ES-588 height ring drawn 15 degrees too high.
//
// Both now read engine/renderer/oar_output_channels.txt, the single
// transcription of OAR's layout table, which
// engine/test/oar_output_channels_test.cc verifies against what OAR
// actually renders. A layout that moves upstream fails there first, and
// updating the table makes this test fail until the app tables follow.
//
// This supersedes the hand-transcribed test/renderer/
// speaker_layout_geometry_test.dart.

import 'dart:io';

import 'package:eclipsa_studio/renderer/speaker_layout.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/waveform/multi_channel_waveform.dart'
    show channelFullName;
import 'package:eclipsa_studio/widgets/routing_labels.dart'
    show iamfChannelLabels;
import 'package:flutter_test/flutter_test.dart';

/// One output channel of a layout, as the engine table describes it.
class _Channel {
  const _Channel(this.oarLabel, this.label, this.azDeg, this.elDeg, this.isLFE);

  /// OAR's own name for the speaker, e.g. `M+030`. Reported in failures.
  final String oarLabel;

  /// Eclipsa Studio's name for the channel, e.g. `L`.
  final String label;
  final double azDeg;
  final double elDeg;
  final bool isLFE;
}

/// One layout section of the engine table.
class _Section {
  _Section(this.id, this.oarValue);
  final String id;
  final int oarValue;
  final List<_Channel> channels = [];
}

/// The `[names]` glossary section: app label to the full tooltip name.
const _namesSection = 'names';

/// Parses `engine/renderer/oar_output_channels.txt` — the format is
/// documented at the head of that file. Runs before any test body, so it
/// reports malformed input as a [FormatException] rather than a matcher.
({List<_Section> layouts, Map<String, String> names}) _parseTable(String text) {
  final layouts = <_Section>[];
  final names = <String, String>{};
  var inNames = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final fields = line.split(RegExp(r'\s+'));
    if (line.startsWith('[')) {
      if (!fields[0].endsWith(']')) {
        throw FormatException('bad section header', line);
      }
      final id = fields[0].substring(1, fields[0].length - 1);
      inNames = id == _namesSection;
      // Every section but the glossary names its oar_layout_t value.
      if (inNames) {
        if (fields.length != 1) throw FormatException('bad [names]', line);
      } else {
        if (fields.length != 2) throw FormatException('bad header', line);
        layouts.add(_Section(id, int.parse(fields[1])));
      }
      continue;
    }
    if (inNames) {
      // The full name runs to the end of the line: it has spaces.
      final split = line.indexOf(RegExp(r'\s'));
      if (split < 0) throw FormatException('bad glossary row', line);
      names[line.substring(0, split)] = line.substring(split).trim();
      continue;
    }
    if (layouts.isEmpty) {
      throw FormatException('channel before a section', line);
    }
    if (fields.length != 5 || (fields[4] != 'lfe' && fields[4] != '-')) {
      throw FormatException('bad channel row', line);
    }
    layouts.last.channels.add(
      _Channel(
        fields[0],
        fields[1],
        double.parse(fields[2]),
        double.parse(fields[3]),
        fields[4] == 'lfe',
      ),
    );
  }
  return (layouts: layouts, names: names);
}

void main() {
  final table = _parseTable(
    File('../engine/renderer/oar_output_channels.txt').readAsStringSync(),
  );
  final sections = table.layouts;

  /// The [OarLayout] that monitors each engine layout id. `mono` and
  /// `3.1.2` are scene layouts only — they are not monitoring targets.
  const oarLayoutById = {
    'stereo': OarLayout.stereo,
    '5.1': OarLayout.layout51,
    '5.1.2': OarLayout.layout512,
    '5.1.4': OarLayout.layout514,
    '7.1': OarLayout.layout71,
    '7.1.2': OarLayout.layout712,
    '7.1.4': OarLayout.layout714,
    '9.1.6': OarLayout.layout916,
  };

  // A missing or malformed table throws out of _parseTable above, before
  // any test body runs, so this only has to cover what parses cleanly.
  test('the engine table covers every layout', () {
    expect(sections.map((s) => s.id), [
      'mono',
      'stereo',
      '3.1.2',
      '5.1',
      '5.1.2',
      '5.1.4',
      '7.1',
      '7.1.2',
      '7.1.4',
      '9.1.6',
    ]);
    // Every scene layout is described, and nothing is described twice.
    expect(
      SpeakerLayout.all.map((l) => l.id).toSet(),
      sections.map((s) => s.id).toSet(),
    );
    // Every monitoring target but Binaural, which renders through HRTFs
    // and has no speaker layout.
    expect(
      OarLayout.values.where((l) => l != OarLayout.binaural).toSet(),
      oarLayoutById.values.toSet(),
    );
  });

  test('channelFullName matches the glossary', () {
    expect(table.names, isNotEmpty);
    table.names.forEach((label, fullName) {
      expect(channelFullName(label), fullName, reason: label);
    });
  });

  for (final section in sections) {
    group(section.id, () {
      final layout = SpeakerLayout.all.firstWhere((l) => l.id == section.id);

      test('SpeakerLayout matches the engine channel order', () {
        expect(layout.speakers, hasLength(section.channels.length));
        for (var i = 0; i < section.channels.length; i++) {
          final want = section.channels[i];
          final got = layout.speakers[i];
          final where = '${section.id}[$i] (${want.oarLabel})';
          expect(got.isLFE, want.isLFE, reason: '$where LFE flag');
          expect(got.label, want.label, reason: '$where label');
          expect(
            (got.azDeg, got.elDeg),
            (want.azDeg, want.elDeg),
            reason: '$where position',
          );
        }
      });

      // Passing a layout's own id as the hint must yield that layout's
      // labels, including for the counts that are ambiguous without one
      // (6ch is 5.1 or 3.1.2, 8ch is 7.1 or 5.1.2, 10ch is 5.1.4 or
      // 7.1.2). Mono is excluded: a 1-channel file reads "M" on the
      // timeline where the scene's mono layout says "C".
      if (section.id != 'mono') {
        test('iamfChannelLabels matches the engine channel order', () {
          expect(
            iamfChannelLabels(
              channelCount: section.channels.length,
              layoutHint: section.id,
            ),
            section.channels.map((c) => c.label).toList(),
          );
        });
      }

      final oarLayout = oarLayoutById[section.id];
      if (oarLayout == null) return;

      test('OarLayout matches the engine layout and channel order', () {
        expect(oarLayout.oarValue, section.oarValue, reason: 'oar_layout_t');
        expect(oarLayout.channels, section.channels.length);
        // The meters, routing matrix and Settings label channels through
        // speakerLabels; the scene labels the same channels through
        // SpeakerLayout. One physical channel wears one name (ES-552).
        expect(
          oarLayout.speakerLabels,
          section.channels.map((c) => c.label).toList(),
        );
        expect(
          oarLayout.speakerLabels.indexOf('LFE'),
          section.channels.indexWhere((c) => c.isLFE),
        );
      });
    });
  }
}
