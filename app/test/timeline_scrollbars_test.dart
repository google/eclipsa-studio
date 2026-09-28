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
import 'package:eclipsa_studio/views/elements_view.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The timeline scrollbars (ES-761): the vertical one follows the track
/// list's extent as well as its scroll offset, and both thumbs stay
/// inside their tracks at either end.
void main() {
  AudioElement elem(int id) => AudioElement(
    id: id,
    name: 'e$id',
    type: 'Channel',
    layout: 'Stereo',
    codec: 'Opus',
    color: 0xFF34D399,
  );

  final thumb = find.byKey(const ValueKey('timeline_vertical_thumb'));

  Future<ProviderContainer> pumpTimeline(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ElementsView())),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ElementsView)),
    );
    container.read(workspaceModeProvider.notifier).enterCreator();
    return container;
  }

  testWidgets('the thumb appears when a vertical zoom makes the tracks '
      'overflow', (tester) async {
    final container = await pumpTimeline(tester);
    container.read(elementsProvider.notifier).set([elem(1), elem(2)]);
    await tester.pumpAndSettle();
    expect(thumb, findsNothing, reason: 'two tracks fit at scale 1');

    container.read(timelineViewportProvider.notifier).setTrackScale(3);
    await tester.pumpAndSettle();
    expect(thumb, findsOneWidget);
  });

  testWidgets('the thumb appears when added tracks overflow', (tester) async {
    final container = await pumpTimeline(tester);
    container.read(elementsProvider.notifier).set([elem(1)]);
    await tester.pumpAndSettle();
    expect(thumb, findsNothing);

    container.read(elementsProvider.notifier).set([
      for (var i = 1; i <= 12; i++) elem(i),
    ]);
    await tester.pumpAndSettle();
    expect(thumb, findsOneWidget);
  });

  /// The thumb's rect and the track's (the [Stack] that holds it).
  (Rect, Rect) thumbInTrack(WidgetTester tester, Finder thumb) => (
    tester.getRect(thumb),
    tester.getRect(
      find.ancestor(of: thumb, matching: find.byType(Stack)).first,
    ),
  );

  testWidgets('the vertical thumb stays inside its track at both ends', (
    tester,
  ) async {
    final container = await pumpTimeline(tester);
    container.read(elementsProvider.notifier).set([
      for (var i = 1; i <= 12; i++) elem(i),
    ]);
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ReorderableListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    for (final end in [0.0, scrollable.position.maxScrollExtent]) {
      scrollable.position.jumpTo(end);
      await tester.pumpAndSettle();
      final (t, track) = thumbInTrack(tester, thumb);
      expect(t.top, greaterThanOrEqualTo(track.top + 1), reason: 'at $end');
      expect(t.bottom, lessThanOrEqualTo(track.bottom - 1), reason: 'at $end');
      expect(t.left, track.left + 1);
      expect(t.right, track.right - 1);
    }
  });

  testWidgets('the horizontal thumb stays inside its track at both ends '
      'and at the highest zoom', (tester) async {
    final container = await pumpTimeline(tester);
    final hThumb = find.byKey(const ValueKey('timeline_horizontal_thumb'));
    final vp = container.read(timelineViewportProvider.notifier);
    for (final zoom in [2.0, 500.0]) {
      for (final scroll in [0.0, 1.0]) {
        vp
          ..setZoom(zoom)
          ..setScroll(scroll);
        await tester.pumpAndSettle();
        final (t, track) = thumbInTrack(tester, hThumb);
        final at = 'zoom $zoom, scroll $scroll';
        if (scroll == 0) expect(t.left, closeTo(track.left + 1, 0.01));
        if (scroll == 1) expect(t.right, closeTo(track.right - 1, 0.01));
        expect(t.left, greaterThanOrEqualTo(track.left + 1), reason: at);
        expect(t.right, lessThanOrEqualTo(track.right - 1), reason: at);
        expect(t.top, track.top + 1, reason: at);
        expect(t.bottom, track.bottom - 1, reason: at);
      }
    }
  });
}
