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
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

/// The encoder-safe bounding box for a still-export video frame.
/// 3840×2160 stays comfortably inside every H.264 hardware encoder's
/// limits (VideoToolbox and Media Foundation both cap near 4096); larger
/// stills are downscaled into this box before encoding.
const int kStillExportMaxWidth = 3840;
const int kStillExportMaxHeight = 2160;

/// Frame rate for the rendered still video. Nothing moves, so the rate
/// only sets container timing granularity — 5 fps keeps a session-length
/// encode to a few thousand identical (near-empty) frames while staying
/// well-behaved in players and on YouTube.
const int kStillExportFps = 5;

/// Duration floor for the rendered still video: one frame at
/// [kStillExportFps]. Applied when the exported audio is degenerately
/// short so the encoder always has something to emit.
const double kStillExportMinDurationSeconds = 1 / kStillExportFps;

/// Video dimensions for a [srcWidth]×[srcHeight] still: fitted inside
/// [kStillExportMaxWidth]×[kStillExportMaxHeight] preserving aspect,
/// floored to even (H.264 4:2:0), minimum 2×2. Pure — unit-tested
/// separately from the dart:ui rendering below. Mirrored by `fitDims`
/// in tool/still_matrix.dart (which cannot import dart:ui) — keep the
/// two in sync when changing the policy.
({int width, int height}) stillExportDimensions(int srcWidth, int srcHeight) {
  assert(srcWidth > 0 && srcHeight > 0);
  var w = srcWidth.toDouble();
  var h = srcHeight.toDouble();
  final scale = [
    1.0,
    kStillExportMaxWidth / w,
    kStillExportMaxHeight / h,
  ].reduce((a, b) => a < b ? a : b);
  w *= scale;
  h *= scale;
  int even(double v) {
    final floored = v.floor() & ~1;
    return floored < 2 ? 2 : floored;
  }

  return (width: even(w), height: even(h));
}

/// Result of [renderStillExportFrame]: tightly packed RGBA8888 pixels of
/// the (possibly downscaled) still, ready for
/// `runStillVideoEncodeOnIsolate`.
class StillExportFrame {
  const StillExportFrame({
    required this.rgba,
    required this.width,
    required this.height,
  });

  final Uint8List rgba;
  final int width;
  final int height;
}

/// Decode the still image at [path] (first frame — same freeze semantics
/// as [StillImageBackend]) and rasterize it to encoder-safe dimensions.
/// Any transparency is flattened onto black, matching the video pane's
/// letterbox fill. Returns null when the file cannot be decoded — the
/// caller surfaces its own error message.
///
/// Main-isolate only: uses dart:ui codecs and rasterization.
Future<StillExportFrame?> renderStillExportFrame(String path) async {
  final ui.Image image;
  try {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      // getNextFrame can throw on truncated frame data even when the
      // header decoded — the finally keeps the native codec from leaking.
      final frame = await codec.getNextFrame();
      image = frame.image;
    } finally {
      codec.dispose();
    }
  } on Object {
    return null;
  }
  try {
    final dims = stillExportDimensions(image.width, image.height);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, dims.width.toDouble(), dims.height.toDouble()),
      Paint()..color = const ui.Color(0xFF000000),
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, dims.width.toDouble(), dims.height.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final ui.Image scaled;
    try {
      scaled = await picture.toImage(dims.width, dims.height);
    } finally {
      picture.dispose();
    }
    try {
      final data = await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return StillExportFrame(
        rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: dims.width,
        height: dims.height,
      );
    } finally {
      scaled.dispose();
    }
  } finally {
    image.dispose();
  }
}
