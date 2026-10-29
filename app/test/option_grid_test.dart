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

// OptionGrid, the Renderer view's output target switcher (ES-930): the
// layout (rows of equal buttons that fill the width, a column count
// from the width and the widest label, every label on one line at
// every font size), the four themes' drawings per state, input (a tap
// or Enter chooses an option; an unavailable option takes neither and
// Tab skips it), the label contrast on the rendered face,
// and the redraw on a theme or font switch. The grid sits on bgBase,
// the Renderer view's output panel fill, at that panel's inner width.

import 'dart:ui' as ui;

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/chrome_surface.dart';
import 'package:eclipsa_studio/widgets/option_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/contrast.dart';
import 'support/golden_fonts.dart';

/// The Renderer view's output panel is 240 px with 12 px of padding a
/// side.
const _panelWidth = 216.0;

const _key = ValueKey('subject');

/// Five targets, as the panel shows them: `Surround` is unavailable.
const _targets = [
  (0, 'Stereo'),
  (1, 'Quad'),
  (2, 'Surround'),
  (3, 'Binaural'),
  (4, 'Mono'),
];
const _unavailable = {2};

/// The labels of every monitoring layout.
final _layouts = [for (final l in OarLayout.values) (l.index, l.label)];

late ProviderContainer _container;

Future<void> _pump(
  WidgetTester tester, {
  required int value,
  List<(int, String)> options = _targets,
  Set<int> unavailable = _unavailable,
  ValueChanged<int>? onChanged,
  double width = _panelWidth,
}) async {
  _container = ProviderContainer();
  addTearDown(_container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _container,
      child: MaterialApp(
        theme: eclipsaStudioTheme(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: _key,
              child: Container(
                color: T.bgBase,
                padding: const EdgeInsets.all(8),
                width: width + 16,
                child: OptionGrid<int>(
                  value: value,
                  options: options,
                  unavailable: unavailable,
                  onChanged: onChanged ?? (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The buttons in grid order.
List<Rect> _buttons(WidgetTester tester, List<(int, String)> options) => [
  for (final (_, label) in options)
    tester.getRect(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(ChromePressable),
      ),
    ),
];

/// The rows of [rects], by their top edge.
List<List<Rect>> _rows(List<Rect> rects) {
  final rows = <List<Rect>>[];
  for (final r in rects) {
    if (rows.isEmpty || rows.last.first.top != r.top) {
      rows.add([r]);
    } else {
      rows.last.add(r);
    }
  }
  return rows;
}

/// The label as drawn: its own style merged over the default text style
/// the chip gives it.
Text _label(WidgetTester tester, String label) {
  final finder = find.text(label);
  final style = DefaultTextStyle.of(
    tester.element(finder),
  ).style.merge(tester.widget<Text>(finder).style);
  return Text(label, style: style);
}

/// The sampler of the subject's rendered pixels, at [scale].
Future<Color Function(Offset point)> _sampler(
  WidgetTester tester, {
  double scale = 2,
}) async {
  final boundary =
      tester.renderObject(find.byKey(_key)) as RenderRepaintBoundary;
  late final ByteData data;
  late final int width;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: scale);
    data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    width = image.width;
    image.dispose();
  });
  final origin = tester.getTopLeft(find.byKey(_key));
  return (point) {
    final p = (point - origin) * scale;
    final i = (p.dy.floor() * width + p.dx.floor()) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  };
}

void main() {
  // The bundled font for every test: the layout tests measure what the
  // app draws, and the pixel samples do not depend on glyph shapes.
  setUpAll(loadGoldenFonts);
  tearDown(() {
    T.setMode(T.defaultMode);
    T.setFontMode(FontSizeMode.medium);
  });

  group('layout', () {
    for (final count in [1, 2, 3, 5, 9]) {
      testWidgets('$count options: rows fill the width with equal buttons', (
        tester,
      ) async {
        final options = _layouts.sublist(0, count);
        await _pump(tester, value: 0, options: options, unavailable: {});
        final grid = tester.getRect(find.byType(OptionGrid<int>));
        expect(grid.width, _panelWidth);
        final rows = _rows(_buttons(tester, options));
        // The column count is the rule's, from the widest label as the
        // grid measures it.
        final context = tester.element(find.byType(OptionGrid<int>));
        final columns = OptionGrid.columnCount(
          width: _panelWidth,
          widestLabel: OptionGrid.widestLabel(context, [
            for (final o in options) o.$2,
          ]),
          count: count,
        );
        expect(rows.length, (count / columns).ceil(), reason: 'rows');
        for (final (r, row) in rows.indexed) {
          final last = r == rows.length - 1;
          expect(
            row.length,
            last ? count - columns * (rows.length - 1) : columns,
            reason: 'row $r',
          );
          expect(
            row.first.left,
            closeTo(grid.left, 0.01),
            reason: 'row $r left',
          );
          expect(
            row.last.right,
            closeTo(grid.right, 0.01),
            reason: 'row $r right',
          );
          for (final b in row) {
            expect(b.width, closeTo(row.first.width, 0.01));
            expect(b.height, OptionGrid.height);
          }
          for (var i = 1; i < row.length; i++) {
            expect(
              row[i].left - row[i - 1].right,
              closeTo(OptionGrid.gap, 0.01),
            );
          }
          if (r > 0) {
            expect(row.first.top - rows[r - 1].first.bottom, OptionGrid.gap);
          }
        }
      });
    }

    test('columnCount fits the most buttons at the widest label', () {
      // Three 60 px labels, 8 px of padding a side, 4 px apart: 76 x 3
      // + 2 x 4 = 236 px.
      int cols(double width) =>
          OptionGrid.columnCount(width: width, widestLabel: 60, count: 9);
      expect(cols(236), 3);
      expect(cols(235), 2);
      expect(cols(1000), 9, reason: 'never more than the options');
      expect(cols(10), 1, reason: 'at least one');
      expect(OptionGrid.columnCount(width: 1000, widestLabel: 60, count: 0), 1);
    });

    testWidgets('every layout label fits on one line at every font size', (
      tester,
    ) async {
      for (final font in FontSizeMode.values) {
        T.setFontMode(font);
        await tester.pumpWidget(const SizedBox());
        await _pump(tester, value: 0, options: _layouts, unavailable: {});
        expect(tester.takeException(), isNull, reason: font.name);
        final context = tester.element(find.byType(OptionGrid<int>));
        final buttons = _buttons(tester, _layouts);
        for (final (i, (_, label)) in _layouts.indexed) {
          final width = OptionGrid.widestLabel(context, [label]);
          expect(
            width,
            lessThanOrEqualTo(buttons[i].width - 16),
            reason: '$label at ${font.name}',
          );
          final text = tester.renderObject<RenderParagraph>(find.text(label));
          expect(text.textSize.width, lessThanOrEqualTo(text.size.width));
        }
        // Three columns at Small and Medium, two at Large, where
        // Binaural at the selected weight no longer fits three across.
        expect(
          _rows(buttons).first.length,
          font == FontSizeMode.large ? 2 : 3,
          reason: font.name,
        );
      }
    });
  });

  group('drawing', () {
    for (final mode in AppThemeMode.values) {
      testWidgets('the states take the theme\'s inks, ${mode.name}', (
        tester,
      ) async {
        T.setMode(mode);
        await _pump(tester, value: 0);
        final selectedInk = T.accentInk;
        final (idleInk, offInk) = switch (T.chromeStyle) {
          ChromeStyle.raised => (T.chromeTabOn, T.textSecondary),
          _ => (T.textSecondary, T.textTertiary),
        };
        expect(_label(tester, 'Stereo').style!.color, selectedInk);
        expect(_label(tester, 'Stereo').style!.fontWeight, FontWeight.w600);
        expect(_label(tester, 'Quad').style!.color, idleInk);
        expect(_label(tester, 'Quad').style!.fontWeight, FontWeight.w400);
        expect(_label(tester, 'Surround').style!.color, offInk);
        // The unavailable face is dimmed under its label; the others
        // are not.
        expect(
          find.ancestor(
            of: find.text('Surround'),
            matching: find.byType(Opacity),
          ),
          findsNothing,
          reason: 'the label is not dimmed',
        );
        final dimmed = find.descendant(
          of: find.ancestor(
            of: find.text('Surround'),
            matching: find.byType(ChromePressable),
          ),
          matching: find.byType(Opacity),
        );
        expect(tester.widget<Opacity>(dimmed).opacity, 0.4);
        expect(
          find.descendant(
            of: find.byType(OptionGrid<int>),
            matching: find.byType(Opacity),
          ),
          findsOneWidget,
        );

        await _pump(tester, value: 2);
        expect(_label(tester, 'Surround').style!.color, T.textPrimary);
        expect(_label(tester, 'Stereo').style!.color, idleInk);
      });
    }

    testWidgets('Light: a lifted RaisedFace, and the flat selected face '
        'when selected', (tester) async {
      T.setMode(AppThemeMode.light);
      await _pump(tester, value: 0);
      Finder raised(String label) => find.descendant(
        of: find.ancestor(
          of: find.text(label),
          matching: find.byType(ChromePressable),
        ),
        matching: find.byType(RaisedFace),
      );
      RaisedFace face(String label) => tester.widget<RaisedFace>(raised(label));
      expect(raised('Stereo'), findsNothing);
      expect(face('Quad').pressed, isFalse);
      expect(face('Quad').face, isNull);
      expect(face('Quad').lifted, isTrue);
      expect(face('Surround').lifted, isFalse, reason: 'unavailable');
      expect(face('Quad').radius, T.radiusSm);
    });

    testWidgets('Dark, Classic and High Contrast draw no RaisedFace', (
      tester,
    ) async {
      for (final mode in [
        AppThemeMode.dark,
        AppThemeMode.classic,
        AppThemeMode.highContrast,
      ]) {
        T.setMode(mode);
        await _pump(tester, value: 0);
        expect(find.byType(RaisedFace), findsNothing, reason: mode.name);
      }
    });

    for (final mode in AppThemeMode.values) {
      testWidgets('the selected face is a flat accent fill with no rim, '
          '${mode.name}', (tester) async {
        T.setMode(mode);
        await _pump(tester, value: 0);
        final box = find.descendant(
          of: find.ancestor(
            of: find.text('Stereo'),
            matching: find.byType(ChromePressable),
          ),
          matching: find.byType(DecoratedBox),
        );
        final deco =
            tester.widget<DecoratedBox>(box.first).decoration as BoxDecoration;
        expect(deco.color, T.accentFill);
        expect(deco.border, isNull);
        expect(deco.boxShadow, isNull, reason: 'sits flat');
      });
    }
  });

  group('input', () {
    testWidgets('a tap chooses; the selected and unavailable options take '
        'none', (tester) async {
      final chosen = <int>[];
      await _pump(tester, value: 0, onChanged: chosen.add);
      await tester.tap(find.text('Surround'));
      await tester.tap(find.text('Stereo'));
      await tester.tap(find.text('Binaural'));
      expect(chosen, [3]);
    });

    testWidgets('Tab focuses an option, Enter activates it; Tab skips an '
        'unavailable one', (tester) async {
      final chosen = <int>[];
      await _pump(tester, value: 0, onChanged: chosen.add);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(chosen, [1], reason: 'the second option, Quad');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(chosen, [1, 3], reason: 'Binaural, past unavailable Surround');
    });

    testWidgets('each option announces as a button with its state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, value: 0);
      SemanticsData data(String label) =>
          tester.getSemantics(find.bySemanticsLabel(label)).getSemanticsData();
      final selected = data('Stereo');
      expect(selected.flagsCollection.isButton, isTrue);
      expect(selected.flagsCollection.isSelected, ui.Tristate.isTrue);
      expect(selected.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      expect(selected.flagsCollection.isEnabled, ui.Tristate.isTrue);
      expect(selected.hasAction(SemanticsAction.tap), isTrue);
      final idle = data('Quad');
      expect(idle.flagsCollection.isSelected, ui.Tristate.isFalse);
      expect(idle.flagsCollection.isEnabled, ui.Tristate.isTrue);
      final unavailable = data('Surround');
      expect(unavailable.flagsCollection.isButton, isTrue);
      expect(unavailable.flagsCollection.isEnabled, ui.Tristate.isFalse);
      expect(unavailable.hasAction(SemanticsAction.tap), isFalse);
      handle.dispose();
    });
  });

  group('contrast', () {
    for (final mode in AppThemeMode.values) {
      testWidgets('every state\'s label is at least 4.5:1 on its face, '
          '${mode.name}', (tester) async {
        T.setMode(mode);
        // The selected option, an idle one, an unavailable one, and
        // the selected option unavailable.
        for (final (value, label) in [
          (0, 'Stereo'),
          (0, 'Quad'),
          (0, 'Surround'),
          (2, 'Surround'),
        ]) {
          await tester.pumpWidget(const SizedBox());
          await _pump(tester, value: value);
          final sample = await _sampler(tester);
          final rect = tester.getRect(find.text(label));
          // 4 px left of the label is the face, inside the button's
          // padding; the ink is the pixel of the label's box that
          // differs most from it.
          final face = sample(Offset(rect.left - 4, rect.center.dy));
          var ink = face;
          var ratio = 1.0;
          for (var y = rect.top; y < rect.bottom; y += 0.5) {
            for (var x = rect.left; x < rect.right; x += 0.5) {
              final c = sample(Offset(x, y));
              final r = contrastRatio(c, face);
              if (r > ratio) {
                ratio = r;
                ink = c;
              }
            }
          }
          final state = value == 2
              ? 'selected unavailable'
              : (label == 'Stereo'
                    ? 'selected'
                    : (label == 'Quad' ? 'idle' : 'unavailable'));
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                '$state: label $ink on face $face is '
                '${ratio.toStringAsFixed(2)}:1',
          );
        }
      });
    }
  });

  group('focus ring', () {
    for (final mode in AppThemeMode.values) {
      testWidgets('the ring reads on the selected and the idle face, '
          '${mode.name}', (tester) async {
        T.setMode(mode);
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        addTearDown(
          () => FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.automatic,
        );
        await _pump(tester, value: 0);
        // The ring is 1.5 px wide on the outer edge of every button.
        for (final (label, inset) in [('Stereo', 0.0), ('Quad', 0.0)]) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final sample = await _sampler(tester);
          final button = tester.getRect(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(ChromePressable),
            ),
          );
          final rect = tester.getRect(find.text(label));
          final ring = sample(
            Offset(button.left + inset + 0.75, rect.center.dy),
          );
          final face = sample(Offset(rect.left - 4, rect.center.dy));
          final ratio = contrastRatio(ring, face);
          expect(
            ratio,
            greaterThanOrEqualTo(3.0),
            reason:
                '$label: ring $ring on face $face is '
                '${ratio.toStringAsFixed(2)}:1',
          );
        }
      });
    }
  });

  group('reactivity', () {
    testWidgets('a const grid redraws on a theme or font switch', (
      tester,
    ) async {
      T.setMode(AppThemeMode.dark);
      _container = ProviderContainer();
      addTearDown(_container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: _container,
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 216,
                child: OptionGrid<int>(
                  value: 0,
                  options: _targets,
                  onChanged: _ignore,
                ),
              ),
            ),
          ),
        ),
      );
      expect(_label(tester, 'Stereo').style!.color, kThemeDark.accentInk);
      _container.read(themeModeProvider.notifier).set(AppThemeMode.light);
      await tester.pump();
      expect(_label(tester, 'Stereo').style!.color, kThemeLight.accentInk);
      // Every option but the selected one is a RaisedFace in Light.
      expect(find.byType(RaisedFace), findsNWidgets(_targets.length - 1));
      final before = _label(tester, 'Stereo').style!.fontSize!;
      _container.read(fontSizeModeProvider.notifier).set(FontSizeMode.large);
      await tester.pump();
      expect(_label(tester, 'Stereo').style!.fontSize, greaterThan(before));
    });
  });
}

void _ignore(int _) {}
