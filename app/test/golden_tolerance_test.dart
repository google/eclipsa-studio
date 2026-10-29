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

// Pins the golden tolerance of the comparator that flutter_test_config.dart
// installs for every test file: a 100 x 100 image may differ from its
// golden in 10 pixels (0.1%) and not in 11. The comparator used to compare
// a fraction against the percentage, which accepted up to 10% (ES-955).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const int _kSide = 100;

/// A [_kSide] x [_kSide] black PNG whose first [white] pixels, in row
/// order, are white.
Future<Uint8List> _png(int white) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final side = _kSide.toDouble();
  canvas.drawRect(
    Rect.fromLTWH(0, 0, side, side),
    Paint()..color = const Color(0xFF000000),
  );
  final paint = Paint()..color = const Color(0xFFFFFFFF);
  for (var i = 0; i < white; i++) {
    final x = (i % _kSide).toDouble();
    final y = (i ~/ _kSide).toDouble();
    canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), paint);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(_kSide, _kSide);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('a golden may differ in 0.1% of its pixels and no more', (
    tester,
  ) async {
    // Image encoding and file I/O are real async work, which the fake
    // async zone of testWidgets never completes.
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('golden_tolerance');
      addTearDown(() => dir.deleteSync(recursive: true));
      final master = File('${dir.path}/golden_tolerance_probe.png');
      await master.writeAsBytes(await _png(0));

      // The failing comparison writes its diff images to the comparator's
      // failures directory. Remove them, and the directory if this test
      // created it.
      final comparator = goldenFileComparator as LocalFileComparator;
      final failures = Directory.fromUri(
        comparator.basedir.resolve('failures/'),
      );
      final failuresExisted = failures.existsSync();
      addTearDown(() {
        for (final kind in const [
          'masterImage',
          'testImage',
          'maskedDiff',
          'isolatedDiff',
        ]) {
          final file = comparator.getFailureFile(
            kind,
            master.uri,
            comparator.basedir,
          );
          if (file.existsSync()) file.deleteSync();
        }
        if (!failuresExisted &&
            failures.existsSync() &&
            failures.listSync().isEmpty) {
          failures.deleteSync();
        }
      });

      expect(
        await goldenFileComparator.compare(await _png(0), master.uri),
        isTrue,
      );
      expect(
        await goldenFileComparator.compare(await _png(10), master.uri),
        isTrue,
      );
      await expectLater(
        goldenFileComparator.compare(await _png(11), master.uri),
        throwsA(isA<FlutterError>()),
      );
    });
  });
}
