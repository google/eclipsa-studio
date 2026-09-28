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
import 'package:eclipsa_studio/video/popout_appearance.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `appearance` message (ES-744) round-trips every theme and font
/// size, and an unknown or missing value decodes to null.
void main() {
  test('every theme and font size round-trips', () {
    for (final theme in AppThemeMode.values) {
      for (final font in FontSizeMode.values) {
        final decoded = decodeAppearance(encodeAppearance(theme, font));
        expect(decoded.theme, theme);
        expect(decoded.font, font);
      }
    }
  });

  test('the body carries the persisted preference strings', () {
    final body = encodeAppearance(AppThemeMode.light, FontSizeMode.large);
    expect(body, {'theme': 'light', 'font': 'large'});
  });

  test('unknown or missing values decode to null', () {
    expect(decodeAppearance(null), (theme: null, font: null));
    expect(decodeAppearance('x'), (theme: null, font: null));
    final decoded = decodeAppearance({'theme': 'no-such', 'font': 7});
    expect(decoded.theme, isNull);
    expect(decoded.font, isNull);
  });
}
