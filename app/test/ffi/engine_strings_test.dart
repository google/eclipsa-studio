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

import 'dart:ffi';

import 'package:eclipsa_studio/ffi/engine_strings.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// A NUL-terminated copy of [bytes] in native memory, freed at teardown.
Pointer<Utf8> _native(List<int> bytes) {
  final p = calloc<Uint8>(bytes.length + 1);
  p.asTypedList(bytes.length).setAll(0, bytes);
  addTearDown(() => calloc.free(p));
  return p.cast<Utf8>();
}

void main() {
  group('decodeEngineString', () {
    test('decodes valid UTF-8', () {
      expect(decodeEngineString(_native([0x61, 0xC3, 0xA9, 0x62])), 'a\u{E9}b');
    });

    test('decodes an empty string', () {
      expect(decodeEngineString(_native([])), '');
    });

    test('a character cut at the end decodes to U+FFFD', () {
      // The first byte of the two-byte U+00E9, as a 511-byte engine log
      // slot leaves it when the cut falls inside the character.
      expect(decodeEngineString(_native([0x61, 0xC3])), 'a\u{FFFD}');
    });
  });
}
