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
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../ffi_bridge.dart';
import '../logging/log.dart';

/// Metadata parsed from a WAV file header.
class WavInfo {
  final int channels;
  final int sampleRate;
  final int bitsPerSample;
  final int audioFormat; // 1=PCM, 3=IEEE float
  final int dataOffset;
  final int dataSize;
  final int totalSamples; // per channel

  const WavInfo({
    required this.channels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.audioFormat,
    required this.dataOffset,
    required this.dataSize,
    required this.totalSamples,
  });

  double get durationSeconds => totalSamples / sampleRate;
}

typedef _ProbeNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ProbeDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// Probes WAV file headers through the engine's shared parser
/// (`eclipsa_studio_wav_probe_json` over engine/wav), so a file the UI accepts
/// is exactly a file the engine will open: RIFF/RF64/BW64, PCM 8/16/24/32 and
/// float32/64, up to 32 channels — one acceptance matrix, no drift.
class WavDecoder {
  WavDecoder._();

  /// Test hook: returns the probe's JSON for a path instead of calling
  /// into the engine (flutter tests run outside the app bundle, where the
  /// engine dylib's @rpath companions cannot resolve). The byte-level
  /// acceptance matrix is pinned engine-side in wav_probe_ffi_test.cc.
  static String Function(String path)? probeForTesting;

  static _ProbeDart? _probe;
  static _FreeDart? _free;

  static void _bind() {
    if (_probe != null) return;
    final lib = DynamicLibrary.open(EclipsaStudioEngine.dylibPath);
    _probe = lib.lookupFunction<_ProbeNative, _ProbeDart>(
      'eclipsa_studio_wav_probe_json',
    );
    _free = lib.lookupFunction<_FreeNative, _FreeDart>(
      'eclipsa_studio_string_free',
    );
  }

  /// Raw probe result as decoded JSON (all fields from
  /// `eclipsa_studio_wav_probe_json`, e.g. `axml_bytes` for the ADM sniff).
  ///
  /// The native probe is a blocking call (file open + chunk walk), so it
  /// runs on a helper isolate — batch imports and session reloads must not
  /// stall the UI isolate on slow storage (same pattern as
  /// `AdmImportBridge.probeJsonAsync`). The closure captures only `path`;
  /// the helper isolate re-binds the dylib itself.
  ///
  /// Throws [FileSystemException] when the file cannot be opened and
  /// [FormatException] when the parser rejects it.
  static Future<Map<String, dynamic>> probeRaw(String path) async {
    final raw = probeForTesting != null
        ? probeForTesting!(path)
        : await Isolate.run(() => _probeNative(path));
    final json = jsonDecode(raw) as Map<String, dynamic>;
    if (json['ok'] != true) {
      final error = (json['error'] as String?) ?? 'unknown error';
      if (error.startsWith('Cannot open')) {
        throw FileSystemException(error, path);
      }
      throw FormatException(error);
    }
    if (json['recovered'] == true) {
      // The lenient parser salvaged a damaged file (truncated payload,
      // malformed tail). It plays/draws with what's readable, but a
      // strict consumer (IAMF export, ADM import) will reject it — the
      // trace matters when that later error looks unrelated.
      Log.w(
        LogCat.audio,
        'Damaged WAV recovered by the lenient parser '
        '(${json['num_frames']} frames readable): $path',
      );
    }
    return json;
  }

  static String _probeNative(String path) {
    _bind();
    final cPath = path.toNativeUtf8();
    Pointer<Utf8> res = nullptr;
    try {
      res = _probe!(cPath);
      if (res == nullptr) {
        throw const FormatException('WAV probe failed (out of memory)');
      }
      return res.toDartString();
    } finally {
      malloc.free(cPath);
      if (res != nullptr) _free!(res);
    }
  }

  /// Parse WAV header from a file path. Does not read sample data.
  ///
  /// Throws [FileSystemException] when the file cannot be opened and
  /// [FormatException] when the parser rejects it (unsupported encoding,
  /// malformed or truncated file — the engine fails closed, so a file
  /// rejected here would not play either).
  static Future<WavInfo> readInfo(String path) async {
    final json = await probeRaw(path);
    final channels = json['channels'] as int;
    // The engine's playback path (io/WavReader) caps at 32 channels;
    // fail here with a clear error instead of downstream at open.
    if (channels < 1 || channels > 32) {
      throw FormatException(
        'Unsupported channel count: $channels (1–32 supported)',
      );
    }
    return WavInfo(
      channels: channels,
      sampleRate: json['sample_rate'] as int,
      bitsPerSample: json['bits_per_sample'] as int,
      audioFormat: (json['is_float'] as bool) ? 3 : 1,
      dataOffset: json['data_offset'] as int,
      dataSize: json['data_size'] as int,
      totalSamples: json['num_frames'] as int,
    );
  }
}
