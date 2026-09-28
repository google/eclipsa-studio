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
import 'package:eclipsa_studio/widgets/resize_handle.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The handle draws nothing at rest and lights the border it sits on
// while hovered (after a delay) or dragged (ES-748). The callers lay it
// with its trailing edge on the border, so the line is pinned to that
// edge here.

/// Mounts the handle the way the app does: a column handle pinned top
/// to bottom with Positioned, a row handle pinned left to right. The
/// thickness across the drag axis comes from the handle itself.
Future<void> pumpHandle(
  WidgetTester tester,
  Axis axis, {
  ValueChanged<double>? onDragUpdate,
  double borderOffset = ResizeHandle.extent,
}) async {
  final handle = ResizeHandle(
    axis: axis,
    onDragUpdate: onDragUpdate ?? (_) {},
    borderOffset: borderOffset,
  );
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 120,
            child: Stack(
              children: [
                if (axis == Axis.horizontal)
                  Positioned(left: 80, top: 0, bottom: 0, child: handle)
                else
                  Positioned(left: 0, right: 0, top: 60, child: handle),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

final _line = find.byKey(const ValueKey('resize-handle-line'));

Future<TestGesture> mouseOver(WidgetTester tester) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await g.moveTo(tester.getCenter(find.byType(ResizeHandle)));
  await tester.pump();
  return g;
}

MouseCursor? activeCursor() =>
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

void main() {
  tearDown(() => T.setMode(T.defaultMode));

  group('at rest', () {
    for (final mode in AppThemeMode.values) {
      testWidgets('${mode.name}: an 8 px hit area that draws nothing', (
        tester,
      ) async {
        T.setMode(mode);
        await pumpHandle(tester, Axis.horizontal);
        expect(tester.getSize(find.byType(ResizeHandle)).width, 8);
        expect(_line, findsNothing);

        await pumpHandle(tester, Axis.vertical);
        expect(tester.getSize(find.byType(ResizeHandle)).height, 8);
        expect(_line, findsNothing);
      });
    }
  });

  group('hover', () {
    testWidgets('takes the resize cursor at once', (tester) async {
      await pumpHandle(tester, Axis.horizontal);
      await mouseOver(tester);
      expect(activeCursor(), SystemMouseCursors.resizeColumn);

      await pumpHandle(tester, Axis.vertical);
      await tester.pump();
      expect(activeCursor(), SystemMouseCursors.resizeRow);
    });

    testWidgets('lights the border after the hover delay', (tester) async {
      await pumpHandle(tester, Axis.horizontal);
      await mouseOver(tester);
      await tester.pump(
        ResizeHandle.hoverDelay - const Duration(milliseconds: 1),
      );
      expect(_line, findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(_line, findsOneWidget);
    });

    testWidgets('a pointer passing over does not light it', (tester) async {
      await pumpHandle(tester, Axis.horizontal);
      final g = await mouseOver(tester);
      await tester.pump(const Duration(milliseconds: 100));
      await g.moveTo(Offset.zero);
      await tester.pump(ResizeHandle.hoverDelay);
      expect(_line, findsNothing);
    });

    testWidgets('goes out when the pointer leaves', (tester) async {
      await pumpHandle(tester, Axis.horizontal);
      final g = await mouseOver(tester);
      await tester.pump(ResizeHandle.hoverDelay);
      expect(_line, findsOneWidget);
      await g.moveTo(Offset.zero);
      await tester.pump();
      expect(_line, findsNothing);
    });
  });

  group('the line', () {
    for (final mode in AppThemeMode.values) {
      testWidgets('${mode.name}: 2 px of accent on the column border', (
        tester,
      ) async {
        T.setMode(mode);
        await pumpHandle(tester, Axis.horizontal);
        await mouseOver(tester);
        await tester.pump(ResizeHandle.hoverDelay);

        final handle = tester.getRect(find.byType(ResizeHandle));
        final line = tester.getRect(_line);
        expect(line.width, 2);
        expect(line.height, handle.height);
        expect(line.right, handle.right, reason: 'flush with the border');
        expect(tester.widget<Container>(_line).color, T.purple);
      });
    }

    testWidgets('follows borderOffset when the border is inside the box', (
      tester,
    ) async {
      // The elements view passes 0 when the channel-label gutter is
      // empty: the box starts on the border and reaches past it.
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      addTearDown(g.removePointer);
      for (final (offset, left) in [(0.0, 0.0), (1.0, 0.0), (5.0, 3.0)]) {
        await pumpHandle(tester, Axis.horizontal, borderOffset: offset);
        await g.moveTo(tester.getCenter(find.byType(ResizeHandle)));
        await tester.pump(ResizeHandle.hoverDelay);
        final handle = tester.getRect(find.byType(ResizeHandle));
        final line = tester.getRect(_line);
        expect(line.left - handle.left, left, reason: 'offset $offset');
        expect(line.width, 2, reason: 'offset $offset');
        await g.moveTo(Offset.zero);
        await tester.pump();
      }
    });

    testWidgets('lies along the bottom edge of a row handle', (tester) async {
      await pumpHandle(tester, Axis.vertical);
      await mouseOver(tester);
      await tester.pump(ResizeHandle.hoverDelay);

      final handle = tester.getRect(find.byType(ResizeHandle));
      final line = tester.getRect(_line);
      expect(line.height, 2);
      expect(line.width, handle.width);
      expect(line.bottom, handle.bottom);
    });
  });

  group('drag', () {
    testWidgets('lights at once, stays lit off the handle, reports the delta', (
      tester,
    ) async {
      var total = 0.0;
      await pumpHandle(
        tester,
        Axis.horizontal,
        onDragUpdate: (dx) => total += dx,
      );
      // A touch drag has no hover, so the only thing that can light the
      // line here is the drag itself.
      final drag = await tester.startGesture(
        tester.getCenter(find.byType(ResizeHandle)),
      );
      await drag.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(_line, findsOneWidget);

      await drag.moveBy(const Offset(-5, 0));
      await tester.pump();
      expect(_line, findsOneWidget, reason: 'pointer is 35 px off the handle');

      await drag.up();
      await tester.pump();
      expect(_line, findsNothing);
      expect(total, 35);
    });

    testWidgets('stays lit when a drag ends on the handle', (tester) async {
      await pumpHandle(tester, Axis.horizontal);
      // A mouse drag that starts before the hover delay has run and
      // ends back on the handle.
      final g = await mouseOver(tester);
      await g.down(tester.getCenter(find.byType(ResizeHandle)));
      await g.moveBy(const Offset(20, 0));
      await tester.pump();
      await g.moveBy(const Offset(-20, 0));
      await g.up();
      await tester.pump();
      expect(_line, findsOneWidget);
      await tester.pump(ResizeHandle.hoverDelay);
      expect(_line, findsOneWidget);
    });

    testWidgets('a row handle reports vertical deltas', (tester) async {
      var total = 0.0;
      await pumpHandle(
        tester,
        Axis.vertical,
        onDragUpdate: (dy) => total += dy,
      );
      final drag = await tester.startGesture(
        tester.getCenter(find.byType(ResizeHandle)),
      );
      await drag.moveBy(const Offset(0, 20));
      await drag.moveBy(const Offset(0, -5));
      await drag.up();
      expect(total, 15);
    });
  });
}
