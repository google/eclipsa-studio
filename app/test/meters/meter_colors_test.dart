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

import 'dart:ui' as ui;

import 'package:eclipsa_studio/meters/db_utils.dart';
import 'package:eclipsa_studio/meters/meter_colors.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Red marks the clip latch only (ES-191): the level ramp is green,
/// yellow and amber in every theme, and a bar filled to 0 dBFS never
/// carries a red pixel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => T.setMode(T.defaultMode));

  group('zoneColor', () {
    for (final mode in AppThemeMode.values) {
      test('${mode.name}: never returns meterRed', () {
        T.setMode(mode);
        for (var i = 0; i <= 1000; i++) {
          final c = MeterColors.zoneColor(i / 1000);
          expect(c, isNot(T.meterRed), reason: 'norm ${i / 1000}');
        }
      });

      test('${mode.name}: amber, yellow and red are distinct', () {
        T.setMode(mode);
        expect(T.meterAmber, isNot(T.meterRed));
        expect(T.meterAmber, isNot(T.meterYellow));
        expect(T.meterAmber, isNot(T.meterGreen));
      });
    }

    test('zones sit at −18 and −6 dBFS', () {
      T.setMode(AppThemeMode.dark);
      expect(MeterColors.zoneColor(0), T.meterGreen);
      expect(MeterColors.zoneColor(DbUtils.normalizeDb(-18.1)), T.meterGreen);
      expect(MeterColors.zoneColor(DbUtils.normalizeDb(-17.9)), T.meterYellow);
      expect(MeterColors.zoneColor(DbUtils.normalizeDb(-6.1)), T.meterYellow);
      expect(MeterColors.zoneColor(DbUtils.normalizeDb(-5.9)), T.meterAmber);
      expect(MeterColors.zoneColor(1), T.meterAmber);
    });
  });

  group('paintZonedBar', () {
    for (final mode in AppThemeMode.values) {
      test('${mode.name}: a full-scale bar has no red pixel', () async {
        T.setMode(mode);
        const w = 10, h = 100;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        paintZonedBar(canvas, Paint(), 0, w.toDouble(), 0, h.toDouble(), 1);
        final image = await recorder.endRecording().toImage(w, h);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        image.dispose();
        final red = T.meterRed;
        final amber = T.meterAmber;
        var amberSeen = false;
        for (var y = 0; y < h; y++) {
          final o = (y * w + w ~/ 2) * 4;
          final px = Color.fromARGB(
            bytes.getUint8(o + 3),
            bytes.getUint8(o),
            bytes.getUint8(o + 1),
            bytes.getUint8(o + 2),
          );
          expect(px, isNot(red), reason: 'row $y');
          if (px == amber) amberSeen = true;
        }
        expect(amberSeen, isTrue, reason: 'the top zone is amber');
      });
    }
  });
}
