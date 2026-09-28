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

class GainSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const GainSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Labels
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${min.toInt()} dB',
              style: TextStyle(fontSize: T.fontBody, color: T.textGhost),
            ),
            Text(
              '+${max.toInt()} dB',
              style: TextStyle(fontSize: T.fontBody, color: T.textGhost),
            ),
          ],
        ),
        const SizedBox(height: 2),
        // Main slider
        SizedBox(
          height: 14,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              thumbColor: T.white,
              activeTrackColor: T.purple,
              inactiveTrackColor: T.bgControls,
              overlayShape: SliderComponentShape.noOverlay,
              trackShape: _GradientTrackShape(),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        const SizedBox(height: 2),
        // Range bar
        SizedBox(
          height: 4,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              return Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: T.bgControls,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Positioned(
                    left: w * 0.3,
                    width: w * 0.4,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: T.borderStrong,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GradientTrackShape extends RoundedRectSliderTrackShape {
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    final canvas = context.canvas;
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    // Inactive track
    final inactivePaint = Paint()
      ..color = sliderTheme.inactiveTrackColor ?? T.bgControls;
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, const Radius.circular(3)),
      inactivePaint,
    );

    // Active track with gradient
    final activeRect = Rect.fromLTRB(
      trackRect.left,
      trackRect.top,
      thumbCenter.dx,
      trackRect.bottom,
    );
    final activePaint = Paint()
      ..shader = LinearGradient(
        colors: [T.purple, T.purpleLight],
      ).createShader(activeRect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(activeRect, const Radius.circular(3)),
      activePaint,
    );
  }
}
