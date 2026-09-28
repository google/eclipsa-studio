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

/// Single cell of the routing matrix — a tappable red/purple dot.
///
/// Shared by the per-element routing dialog (and any future routing
/// surfaces). Stateless: callers pass `selected` and `onTap` and the
/// cell is a thin visual wrapper.
class RoutingCell extends StatelessWidget {
  final double size;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const RoutingCell({
    super.key,
    required this.size,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? color : Colors.transparent,
              border: Border.all(
                color: selected ? color : T.textGhost,
                width: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
