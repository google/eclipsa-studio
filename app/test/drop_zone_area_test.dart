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
import 'package:eclipsa_studio/widgets/drop_zone.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The area drop zone fits its icon and two labels in the 80 px slot
/// in every theme and font size (ES-765: High Contrast's 2 px border at
/// the large font left 76 px for 77 px of content).
void main() {
  tearDown(() {
    T.setMode(T.defaultMode);
    T.setFontMode(FontSizeMode.medium);
  });

  for (final mode in AppThemeMode.values) {
    for (final font in FontSizeMode.values) {
      testWidgets('${mode.name}, ${font.name} font: the area zone fits', (
        tester,
      ) async {
        T.setMode(mode);
        T.setFontMode(font);
        await tester.pumpWidget(
          // Under a Scaffold, as in the app: its Material supplies the
          // default text style whose line height the labels take.
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 600,
                  height: DropZone.areaHeight,
                  child: DropZone(
                    variant: DropZoneVariant.area,
                    icon: Icons.audio_file_outlined,
                    primaryLabel: 'Drop WAV files or click to browse',
                    secondaryLabel: 'WAV · 16/24/32 bit',
                    isDragOver: false,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
