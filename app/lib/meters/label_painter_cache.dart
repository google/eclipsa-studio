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

import 'package:flutter/material.dart';

import '../theme.dart';

/// Cache of laid-out [TextPainter]s for meter labels.
///
/// Meter painters are reconstructed every tick with fresh level data, so
/// per-instance `late final` reuse never survives a frame — labels and
/// dB marks were being allocated and laid out per channel per paint at
/// 60 Hz. Holders declare one static instance per style role; entries
/// are keyed by label text and invalidated whenever the font or theme
/// mode changes (the style closure re-reads T.* on rebuild).
class LabelPainterCache {
  LabelPainterCache(this._styleOf);

  /// Resolves the label style from T.* — called only when the cache
  /// (re)builds, so a mode switch picks up the new tokens.
  final TextStyle Function() _styleOf;

  FontSizeMode? _fontMode;
  AppThemeMode? _themeMode;
  final _painters = <String, TextPainter>{};

  /// A laid-out painter for [text] under the given modes. The returned
  /// painter is owned by the cache — paint it, don't dispose it.
  TextPainter painterFor(
    String text,
    FontSizeMode fontMode,
    AppThemeMode themeMode,
  ) {
    if (fontMode != _fontMode || themeMode != _themeMode) {
      for (final tp in _painters.values) {
        tp.dispose();
      }
      _painters.clear();
      _fontMode = fontMode;
      _themeMode = themeMode;
    }
    return _painters.putIfAbsent(
      text,
      () => TextPainter(
        text: TextSpan(text: text, style: _styleOf()),
        textDirection: TextDirection.ltr,
      )..layout(),
    );
  }

  /// Disposes every cached painter. The cache stays usable and lays out
  /// painters again on the next [painterFor].
  void dispose() {
    for (final tp in _painters.values) {
      tp.dispose();
    }
    _painters.clear();
    _fontMode = null;
    _themeMode = null;
  }
}
