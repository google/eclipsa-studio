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

import 'dart:convert' show base64Decode;
import 'dart:io';

import 'package:eclipsa_studio/export/still_export_frame.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A valid 1×1 transparent PNG (same fixture as
/// still_image_backend_test.dart).
final _onePxPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Unit tests for the still-export frame preparation (ES-192): the pure
/// dimension policy (fit inside the encoder-safe box, preserve aspect,
/// floor to even, never collapse below 2×2) and the decode/rasterize
/// path over real files.
void main() {
  group('stillExportDimensions', () {
    test('small images pass through unchanged (already even)', () {
      expect(stillExportDimensions(1920, 1080), (width: 1920, height: 1080));
      expect(stillExportDimensions(16, 16), (width: 16, height: 16));
    });

    test('odd dimensions floor to even', () {
      expect(stillExportDimensions(1921, 1081), (width: 1920, height: 1080));
      expect(stillExportDimensions(3, 5), (width: 2, height: 4));
    });

    test('oversized images downscale into the box, preserving aspect', () {
      // 6000x4000 (3:2) → height-limited: 2160 * 1.5 = 3240.
      expect(stillExportDimensions(6000, 4000), (width: 3240, height: 2160));
      // Exact 4K UHD fits the box unchanged.
      expect(stillExportDimensions(3840, 2160), (width: 3840, height: 2160));
      // Ultrawide → width-limited.
      final wide = stillExportDimensions(7680, 1600);
      expect(wide.width, kStillExportMaxWidth);
      expect(wide.height, 800);
    });

    test('tall portrait images are height-limited', () {
      final portrait = stillExportDimensions(2160, 3840);
      expect(portrait.height, kStillExportMaxHeight);
      expect(portrait.width, 1214); // 2160 * (2160/3840) = 1215 → even floor
    });

    test('degenerate 1x1 yields the 2x2 minimum', () {
      expect(stillExportDimensions(1, 1), (width: 2, height: 2));
    });
  });

  group('renderStillExportFrame', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('still_export_test_');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('decodes a real PNG into a tightly packed RGBA frame', () async {
      final file = File(p.join(tmp.path, 'one.png'));
      await file.writeAsBytes(_onePxPng);

      final frame = await renderStillExportFrame(file.path);
      expect(frame, isNotNull);
      // 1×1 source hits the 2×2 even-dimension floor.
      expect(frame!.width, 2);
      expect(frame.height, 2);
      expect(frame.rgba.length, frame.width * frame.height * 4);
      // Transparent source flattens onto the opaque black letterbox fill.
      expect(frame.rgba[3], 0xFF, reason: 'alpha must be flattened opaque');
    });

    test('returns null for undecodable bytes', () async {
      final file = File(p.join(tmp.path, 'corrupt.png'));
      await file.writeAsBytes(List.filled(64, 0x42));
      expect(await renderStillExportFrame(file.path), isNull);
    });

    test('returns null for a missing file', () async {
      expect(
        await renderStillExportFrame(p.join(tmp.path, 'nope.png')),
        isNull,
      );
    });
  });
}
