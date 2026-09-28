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

/// Pill badge showing "NOT IN MIX" when an element is excluded.
class MixStatusBadge extends StatelessWidget {
  /// Tooltip for Creator-mode call sites, where inclusion is editable.
  static const String creatorTooltip =
      'This element is not in the active mix. '
      'Add it in the Mix tab.';

  final String? tooltip;

  const MixStatusBadge({super.key, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: T.meterYellow.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(T.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.block, size: 10, color: T.meterYellow),
          const SizedBox(width: 4),
          // Flexible so a narrow parent ellipsizes the label instead of
          // overflowing (the element header at its 120 px minimum).
          Flexible(
            child: Text(
              'NOT IN MIX',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: T.fontCaption,
                color: T.meterYellow,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (tooltip == null) return badge;
    return Tooltip(message: tooltip!, child: badge);
  }
}
