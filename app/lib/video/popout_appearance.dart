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

import '../theme.dart';

/// The `appearance` message the main window sends the pop-out over the
/// pop-out channel: the theme and font size to draw in (ES-744).
///
/// The pop-out runs its own Flutter engine with its own `T`, so a
/// change made in the main window's Settings reaches it only by
/// message. The values are the strings `AppPreferences` persists (the
/// enum names), so both sides parse them the same way `main()` parses
/// the preferences file at launch.
const appearanceMethod = 'appearance';

/// The message body for [theme] and [font].
Map<String, String> encodeAppearance(AppThemeMode theme, FontSizeMode font) => {
  'theme': theme.name,
  'font': font.name,
};

/// The theme and font in a message body, or null for a field that is
/// missing or names no known value.
({AppThemeMode? theme, FontSizeMode? font}) decodeAppearance(Object? body) {
  if (body is! Map) return (theme: null, font: null);
  final themeId = body['theme'];
  final fontName = body['font'];
  return (
    theme: themeId is String ? themeModeFromId(themeId) : null,
    font: fontName is String
        ? FontSizeMode.values.where((m) => m.name == fontName).firstOrNull
        : null,
  );
}
