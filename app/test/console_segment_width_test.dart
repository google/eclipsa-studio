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

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/video/video_backend_kind.dart';
import 'package:eclipsa_studio/widgets/console_widgets.dart';
import 'package:eclipsa_studio/widgets/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the font-scale safety of [ConsoleSegment.uniformWidth]: at every
/// font-size mode, every label of the settings dialog's segmented rows
/// renders on a single line inside its equal-width cell at the shared
/// measured width. The option sets are imported from the settings
/// dialog and the backend enum — a label edit there is a label edit
/// here — and the app pumps under the production theme so the ambient
/// DefaultTextStyle matches what ships. The theme picker is not here:
/// it is a [ConsoleSelector], not a segmented row.
List<List<String>> _settingsOptionSets() => [
  [for (final o in kTimeDisplayOptions) o.$2],
  [for (final o in kPlayheadFollowOptions) o.$2],
  [for (final m in FontSizeMode.values) m.label],
  // Cross-platform superset of the backend selector (per-OS at runtime).
  [
    for (final k in VideoBackendKind.values)
      if (k != VideoBackendKind.auto && k.userSelectable) k.label,
  ],
];

void main() {
  tearDown(() => T.setFontMode(FontSizeMode.medium));

  /// Pumps a [ConsoleSegment] for [labels] with [active] selected under
  /// the production theme, sized by [ConsoleSegment.uniformWidth] over
  /// all settings option sets; returns the measured shared width.
  Future<double> pumpSegment(
    WidgetTester tester,
    List<String> labels,
    String active, {
    bool enabled = true,
    ValueChanged<String>? onChanged,
  }) async {
    late double width;
    await tester.pumpWidget(
      MaterialApp(
        theme: eclipsaStudioTheme(),
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) {
                width = ConsoleSegment.uniformWidth(
                  context,
                  _settingsOptionSets(),
                );
                return ConsoleSegment<String>(
                  width: width,
                  enabled: enabled,
                  value: active,
                  options: [for (final l in labels) (l, l)],
                  onChanged: onChanged ?? (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );
    return width;
  }

  for (final mode in FontSizeMode.values) {
    testWidgets('every settings label renders one line at ${mode.label}', (
      tester,
    ) async {
      T.setFontMode(mode);
      for (final labels in _settingsOptionSets()) {
        // Render each option as the *active* (w600, widest) segment and
        // assert against the render tree: the paragraph must stay a
        // single line (wrapping, not an exception, is how an over-tight
        // cell fails).
        for (final active in labels) {
          final width = await pumpSegment(tester, labels, active);
          expect(
            tester.getSize(find.byType(ConsoleSegment<String>)).width,
            width,
            reason: 'control must render at the shared width',
          );
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(active),
          );
          final oneLine = paragraph.text.style!.fontSize! * 1.6;
          expect(
            paragraph.size.height,
            lessThanOrEqualTo(oneLine),
            reason:
                '"$active" must render on one line at ${mode.label} '
                '(${mode.scale}x)',
          );
        }
      }
    });
  }

  testWidgets('uniformWidth tracks the font scale', (tester) async {
    final widths = <FontSizeMode, double>{};
    for (final mode in FontSizeMode.values) {
      T.setFontMode(mode);
      widths[mode] = await pumpSegment(
        tester,
        _settingsOptionSets().first,
        _settingsOptionSets().first.first,
      );
    }
    expect(widths[FontSizeMode.small], lessThan(widths[FontSizeMode.medium]!));
    expect(widths[FontSizeMode.medium], lessThan(widths[FontSizeMode.large]!));
  });

  testWidgets('disabled segment ignores taps', (tester) async {
    final taps = <String>[];
    await pumpSegment(
      tester,
      const ['A', 'B'],
      'A',
      enabled: false,
      onChanged: taps.add,
    );
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(taps, isEmpty);
  });
}
