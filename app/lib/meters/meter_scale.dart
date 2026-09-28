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

import 'db_utils.dart';

/// The dBFS scale drawn beside the multichannel level meter (ES-191).
///
/// Majors carry a label and a grid line across the bars. Minors are
/// short ticks in the scale column only: 1 dB apart from 0 down to
/// −12 dBFS, 3 dB apart from −12 down to −24, none below.
class MeterScale {
  MeterScale._();

  /// Labelled marks, top to bottom.
  static const List<int> majorDb = [0, -3, -6, -12, -18, -24, -36, -48, -60];

  /// Majors in the order they claim space on a short meter: the
  /// 6/12 dB set first, then −3. A label that would overlap one already
  /// placed is skipped rather than drawn on top of it.
  static const List<int> labelPriority = [
    0,
    -6,
    -12,
    -18,
    -24,
    -36,
    -48,
    -60,
    -3,
  ];

  /// Unlabelled ticks, top to bottom: every 1 dB from −1 to −11 and
  /// every 3 dB from −15 to −21, excluding values in [majorDb].
  static final List<int> minorDb = List.unmodifiable(_minors());

  /// Pixels per dB below which no minor tick is drawn: 1 dB ticks
  /// closer than this merge into a solid edge.
  static const double minTickPitch = 2.0;

  static List<int> _minors() {
    final out = <int>[];
    for (var db = -1; db > -12; db--) {
      if (!majorDb.contains(db)) out.add(db);
    }
    for (var db = -15; db > -24; db -= 3) {
      if (!majorDb.contains(db)) out.add(db);
    }
    return out;
  }
}

/// Which scale marks fit a bar area of a given height: the labels to
/// draw and the minor ticks to draw. Pure geometry, so the painter can
/// cache one per (height, label height) instead of deciding per frame.
class MeterScaleLayout {
  /// Majors whose label is drawn, in [MeterScale.majorDb] order.
  final List<int> labels;

  /// Minors whose tick is drawn, in [MeterScale.minorDb] order.
  final List<int> minors;

  const MeterScaleLayout({required this.labels, required this.minors});

  /// Lays out the scale for a bar area [barAreaH] px tall (0 dBFS at
  /// the top, −60 at the bottom) with labels [labelH] px tall.
  ///
  /// Labels are placed in [MeterScale.labelPriority] order; one whose
  /// box (centred on its mark) would overlap an already-placed box is
  /// skipped. A minor tick is drawn when the pitch is at least
  /// [MeterScale.minTickPitch] px per dB and its mark falls outside
  /// every placed label box.
  factory MeterScaleLayout.fit({
    required double barAreaH,
    required double labelH,
  }) {
    double yOf(int db) => barAreaH * (1 - DbUtils.normalizeDb(db.toDouble()));
    final placedY = <int, double>{};
    for (final db in MeterScale.labelPriority) {
      final y = yOf(db);
      final overlaps = placedY.values.any((p) => (p - y).abs() < labelH);
      if (!overlaps) placedY[db] = y;
    }
    final labels = [
      for (final db in MeterScale.majorDb)
        if (placedY.containsKey(db)) db,
    ];
    final pxPerDb = yOf(-1) - yOf(0);
    final minors = <int>[];
    if (pxPerDb >= MeterScale.minTickPitch) {
      for (final db in MeterScale.minorDb) {
        final y = yOf(db);
        final inLabel = placedY.values.any((p) => (p - y).abs() < labelH / 2);
        if (!inLabel) minors.add(db);
      }
    }
    return MeterScaleLayout(
      labels: List.unmodifiable(labels),
      minors: List.unmodifiable(minors),
    );
  }
}
