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

import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/eclipsa_studio_wordmark.dart';
import 'package:eclipsa_studio/workspace/landing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the landing screen's card alignment: the
/// two cards' Recent blocks must start at the same vertical position
/// even when the recent lists differ in length, at every font-size
/// mode. The card is a head over a Recent block with a shared slot
/// count, and the head absorbs the slack the IntrinsicHeight row hands
/// it, so the boundary lands at the same y in both cards. The test
/// guards that construction, in every theme: the hairline between the
/// head and the list is one line across the pair, so a drift shows.
class _FakeSessions extends RecentSessionsNotifier {
  _FakeSessions(this.paths);
  final List<String> paths;

  @override
  List<String> build() => paths;
}

class _FakeQcFiles extends RecentQcFilesNotifier {
  _FakeQcFiles(this.paths);
  final List<String> paths;

  @override
  List<String> build() => paths;
}

void main() {
  Future<void> pumpLanding(
    WidgetTester tester, {
    required List<String> sessions,
    required List<String> qcFiles,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentSessionsProvider.overrideWith(() => _FakeSessions(sessions)),
          recentQcFilesProvider.overrideWith(() => _FakeQcFiles(qcFiles)),
        ],
        child: const MaterialApp(home: LandingScreen()),
      ),
    );
  }

  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
      ..physicalSize = const Size(1400, 1000)
      ..devicePixelRatio = 1.0;
  });

  tearDown(() {
    T.setFontMode(FontSizeMode.medium);
    T.setMode(AppThemeMode.classic);
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
  });

  // The eyebrow renders 'Recent' upper-cased.
  Finder recentHeaders() => find.text('RECENT');

  for (final mode in FontSizeMode.values) {
    testWidgets('Recent blocks align with asymmetric lists at ${mode.label}', (
      tester,
    ) async {
      T.setFontMode(mode);
      await pumpLanding(
        tester,
        sessions: ['/a/one.esp', '/a/two.esp', '/a/three.esp'],
        qcFiles: ['/b/only.iamf'],
      );
      expect(recentHeaders(), findsNWidgets(2));
      final first = tester.getTopLeft(recentHeaders().first).dy;
      final last = tester.getTopLeft(recentHeaders().last).dy;
      expect(
        first,
        equals(last),
        reason:
            'Recent headers must sit at the same height in both '
            'cards at ${mode.label}',
      );
    });
  }

  for (final mode in AppThemeMode.values) {
    testWidgets('Recent blocks align in ${mode.name}', (tester) async {
      T.setMode(mode);
      await pumpLanding(
        tester,
        sessions: ['/a/one.esp', '/a/two.esp', '/a/three.esp'],
        qcFiles: ['/b/only.iamf'],
      );
      expect(recentHeaders(), findsNWidgets(2));
      expect(
        tester.getTopLeft(recentHeaders().first).dy,
        equals(tester.getTopLeft(recentHeaders().last).dy),
        reason:
            'the section boundary must land at the same y in both '
            'cards in ${mode.name}; the hairline between head and list '
            'is one line across the pair, so a drift here is visible',
      );
    });
  }

  // A short window at the Large font mode used to squeeze the card head
  // inside the Light card's ClipRRect, which swallowed the overflow:
  // the last entry button and the drop hint disappeared with no
  // indicator and no way to scroll to them.
  for (final mode in [AppThemeMode.classic, AppThemeMode.light]) {
    testWidgets('every entry button survives a short window in ${mode.name}', (
      tester,
    ) async {
      T.setMode(mode);
      T.setFontMode(FontSizeMode.large);
      TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        ..physicalSize = const Size(900, 600)
        ..devicePixelRatio = 1.0;
      await pumpLanding(
        tester,
        sessions: ['/a/one.esp'],
        qcFiles: ['/b/only.iamf'],
      );
      expect(tester.takeException(), isNull, reason: 'must not overflow');

      // find.text matches a widget laid out entirely off-screen, so
      // presence proves nothing. The content has to be reachable: the
      // view must actually scroll, and the last button must sit inside
      // the viewport once it has.
      final scrollable = find.byType(Scrollable).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason: 'the content overflows 900x600 at Large, so it must scroll',
      );

      const last = 'Open Existing Session…';
      await tester.scrollUntilVisible(find.text(last), 200);
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text(last));
      expect(
        rect.bottom <= 600 && rect.top >= 0,
        isTrue,
        reason:
            '$last must be reachable in ${mode.name}, not just built '
            '-- it was off-screen inside the card clip before ES-698',
      );
    });
  }

  // The screen fills the window when the content is short: a bare
  // SingleChildScrollView lets the Center shrink-wrap, which pins the
  // column to the top, so the screen ends where the content does
  // rather than at the window edge.
  testWidgets('short content stays centred and the ground fills', (
    tester,
  ) async {
    T.setMode(AppThemeMode.light);
    await pumpLanding(tester, sessions: ['/a/one.esp'], qcFiles: ['/b/y.iamf']);

    final scrollView = tester.getRect(find.byType(SingleChildScrollView));
    expect(
      scrollView.height,
      equals(1000.0),
      reason:
          'the scroll view must fill the 1400x1000 view, so the '
          'gradient painted around it reaches the bottom edge',
    );

    final wordmark = tester.getRect(find.byType(EclipsaStudioWordmark));
    expect(
      wordmark.top,
      greaterThan(100),
      reason: 'the column must be centred, not pinned to the top',
    );
  });

  testWidgets('Recent blocks align when both lists are empty', (tester) async {
    // Exercises the max(1, ...) clamp: one slot, two aligned empty states.
    await pumpLanding(tester, sessions: const [], qcFiles: const []);
    expect(recentHeaders(), findsNWidgets(2));
    expect(
      tester.getTopLeft(recentHeaders().first).dy,
      equals(tester.getTopLeft(recentHeaders().last).dy),
    );
    expect(find.text('No recent sessions'), findsOneWidget);
    expect(find.text('No recent files'), findsOneWidget);
  });

  testWidgets('Recent blocks align when one list is empty', (tester) async {
    await pumpLanding(
      tester,
      sessions: const [],
      qcFiles: ['/b/one.iamf', '/b/two.iamf'],
    );
    final first = tester.getTopLeft(recentHeaders().first).dy;
    final last = tester.getTopLeft(recentHeaders().last).dy;
    expect(first, equals(last));
    // The empty card shows its empty-state hint in the first slot.
    expect(find.text('No recent sessions'), findsOneWidget);
  });

  testWidgets('Recent blocks align when a list overflows the 5-slot cap', (
    tester,
  ) async {
    await pumpLanding(
      tester,
      sessions: ['/a/one.esp'],
      qcFiles: [for (var i = 0; i < 7; i++) '/b/file$i.iamf'],
    );
    // 7 recents clamp to 5 rendered slots per card.
    expect(find.text('file4.iamf'), findsOneWidget);
    expect(find.text('file5.iamf'), findsNothing);
    final first = tester.getTopLeft(recentHeaders().first).dy;
    final last = tester.getTopLeft(recentHeaders().last).dy;
    expect(first, equals(last));
  });
}
