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

// Local test harness (not shipped in the app): drives the engine's
// still→video encode (`eclipsa_studio_still_video_encode`) + IAMF mux
// (`eclipsa_studio_iamf_mux`) over a directory of images and verifies each
// output MP4 with ffprobe/MP4Box. Needs ffmpeg + gpac on PATH and a
// built engine (`./build.sh engine`).
//
// Usage: cd app && dart run tool/still_matrix.dart <images_dir> <out_dir>
// ignore_for_file: avoid_print

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi_pkg;

typedef _EncodeNative =
    Int32 Function(
      Pointer<Uint8>,
      Uint64,
      Uint32,
      Uint32,
      Uint32,
      Double,
      Pointer<ffi_pkg.Utf8>,
    );
typedef _EncodeDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      int,
      int,
      double,
      Pointer<ffi_pkg.Utf8>,
    );
typedef _MuxNative =
    Int32 Function(
      Pointer<ffi_pkg.Utf8>,
      Pointer<ffi_pkg.Utf8>,
      Pointer<ffi_pkg.Utf8>,
    );
typedef _MuxDart =
    int Function(
      Pointer<ffi_pkg.Utf8>,
      Pointer<ffi_pkg.Utf8>,
      Pointer<ffi_pkg.Utf8>,
    );

const maxW = 3840, maxH = 2160;

// Mirrors `stillExportDimensions` in lib/export/still_export_frame.dart —
// duplicated because that file pulls in dart:ui, which a plain `dart run`
// harness cannot load. Keep the two in sync when changing the policy.
({int width, int height}) fitDims(int w, int h) {
  final scale = [1.0, maxW / w, maxH / h].reduce((a, b) => a < b ? a : b);
  int even(double v) {
    final f = v.floor() & ~1;
    return f < 2 ? 2 : f;
  }

  return (width: even(w * scale), height: even(h * scale));
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('usage: dart run tool/still_matrix.dart <images_dir> <out_dir>');
    exitCode = 64;
    return;
  }
  final imagesDir = args[0];
  final outDir = args[1];
  const dylib = '../engine/bazel-bin/libeclipsa_studio_engine.dylib';
  const fixtureIamf = '../engine/test/fixtures/sine_128samp_7_1_pcm.iamf';
  Directory(outDir).createSync(recursive: true);

  final lib = DynamicLibrary.open(dylib);
  final encode = lib.lookupFunction<_EncodeNative, _EncodeDart>(
    'eclipsa_studio_still_video_encode',
  );
  final mux = lib.lookupFunction<_MuxNative, _MuxDart>(
    'eclipsa_studio_iamf_mux',
  );

  final images =
      Directory(imagesDir)
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith('.tiff'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final results = <String>[];
  for (final img in images) {
    final name = img.uri.pathSegments.last;
    final stem = name.replaceAll(RegExp(r'\.[^.]+$'), '');

    // Probe dimensions.
    final probe = Process.runSync('ffprobe', [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=width,height',
      '-of',
      'csv=p=0',
      img.path,
    ]);
    final dims = (probe.stdout as String).trim().split(',');
    if (probe.exitCode != 0 || dims.length < 2) {
      results.add('$name: DECODE FAILED (expected for corrupt) ✗→✓');
      continue;
    }
    final fitted = fitDims(int.parse(dims[0]), int.parse(dims[1]));

    // Decode first frame to raw RGBA at target size.
    final dec = Process.runSync('ffmpeg', [
      '-v',
      'error',
      '-i',
      img.path,
      '-frames:v',
      '1',
      '-vf',
      'scale=${fitted.width}:${fitted.height}',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'rgba',
      '-',
    ], stdoutEncoding: null);
    if (dec.exitCode != 0) {
      results.add('$name: RGBA DECODE FAILED');
      continue;
    }
    final rgba = Uint8List.fromList(dec.stdout as List<int>);

    // Engine encode: 12 s @ 5 fps.
    final stillMp4 = '$outDir/$stem.video.mp4';
    final finalMp4 = '$outDir/$stem.iamf.mp4';
    final px = ffi_pkg.malloc.allocate<Uint8>(rgba.length);
    px.asTypedList(rgba.length).setAll(0, rgba);
    final outPtr = stillMp4.toNativeUtf8(allocator: ffi_pkg.malloc);
    final encRc = encode(
      px,
      rgba.length,
      fitted.width,
      fitted.height,
      5,
      12.0,
      outPtr,
    );
    ffi_pkg.malloc.free(px);
    ffi_pkg.malloc.free(outPtr);
    if (encRc != 0) {
      results.add('$name: ENCODE rc=$encRc');
      continue;
    }

    // Mux with the fixture IAMF.
    final a = fixtureIamf.toNativeUtf8(allocator: ffi_pkg.malloc);
    final v = stillMp4.toNativeUtf8(allocator: ffi_pkg.malloc);
    final o = finalMp4.toNativeUtf8(allocator: ffi_pkg.malloc);
    final muxRc = mux(a, v, o);
    ffi_pkg.malloc.free(a);
    ffi_pkg.malloc.free(v);
    ffi_pkg.malloc.free(o);
    if (muxRc != 0) {
      results.add('$name: MUX rc=$muxRc');
      continue;
    }

    // Verify: expect 2 tracks (iamf audio + h264 video) and h264 stream.
    final info = Process.runSync('MP4Box', ['-info', finalMp4]);
    final infoText = '${info.stdout}${info.stderr}';
    final tracks = RegExp('Track #').allMatches(infoText).length;
    final h264 = Process.runSync('ffprobe', [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=codec_name,width,height,duration',
      '-of',
      'csv=p=0',
      finalMp4,
    ]);
    final vinfo = (h264.stdout as String).trim();
    File(stillMp4).deleteSync(); // keep only the muxed result
    results.add(
      '$name: OK ${fitted.width}x${fitted.height} tracks=$tracks '
      'video=[$vinfo]',
    );
  }

  print('\n=== Still→MP4+IAMF matrix ===');
  results.forEach(print);
}
