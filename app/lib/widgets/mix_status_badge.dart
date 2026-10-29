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
import 'ae_type_badge.dart';

/// "Not in mix presentation" line of an element card, shown when the
/// active mix presentation excludes the element: a block glyph and the
/// label in `meterYellow`, drawn as an [ElementDetailRow] so it lines up
/// with the card's other detail lines.
///
/// Watches the theme so a `const` call site still rebuilds with the new
/// colour.
class MixStatusBadge extends ConsumerWidget {
  /// Tooltip for Creator-mode call sites, where inclusion is editable.
  static const String creatorTooltip =
      'This element is not in the active mix presentation. '
      'Add it in the Mix tab.';

  final String? tooltip;

  const MixStatusBadge({super.key, this.tooltip});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    final row = ElementDetailRow(
      glyph: Icon(
        Icons.block,
        size: ElementDetailRow.glyphSize,
        color: T.meterYellow,
      ),
      label: 'Not in mix presentation',
      color: T.meterYellow,
    );
    if (tooltip == null) return row;
    return Tooltip(message: tooltip!, child: row);
  }
}
