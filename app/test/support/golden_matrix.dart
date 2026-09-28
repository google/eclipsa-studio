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

// The theme x font-mode matrix every painter golden runs over, and the
// one way a golden subject is pumped: a fixed-size surface at 1x, the
// theme and font mode set on `T` before the first build, and a
// RepaintBoundary around the subject so the image holds only it.

import 'package:eclipsa_studio/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden file name segment for a theme: its id (`dark`, `light`,
/// `classic`, `high-contrast`), so renaming a theme label never renames
/// a golden.
String themeTag(AppThemeMode mode) => kThemeMeta[mode]!.id;

/// Golden file name segment for a font mode.
String fontTag(FontSizeMode mode) => mode.name;

/// Runs [body] once per theme and, when [fonts] is true, per font mode.
/// Painters that draw no text take the theme axis only.
void forEachThemeAndFont(
  void Function(AppThemeMode theme, FontSizeMode font) body, {
  bool fonts = true,
}) {
  for (final theme in AppThemeMode.values) {
    for (final font in fonts ? FontSizeMode.values : [FontSizeMode.medium]) {
      body(theme, font);
    }
  }
}

/// Pumps the widget [subject] builds, at [size] under [theme] and
/// [font], and returns the finder for the RepaintBoundary to hand to
/// `matchesGoldenFile`. [subject] runs after the theme and font mode
/// are set, so a style that reads `T.*` when constructed (such as
/// `WaveformStyle.object`) picks up the theme under test.
Future<Finder> pumpGoldenSubject(
  WidgetTester tester,
  Widget Function() subject, {
  required Size size,
  required AppThemeMode theme,
  required FontSizeMode font,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  T.setMode(theme);
  T.setFontMode(font);
  addTearDown(() {
    T.setMode(T.defaultMode);
    T.setFontMode(FontSizeMode.medium);
  });
  const key = ValueKey('golden-subject');
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox.fromSize(size: size, child: subject()),
        ),
      ),
    ),
  );
  await tester.pump();
  return find.byKey(key);
}
