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

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../meters/label_painter_cache.dart';
import '../state.dart' show fontSizeModeProvider, themeModeProvider;
import '../theme.dart';

/// A label over the 3D scene: [text] centred on [position], in logical
/// pixels from the top left of the scene viewport.
@immutable
class SceneLabel {
  const SceneLabel(this.text, this.position);

  final String text;
  final Offset position;

  @override
  bool operator ==(Object other) =>
      other is SceneLabel && other.text == text && other.position == position;

  @override
  int get hashCode => Object.hash(text, position);
}

/// Where the label of a point sits in a viewport of [viewSize] seen by a
/// perspective camera with vertical field of view [fovDeg] and clip
/// planes [near] and [far], or null when the point is nearer than [near],
/// behind the camera or past [far]. ([viewX], [viewY], [viewZ]) is the
/// point in the camera's view space, which looks down -Z. The label is
/// centred [gap] pixels below the projected point plus the projected
/// length of [halfHeight] scene units at the point's depth: below the
/// bottom of an upright mesh of that half height seen from the side.
/// Rounded to whole pixels, so a camera at rest yields the same labels.
Offset? sceneLabelPosition({
  required double viewX,
  required double viewY,
  required double viewZ,
  required double fovDeg,
  required double near,
  required double far,
  required Size viewSize,
  double halfHeight = 0,
  double gap = 0,
}) {
  final depth = -viewZ;
  if (depth < near || depth > far || viewSize.isEmpty) return null;
  // Pixels per scene unit at unit depth.
  final focal = viewSize.height / 2 / math.tan(fovDeg * math.pi / 360);
  return Offset(
    (viewSize.width / 2 + viewX * focal / depth).roundToDouble(),
    (viewSize.height / 2 -
            viewY * focal / depth +
            halfHeight * focal / depth +
            gap)
        .roundToDouble(),
  );
}

/// Paints [labels] over the 3D scene, repainting whenever the renderer
/// publishes new positions, and clipped to the scene so a label projected
/// past its edge stays off the panels beside it. Pointer events pass
/// through to the scene.
class SceneLabelOverlay extends ConsumerWidget {
  const SceneLabelOverlay({super.key, required this.labels});

  final ValueListenable<List<SceneLabel>> labels;

  /// The label style, shared with the ADM import preview's speaker
  /// labels. Reads T.* when called.
  static TextStyle labelStyle() => TextStyle(
    color: T.textSecondary.withValues(alpha: 0.7),
    fontSize: T.fontMeter,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontMode = ref.watch(fontSizeModeProvider);
    final themeMode = ref.watch(themeModeProvider);
    return IgnorePointer(
      child: ClipRect(
        child: CustomPaint(
          size: Size.infinite,
          painter: _SceneLabelPainter(labels, fontMode, themeMode),
        ),
      ),
    );
  }
}

class _SceneLabelPainter extends CustomPainter {
  _SceneLabelPainter(this.labels, this.fontMode, this.themeMode)
    : super(repaint: labels);

  final ValueListenable<List<SceneLabel>> labels;
  final FontSizeMode fontMode;
  final AppThemeMode themeMode;

  static final _cache = LabelPainterCache(SceneLabelOverlay.labelStyle);

  @override
  void paint(Canvas canvas, Size size) {
    for (final label in labels.value) {
      final tp = _cache.painterFor(label.text, fontMode, themeMode);
      tp.paint(canvas, label.position - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_SceneLabelPainter oldDelegate) =>
      oldDelegate.labels != labels ||
      oldDelegate.fontMode != fontMode ||
      oldDelegate.themeMode != themeMode;
}
