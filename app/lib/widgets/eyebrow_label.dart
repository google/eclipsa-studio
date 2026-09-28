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
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';

/// ALL-CAPS eyebrow / section-header label built on [T.styleEyebrow],
/// the single point of truth for the recipe — use this instead of
/// hand-rolling a `_SectionLabel` (ES-319). Upper-cases [text] itself,
/// so call sites pass natural-case strings.
class EyebrowLabel extends ConsumerWidget {
  final String text;

  /// Overrides [T.styleEyebrow]'s own colour for one call site. The
  /// landing card's Recent block uses it because the Light theme draws
  /// that block on `bgSurface` rather than the card ground the recipe was
  /// picked against. This is not a per-theme eyebrow ink: every other
  /// [EyebrowLabel] keeps `styleEyebrow`'s colour in every theme, and
  /// a theme-wide change belongs in the recipe, not here.
  final Color? color;

  const EyebrowLabel(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Self-track theme/font: instances are often const-constructed,
    // so parent rebuilds skip them (the const-skip pattern).
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final style = T.styleEyebrow;
    return Text(
      text.toUpperCase(),
      style: color == null ? style : style.copyWith(color: color),
    );
  }
}
