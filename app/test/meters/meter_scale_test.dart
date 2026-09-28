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

import 'package:eclipsa_studio/meters/meter_scale.dart';
import 'package:flutter_test/flutter_test.dart';

/// The dB scale beside the multichannel meter (ES-191): labelled majors,
/// unlabelled minors 1 dB apart to −12 and 3 dB apart to −24, and the
/// layout that decides which of them fit a given meter height.
void main() {
  group('marks', () {
    test('minors fill 1 dB to −12 and 3 dB to −24, none on a major', () {
      expect(MeterScale.minorDb, [
        -1,
        -2,
        -4,
        -5,
        -7,
        -8,
        -9,
        -10,
        -11,
        -15,
        -21,
      ]);
      for (final db in MeterScale.minorDb) {
        expect(MeterScale.majorDb, isNot(contains(db)));
      }
    });

    test('label priority covers every major, 0 first and −3 last', () {
      expect(MeterScale.labelPriority.toSet(), MeterScale.majorDb.toSet());
      expect(MeterScale.labelPriority.length, MeterScale.majorDb.length);
      expect(MeterScale.labelPriority.first, 0);
      expect(MeterScale.labelPriority.last, -3);
    });
  });

  group('MeterScaleLayout.fit', () {
    const labelH = 10.0;

    /// y of [db] on a bar area [h] px tall, 0 dBFS at the top.
    double yOf(int db, double h) => h * (-db / 60);

    test('a tall meter places every label and every minor', () {
      final l = MeterScaleLayout.fit(barAreaH: 600, labelH: labelH);
      expect(l.labels, MeterScale.majorDb);
      expect(l.minors, MeterScale.minorDb);
    });

    test('−3 is the first label dropped', () {
      // 180 px: 3 dB is 9 px, under the 10 px label, so −3 collides
      // with 0 and −6; every 6 dB neighbour is 18 px apart and fits.
      final l = MeterScaleLayout.fit(barAreaH: 180, labelH: labelH);
      expect(l.labels, [0, -6, -12, -18, -24, -36, -48, -60]);
    });

    test('a short meter keeps 0 and the 12 dB set', () {
      // 90 px: 6 dB is 9 px, so −6 collides with 0 and −12; 12 dB is
      // 18 px and fits.
      final l = MeterScaleLayout.fit(barAreaH: 90, labelH: labelH);
      expect(l.labels, [0, -12, -24, -36, -48, -60]);
    });

    test('placed labels never overlap', () {
      for (var h = 20.0; h <= 600; h += 7) {
        final l = MeterScaleLayout.fit(barAreaH: h, labelH: labelH);
        final ys = l.labels.map((db) => yOf(db, h)).toList();
        for (var i = 1; i < ys.length; i++) {
          expect(
            ys[i] - ys[i - 1],
            greaterThanOrEqualTo(labelH),
            reason: 'h=$h ${l.labels}',
          );
        }
        expect(l.labels, contains(0), reason: 'h=$h');
      }
    });

    test('minors vanish under 2 px per dB', () {
      // 119 px is 1.98 px per dB; 120 px is 2.0.
      expect(
        MeterScaleLayout.fit(barAreaH: 119, labelH: labelH).minors,
        isEmpty,
      );
      expect(
        MeterScaleLayout.fit(barAreaH: 120, labelH: labelH).minors,
        isNotEmpty,
      );
    });

    test('a minor inside a placed label box is not drawn', () {
      // 120 px: 2 px per dB, so −1 and −2 sit inside the 10 px box
      // centred on 0, and −4/−5/−7/−8 inside the one on −6.
      final l = MeterScaleLayout.fit(barAreaH: 120, labelH: labelH);
      expect(l.labels, contains(-6));
      expect(l.minors, isNot(contains(-1)));
      expect(l.minors, isNot(contains(-2)));
      expect(l.minors, isNot(contains(-4)));
      expect(l.minors, isNot(contains(-8)));
      for (final db in l.minors) {
        final y = yOf(db, 120);
        for (final label in l.labels) {
          expect(
            (yOf(label, 120) - y).abs(),
            greaterThanOrEqualTo(labelH / 2),
            reason: 'minor $db against label $label',
          );
        }
      }
    });
  });
}
