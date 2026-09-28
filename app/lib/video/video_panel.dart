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

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../playback/playback_session.dart';
import '../state.dart'
    show importNoticeProvider, lastVideoImportDirProvider, themeModeProvider;
import '../theme.dart' show T;
import '../widgets/drop_zone.dart';
import '../widgets/resize_handle.dart';
import '../workspace/workspace_mode.dart';
import 'still_image_backend.dart' show kStillImageExtensions;
import 'video_provider.dart';
import 'video_strip.dart';

/// Video preview panel that displays in the timeline area.
///
/// Holds one media item: a video, or a still image shown statically while
/// the transport runs underneath (ES-192) — loading one replaces the other.
///
/// Supports:
/// - Drag-and-drop video / image files
/// - File picker via button
/// - Resize by dragging the bottom edge
/// - Pop out to a separate window (double-click or the toolbar button)
/// - Collapse/expand
class VideoPanel extends ConsumerStatefulWidget {
  /// Initial height of the strip, in every theme: the 200 px of
  /// picture it drew before the header moved over it, plus the 24 px
  /// row the header used to take (ES-683).
  final double initialHeight;

  const VideoPanel({super.key, this.initialHeight = 224});

  @override
  ConsumerState<VideoPanel> createState() => _VideoPanelState();
}

class _VideoPanelState extends ConsumerState<VideoPanel> {
  /// The user's resize, or null for the layout's default. Nullable so
  /// a live theme switch between the flat and the beveled/raised
  /// layouts, whose defaults differ (224 against 256), takes effect
  /// until the user drags the handle; a value snapshotted in initState
  /// would not.
  double? _height;

  bool _hovering = false;

  static const _minHeight = 100.0;
  static const _maxHeight = 600.0;
  static const _videoExtensions = {
    '.mp4',
    '.mov',
    '.mkv',
    '.avi',
    '.webm',
    '.m4v',
    '.mxf',
  };

  /// Everything the pane accepts: videos plus still images (ES-192).
  static const _mediaExtensions = {
    ..._videoExtensions,
    ...kStillImageExtensions,
  };

  /// The header lies over the picture in every layout, so this is the
  /// whole strip's height, and [_minHeight] and [_maxHeight] clamp the
  /// strip.
  ///
  /// One height in every theme, so switching theme does not resize the
  /// picture; a component's size is the app's, not the theme's.
  double get _effectiveHeight => _height ?? widget.initialHeight;

  bool _isMediaFile(String path) {
    final ext = p.extension(path).toLowerCase();
    return _mediaExtensions.contains(ext);
  }

  Future<void> _onDragDone(DropDoneDetails details) async {
    setState(() => _hovering = false);
    final mediaFiles = details.files
        .where((f) => _isMediaFile(f.path))
        .toList();
    final rejected = details.files.length - mediaFiles.length;

    if (mediaFiles.isEmpty) {
      // Nothing importable in the drop — blocker (ES-184).
      final what = rejected == 1
          ? 'The dropped file is not a supported video or image file'
          : 'None of the dropped files are supported video or image files';
      ref
          .read(importNoticeProvider.notifier)
          .showBlocker(
            '$what \u2014 nothing was imported.\n\n'
            'Supported formats: '
            '${_mediaExtensions.map((e) => e.substring(1)).join(', ')}.',
          );
      return;
    }

    ref
        .read(lastVideoImportDirProvider.notifier)
        .set(p.dirname(mediaFiles.first.path));
    final err = await ref
        .read(videoProvider.notifier)
        .loadFile(mediaFiles.first.path);
    final fyis = <String>[];
    if (mediaFiles.length > 1) {
      final extras = mediaFiles.length - 1;
      fyis.add(
        extras == 1
            ? '1 extra file ignored \u2014 only one can be loaded'
            : '$extras extra files ignored \u2014 only one can be '
                  'loaded',
      );
    }
    if (rejected > 0) {
      fyis.add(
        rejected == 1
            ? '1 unsupported file ignored'
            : '$rejected unsupported files ignored',
      );
    }
    final notifier = ref.read(importNoticeProvider.notifier);
    if (err != null) {
      // The video load itself failed — nothing was imported, so
      // escalate to a blocker dialog (ES-184), with the failure as the
      // lead paragraph and any FYIs kept apart from it.
      var message = err;
      if (fyis.isNotEmpty) {
        message += '\n\nAlso: ${fyis.join(' \u00B7 ')}.';
      }
      notifier.showBlocker(message);
    } else if (fyis.isNotEmpty) {
      notifier.show(fyis.join(' \u00B7 '));
    }
  }

  Future<void> _pickFile() async {
    final hasVideo = ref.read(videoProvider).hasVideo;
    final initialDir = ref.read(lastVideoImportDirProvider);
    final result = await FilePicker.pickFiles(
      dialogTitle: hasVideo
          ? 'Select a video or image to replace the current one'
          : 'Select a video or image file',
      type: FileType.custom,
      allowedExtensions: _mediaExtensions.map((e) => e.substring(1)).toList(),
      initialDirectory: initialDir,
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    ref.read(lastVideoImportDirProvider.notifier).set(p.dirname(path));
    final err = await ref.read(videoProvider.notifier).loadFile(path);
    if (err != null) {
      // The picked video failed to load — blocker (ES-184).
      ref.read(importNoticeProvider.notifier).showBlocker(err);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    final videoState = ref.watch(videoProvider);

    // When not inline (popped out), the picture lives in the separate
    // pop-out window — hide this panel entirely.
    if (!videoState.isInline) {
      return const SizedBox.shrink();
    }

    // Playback (QC) mode: only show the panel when the opened file
    // is an .mp4 container — bare .iamf carries no video, so the
    // drop zone / pick button would have nothing to attach to.
    final mode = ref.watch(workspaceModeProvider);
    if (mode == WorkspaceMode.playback) {
      final qcPath = ref.watch(playbackSessionProvider)?.path;
      final ext = qcPath != null ? p.extension(qcPath).toLowerCase() : '';
      if (ext != '.mp4') {
        return const SizedBox.shrink();
      }
    }

    // In Playback (QC) mode the video is the MP4's own picture track —
    // intrinsic to the file being analysed, not a separately-attached
    // asset. Hide every attach/detach affordance (Remove ✕, Open 📂,
    // drag-to-replace); only the view controls remain (ES-237).
    final isQc = mode == WorkspaceMode.playback;

    final notifier = ref.read(videoProvider.notifier);
    final fileName = videoState.filePath != null
        ? p.basename(videoState.filePath!)
        : null;
    final visible = videoState.visible;

    final actions = <VideoStripAction>[
      if (videoState.hasVideo && visible) ...[
        VideoStripAction(
          icon: Icons.open_in_new,
          onTap: () => notifier.enterPopOut(),
          tooltip: 'Pop out to a separate window',
        ),
        // An expand control sits beside the pop-out. There is no inline
        // fullscreen -- VideoMode is inline or popOut -- so this pops
        // out already fullscreened, which is the state it names.
        VideoStripAction(
          icon: Icons.fullscreen,
          onTap: () => notifier.enterPopOut(fullscreen: true),
          tooltip: 'Pop out fullscreen',
          gapBefore: 2,
        ),
        if (!isQc)
          VideoStripAction(
            icon: Icons.close,
            onTap: () => notifier.unload(),
            tooltip: videoState.isStillImage ? 'Remove image' : 'Remove video',
            gapBefore: 2,
          ),
      ] else if (!videoState.hasVideo && !isQc)
        VideoStripAction(
          icon: Icons.folder_open,
          onTap: _pickFile,
          tooltip: 'Open video or image file',
        ),
      VideoStripAction(
        icon: visible ? Icons.expand_less : Icons.expand_more,
        onTap: () => notifier.toggleVisible(),
        tooltip: visible ? 'Collapse video' : 'Expand video',
        gapBefore: videoState.hasVideo && visible ? 4 : 0,
      ),
    ];

    // QC video is read-only (see above): show the picture with no drop
    // target, so a stray file drop can't replace the MP4's own track.
    // Creator mode keeps the full attach/replace flow.
    final Widget body = isQc
        ? (videoState.hasVideo
              ? const _VideoDisplay()
              : ColoredBox(color: T.videoBg))
        : DropTarget(
            onDragEntered: (_) => setState(() => _hovering = true),
            onDragExited: (_) => setState(() => _hovering = false),
            onDragDone: _onDragDone,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (videoState.hasVideo)
                  const _VideoDisplay()
                else
                  VideoEmptyBody(
                    dragOver: _hovering,
                    onTap: _pickFile,
                    primaryLabel: _hovering
                        ? 'Drop video or image'
                        : 'Drop video or image, or click to browse',
                    secondaryLabel:
                        'MP4 \u00B7 MOV \u00B7 '
                        'MKV \u00B7 AVI \u00B7 '
                        'WebM \u00B7 PNG \u00B7 '
                        'JPG \u00B7 WebP \u00B7 '
                        'GIF',
                  ),
                if (videoState.hasVideo && _hovering)
                  const Positioned.fill(
                    child: DropZone(
                      variant: DropZoneVariant.overlay,
                      icon: Icons.video_file_outlined,
                      primaryLabel: 'Drop to replace',
                      isDragOver: true,
                    ),
                  ),
              ],
            ),
          );

    final strip = VideoStrip(
      height: _effectiveHeight,
      fileName: fileName,
      hasMedia: videoState.hasVideo,
      isStillImage: videoState.isStillImage,
      visible: visible,
      actions: actions,
      body: body,
    );
    // Collapsed, the header is the strip and there is nothing to drag.
    if (!visible) return strip;
    // Expanded, the strip ends in a hairline, the border the handle
    // moves. The handle lies over the bottom of the picture with its
    // lower edge on that line, so the view below keeps all of its
    // pointer input (ES-748).
    return Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            strip,
            Container(height: 0.5, color: T.border),
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ResizeHandle(
            axis: Axis.vertical,
            onDragUpdate: (dy) {
              setState(() {
                _height = (_effectiveHeight + dy).clamp(_minHeight, _maxHeight);
              });
            },
          ),
        ),
      ],
    );
  }
}

class _VideoDisplay extends ConsumerWidget {
  const _VideoDisplay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    // Rebuild when the video state changes so [buildSurface] is re-invoked
    // after a backend swap. This widget is `const`-constructed upstream and
    // the native backends' surfaces are bare `Texture(textureId:)`s captured
    // at build time (unlike FFmpeg-in-engine, which is internally reactive),
    // so without this watch a switch would leave the panel on the old, now-
    // unregistered texture — a black picture (the const-skip pattern).
    ref.watch(videoProvider);
    final notifier = ref.read(videoProvider.notifier);
    final fill = T.bgDeep;
    return GestureDetector(
      // Double-tap the inline picture to pop the video out into its own
      // window (the pop-out is the path to fullscreen video).
      onDoubleTap: () => notifier.enterPopOut(),
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(
        color: fill,
        child: notifier.buildSurface(context, fill: fill),
      ),
    );
  }
}
