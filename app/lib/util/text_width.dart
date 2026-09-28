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

import 'package:flutter/widgets.dart';

/// Widest rendered width of [texts] in [style], measured the way a
/// [Text] under [context] lays out: the ambient [DefaultTextStyle] is
/// merged beneath [style] and the [MediaQuery] text scaler is applied.
/// Measuring with a bare style under-reports the rendered width.
///
/// For a grid column, call this with the column's headers and its
/// widest value strings at the current font-size mode instead of
/// hardcoding a width; a constant fits one font mode only.
/// Returns 0 for an empty [texts].
double widestTextWidth(
  BuildContext context,
  Iterable<String> texts,
  TextStyle style,
) {
  final merged = DefaultTextStyle.of(context).style.merge(style);
  final scaler = MediaQuery.textScalerOf(context);
  var widest = 0.0;
  for (final text in texts) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: merged),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    if (painter.width > widest) widest = painter.width;
    painter.dispose();
  }
  return widest;
}
