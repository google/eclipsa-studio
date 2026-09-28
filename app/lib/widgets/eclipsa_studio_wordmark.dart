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

/// Stylised "Eclipsa Studio" wordmark, with the release-stage label
/// beside it unless [showLabel] is off.
///
/// The label ([ReleaseStageLabel]) reads BETA, the public-beta label
/// since 0.28.0. It is not part of the brand lockup: [EclipsaStudioLockup]
/// aligns the mark and the wordmark without it and adds it after.
///
/// Single source of truth for the wordmark, used in the top bar at
/// title size and on the landing screen at hero size. Watches
/// theme + font mode so it tracks both even when constructed `const`
/// upstream, where no parent rebuild reaches it.
///
/// One drawing in every theme, as the brand lockup in `app/design/brand`
/// is set: [family], Inter, at weight 600 with [kTracking] letter
/// spacing, "Eclipsa" in `textPrimary` and " Studio" in `pink`. The
/// cube beside it draws its E and S in the same two tokens, so the
/// lockup reads as one thing in every theme. On the chrome bar
/// ([onChrome]) "Eclipsa" and the label take `chromeInk` instead, as
/// the cube's E does: the bar is its own surface with its own ground,
/// and `chromeInk` is the ink gated against it.
class EclipsaStudioWordmark extends ConsumerWidget {
  const EclipsaStudioWordmark({
    super.key,
    this.fontSize,
    this.labelFontSize,
    this.showLabel = true,
    this.onChrome = false,
  });

  final double? fontSize;
  final double? labelFontSize;

  /// The wordmark's face in every theme: the brand lockup is set in
  /// Inter, and the themes' own UI faces stay on the UI.
  static const String family = 'Inter';

  /// The wordmark's letter spacing in every theme, as a percentage of
  /// the type size: the brand lockup's -2%.
  static const double kTracking = -2;

  /// The wordmark's type at [size]: [family] at weight 600 with
  /// [kTracking], the same in every theme.
  static TextStyle typeStyle(double size) => TextStyle(
    fontFamily: family,
    fontSize: size,
    fontWeight: FontWeight.w600,
    letterSpacing: T.tracking(size, kTracking),
  );

  /// Whether the release-stage label follows the wordmark.
  final bool showLabel;

  /// Set when the wordmark sits on the chrome bar rather than a body
  /// surface: "Eclipsa" and the label take `chromeInk`.
  final bool onChrome;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);

    // The concept frames draw the mark at 22; it is fontTitle in every
    // theme, since text size is part of a component's size.
    final size = fontSize ?? T.fontTitle;
    final labelSize = labelFontSize ?? (size * 0.5);

    final type = typeStyle(size);
    final mark = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Eclipsa',
          style: type.copyWith(color: onChrome ? T.chromeInk : T.textPrimary),
        ),
        Text(' Studio', style: type.copyWith(color: T.pink)),
      ],
    );

    if (!showLabel) return mark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        mark,
        ReleaseStageLabel(
          wordmarkFontSize: size,
          fontSize: labelSize,
          onChrome: onChrome,
        ),
      ],
    );
  }
}

/// The release-stage label that follows the wordmark: BETA, the
/// public-beta label since 0.28.0 (ALPHA before it). Sized and offset
/// from the wordmark's type
/// size — a quarter em in from it, 0.06 em down from its top — so it
/// sits the same beside a wordmark drawn on its own or in the lockup.
class ReleaseStageLabel extends StatelessWidget {
  const ReleaseStageLabel({
    super.key,
    required this.wordmarkFontSize,
    this.fontSize,
    this.onChrome = false,
  });

  /// The type size of the wordmark this label follows.
  final double wordmarkFontSize;

  /// The label's own size; half the wordmark's when null.
  final double? fontSize;

  /// On the chrome bar the label takes `chromeInk`, like the wordmark.
  final bool onChrome;

  @override
  Widget build(BuildContext context) {
    final size = wordmarkFontSize;
    return Padding(
      padding: EdgeInsets.only(left: size * 0.25, top: size * 0.06),
      child: Text(
        'BETA',
        style: TextStyle(
          fontFamily: EclipsaStudioWordmark.family,
          fontSize: fontSize ?? size * 0.5,
          fontWeight: FontWeight.w700,
          color: onChrome ? T.chromeInk : T.textSecondary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
