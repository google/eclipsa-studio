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

import 'package:eclipsa_studio/meters/label_painter_cache.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returns the same laid-out painter for repeated lookups', () {
    final cache = LabelPainterCache(() => const TextStyle(fontSize: 8));
    final a = cache.painterFor('L', FontSizeMode.medium, AppThemeMode.classic);
    final b = cache.painterFor('L', FontSizeMode.medium, AppThemeMode.classic);
    expect(identical(a, b), isTrue);
    expect(a.width, greaterThan(0)); // already laid out
  });

  test('invalidates when font or theme mode changes', () {
    final cache = LabelPainterCache(() => const TextStyle(fontSize: 8));
    final a = cache.painterFor('L', FontSizeMode.medium, AppThemeMode.classic);
    final b = cache.painterFor('L', FontSizeMode.large, AppThemeMode.classic);
    expect(identical(a, b), isFalse);
    final c = cache.painterFor('L', FontSizeMode.large, AppThemeMode.dark);
    expect(identical(b, c), isFalse);
    // Stable again once modes settle.
    final d = cache.painterFor('L', FontSizeMode.large, AppThemeMode.dark);
    expect(identical(c, d), isTrue);
  });

  test('caches distinct labels independently', () {
    final cache = LabelPainterCache(() => const TextStyle(fontSize: 8));
    final l = cache.painterFor('L', FontSizeMode.medium, AppThemeMode.classic);
    final r = cache.painterFor('R', FontSizeMode.medium, AppThemeMode.classic);
    expect(identical(l, r), isFalse);
    expect(
      identical(
        cache.painterFor('R', FontSizeMode.medium, AppThemeMode.classic),
        r,
      ),
      isTrue,
    );
  });
}
