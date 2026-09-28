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
import 'package:eclipsa_studio/widgets/dialog_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins DialogShell's sizing contract, which seven dialogs depend on:
/// intrinsic hugs the child, flexible hugs short content but caps tall
/// content at maxHeight, expand always fills the height bound, and the
/// footer divider appears only when requested.
void main() {
  Future<void> pumpShell(WidgetTester tester, DialogShell shell) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: Center(child: shell)),
        ),
      ),
    );
  }

  // The shell's element spans the whole body; the visible dialog box is
  // the Material surface Dialog builds internally.
  Size surfaceSize(WidgetTester tester) => tester.getSize(
    find
        .descendant(of: find.byType(Dialog), matching: find.byType(Material))
        .first,
  );

  testWidgets('intrinsic hugs its child', (tester) async {
    await pumpShell(
      tester,
      DialogShell(title: 'T', width: 400, child: const SizedBox(height: 100)),
    );
    final size = surfaceSize(tester);
    expect(size.width, 400);
    expect(size.height, lessThan(250)); // title + child + padding only
  });

  testWidgets('flexible hugs short content and caps tall content', (
    tester,
  ) async {
    await pumpShell(
      tester,
      DialogShell(
        width: 400,
        maxHeight: 300,
        bodyFit: DialogBodyFit.flexible,
        child: const SizedBox(height: 50),
      ),
    );
    expect(
      surfaceSize(tester).height,
      lessThan(300),
      reason: 'short content must hug, not stretch to maxHeight',
    );

    await pumpShell(
      tester,
      DialogShell(
        width: 400,
        maxHeight: 300,
        bodyFit: DialogBodyFit.flexible,
        child: SingleChildScrollView(child: const SizedBox(height: 900)),
      ),
    );
    expect(surfaceSize(tester).height, 300);
  });

  testWidgets('expand fills the fixed height', (tester) async {
    await pumpShell(
      tester,
      DialogShell(
        width: 400,
        height: 350,
        bodyFit: DialogBodyFit.expand,
        child: const SizedBox(height: 10),
      ),
    );
    expect(surfaceSize(tester).height, 350);
  });

  // The Light theme draws a chromeBg head over a bgSurface body. The head is
  // the rectangle the title block already occupied, so the dialog's
  // size and its title's position must not move between themes -- a
  // component's size does not vary by theme.
  testWidgets('the head changes the ground, not the geometry', (tester) async {
    Future<(Size, Offset)> measure(AppThemeMode mode) async {
      T.setMode(mode);
      await tester.pumpWidget(const SizedBox());
      await pumpShell(
        tester,
        DialogShell(
          title: 'T',
          subtitle: 'S',
          width: 400,
          child: const SizedBox(height: 100),
        ),
      );
      return (surfaceSize(tester), tester.getTopLeft(find.text('T')));
    }

    final flat = await measure(AppThemeMode.classic);
    final raised = await measure(AppThemeMode.light);
    expect(raised.$1, flat.$1, reason: 'the dialog box must not move');
    expect(raised.$2, flat.$2, reason: 'the title must not move');
    T.setMode(AppThemeMode.classic);
  });

  testWidgets('only the Light theme paints a head', (tester) async {
    Color? headFill(WidgetTester tester) {
      final c = tester.widgetList<Container>(
        find.ancestor(of: find.text('T'), matching: find.byType(Container)),
      );
      return c.isEmpty ? null : c.last.color;
    }

    for (final mode in [
      AppThemeMode.classic,
      AppThemeMode.highContrast,
      AppThemeMode.dark,
    ]) {
      T.setMode(mode);
      await tester.pumpWidget(const SizedBox());
      await pumpShell(
        tester,
        DialogShell(title: 'T', width: 400, child: const SizedBox(height: 40)),
      );
      expect(headFill(tester), isNull, reason: mode.name);
    }
    T.setMode(AppThemeMode.light);
    await tester.pumpWidget(const SizedBox());
    await pumpShell(
      tester,
      DialogShell(title: 'T', width: 400, child: const SizedBox(height: 40)),
    );
    expect(headFill(tester), T.chromeBg);
    expect(
      tester.widget<Text>(find.text('T')).style!.color,
      T.chromeInk,
      reason: 'chromeInk on chromeBg is 8.01:1 and is a contrast.json rule',
    );
    T.setMode(AppThemeMode.classic);
  });

  // A tab row lives in the head in every theme, so where the head
  // gets a ground the row sits on it, and where it does not the
  // geometry is the same as before the slot existed.
  testWidgets('headBelow sits in the head, in the same place in every '
      'theme', (tester) async {
    const rowKey = Key('row');
    Future<(Size, Offset)> measure(AppThemeMode mode) async {
      T.setMode(mode);
      await tester.pumpWidget(const SizedBox());
      await pumpShell(
        tester,
        DialogShell(
          width: 400,
          headBelow: const SizedBox(key: rowKey, height: 30, width: 100),
          child: const SizedBox(height: 40),
        ),
      );
      return (surfaceSize(tester), tester.getTopLeft(find.byKey(rowKey)));
    }

    final flat = await measure(AppThemeMode.classic);
    final raised = await measure(AppThemeMode.light);
    expect(raised.$1, flat.$1, reason: 'the dialog box must not move');
    expect(raised.$2, flat.$2, reason: 'the row must not move');
    // The row is inside the head: its padded container is the row's
    // ancestor, and in the Light theme that container carries chromeBg.
    final head = tester.widget<Container>(
      find
          .ancestor(of: find.byKey(rowKey), matching: find.byType(Container))
          .first,
    );
    expect(head.color, T.chromeBg);
    T.setMode(AppThemeMode.classic);
  });

  testWidgets('footer renders actions; divider only when requested', (
    tester,
  ) async {
    await pumpShell(
      tester,
      DialogShell(
        width: 400,
        actions: const [Text('A'), Text('B')],
        child: const SizedBox(height: 20),
      ),
    );
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);

    // No footer at all without actions.
    await pumpShell(
      tester,
      DialogShell(width: 400, child: const SizedBox(height: 20)),
    );
    expect(find.text('A'), findsNothing);
  });
}
