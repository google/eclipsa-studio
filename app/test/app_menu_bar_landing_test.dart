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

import 'dart:io';

import 'package:eclipsa_studio/widgets/app_menu_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The landing screen used to return only the app menu, which hid Help.
// Help is meaningful on landing (Release Notes, Keyboard Shortcuts,
// Export Log, and the debug theme tools) even though File and View are
// not.
//
// macOS-only: the PlatformMenuBar path is what this covers. Windows uses
// a Material MenuBar that already rendered Help in every mode.
void main() {
  List<String> topLevelMenuLabels(WidgetTester tester) {
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    return [
      for (final m in bar.menus)
        if (m is PlatformMenu) m.label,
    ];
  }

  testWidgets('landing screen still offers the Help menu', (tester) async {
    // The widget picks its menu path off dart:io Platform, but
    // PlatformProvidedMenuItem validates against defaultTargetPlatform,
    // which is android under flutter_test. Without this the macOS branch
    // runs and then throws building an android quit item.
    // Reset inside the body, not via addTearDown: the framework asserts
    // foundation debug vars are unset when the body returns, which runs
    // before tear-downs do.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: AppMenuBar(child: Scaffold(body: SizedBox.expand())),
          ),
        ),
      );
      await tester.pump();

      // WorkspaceMode defaults to none, i.e. the landing screen.
      final labels = topLevelMenuLabels(tester);
      expect(
        labels,
        contains('Help'),
        reason: 'Help applies on the landing screen',
      );
      // File stays hidden: there is no session to save. View is there
      // for the theme commands alone, which apply on the landing screen.
      expect(labels, isNot(contains('File')));
      expect(labels, contains('View'));
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      final view = bar.menus.whereType<PlatformMenu>().firstWhere(
        (m) => m.label == 'View',
      );
      final viewLabels = [
        for (final g in view.menus.whereType<PlatformMenuItemGroup>())
          for (final m in g.members) m.label,
      ];
      expect(viewLabels, contains('Next Theme'));
      expect(viewLabels, isNot(contains('Loudness Report...')));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }, skip: !Platform.isMacOS);
}
