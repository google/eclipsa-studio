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

// The IAMF probe's mix presentation name and language are copied from
// the file's annotations, and a file-open error holds the path cut to
// 256 bytes, so they can hold bytes that are not UTF-8. readProbeResult
// decodes them to U+FFFD instead of throwing, which would fail the whole
// probe (ES-943).

import 'dart:ffi';

import 'package:eclipsa_studio/ffi/engine_bindings.dart';
import 'package:eclipsa_studio/playback/iamf_probe.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// A NUL-terminated copy of [bytes] in native memory, freed at teardown.
Pointer<Utf8> _native(List<int> bytes) {
  final p = calloc<Uint8>(bytes.length + 1);
  p.asTypedList(bytes.length).setAll(0, bytes);
  addTearDown(() => calloc.free(p));
  return p.cast<Utf8>();
}

/// 'Haupt' followed by 0xFF, which is never valid in UTF-8.
const _malformedName = [0x48, 0x61, 0x75, 0x70, 0x74, 0xFF];

/// 'de' followed by the first byte of a two-byte é.
const _cutLanguage = [0x64, 0x65, 0xC3];

void main() {
  test('a malformed mix presentation name and language decode', () {
    final result = calloc<NativeIamfProbeResult>();
    final mp = calloc<NativeIamfProbeMixPres>();
    addTearDown(() {
      calloc.free(mp);
      calloc.free(result);
    });
    mp.ref
      ..mixPresentationId = 7
      ..name = _native(_malformedName)
      ..language = _native(_cutLanguage)
      ..loudnessLufs = -23
      ..truePeakDbtp = -1;
    result.ref
      ..sampleRate = 48000
      ..numMixPresentations = 1
      ..mixPresentations = mp;

    final report = readProbeResult(result.ref);

    expect(report.ok, isTrue);
    expect(report.mixPresentations.single.name, 'Haupt\u{FFFD}');
    expect(report.mixPresentations.single.language, 'de\u{FFFD}');
  });

  test('a malformed error message decodes', () {
    final result = calloc<NativeIamfProbeResult>();
    addTearDown(() => calloc.free(result));
    result.ref
      ..status = 1
      ..errorMessage = _native(_malformedName);

    final report = readProbeResult(result.ref);

    expect(report.ok, isFalse);
    expect(report.errorMessage, 'Haupt\u{FFFD}');
  });
}
