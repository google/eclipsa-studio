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

import 'package:flutter/painting.dart';

import '../theme.dart';

/// Visual styling for waveform rendering.
class WaveformStyle {
  // Nullable backing fields so the unset defaults resolve against the
  // active theme at read time (the old frozen hex defaults were one
  // theme's values, and a white centerline was near-invisible on the
  // light theme the app had at the time).
  final Color? _waveColor;
  final Gradient? waveGradient;
  final Color? _centerlineColor;
  final Color? backgroundColor;
  final Color? rmsColor;
  final double opacity;
  final bool mirrored;
  final bool antiAlias;
  final double borderRadius;

  /// Wave fill color; defaults to the theme's Object-type green.
  Color get waveColor => _waveColor ?? T.typeObject;

  /// Centerline color; defaults to a faint theme-aware text tint.
  Color get centerlineColor =>
      _centerlineColor ?? T.textPrimary.withValues(alpha: 0.19);

  /// Prefer the named constructors [object], [channel], [scene], or
  /// [accent], which pick per-type theme colors. Colors left unset
  /// here fall back to theme-aware values via the getters above.
  const WaveformStyle({
    Color? waveColor,
    this.waveGradient,
    Color? centerlineColor,
    this.backgroundColor,
    this.rmsColor,
    this.opacity = 0.8,
    this.mirrored = true,
    this.antiAlias = true,
    this.borderRadius = 4.0,
  }) : _waveColor = waveColor,
       _centerlineColor = centerlineColor;

  /// Eclipsa Studio Object type (emerald green).
  static WaveformStyle get object => WaveformStyle(
    waveColor: T.typeObject,
    rmsColor: T.typeObject.withValues(alpha: 0.31),
  );

  /// Eclipsa Studio Channel type (amber).
  static WaveformStyle get channel => WaveformStyle(
    waveColor: T.typeChannel,
    rmsColor: T.typeChannel.withValues(alpha: 0.31),
  );

  /// Eclipsa Studio Scene type (indigo).
  static WaveformStyle get scene => WaveformStyle(
    waveColor: T.typeScene,
    rmsColor: T.typeScene.withValues(alpha: 0.31),
  );

  /// Purple-pink gradient accent.
  static WaveformStyle get accent => WaveformStyle(
    waveColor: T.purple,
    waveGradient: LinearGradient(colors: [T.purple, T.pink]),
  );

  WaveformStyle copyWith({
    Color? waveColor,
    Gradient? waveGradient,
    Color? centerlineColor,
    Color? backgroundColor,
    Color? rmsColor,
    double? opacity,
    bool? mirrored,
    bool? antiAlias,
    double? borderRadius,
  }) {
    return WaveformStyle(
      // Fall back to the backing fields (not the getters) so an unset
      // color stays theme-following in the copy instead of freezing at
      // the theme value current at copyWith() time.
      waveColor: waveColor ?? _waveColor,
      waveGradient: waveGradient ?? this.waveGradient,
      centerlineColor: centerlineColor ?? _centerlineColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      rmsColor: rmsColor ?? this.rmsColor,
      opacity: opacity ?? this.opacity,
      mirrored: mirrored ?? this.mirrored,
      antiAlias: antiAlias ?? this.antiAlias,
      borderRadius: borderRadius ?? this.borderRadius,
    );
  }
}
