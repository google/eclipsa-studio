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

/// Shared inline remove affordance: the small ghost '✕' used to delete
/// the thing it sits on — mix-presentation tabs, channel strips,
/// loudness-layout chips, and element rows.
///
/// One component so every ✕ renders identically (glyph, T.fontSmall,
/// T.textGhost by default), shows the click cursor, and hit-tests its
/// whole box — with the default deferToChild only the glyph itself
/// would be tappable and near-misses would fall through to whatever is
/// behind. [color] exists for backgrounds where the ghost tone lacks
/// contrast (e.g. a selected ConsoleChip passes its own ink).
class RemoveXButton extends ConsumerWidget {
  final VoidCallback onTap;
  final double width;
  final double height;
  final Color? color;

  const RemoveXButton({
    super.key,
    required this.onTap,
    this.width = 18,
    this.height = 18,
    this.color,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Self-track theme/font: a const-constructed instance is never
    // rebuilt by its parent and would keep stale T.* values.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: height,
          child: Center(
            child: Text(
              '✕',
              style: TextStyle(
                fontSize: T.fontSmall,
                color: color ?? T.textGhost,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
