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
import 'package:eclipsa_studio/widgets/ae_type_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The element type glyphs and the detail line the Mix and Renderer
/// cards draw them in.
void main() {
  tearDown(() {
    T.setMode(T.defaultMode);
    T.setFontMode(FontSizeMode.medium);
  });

  late WidgetRef ref;

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    ProviderScope(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Consumer(
          builder: (context, r, _) {
            ref = r;
            return Center(child: child);
          },
        ),
      ),
    ),
  );

  group('AeTypeGlyph', () {
    testWidgets('Channel draws the loudspeaker icon', (tester) async {
      await pump(tester, const AeTypeGlyph(type: 'Channel', size: 15));
      expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.speaker);
      expect(
        find.descendant(
          of: find.byType(AeTypeGlyph),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
    });

    for (final type in ['Object', 'Scene']) {
      testWidgets('$type paints a glyph laid out at size x size', (
        tester,
      ) async {
        await pump(tester, AeTypeGlyph(type: type, size: 15));
        expect(find.byType(Icon), findsNothing);
        final paint = find.descendant(
          of: find.byType(AeTypeGlyph),
          matching: find.byType(CustomPaint),
        );
        expect(tester.getSize(paint), const Size(15, 15));
      });
    }

    // Const-constructed on purpose: the glyphs must repaint on a theme
    // switch even when their parent's rebuild skips them.
    testWidgets('the painted glyphs take the type colour of every theme', (
      tester,
    ) async {
      await pump(
        tester,
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AeTypeGlyph(key: ValueKey('o'), type: 'Object', size: 24),
            AeTypeGlyph(key: ValueKey('s'), type: 'Scene', size: 24),
          ],
        ),
      );
      for (final mode in AppThemeMode.values) {
        ref.read(themeModeProvider.notifier).set(mode);
        await tester.pump();
        RenderObject paintOf(String key) => tester.renderObject(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(CustomPaint),
          ),
        );
        // Orbit: the open ring, the source on it, the centre disc.
        expect(
          paintOf('o'),
          paints
            ..arc(color: T.typeObject)
            ..circle(color: T.typeObject)
            ..circle(color: T.typeObject),
          reason: mode.name,
        );
        // Four lobes: one even-odd path.
        expect(
          paintOf('s'),
          paints..path(color: T.typeScene),
          reason: mode.name,
        );
      }
    });

    testWidgets('an explicit colour replaces the type colour', (tester) async {
      const red = Color(0xFFFF0000);
      await pump(
        tester,
        const AeTypeGlyph(type: 'Object', size: 24, color: red),
      );
      expect(
        tester.renderObject(
          find.descendant(
            of: find.byType(AeTypeGlyph),
            matching: find.byType(CustomPaint),
          ),
        ),
        paints..arc(color: red),
      );
    });
  });

  group('ElementDetailRow', () {
    Widget row({bool numeric = false, bool dim = false}) => ElementDetailRow(
      glyph: const SizedBox.square(dimension: ElementDetailRow.glyphSize),
      label: '0.0 dB',
      numeric: numeric,
      dim: dim,
    );

    TextStyle styleOf(WidgetTester tester) =>
        tester.widget<Text>(find.text('0.0 dB')).style!;

    testWidgets('a label draws at fontBody in textSecondary', (tester) async {
      await pump(tester, row());
      final style = styleOf(tester);
      expect(style.fontSize, T.fontBody);
      expect(style.color, T.textSecondary);
      expect(style.fontFamily, isNull);
    });

    testWidgets('a numeric label draws in the monospace family at '
        'fontSmall', (tester) async {
      await pump(tester, row(numeric: true));
      final style = styleOf(tester);
      expect(style.fontFamily, T.monoFamily);
      expect(style.fontSize, T.fontSmall);
    });

    testWidgets('a dim label draws in textTertiary', (tester) async {
      await pump(tester, row(dim: true));
      expect(styleOf(tester).color, T.textTertiary);
    });
  });
}
