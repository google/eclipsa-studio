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

import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/views/mix_view.dart';
import 'package:eclipsa_studio/widgets/console_chip.dart';
import 'package:eclipsa_studio/widgets/remove_x_button.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/mix_state_engine.dart';

/// The Mix view draws its mix presentation tabs, its layout chips and
/// its two add buttons as [ConsoleChip]s, as the Renderer view draws its
/// monitoring targets: selected for the active mix presentation, plain
/// for the other tabs, the add buttons and the tagged layouts, which are
/// labels. Its caps labels share [T.styleSectionLabel].
void main() {
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, AppThemeMode mode) async {
    T.setMode(mode);
    addTearDown(() => T.setMode(T.defaultMode));
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [
        eclipsaStudioEngineProvider.overrideWithValue(MixStateEngine()),
      ],
    );
    addTearDown(container.dispose);
    container.read(workspaceModeProvider.notifier).enterCreator();
    container.read(elementsProvider.notifier).set([
      AudioElement(
        id: 1,
        name: 'Bed',
        type: 'Channel',
        layout: '5.1',
        codec: 'WAV 16bit',
        color: 0xFF34D399,
      ),
    ]);
    container.read(mixesNotifierProvider.notifier).set(const [
      Mix(
        id: 1,
        name: 'Main',
        subMixes: [
          SubMix(
            elementSettings: [MixElementSettings(elementId: 1)],
            layouts: [
              MixLayout(soundSystem: SoundSystem.stereo),
              MixLayout(soundSystem: SoundSystem.surround5_1_4),
            ],
          ),
        ],
      ),
      Mix(id: 2, name: 'Commentary', subMixes: [SubMix()]),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: MixView())),
      ),
    );
    await tester.pump();
  }

  Finder chipOf(Finder child) =>
      find.ancestor(of: child, matching: find.byType(ConsoleChip)).first;

  // An add button's chip, under its tooltip.
  Finder addChip(String tooltip) => find.descendant(
    of: find.byTooltip(tooltip),
    matching: find.byType(ConsoleChip),
  );

  ConsoleChip chip(WidgetTester tester, Finder child) =>
      tester.widget<ConsoleChip>(chipOf(child));

  // A chip's text as drawn: its own style over the chip's default
  // style. 'Stereo' is also a headphones mode in the channel strips.
  TextStyle drawn(WidgetTester tester, String text) {
    final finder = find.descendant(
      of: chipOf(find.text(text)),
      matching: find.text(text),
    );
    return DefaultTextStyle.of(
      tester.element(finder),
    ).style.merge(tester.widget<Text>(finder).style);
  }

  for (final mode in AppThemeMode.values) {
    testWidgets('${mode.name}: the active tab is selected, the rest plain', (
      tester,
    ) async {
      await pump(tester, mode);
      final tab = find.descendant(
        of: find.byType(MixView),
        matching: find.text('Main'),
      );
      expect(chip(tester, tab).selected, isTrue);
      expect(chip(tester, find.text('Commentary')).selected, isFalse);
      expect(chip(tester, find.text('Stereo')).selected, isFalse);
      expect(chip(tester, find.text('5.1.4')).selected, isFalse);
      expect(chip(tester, find.text('5.1.4')).onTap, isNull, reason: 'a label');
      for (final add in ['Add mix presentation', 'Add layout']) {
        final c = tester.widget<ConsoleChip>(addChip(add));
        expect(c.selected, isFalse, reason: add);
        expect(c.onTap, isNotNull, reason: add);
      }

      // The labels take the chip's ink and weight.
      final selected = ConsoleChip.ink(selected: true);
      final plain = ConsoleChip.ink(selected: false);
      expect(drawn(tester, 'Main').color, selected);
      expect(drawn(tester, 'Main').fontWeight, FontWeight.w600);
      expect(drawn(tester, 'Stereo').color, plain);
      expect(drawn(tester, 'Stereo').fontWeight, FontWeight.w400);
      expect(drawn(tester, 'Commentary').color, plain);
      expect(drawn(tester, 'Commentary').fontWeight, FontWeight.w400);
    });
  }

  testWidgets('the caps labels share the section label style', (tester) async {
    await pump(tester, AppThemeMode.dark);
    for (final label in ['NAME', 'LANG', 'OUTPUT MIX GAIN', 'LAYOUTS']) {
      expect(
        tester.widget<Text>(find.text(label)).style,
        T.styleSectionLabel,
        reason: label,
      );
    }
  });

  testWidgets('the removable layout chip\'s ✕ reads on its fill', (
    tester,
  ) async {
    await pump(tester, AppThemeMode.dark);
    final remove = tester.widget<RemoveXButton>(
      find.descendant(
        of: chipOf(find.text('5.1.4')),
        matching: find.byType(RemoveXButton),
      ),
    );
    expect(remove.color, ConsoleChip.ink(selected: false));
  });

  testWidgets('a tab shows the grab cursor of drag to reorder', (tester) async {
    await pump(tester, AppThemeMode.dark);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Commentary')));
    await tester.pump();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.grab,
    );
  });

  testWidgets('a plain tab selects its mix presentation', (tester) async {
    await pump(tester, AppThemeMode.dark);
    await tester.tap(find.text('Commentary'));
    await tester.pump();
    expect(container.read(activeMixProvider), 1);
    expect(chip(tester, find.text('Commentary')).selected, isTrue);
  });

  testWidgets('the add chip adds a mix presentation and selects it', (
    tester,
  ) async {
    await pump(tester, AppThemeMode.dark);
    await tester.tap(addChip('Add mix presentation'));
    await tester.pump();
    expect(container.read(mixesNotifierProvider), hasLength(3));
    expect(container.read(activeMixProvider), 2);
  });
}
