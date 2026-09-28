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

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/import/adm_detect.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart';

/// The sniff goes through the engine's shared WAV parser (the same probe
/// as [WavDecoder]); container/chunk-walk behavior — RF64/BW64, ds64
/// sizing, axml after data — is pinned engine-side. These tests cover
/// the Dart-side rule: axml_bytes > 0 ⇔ ADM, and anything the parser
/// rejects routes to the plain-WAV path (false).
String probeJson({int axmlBytes = 0, bool metadataDropped = false}) =>
    jsonEncode({
      'ok': true,
      'recovered': metadataDropped,
      'metadata_dropped': metadataDropped,
      'container': 'bw64',
      'channels': 2,
      'sample_rate': 48000,
      'bits_per_sample': 24,
      'is_float': false,
      'num_frames': 64,
      'data_offset': 92,
      'data_size': 64 * 6,
      'axml_bytes': axmlBytes,
      'chna_bytes': 0,
    });

void main() {
  tearDown(() => WavDecoder.probeForTesting = null);

  test('non-empty axml chunk is ADM', () async {
    WavDecoder.probeForTesting = (_) => probeJson(axmlBytes: 23);
    expect(await wavHasAdmMetadata('adm.wav'), isTrue);
  });

  test('absent axml chunk is not ADM', () async {
    WavDecoder.probeForTesting = (_) => probeJson();
    expect(await wavHasAdmMetadata('plain.wav'), isFalse);
  });

  test('empty axml chunk is not ADM (matches the engine rule)', () async {
    WavDecoder.probeForTesting = (_) => probeJson(axmlBytes: 0);
    expect(await wavHasAdmMetadata('empty-axml.wav'), isFalse);
  });

  test('dropped ADM metadata routes to the strict ADM path', () async {
    // A lenient recovery that discarded an announced axml/chna chunk:
    // axml_bytes is 0 (the payload was unreadable), but the file must
    // NOT silently import as plain audio — returning true sends it to
    // the strict ADM import, which surfaces an honest damage error.
    WavDecoder.probeForTesting = (_) => probeJson(metadataDropped: true);
    expect(await wavHasAdmMetadata('damaged-adm.wav'), isTrue);
  });

  test('probe JSON without axml_bytes key is not ADM', () async {
    // Pins the `?? 0` fallback: a probe schema without the key must
    // route to the plain-WAV path, not throw.
    WavDecoder.probeForTesting = (_) {
      final m = jsonDecode(probeJson()) as Map<String, dynamic>
        ..remove('axml_bytes')
        ..remove('chna_bytes');
      return jsonEncode(m);
    };
    expect(await wavHasAdmMetadata('no-key.wav'), isFalse);
  });

  test('parser-rejected files are not ADM', () async {
    WavDecoder.probeForTesting = (_) =>
        jsonEncode({'ok': false, 'error': 'Missing RIFF/RF64/BW64 magic.'});
    expect(await wavHasAdmMetadata('not-a.wav'), isFalse);
  });

  test('missing files are not ADM', () async {
    WavDecoder.probeForTesting = (_) =>
        jsonEncode({'ok': false, 'error': 'Cannot open WAV file: absent.wav'});
    expect(await wavHasAdmMetadata('absent.wav'), isFalse);
  });
}
