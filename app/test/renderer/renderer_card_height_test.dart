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

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/views/renderer_view.dart';
import 'package:eclipsa_studio/widgets/ae_type_badge.dart';
import 'package:eclipsa_studio/widgets/mix_status_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/golden_fonts.dart';

/// The Renderer view's element cards are one height whatever the element
/// type, and keep their gain line at one offset from the card's top. An
/// excluded card's Not in mix presentation line sits where the others
/// draw the headphones line, uncut. The fonts are the bundled Inter and
/// JetBrains Mono: the test font gives every family the same metrics and
/// would hide a height difference.
void main() {
  setUpAll(loadGoldenFonts);
  tearDown(() => T.setFontMode(FontSizeMode.medium));

  AudioElement element(int id, String type, String layout) => AudioElement(
    id: id,
    name: 'e$id',
    type: type,
    layout: layout,
    codec: 'WAV 24bit',
    color: 0xFF34D399,
    azimuth: -180,
    elevation: -90,
    distance: 1,
  );

  final cards = <String, Widget>{
    'object': InputElementCard(
      element: element(1, 'Object', 'Mono'),
      levels: const [0],
      mixSettings: const MixElementSettings(elementId: 1),
    ),
    'channel': InputElementCard(
      element: element(2, 'Channel', '7.1.4'),
      levels: List.filled(12, 0),
      mixSettings: const MixElementSettings(elementId: 2),
    ),
    'scene': InputElementCard(
      element: element(3, 'Scene', '3OA'),
      levels: List.filled(16, 0),
      mixSettings: const MixElementSettings(elementId: 3),
    ),
    // Twelve channels: the widest meter, the narrowest details column.
    'excluded': InputElementCard(
      element: element(4, 'Channel', '7.1.4'),
      levels: List.filled(12, 0),
      excludedFromMix: true,
    ),
  };

  for (final mode in FontSizeMode.values) {
    testWidgets('cards are one height at the ${mode.label} font size', (
      tester,
    ) async {
      T.setFontMode(mode);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: eclipsaStudioTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 240,
                  child: Column(
                    children: [
                      for (final e in cards.entries)
                        KeyedSubtree(key: ValueKey(e.key), child: e.value),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final heights = {
        for (final k in cards.keys)
          k: tester.getSize(find.byKey(ValueKey(k))).height,
      };
      expect(heights.values.toSet(), hasLength(1), reason: '$heights');

      // The top of a card's line, below the card's top.
      double offset(String key, Finder line) =>
          tester.getTopLeft(line).dy -
          tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      Finder row(String key, Finder child) => find.ancestor(
        of: find.descendant(of: find.byKey(ValueKey(key)), matching: child),
        matching: find.byType(ElementDetailRow),
      );
      const included = ['object', 'channel', 'scene'];

      // The gain line sits at one offset in every card.
      final gains = {
        for (final k in included) k: offset(k, row(k, find.text('0.0 dB'))),
      };
      expect(gains.values.toSet(), hasLength(1), reason: '$gains');

      // The Not in mix presentation line takes the headphones line's
      // place.
      final lastLines = {
        for (final k in included)
          k: offset(k, row(k, find.byIcon(Icons.headphones))),
        'excluded': offset(
          'excluded',
          find.descendant(
            of: find.byKey(const ValueKey('excluded')),
            matching: find.byType(MixStatusBadge),
          ),
        ),
      };
      expect(lastLines.values.toSet(), hasLength(1), reason: '$lastLines');

      // The excluded card's label fits the card uncut.
      final label = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const ValueKey('excluded')),
          matching: find.text('Not in mix presentation'),
        ),
      );
      expect(label.didExceedMaxLines, isFalse);
    });
  }
}
