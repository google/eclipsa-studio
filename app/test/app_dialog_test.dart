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

// Pins the app-wide dialog policy (ES-639): a tap on the barrier leaves a
// dialog open; Escape pops it with null; Escape is inert under
// DialogEscape.none; a dialog whose text field autofocuses keeps that
// focus and still closes on Escape; and no source file calls
// showDialog directly, so a new dialog cannot inherit the framework's
// barrier default.
//
// Also pins the single-instance guard (ES-682): a dialog given an id
// opens once until it closes, an id-less call still opens, and every
// exit path releases the id.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/widgets/app_dialog.dart';
import 'package:eclipsa_studio/widgets/settings_dialog.dart';

/// Pumps a button that opens [dialog] through [showAppDialog] and
/// records the result; returns the future for the dialog result.
Future<Future<String?>> _open(
  WidgetTester tester,
  Widget dialog, {
  DialogEscape escape = DialogEscape.dismiss,
}) async {
  late Future<String?> result;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              result = showAppDialog<String>(
                context: context,
                escape: escape,
                builder: (_) => dialog,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

Widget _alert() => AlertDialog(
  title: const Text('Alert'),
  actions: [
    Builder(
      builder: (ctx) => TextButton(
        onPressed: () => Navigator.pop(ctx, 'done'),
        child: const Text('Done'),
      ),
    ),
  ],
);

/// Pumps a bare app and returns a context below its [Navigator], so a
/// test can call [showAppDialog] itself rather than through a button.
Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext host;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          host = context;
          return const Scaffold();
        },
      ),
    ),
  );
  return host;
}

/// Pumps a host for [SettingsDialog], which needs a [ProviderScope].
Future<BuildContext> _pumpSettingsHost(WidgetTester tester) async {
  late BuildContext host;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            host = context;
            return const Scaffold();
          },
        ),
      ),
    ),
  );
  return host;
}

/// Opens an alert titled [title] through [showAppDialog].
Future<String?> _show(BuildContext context, {Object? id, String? title}) {
  return showAppDialog<String>(
    context: context,
    id: id,
    builder: (_) => AlertDialog(
      title: Text(title ?? 'Alert'),
      actions: [
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () => Navigator.pop(ctx, 'done'),
            child: const Text('Done'),
          ),
        ),
      ],
    ),
  );
}

void main() {
  testWidgets('a tap on the barrier leaves the dialog open', (tester) async {
    await _open(tester, _alert());
    expect(find.text('Alert'), findsOneWidget);
    // The barrier covers the whole screen outside the dialog box.
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('Alert'), findsOneWidget);
  });

  testWidgets('Escape pops the dialog with null', (tester) async {
    final result = await _open(tester, _alert());
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Alert'), findsNothing);
    expect(await result, isNull);
  });

  testWidgets('the Done button still returns its value', (tester) async {
    final result = await _open(tester, _alert());
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(await result, 'done');
  });

  testWidgets('Escape is inert under DialogEscape.none', (tester) async {
    await _open(tester, _alert(), escape: DialogEscape.none);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Alert'), findsOneWidget);
  });

  testWidgets('an autofocused text field keeps focus and Escape closes', (
    tester,
  ) async {
    final result = await _open(
      tester,
      const AlertDialog(
        title: Text('Name'),
        content: TextField(autofocus: true),
      ),
    );
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue, reason: 'autofocus must win');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Name'), findsNothing);
    expect(await result, isNull);
  });

  group('the single-instance id guard', () {
    // The ids are Types, as the app passes them: SettingsDialog,
    // IamfExportDialog and so on.
    setUp(debugResetOpenDialogIds);
    tearDown(debugResetOpenDialogIds);

    testWidgets('a second call with the same id pushes no second route', (
      tester,
    ) async {
      final context = await _pumpHost(tester);
      _show(context, id: AlertDialog, title: 'First');
      await tester.pumpAndSettle();
      final second = _show(context, id: AlertDialog, title: 'Second');
      await tester.pumpAndSettle();

      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(await second, isNull, reason: 'the dropped call still returns');
    });

    testWidgets('a call with a different id pushes', (tester) async {
      final context = await _pumpHost(tester);
      _show(context, id: AlertDialog, title: 'First');
      await tester.pumpAndSettle();
      _show(context, id: SimpleDialog, title: 'Second');
      await tester.pumpAndSettle();

      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
    });

    testWidgets('a call with no id pushes, so nesting is preserved', (
      tester,
    ) async {
      final context = await _pumpHost(tester);
      _show(context, title: 'First');
      await tester.pumpAndSettle();
      _show(context, title: 'Second');
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNWidgets(2));
    });

    testWidgets('Escape releases the id', (tester) async {
      final context = await _pumpHost(tester);
      _show(context, id: AlertDialog, title: 'First');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      _show(context, id: AlertDialog, title: 'Second');
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);
    });

    testWidgets('the Done button releases the id', (tester) async {
      final context = await _pumpHost(tester);
      _show(context, id: AlertDialog, title: 'First');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      _show(context, id: AlertDialog, title: 'Second');
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);
    });

    testWidgets('a Navigator.pop from inside the dialog releases the id', (
      tester,
    ) async {
      final context = await _pumpHost(tester);
      _show(context, id: AlertDialog, title: 'First');
      await tester.pumpAndSettle();
      Navigator.of(context).pop();
      await tester.pumpAndSettle();

      _show(context, id: AlertDialog, title: 'Second');
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);
    });

    testWidgets('a push that throws releases the id', (tester) async {
      final stale = await _pumpHost(tester);
      // Unmount the tree the context belongs to. showDialog then
      // throws on the ancestor lookup, the same failure a stale
      // context across an await produces in the app.
      await tester.pumpWidget(const SizedBox());
      expect(
        () => _show(stale, id: AlertDialog, title: 'Never'),
        throwsFlutterError,
      );

      final context = await _pumpHost(tester);
      _show(context, id: AlertDialog, title: 'Opens');
      await tester.pumpAndSettle();
      expect(
        find.text('Opens'),
        findsOneWidget,
        reason: 'a failed push must not strand the id',
      );
    });

    testWidgets('SettingsDialog.show opens one dialog, not three', (
      tester,
    ) async {
      final host = await _pumpSettingsHost(tester);
      SettingsDialog.show(host);
      await tester.pumpAndSettle();
      SettingsDialog.show(host);
      SettingsDialog.show(host);
      await tester.pumpAndSettle();

      expect(find.byType(SettingsDialog), findsOneWidget);
    });

    testWidgets('a dropped Settings request does not move the tab', (
      tester,
    ) async {
      final host = await _pumpSettingsHost(tester);
      SettingsDialog.show(host);
      await tester.pumpAndSettle();
      // What the status bar's audio-device label asks for. The dialog
      // is already up, so the request is dropped.
      SettingsDialog.show(host, initialTab: SettingsDialog.tabAudio);
      await tester.pumpAndSettle();
      expect(find.text('Output device'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      SettingsDialog.show(host);
      await tester.pumpAndSettle();
      expect(
        find.text('Output device'),
        findsNothing,
        reason: 'the dropped request must not select the Audio tab',
      );
    });
  });

  test('no source file calls showDialog directly', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('widgets/app_dialog.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (RegExp(r'\bshowDialog\s*[<(]').hasMatch(line)) {
          offenders.add('${entity.path}:${i + 1}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'route every dialog through showAppDialog (ES-639)',
    );
  });
}
