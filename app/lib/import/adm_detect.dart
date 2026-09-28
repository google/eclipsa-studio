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

import 'dart:io';

import '../logging/log.dart';
import '../waveform/wav_decoder.dart';

/// Sniffs whether a WAV file carries ADM metadata — a non-empty `axml`
/// chunk — through the engine's shared WAV parser (the same
/// `eclipsa_studio_wav_probe_json` probe that backs [WavDecoder.readInfo]), so
/// the detection rule is byte-for-byte the engine's own.
///
/// Header-only: the probe walks the RIFF/RF64/BW64 chunk list with seeks
/// and never reads sample data, so it stays cheap on multi-GB masters.
///
/// Returns false for anything unreadable: the caller then routes the
/// file down the plain-WAV import path. The probe opens leniently (it
/// also backs playback/waveform), so a damaged-but-playable plain WAV
/// probes as usable — but when the lenient recovery had to drop a
/// chunk that announced itself as ADM metadata (`metadata_dropped`),
/// this returns true so the file goes to the strict ADM import path,
/// which re-parses it and produces an honest damage error instead of
/// silently importing an ADM master as plain audio.
Future<bool> wavHasAdmMetadata(String path) async {
  try {
    final info = await WavDecoder.probeRaw(path);
    if (info['metadata_dropped'] == true) {
      Log.w(
        LogCat.app,
        'ADM sniff: $path lost ADM metadata to damage — routing to the '
        'strict ADM import for a real error',
      );
      return true;
    }
    return ((info['axml_bytes'] as int?) ?? 0) > 0;
  } on FileSystemException catch (e) {
    Log.d(LogCat.app, 'ADM sniff failed for $path: $e');
    return false;
  } on FormatException catch (e) {
    Log.d(LogCat.app, 'ADM sniff rejected $path: $e');
    return false;
  }
}
