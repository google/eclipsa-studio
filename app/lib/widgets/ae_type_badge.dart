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

/// Icon for an audio-element type ('Object' / 'Scene' / 'Channel').
/// Shared by [AeTypeBadge] and the format pickers so every surface
/// speaks the same visual language.
IconData aeTypeIcon(String type) {
  final t = type.toLowerCase();
  if (t.contains('object')) return Icons.circle;
  if (t.contains('scene')) return Icons.blur_on;
  return Icons.speaker_group;
}

/// Theme colour for an audio-element type.
Color aeTypeColor(String type) {
  final t = type.toLowerCase();
  if (t.contains('object')) return T.typeObject;
  if (t.contains('scene')) return T.typeScene;
  return T.typeChannel;
}

/// Shared pill body for the passive [AeTypeBadge] and interactive
/// variants (the elements-view format chip): tinted rounded container
/// with the type icon and a label in the type colour.
///
/// [fill] overrides the default 12 % type tint — interactive hosts
/// pass a neutral rest colour and tint on hover / press; [borderColor]
/// adds the 0.5-wide border every clickable console surface carries
/// (passive badges stay borderless); [trailing] appends state or
/// action glyphs after the label. With [expand] the label claims all
/// remaining width (full-width button hosts) instead of
/// shrink-wrapping (inline badge).
Widget aeTypePill({
  required String type,
  required String label,
  List<Widget> trailing = const [],
  double? height,
  Color? fill,
  Color? borderColor,
  double? fontSize,
  bool expand = false,
  EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
    horizontal: T.gapPair,
    vertical: 2,
  ),
}) {
  final color = aeTypeColor(type);
  final text = Text(
    label,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: fontSize ?? T.fontCaption, color: color),
  );
  return Container(
    height: height,
    padding: padding,
    decoration: BoxDecoration(
      color: fill ?? color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(T.radiusSm),
      border: borderColor == null
          ? null
          : Border.all(color: borderColor, width: 0.5),
    ),
    child: Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Icon(aeTypeIcon(type), size: 10, color: color),
        const SizedBox(width: 4),
        if (expand) Expanded(child: text) else Flexible(child: text),
        ...trailing,
      ],
    ),
  );
}

/// Compact audio-element type + layout label.
///
/// Shows "Object · Mono", "Channel · 7.1.4", "Scene · 3OA", etc.
/// Styled to match _BinauralSettings: bgControls pill with icon.
class AeTypeBadge extends StatelessWidget {
  final String type;
  final String layout;

  const AeTypeBadge({super.key, required this.type, required this.layout});

  @override
  Widget build(BuildContext context) {
    return aeTypePill(type: type, label: '$type · $layout');
  }
}
