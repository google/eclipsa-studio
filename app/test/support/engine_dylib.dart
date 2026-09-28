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

// Shared setup for tests that drive the REAL engine dylib through the
// app's own code paths, rather than a fake.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:eclipsa_studio/ffi_bridge.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// The built engine library, or null when it has not been built (CI
/// builds it before `flutter test`; run `./build.sh engine` locally).
File? engineDylibFile() {
  final name = Platform.isMacOS
      ? 'libeclipsa_studio_engine.dylib'
      : Platform.isWindows
      ? 'eclipsa_studio_engine.dll'
      : 'libeclipsa_studio_engine.so';
  final file = File('../engine/build/$name').absolute;
  return file.existsSync() ? file : null;
}

/// [engineDylibFile], or null after marking the test skipped when the
/// library is not built. On CI (GitHub Actions sets `CI=true`) a missing
/// library fails the test instead, so a change to the build step cannot
/// turn every engine-backed test into a silent skip.
File? engineDylibOrSkip() {
  final dylib = engineDylibFile();
  if (dylib != null) return dylib;
  if (Platform.environment['CI'] == 'true') {
    fail('engine dylib not built on CI (./build.sh engine runs first)');
  }
  markTestSkipped('engine dylib not built (run ./build.sh engine)');
  return null;
}

/// Points [EclipsaStudioEngine] at [dylib] and makes it loadable from a test
/// process. Call from inside a test body — it registers its own
/// teardowns.
///
/// The engine links libgpac + FFmpeg via `@rpath`, resolved through the
/// app bundle's Frameworks dir in production. The test process has no
/// such rpath, so each companion is pre-loaded by absolute path — dyld
/// then satisfies the engine's install-name deps from the already-loaded
/// images (the same trick `_loadLibrary` uses for libgpac.dll on
/// Windows). Dependency order matters: the companions reference each
/// other by `@rpath` too.
///
/// [WavDecoder] probes are routed through the real parser bound
/// in-process as well: the probe otherwise runs on a worker isolate that
/// re-resolves the dylib path, which the static override does not cross.
void useEngineDylib(File dylib) {
  EclipsaStudioEngine.dylibPathOverride = dylib.path;
  addTearDown(() => EclipsaStudioEngine.dylibPathOverride = null);

  for (final companion in const [
    '../engine/deps/ffmpeg/lib/libavutil.dylib',
    '../engine/deps/ffmpeg/lib/libswresample.dylib',
    '../engine/deps/ffmpeg/lib/libswscale.dylib',
    '../engine/deps/ffmpeg/lib/libdav1d.dylib',
    '../engine/deps/ffmpeg/lib/libavcodec.dylib',
    '../engine/deps/ffmpeg/lib/libavformat.dylib',
    '../engine/deps/gpac/lib/libgpac.dylib',
  ]) {
    final file = File(companion);
    if (file.existsSync()) DynamicLibrary.open(file.absolute.path);
  }

  final lib = DynamicLibrary.open(dylib.path);
  final probe = lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>)
      >('eclipsa_studio_wav_probe_json');
  final free = lib
      .lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('eclipsa_studio_string_free');
  WavDecoder.probeForTesting = (path) {
    final cPath = path.toNativeUtf8();
    try {
      final res = probe(cPath);
      final json = res.toDartString();
      free(res);
      return json;
    } finally {
      malloc.free(cPath);
    }
  };
  addTearDown(() => WavDecoder.probeForTesting = null);
}

/// Minimal PCM16 WAV: 44-byte canonical header + silence.
Uint8List wavBytes({int channels = 1, int rate = 48000, int frames = 4800}) {
  final dataSize = frames * channels * 2;
  final b = BytesBuilder();
  void str(String s) => b.add(s.codeUnits);
  void u32(int v) =>
      b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) =>
      b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
  str('RIFF');
  u32(36 + dataSize);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1); // PCM
  u16(channels);
  u32(rate);
  u32(rate * channels * 2); // byte rate
  u16(channels * 2); // block align
  u16(16); // bits
  str('data');
  u32(dataSize);
  b.add(Uint8List(dataSize));
  return b.toBytes();
}
