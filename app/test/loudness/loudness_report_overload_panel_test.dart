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

// Widget tests for the Loudness Report's signal-overload panel (ES-527):
// a report whose elementClipStats holds a clipped entry surfaces a
// per-element warning row; a clean report shows no panel; the panel
// coexists with the stale banner and stays inside its height cap when
// many elements clip. The seeded report's fingerprint matches the live
// session so the dialog shows it as-is instead of starting a
// measurement pass.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/export/element_clip_stats.dart';
import 'package:eclipsa_studio/export/iamf_export_config.dart'
    show kIamfTargetSampleRate;
import 'package:eclipsa_studio/loudness/loudness_fingerprint.dart';
import 'package:eclipsa_studio/loudness/loudness_report_dialog.dart';
import 'package:eclipsa_studio/loudness/loudness_report_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';

AudioElement _element(int id, String name, {double gain = 0}) => AudioElement(
  id: id,
  name: name,
  type: 'Channel',
  layout: 'Stereo',
  codec: 'PCM',
  color: 0xFF000000,
  gain: gain,
  wavPath: '/tmp/$name.wav',
);

const _mixes = [
  Mix(id: 1, name: 'Main Mix', language: 'en', subMixes: [SubMix()]),
];

const _hot = ElementClipStats(clippedSamples: 1204, peakLinear: 1.3);

class _FixedElements extends ElementsNotifier {
  final List<AudioElement> fixture;
  _FixedElements(this.fixture);

  @override
  List<AudioElement> build() => fixture;
}

class _FixedMixes extends MixesNotifier {
  @override
  List<Mix> build() => _mixes;
}

class _SeededReport extends LoudnessReportNotifier {
  final List<AudioElement> elements;
  final Map<int, ElementClipStats> clipStats;
  _SeededReport(this.elements, this.clipStats);

  @override
  LoudnessReportData? build() => LoudnessReportData(
    results: const [],
    fingerprint: loudnessFingerprint(
      elements: elements,
      mixes: _mixes,
      sampleRate: kIamfTargetSampleRate,
    ),
    measuredAt: DateTime(2026, 8, 6, 12, 0),
    sampleRate: kIamfTargetSampleRate,
    elementClipStats: clipStats,
  );
}

Future<void> _pumpReport(
  WidgetTester tester,
  Map<int, ElementClipStats> clipStats, {
  List<AudioElement>? elements,
}) async {
  final elems = elements ?? [_element(1, 'Drums')];
  // The dialog lays out for a desktop window; the default 800×600 test
  // surface overflows its header under the wide Ahem test font.
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        elementsProvider.overrideWith(() => _FixedElements(elems)),
        mixesNotifierProvider.overrideWith(_FixedMixes.new),
        loudnessReportProvider.overrideWith(
          () => _SeededReport(elems, clipStats),
        ),
      ],
      child: const MaterialApp(home: LoudnessReportDialog()),
    ),
  );
  // Let the post-frame fingerprint check run (it matches → no measure).
  await tester.pump();
}

void main() {
  testWidgets('clipped element surfaces an overload row', (tester) async {
    await _pumpReport(tester, {1: _hot});

    expect(find.text('SIGNAL OVERLOAD'), findsOneWidget);
    expect(
      find.textContaining('Element "Drums": 1,204 samples above full scale'),
      findsOneWidget,
    );
  });

  testWidgets('clean report shows no overload panel', (tester) async {
    await _pumpReport(tester, {
      1: const ElementClipStats(clippedSamples: 0, peakLinear: 0.9),
    });

    expect(find.text('SIGNAL OVERLOAD'), findsNothing);
  });

  testWidgets('stats for a removed element still warn, with placeholder '
      'name', (tester) async {
    // Interpolated, not a literal: the open-source export rewrites a
    // literal `ES-99` as an issue reference.
    const id = 99;
    await _pumpReport(tester, {id: _hot});

    expect(find.text('SIGNAL OVERLOAD'), findsOneWidget);
    expect(find.textContaining('Element "Element #$id"'), findsOneWidget);
  });

  testWidgets('stale report keeps the panel, alongside the stale banner '
      'and with live element names', (tester) async {
    await _pumpReport(tester, {1: _hot});

    // Mutate the session after measuring: a gain change makes the
    // report stale (gain is a fingerprint input) and a rename checks
    // the rows resolve names against the LIVE elements list (names are
    // deliberately not fingerprinted).
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LoudnessReportDialog)),
    );
    container.read(workspaceModeProvider.notifier).enterCreator();
    container.read(elementsProvider.notifier).set([
      _element(1, 'Kick', gain: -3),
    ]);
    await tester.pump();

    expect(find.textContaining('The session changed'), findsOneWidget);
    expect(find.text('SIGNAL OVERLOAD'), findsOneWidget);
    expect(find.textContaining('Element "Kick"'), findsOneWidget);
  });

  testWidgets('many clipped elements stay inside the height cap', (
    tester,
  ) async {
    final elems = [for (var i = 1; i <= 12; i++) _element(i, 'E$i')];
    await _pumpReport(tester, {
      for (final e in elems) e.id: _hot,
    }, elements: elems);

    expect(tester.takeException(), isNull);
    expect(find.text('SIGNAL OVERLOAD'), findsOneWidget);
    // The row list scrolls inside its cap instead of crowding out the
    // grid, which must still be present below.
    final scroller = find.ancestor(
      of: find.textContaining('Element "E1"'),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scroller, findsOneWidget);
    expect(tester.getSize(scroller).height, lessThanOrEqualTo(96));
    expect(find.text('MIX / LAYOUT'), findsOneWidget);
  });
}
