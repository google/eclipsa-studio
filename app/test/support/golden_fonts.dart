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

// Loads the app's bundled fonts into the test process so golden images
// rasterize the glyphs the app draws. Without this, `flutter test`
// substitutes the FlutterTest font (every glyph a box), which hides the
// label spacing and size regressions the goldens exist to catch.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void>? _loaded;

/// Registers Inter and JetBrains Mono from `assets/fonts/` under the
/// family names the themes use. Idempotent; call from `setUpAll`.
/// Paths resolve against the test cwd, which `flutter test` pins to the
/// package root (`app/`).
Future<void> loadGoldenFonts() => _loaded ??= _load();

Future<void> _load() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  const families = {
    'Inter': [
      'Inter-Light.ttf',
      'Inter-Regular.ttf',
      'Inter-Medium.ttf',
      'Inter-SemiBold.ttf',
      'Inter-Bold.ttf',
    ],
    'JetBrains Mono': ['JetBrainsMono-Regular.ttf', 'JetBrainsMono-Bold.ttf'],
  };
  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    for (final file in entry.value) {
      final bytes = await File('assets/fonts/$file').readAsBytes();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}
