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
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../logging/log.dart';
import 'video_backend.dart';

/// File extensions accepted as still images (ES-192) — exactly the formats
/// Flutter's bundled codecs decode on both desktop platforms. HEIC/TIFF
/// would need an image-decoding plugin and are deliberately out.
const Set<String> kStillImageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.bmp',
  '.gif',
};

/// Whether [path] names a still image (by extension, case-insensitive).
bool isStillImagePath(String path) =>
    kStillImageExtensions.contains(p.extension(path).toLowerCase());

/// Displays a user-supplied still image in the video slot (ES-192).
///
/// The degenerate [VideoBackend]: [loadFile] decodes the image once and
/// [buildSurface] shows it letterboxed; every transport method is a no-op,
/// so play/pause/seek/loop leave the picture untouched and nothing upstream
/// ([VideoNotifier], `VideoTransportSync`, the tick loop, the pop-out
/// window) needs to special-case images. [VideoMeta] carries only the pixel
/// dimensions — the null duration keeps the image out of the timeline
/// reconcile and hides the video track's duration bar.
class StillImageBackend extends VideoBackend {
  ui.Image? _image;
  VideoMeta _meta = VideoMeta.empty;
  bool _shutDown = false;

  @override
  VideoMeta get meta => _meta;

  @override
  Future<String?> loadFile(String path) async {
    final name = p.basename(path);
    final ui.FrameInfo frame;
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        // First frame only: an animated GIF/WebP is deliberately frozen —
        // free-running motion beside a transport-synced timeline reads as
        // a sync bug. getNextFrame can throw on truncated frame data even
        // when the header decoded — the finally keeps the native codec
        // from leaking.
        frame = await codec.getNextFrame();
      } finally {
        codec.dispose();
      }
    } on Object catch (e) {
      Log.w(LogCat.video, 'still image load failed: $name', e);
      return 'Could not load image "$name". The file is missing, '
          'unreadable, or not a supported image.';
    }
    if (_shutDown) {
      frame.image.dispose();
      return 'Image display is shutting down.';
    }
    _retire(_image);
    _image = frame.image;
    _meta = VideoMeta(width: frame.image.width, height: frame.image.height);
    Log.i(
      LogCat.video,
      'still image loaded: $name ${_meta.width}×${_meta.height}',
    );
    onMetaChanged?.call(_meta);
    return null;
  }

  @override
  Future<void> unload() async {
    _retire(_image);
    _image = null;
    _meta = VideoMeta.empty;
  }

  // The transport has no meaning for a still: the picture simply stays on
  // screen across play/pause/seek/loop while the audio runs underneath.

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(double seconds) async {}

  @override
  Future<void> syncToAudio(
    double audioSeconds, {
    required bool playing,
  }) async {}

  @override
  Widget buildSurface(
    BuildContext context, {
    Color fill = const Color(0xFF000000),
  }) {
    final image = _image;
    return ColoredBox(
      color: fill,
      child: image == null
          ? const SizedBox.expand()
          : SizedBox.expand(
              child: RawImage(image: image, fit: BoxFit.contain),
            ),
    );
  }

  @override
  Future<void> shutdown() async {
    _shutDown = true;
    await unload();
  }

  /// Dispose a replaced/unloaded image on the next frame, not immediately:
  /// a [RawImage] built from it may still be in the tree until the state
  /// change that follows rebuilds the surface, and painting a disposed
  /// `ui.Image` is a contract violation. (At process exit the callback may
  /// never run — a one-image leak the OS reclaims.)
  void _retire(ui.Image? old) {
    if (old == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }
}
