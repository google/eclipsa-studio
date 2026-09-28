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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';

/// Cycle the active theme from anywhere in the app.
///
/// Design review means looking at real surfaces (the Renderer, the
/// timeline, a dialog) in each theme as well as the gallery's swatches,
/// so the shortcut works from any screen.
///
/// Ships in every build, unlike [ThemeGallery]: all four themes are
/// offered in Settings, so stepping through them is a user-facing way
/// to compare them on a real surface. The cycle and the Settings
/// picker cover the same set of themes.
class ThemeCycle {
  ThemeCycle._();

  /// Advance to the next theme, wrapping.
  ///
  /// Deliberately silent. The active theme is shown in the status bar
  /// instead of a toast: a toast would cover the surface under
  /// comparison and then disappear.
  static void next(WidgetRef ref) {
    const modes = AppThemeMode.values;
    final current = ref.read(themeModeProvider);
    final mode = modes[(modes.indexOf(current) + 1) % modes.length];

    // Goes through the provider, not T.setMode, so the change persists
    // and every watcher rebuilds — same path as the Settings picker.
    ref.read(themeModeProvider.notifier).set(mode);
  }
}
