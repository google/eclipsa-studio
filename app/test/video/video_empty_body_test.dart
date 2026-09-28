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
import 'package:eclipsa_studio/video/video_strip.dart';
import 'package:eclipsa_studio/widgets/drop_zone.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _label = 'Drop video or image, or click to browse';
const _dragLabel = 'Drop video or image';
const _hint = 'MP4 · MOV · MKV · AVI · WebM · PNG · JPG · WebP · GIF';

/// The empty video panel draws one placeholder in every theme: a
/// 320 x 160 drop-zone area with the image glyph, the label and the
/// format line, shrinking under the header in a short strip (ES-780).
void main() {
  tearDown(() {
    T.setMode(T.defaultMode);
    T.setFontMode(FontSizeMode.medium);
  });

  /// The body inside a strip-sized box under a Scaffold, as in the app.
  Future<void> pump(
    WidgetTester tester, {
    double width = 600,
    double height = 224,
    bool dragOver = false,
    VoidCallback? onTap,
    String? hint = _hint,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: height,
            child: VideoEmptyBody(
              dragOver: dragOver,
              onTap: onTap,
              primaryLabel: dragOver ? _dragLabel : _label,
              secondaryLabel: hint,
            ),
          ),
        ),
      ),
    ),
  );

  for (final mode in AppThemeMode.values) {
    for (final font in FontSizeMode.values) {
      testWidgets('${mode.name}, ${font.name} font: glyph, label, format '
          'line, one size', (tester) async {
        T.setMode(mode);
        T.setFontMode(font);
        await pump(tester);
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.image_outlined), findsOneWidget);
        expect(find.text(_label), findsOneWidget);
        expect(find.text(_hint), findsOneWidget);
        expect(
          tester.getSize(find.byType(DropZone)),
          const Size(VideoEmptyBody.width, VideoEmptyBody.height),
        );
        // Centred in the band under the 24 px header.
        final area = tester.getRect(find.byType(DropZone));
        expect(area.top, greaterThanOrEqualTo(VideoStrip.headerHeight));
        expect(area.center.dx, 300);
      });
    }
  }

  BoxDecoration box(WidgetTester tester) =>
      tester
              .widget<AnimatedContainer>(find.byType(AnimatedContainer))
              .decoration!
          as BoxDecoration;

  for (final mode in AppThemeMode.values) {
    testWidgets('${mode.name}: no frame, the drag-over tint only', (
      tester,
    ) async {
      T.setMode(mode);
      await pump(tester);
      expect(box(tester).color!.a, 0);
      expect(box(tester).border, isNull);
      await pump(tester, dragOver: true);
      await tester.pumpAndSettle();
      expect(box(tester).color, T.purpleDim);
      expect(box(tester).border, isNull);
    });
  }

  testWidgets('a drag over the body switches the label and tints the zone', (
    tester,
  ) async {
    await pump(tester, dragOver: true);
    expect(find.text(_dragLabel), findsOneWidget);
    expect(find.text(_label), findsNothing);
    expect(tester.widget<DropZone>(find.byType(DropZone)).isDragOver, isTrue);
  });

  testWidgets('a tap on the area calls onTap', (tester) async {
    var taps = 0;
    await pump(tester, onTap: () => taps++);
    await tester.tap(find.byType(DropZone));
    expect(taps, 1);
  });

  testWidgets('a tap beside the area calls onTap too', (tester) async {
    var taps = 0;
    await pump(tester, onTap: () => taps++);
    await tester.tapAt(const Offset(20, 200));
    expect(taps, 1);
  });

  testWidgets('a short strip shrinks the area and drops the format line', (
    tester,
  ) async {
    // The pane's minimum is 100 px: 24 px of header and 8 px margins
    // leave 60 px for the area, under hintHeight.
    await pump(tester, height: 100);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(DropZone)),
      const Size(VideoEmptyBody.width, 60),
    );
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.text(_label), findsOneWidget);
    expect(find.text(_hint), findsNothing);
  });

  testWidgets('a narrow strip shrinks the area to its width', (tester) async {
    await pump(tester, width: 200);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(DropZone)).width, 200 - 16);
  });
}
