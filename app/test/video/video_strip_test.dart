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
import 'package:eclipsa_studio/video/video_panel.dart';
import 'package:eclipsa_studio/video/video_provider.dart';
import 'package:eclipsa_studio/video/video_strip.dart';
import 'package:eclipsa_studio/widgets/drop_zone.dart';
import 'package:eclipsa_studio/widgets/resize_handle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => T.setMode(AppThemeMode.classic));
  tearDown(() => T.setMode(T.defaultMode));

  VideoStripAction action(IconData icon, {double gapBefore = 0}) =>
      VideoStripAction(
        icon: icon,
        tooltip: icon.toString(),
        onTap: () {},
        gapBefore: gapBefore,
      );

  testWidgets('the flat header keeps the panel\'s uneven action spacing', (
    tester,
  ) async {
    // Before VideoStrip, VideoPanel's header put 2 px between pop out
    // and remove and 4 px before collapse; a uniform loop would not.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: VideoStrip(
              height: 100,
              fileName: 'a.mp4',
              hasMedia: true,
              isStillImage: false,
              visible: true,
              actions: [
                action(Icons.open_in_new),
                action(Icons.close, gapBefore: 2),
                action(Icons.expand_less, gapBefore: 4),
              ],
              body: const SizedBox(),
            ),
          ),
        ),
      ),
    );
    double left(IconData icon) => tester.getTopLeft(find.byIcon(icon)).dx;
    // Each action is a 15 px glyph in 4 px of padding: 23 px wide.
    expect(left(Icons.close) - left(Icons.open_in_new), 23 + 2);
    expect(left(Icons.expand_less) - left(Icons.close), 23 + 4);
  });

  /// The flat strip on its own, 600 px wide, with [body] under the
  /// header and one collapse action unless [stripActions] says
  /// otherwise.
  Widget flatStrip({
    required double height,
    required bool visible,
    Widget body = const SizedBox(),
    List<VideoStripAction>? stripActions,
  }) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 600,
        child: VideoStrip(
          height: height,
          fileName: 'a.mp4',
          hasMedia: true,
          isStillImage: false,
          visible: visible,
          actions: stripActions ?? [action(Icons.expand_less)],
          body: body,
        ),
      ),
    ),
  );

  /// The header's own box: the only [Container] over the glyph.
  final headerBox = find.ancestor(
    of: find.byIcon(Icons.videocam_outlined),
    matching: find.byType(Container),
  );

  testWidgets('the flat strip lays its header over the body', (tester) async {
    // The header used to be a row of its own above the body, so the
    // strip ran 24 px taller than the picture. It now sits over the
    // body as the concept headers do, and the body has the whole
    // strip (ES-683).
    const bodyKey = ValueKey('body');
    await tester.pumpWidget(
      flatStrip(height: 224, visible: true, body: const SizedBox(key: bodyKey)),
    );
    final strip = tester.getRect(find.byType(VideoStrip));
    expect(strip.height, 224);
    expect(tester.getRect(find.byKey(bodyKey)), strip);
    // The header is drawn inside that box, at its top.
    expect(tester.getRect(headerBox).top, strip.top);
    expect(tester.getSize(headerBox).height, 24);
  });

  testWidgets('the overlaid flat header drops its fill and its hairline', (
    tester,
  ) async {
    // Over the picture the header paints neither the bgSurface fill
    // nor the 0.5 px hairline; its metrics and ink are unchanged.
    await tester.pumpWidget(flatStrip(height: 224, visible: true));
    expect(tester.widget<Container>(headerBox).decoration, isNull);
    final name = tester.widget<Text>(find.text('a.mp4'));
    expect(name.style!.fontSize, T.fontCaption);
    expect(name.style!.color, T.textSecondary);
    final glyph = tester.widget<Icon>(find.byIcon(Icons.videocam_outlined));
    expect(glyph.size, T.iconXs);
  });

  testWidgets('the collapsed flat strip is a 24 px bar with its fill', (
    tester,
  ) async {
    // Collapsed the header is the whole strip, so it keeps the bar it
    // has always drawn.
    await tester.pumpWidget(flatStrip(height: 224, visible: false));
    expect(tester.getSize(find.byType(VideoStrip)).height, 24);
    final box =
        tester.widget<Container>(headerBox).decoration! as BoxDecoration;
    expect(box.color, T.bgSurface);
    expect(box.border!.bottom.width, 0.5);
    expect(box.border!.bottom.color, T.border);
  });

  /// The video pane with the panel's own state and resize handle,
  /// 600 px wide on a surface tall enough for the 600 px clamp.
  /// [initialHeight] omitted takes the panel's default.
  Future<void> pumpPane(WidgetTester tester, {double? initialHeight}) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [videoProvider.overrideWith(_StubVideoNotifier.new)],
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                child: initialHeight == null
                    ? const VideoPanel()
                    : VideoPanel(initialHeight: initialHeight),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double stripHeight(WidgetTester tester) =>
      tester.getSize(find.byType(VideoStrip)).height;

  testWidgets('the flat pane keeps the height its header row used to take', (
    tester,
  ) async {
    // The header costs the pane no row now, so the flat default is the
    // 200 px of picture it drew plus the 24 px the header took: the
    // pane is the same 224 px tall and the picture has the difference.
    await pumpPane(tester);
    expect(stripHeight(tester), 24 + 200);
    // The strip's height is the panel's initialHeight, not a number
    // the flat branch carries: another initial height draws that one.
    await pumpPane(tester, initialHeight: 300);
    expect(stripHeight(tester), 300);
  });

  testWidgets('the resize handle clamps the flat strip to 100 and 600', (
    tester,
  ) async {
    // _minHeight (100) and _maxHeight (600) clamp the strip now that
    // the header lies over it, where in the flat layout they clamped
    // the body under a header row: the pane's own range is 100 to 600
    // px where it was 124 to 624.
    await pumpPane(tester);
    await tester.drag(find.byType(ResizeHandle), const Offset(0, -400));
    await tester.pump();
    expect(stripHeight(tester), 100);
    await tester.drag(find.byType(ResizeHandle), const Offset(0, 1000));
    await tester.pump();
    expect(stripHeight(tester), 600);
  });

  testWidgets('the overlaid header clears the empty state and takes the tap', (
    tester,
  ) async {
    // With no media the body is the drop zone, whose label is
    // centred and whose tap opens the picker. At the pane's default
    // height the label clears the header's 24 px band, and the header
    // is over the body, so its actions get the pointer first.
    var picked = 0;
    var collapsed = 0;
    await tester.pumpWidget(
      flatStrip(
        height: 224,
        visible: true,
        stripActions: [
          VideoStripAction(
            icon: Icons.expand_less,
            tooltip: 'Collapse video',
            onTap: () => collapsed++,
          ),
        ],
        body: VideoEmptyBody(
          dragOver: false,
          onTap: () => picked++,
          primaryLabel: 'Drop video or image, or click to browse',
          secondaryLabel: 'MP4',
        ),
      ),
    );
    final strip = tester.getRect(find.byType(VideoStrip));
    final label = tester.getRect(
      find.text('Drop video or image, or click to browse'),
    );
    expect(label.top - strip.top, greaterThan(24));
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pump();
    expect(collapsed, 1);
    expect(picked, 0);
  });

  testWidgets('the empty body follows a theme switch without a remount', (
    tester,
  ) async {
    // The area reads T.* and is not const-constructed, so a rebuild
    // after setMode must recolour the glyph in place. Its size is the
    // same in every theme, and it draws no frame (ES-780).
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SizedBox(
                width: 800,
                height: 260,
                child: VideoEmptyBody(
                  dragOver: false,
                  onTap: null,
                  primaryLabel: 'Drop',
                  secondaryLabel: null,
                ),
              );
            },
          ),
        ),
      ),
    );
    Size area() => tester.getSize(find.byType(DropZone));
    BoxDecoration box() =>
        tester
                .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                .decoration!
            as BoxDecoration;
    Color glyph() =>
        tester.widget<Icon>(find.byIcon(Icons.image_outlined)).color!;
    expect(area(), const Size(320, 160));
    expect(box().color!.a, 0);
    expect(box().border, isNull);
    final classicGlyph = glyph();

    T.setMode(AppThemeMode.dark);
    rebuild(() {});
    await tester.pumpAndSettle();
    expect(find.byType(DropZone), findsOneWidget);
    expect(area(), const Size(320, 160));
    expect(box().color!.a, 0);
    expect(box().border, isNull);
    expect(glyph(), isNot(classicGlyph));

    T.setMode(AppThemeMode.light);
    rebuild(() {});
    await tester.pumpAndSettle();
    expect(area(), const Size(320, 160));
  });
}

/// The video state without a backend: [VideoNotifier.build] builds a
/// decoder, and these tests need none. The panel reads the state's
/// fields and takes the notifier only to hang its actions on, so an
/// empty state stands in.
class _StubVideoNotifier extends VideoNotifier {
  @override
  VideoState build() => const VideoState();
}
