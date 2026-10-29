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

import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../logging/log.dart';
import '../meters/meter_provider.dart' show eclipsaStudioEngineProvider;
import '../state.dart';
import '../theme.dart';
import '../workspace/workspace_mode.dart'
    show WorkspaceMode, workspaceModeProvider;
import 'popout_appearance.dart';
import 'still_image_backend.dart' show isStillImagePath;
import 'video_backend.dart';
import 'video_backend_factory.dart';
import 'video_backend_kind.dart';
import 'video_popout_app.dart';

/// The video layout modes (orthogonal to native macOS fullscreen).
///
/// Video fullscreen is reached only by popping out and fullscreening that
/// window (see [VideoNotifier.enterPopOut]). The main window's own fullscreen
/// is the normal app fullscreen (green button / Cmd+Ctrl+F), which keeps the
/// video inline.
///
/// - [inline] → video panel sits in the timeline area
/// - [popOut] → video plays in a separate window (which can be fullscreened,
///   including directly onto an external display)
enum VideoMode {
  /// Video panel sits inline in the timeline area.
  inline,

  /// Video is displayed in a separate pop-out window.
  popOut,
}

/// State for the video track.
class VideoState {
  /// Path to the loaded media — a video file or a still image (ES-192) —
  /// or null if nothing is loaded.
  final String? filePath;

  /// Whether the video panel is visible (only relevant in [VideoMode.inline]).
  final bool visible;

  /// Current video layout mode.
  final VideoMode mode;

  /// Duration of the loaded video, resolved asynchronously by the backend.
  final Duration? duration;

  /// Video resolution (width × height), resolved asynchronously.
  final int? videoWidth;
  final int? videoHeight;

  /// Video frame rate, resolved asynchronously.
  final double? fps;

  // The inspector metadata below (ES-462) resolves asynchronously and is
  // null where the active backend doesn't report it (the FFmpeg-in-engine
  // fallback reports none of these).

  /// Container (presentation) duration — exceeds [duration] on a muxed
  /// master whose audio outlasts the picture (ES-459).
  final Duration? containerDuration;

  /// Codec display name with the raw fourcc, e.g. `HEVC (hvc1)`.
  final String? codec;

  /// Average bit rate of the video track, bits per second.
  final int? bitRateBps;

  /// Color transfer/primaries display string, e.g. `PQ (HDR10) · BT.2020`.
  final String? colorInfo;

  const VideoState({
    this.filePath,
    this.visible = true,
    this.mode = VideoMode.inline,
    this.duration,
    this.videoWidth,
    this.videoHeight,
    this.fps,
    this.containerDuration,
    this.codec,
    this.bitRateBps,
    this.colorInfo,
  });

  bool get hasVideo => filePath != null;

  /// Whether the loaded media is a still image rather than a video (ES-192).
  bool get isStillImage => filePath != null && isStillImagePath(filePath!);

  bool get isInline => mode == VideoMode.inline;
  bool get isPoppedOut => mode == VideoMode.popOut;

  VideoState copyWith({
    String? filePath,
    bool? visible,
    VideoMode? mode,
    Duration? duration,
    int? videoWidth,
    int? videoHeight,
    double? fps,
    Duration? containerDuration,
    String? codec,
    int? bitRateBps,
    String? colorInfo,
    bool clearFile = false,
    bool clearDuration = false,
    bool clearMedia = false,
  }) {
    return VideoState(
      filePath: clearFile ? null : (filePath ?? this.filePath),
      visible: visible ?? this.visible,
      mode: mode ?? this.mode,
      duration: clearDuration ? null : (duration ?? this.duration),
      videoWidth: clearMedia ? null : (videoWidth ?? this.videoWidth),
      videoHeight: clearMedia ? null : (videoHeight ?? this.videoHeight),
      fps: clearMedia ? null : (fps ?? this.fps),
      containerDuration: clearDuration
          ? null
          : (containerDuration ?? this.containerDuration),
      codec: clearMedia ? null : (codec ?? this.codec),
      bitRateBps: clearMedia ? null : (bitRateBps ?? this.bitRateBps),
      colorInfo: clearMedia ? null : (colorInfo ?? this.colorInfo),
    );
  }
}

/// Channel for sending transport commands to the pop-out window.
const _popoutChannel = WindowMethodChannel('eclipsa/video_popout');

/// Manages video track state, backend lifecycle, and transport sync.
///
/// This is a thin, backend-agnostic coordinator (issue ES-249): it owns the
/// *selected* [VideoBackend], forwards transport to it, mirrors the backend's
/// async metadata into [VideoState], and manages the inline / fullscreen /
/// pop-out layout. All decoder-specific work lives in the backend.
class VideoNotifier extends Notifier<VideoState> {
  /// The active playback backend. Reused across files; swapped when the
  /// selected backend changes — immediately if a clip is loaded (the live
  /// reload below), otherwise on the next [loadFile].
  late VideoBackend _backend;

  /// The concrete kind currently instantiated as [_backend].
  late VideoBackendKind _activeKind;

  WindowController? _popoutWindow;

  /// Whether the pop-out has opened its file and asked for the playhead.
  /// Set by its first 'requestSync' and cleared when it closes;
  /// [_sendToPopout] drops everything but 'close' and 'appearance' until
  /// then (ES-786).
  bool _popoutReady = false;

  /// Guards [shutdown] so it runs once — it is invoked both from
  /// `ref.onDispose` and from the app's exit handler.
  bool _shutDown = false;

  /// True while a backend-switch reload is running, and whether another
  /// switch landed mid-reload. Together they coalesce rapid back-to-back
  /// switches into sequential reloads (no overlapping load/teardown).
  bool _switchReloading = false;
  bool _switchPending = false;

  @override
  VideoState build() {
    _instantiateBackend(_resolveKind());
    // Live-apply a backend change: when the user picks a different backend
    // in Settings while a clip is loaded, reload it on the new backend at
    // the current playhead so the picture follows the selection immediately.
    ref.listen<VideoBackendKind>(
      videoBackendProvider,
      (_, _) => _onBackendSelectionChanged(),
    );
    // The pop-out runs its own engine with its own T; a theme or font
    // change here reaches it by message (ES-744). These fire on a change
    // only, never per tick.
    ref.listen<AppThemeMode>(themeModeProvider, (_, _) => _sendAppearance());
    ref.listen<FontSizeMode>(fontSizeModeProvider, (_, _) => _sendAppearance());
    ref.onDispose(shutdown);
    return const VideoState();
  }

  /// Tells the pop-out the current theme and font size. No-op without a
  /// pop-out.
  void _sendAppearance() {
    if (_popoutWindow == null) return;
    _sendToPopout(
      appearanceMethod,
      encodeAppearance(
        ref.read(themeModeProvider),
        ref.read(fontSizeModeProvider),
      ),
    );
  }

  /// Reload the current clip when the selected backend changes. No-op when
  /// nothing is loaded (the next [loadFile] applies the change) or when the
  /// resolved backend is unchanged (e.g. `auto` → the same concrete kind).
  /// Rapid switches coalesce via [_switchPending].
  void _onBackendSelectionChanged() {
    if (_shutDown || state.filePath == null) return;
    _switchPending = true;
    if (_switchReloading) return;
    _runSwitchReloads();
  }

  Future<void> _runSwitchReloads() async {
    _switchReloading = true;
    try {
      while (_switchPending && !_shutDown) {
        _switchPending = false;
        final path = state.filePath;
        if (path == null) break;
        // Skip if the selection resolves to the backend already running.
        // Uses the per-path kind, so a loaded still image never reloads —
        // the selection is a *video* backend choice and applies to the next
        // video load ([loadFile]).
        if (_kindForPath(path) == _activeKind) continue;
        Log.i(LogCat.video, 'backend changed — reloading ${p.basename(path)}');
        // If the video is popped out (possibly fullscreen), the pop-out is
        // rendering on its own backend and must be recreated to pick up the
        // new one. Snapshot its frame first so the replacement window
        // reopens where the user put this one, then let loadFile collapse
        // it to inline as usual and pop back out afterwards.
        final oldPopout = state.isPoppedOut ? _popoutWindow : null;
        final geo = oldPopout == null ? null : await _queryPopoutGeometry();
        final err = await loadFile(path);
        if (err != null) {
          ref
              .read(importNoticeProvider.notifier)
              .showWarning(err, title: "Couldn't Load Video");
          continue;
        }
        if (oldPopout != null && !_shutDown && state.filePath != null) {
          // Wait for the old window to actually die before opening the new
          // one: its channel handler is only unregistered late in its close
          // sequence, and a second pop-out registering while the old slot is
          // held leaves the new window deaf (CHANNEL_LIMIT_REACHED) — the
          // same hazard _closePopoutWindow documents. Its stale 'closed'
          // notify is also still in flight; re-registering our handler only
          // after it has died keeps it from tearing the new pop-out down.
          await _awaitPopoutClosed(oldPopout.windowId);
          await enterPopOut(
            bounds: geo?.bounds,
            fullscreen: geo?.fullscreen ?? false,
          );
        }
      }
    } finally {
      _switchReloading = false;
    }
  }

  /// Ask the pop-out window for its current frame and fullscreen state (the
  /// `geometry` reply in `video_popout_app.dart`), so a backend-switch
  /// recreate can reopen the new pop-out in place. Null when the query fails
  /// or times out — the recreate then falls back to a centred default window.
  Future<({Rect bounds, bool fullscreen})?> _queryPopoutGeometry() async {
    if (_popoutWindow == null) return null;
    try {
      final raw = await _popoutChannel
          .invokeMethod<dynamic>('geometry')
          .timeout(const Duration(milliseconds: 500));
      final map = (raw as Map).cast<String, dynamic>();
      return (
        bounds: Rect.fromLTWH(
          (map['x'] as num).toDouble(),
          (map['y'] as num).toDouble(),
          (map['w'] as num).toDouble(),
          (map['h'] as num).toDouble(),
        ),
        fullscreen: map['fullscreen'] as bool? ?? false,
      );
    } on Object catch (e) {
      Log.w(LogCat.video, 'pop-out geometry query failed', e);
      return null;
    }
  }

  /// Wait (bounded) for the pop-out sub-window [windowId] to disappear from
  /// the live window list. The pop-out's close sequence is multi-step and
  /// async (exit fullscreen, backend teardown, notify, leave the channel),
  /// so "we sent 'close'" is far from "the window is gone".
  Future<void> _awaitPopoutClosed(String windowId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(deadline) && !_shutDown) {
      try {
        final alive = await WindowController.getAll();
        if (!alive.any((w) => w.windowId == windowId)) return;
      } on Object catch (e) {
        Log.w(LogCat.video, 'pop-out window-list query failed', e);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    Log.w(LogCat.video, 'pop-out $windowId still open after close timeout');
  }

  /// Resolve the concrete backend kind to run from the user's selection.
  VideoBackendKind _resolveKind() =>
      resolveBackendKind(ref.read(videoBackendProvider), currentTargetOs());

  /// The backend kind for [path]: a still image forces the image backend
  /// regardless of the Settings selection (ES-192); anything else runs on the
  /// selected video backend.
  VideoBackendKind _kindForPath(String path) =>
      isStillImagePath(path) ? VideoBackendKind.stillImage : _resolveKind();

  /// Build [_backend] for [kind] and wire its async callbacks.
  ///
  /// A backend whose native constructor throws must not crash provider
  /// construction — fall back to [kHardFallbackBackend], which is always
  /// available.
  void _instantiateBackend(VideoBackendKind kind) {
    _activeKind = kind;
    try {
      _backend = createVideoBackend(kind);
    } on Object catch (e) {
      Log.e(
        LogCat.video,
        'backend ${kind.name} init failed; using ${kHardFallbackBackend.name}',
        e,
      );
      _activeKind = kHardFallbackBackend;
      _backend = createVideoBackend(kHardFallbackBackend);
    }
    _backend
      ..onMetaChanged = _onMeta
      ..onError = _onVideoError;
    Log.i(LogCat.video, 'video backend: ${_activeKind.name}');
  }

  /// Mirror the backend's resolved metadata into [VideoState]. Reconcile the
  /// timeline only when the duration changes (matching the old per-stream
  /// behaviour where duration drove the reconcile).
  void _onMeta(VideoMeta m) {
    // Metadata from a load that a newer load or unload has overtaken
    // describes a clip that is not staying.
    if (_activeGeneration != _loadGeneration) return;
    final durationChanged = m.duration != state.duration;
    Log.i(
      LogCat.video,
      'meta: ${m.width}x${m.height} @ ${m.fps} fps, '
      'duration ${m.duration?.inMilliseconds} ms '
      '(container ${m.containerDuration?.inMilliseconds} ms), '
      'codec ${m.codec}, ${m.bitRateBps} b/s, color ${m.colorInfo}',
    );
    // Replace the metadata wholesale rather than merging via copyWith's
    // `??`: every backend reports one complete snapshot per load, so a null
    // field means "absent for this clip" — merging would leak the previous
    // clip's codec/color/bit rate through a backend switch or a same-mode
    // session reopen (which skips unload()).
    state = VideoState(
      filePath: state.filePath,
      visible: state.visible,
      mode: state.mode,
      duration: m.duration,
      videoWidth: m.width,
      videoHeight: m.height,
      fps: m.fps,
      containerDuration: m.containerDuration,
      codec: m.codec,
      bitRateBps: m.bitRateBps,
      colorInfo: m.colorInfo,
    );
    if (durationChanged && m.duration != null) {
      _reconcileTimelineDuration();
    }
  }

  /// Surface a backend decoder error to the user. (The backend has already
  /// logged the underlying message.)
  void _onVideoError(String msg) {
    final path = state.filePath;
    final name = path != null ? p.basename(path) : 'video';
    ref
        .read(importNoticeProvider.notifier)
        .showWarning(
          'Video playback error in "$name": $msg',
          title: 'Video Playback Error',
        );
  }

  /// Cancel subscriptions, dispose the backend, and close the pop-out
  /// window. Idempotent and awaitable.
  ///
  /// Besides the normal `ref.onDispose` path, this is called from the
  /// app's macOS exit handler (`_confirmAndTearDownForExit` in main.dart):
  /// the backend's player must be torn down *before* the Dart VM shuts
  /// down, otherwise a decoder thread can fire a Dart FFI callback into a
  /// half-shut-down VM and abort the process (issue ES-203). `ref.onDispose`
  /// does not run on `terminate:`, so the exit handler awaits this
  /// directly.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    Log.i(LogCat.video, 'shutdown: disposing video backend');
    // Close the pop-out before awaiting dispose. This also runs via
    // `ref.onDispose` on a runtime teardown (returnToLanding), and the
    // pop-out's method-channel handler is process-global — clearing it
    // synchronously here avoids a deferred close clobbering a freshly
    // re-opened pop-out's handler.
    _closePopoutWindow();
    await _backend.shutdown();
  }

  /// Before the app quits (macOS): has the pop-out, if one is open, shut
  /// its own backend down, and waits for it up to [timeout]. The pop-out
  /// runs a separate engine whose decoder must stop before the process
  /// exits (ES-203); a plain 'close' is not awaited, so it cannot promise
  /// that.
  Future<void> shutdownPopoutForQuit({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_popoutWindow == null) return;
    try {
      await _popoutChannel
          .invokeMethod<void>('shutdownForQuit')
          .timeout(timeout);
      // The pop-out's backend is stopped and the app terminates next, so
      // there is nothing left to close: forget the pop-out, and the main
      // video's shutdown sends no 'close'. Its window stays up, empty,
      // until the process exits a moment later.
      _popoutWindow = null;
      _popoutReady = false;
    } on Object catch (e) {
      // A pop-out still starting has not registered its handler yet, so
      // it rejects the call; that is expected. Any other failure, a
      // timeout included, is a pop-out with a handler that did not
      // confirm its backend stopped. One whose file failed to load has a
      // handler and a backend.
      if (isUnregisteredPopoutRejection('shutdownForQuit', e)) {
        Log.d(LogCat.video, 'Pop-out had no handler at quit: $e');
      } else {
        Log.w(LogCat.video, 'Pop-out shutdown before quit failed', e);
      }
    }
  }

  /// Build the active backend's render surface (inline panel / fullscreen).
  Widget buildSurface(
    BuildContext context, {
    Color fill = const Color(0xFF000000),
  }) {
    return _backend.buildSurface(context, fill: fill);
  }

  /// Load a video or still-image file from a local path.
  ///
  /// Returns `null` on success or a short user-facing error message on
  /// failure. Callers typically push the message onto
  /// `importNoticeProvider`.
  Future<String?> loadFile(String path) {
    final generation = ++_loadGeneration;
    return _serialized(() => _loadFile(path, generation));
  }

  Future<String?> _loadFile(String path, int generation) async {
    final name = p.basename(path);
    // A newer load or unload is queued behind this one and will set the
    // state: opening this file would only be undone.
    if (generation != _loadGeneration || !ref.mounted) {
      Log.i(LogCat.video, 'loadFile skipped, superseded: $name');
      return null;
    }
    _activeGeneration = generation;
    Log.i(LogCat.video, 'loadFile start: $name');
    // If the video is popped out, the pop-out window is showing the *previous*
    // clip on its own backend and can't be re-targeted at a new file (its path
    // is baked into the window's launch args). Collapse back to inline first,
    // so the transport calls below (seekTo / play) drive the visible main
    // backend rather than forwarding to a now-stale pop-out. Mirrors unload()
    // / exitPopOut(). Reached on a same-mode session reopen (which skips
    // unload(), see prepareForWorkspaceSwitch) and on a backend-switch reload.
    if (state.isPoppedOut) {
      _closePopoutWindow();
      state = state.copyWith(mode: VideoMode.inline, visible: true);
    }
    // Apply-on-next-load: if the wanted backend (the user's selection, or
    // the image backend when [path] is a still — ES-192) no longer matches the
    // active one, swap it in now. The notifier is reused for the app's
    // lifetime, so this is the seam where a selection change takes effect.
    await _maybeSwapBackend(_kindForPath(path));
    final err = await _openInBackend(path);
    // A later loadFile or an unload() ran while the backend opened this
    // file: that call owns the state now (ES-841).
    if (generation != _loadGeneration || !ref.mounted) {
      Log.i(LogCat.video, 'loadFile superseded: $name');
      return null;
    }
    if (err != null) return err;
    state = state.copyWith(filePath: path, visible: true);
    // A still has no duration, so _onMeta's duration-driven reconcile never
    // fires for it — reconcile here so an image *replacing* a video releases
    // the video's hold on the timeline length.
    if (state.isStillImage) _reconcileTimelineDuration();
    final rolling = ref.read(playingProvider);
    Log.i(LogCat.video, 'loadFile opened: $name (autostart=$rolling)');
    // Paint the frame at the current playhead. A pull-based backend
    // renders nothing until asked, so without this the panel stays black
    // while paused until the transport first moves.
    await seekTo(ref.read(transportProvider).seconds);
    // If the transport is already rolling, start the freshly-loaded video
    // in sync. The transport play/pause listener (video_sync.dart) fires
    // only on transitions, so a video added mid-playback would otherwise
    // sit paused until the next stop → start.
    if (rolling) {
      await play();
    }
    return null;
  }

  /// Bumped by every [loadFile] and [unload] when it is called. A load
  /// that finds it changed leaves the state to the newer call (ES-841).
  int _loadGeneration = 0;

  /// The generation of the load or unload the backend last ran.
  int _activeGeneration = 0;

  /// How long a backend may take to open a file before the load reports
  /// a failure and releases the queue.
  static const _kBackendLoadTimeout = Duration(seconds: 30);

  /// Tail of the queue that runs every backend open and close ([loadFile],
  /// [unload], and the pop-out's [enterPopOut] / [exitPopOut]) one at a
  /// time, so two backend opens, or an open and a close, never interleave.
  Future<void> _backendQueue = Future.value();

  /// Opens [path] on the backend, bounded by [_kBackendLoadTimeout]: a
  /// native open that never answers would otherwise hold the queue, and
  /// with it every later unload and workspace switch. The native open is
  /// not cancelled; metadata it reports after the timeout is dropped
  /// until the next load or unload.
  Future<String?> _openInBackend(String path) {
    final name = p.basename(path);
    return _backend
        .loadFile(path)
        .timeout(
          _kBackendLoadTimeout,
          onTimeout: () {
            Log.e(LogCat.video, 'loadFile timed out: $name');
            _activeGeneration = -1;
            return 'Timed out opening $name.';
          },
        );
  }

  Future<R> _serialized<R>(Future<R> Function() op) {
    final result = _backendQueue.then((_) => op());
    _backendQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Swap [_backend] if [wanted] no longer matches the active kind.
  /// Runs at [loadFile] time — both for a normal open and for the live
  /// reload triggered when the user changes the backend in Settings. Not a
  /// seamless hot-swap: the clip is reloaded on the new backend.
  Future<void> _maybeSwapBackend(VideoBackendKind wanted) async {
    if (wanted == _activeKind) return;
    Log.i(
      LogCat.video,
      'switching video backend: ${_activeKind.name} -> ${wanted.name}',
    );
    final old = _backend;
    // Detach the old backend's callbacks before instantiating the new one.
    // `shutdown()` cancels the old player's stream subscriptions, but a
    // stream event already queued at cancel time can still deliver and would
    // otherwise fire `_onMeta`/`_onVideoError` with stale data after the new
    // backend is live.
    old
      ..onMetaChanged = null
      ..onError = null;
    _instantiateBackend(wanted);
    await old.shutdown();
  }

  /// Unload the current video.
  Future<void> unload() {
    _loadGeneration++;
    return _serialized(_unload);
  }

  Future<void> _unload() async {
    // Queued behind a load, this can run after the notifier is disposed
    // (app exit, a test's teardown): the backend is shut down then and
    // reading state would throw (ES-825).
    if (!ref.mounted) return;
    _activeGeneration = _loadGeneration;
    Log.i(LogCat.video, 'unload: clearing video');
    if (state.isPoppedOut) {
      _closePopoutWindow();
    }
    await _backend.unload();
    // returnToLanding and newSession fire this without awaiting it, so
    // the container can be disposed before the backend returns (app exit,
    // a test's teardown); writing state on a disposed notifier throws
    // (ES-825).
    if (!ref.mounted) return;
    state = state.copyWith(
      clearFile: true,
      clearDuration: true,
      clearMedia: true,
      mode: VideoMode.inline,
    );
    _reconcileTimelineDuration();
  }

  /// Reconcile the transport timeline length with the current video and
  /// audio media. Called whenever the video's duration arrives or changes
  /// (it lands asynchronously from the backend) and when the video is
  /// unloaded.
  ///
  /// Duration is stored in engine-rate frames so that Dart's playhead
  /// position (which mirrors `engine.transportPositionFrames()`) and the
  /// timeline duration share a clock. Source the rate from the engine, not
  /// `transport.sampleRate`: on a device that forced a non-48 kHz rate, a
  /// stale 48 kHz basis would race the playhead by the rate ratio (ES-218).
  ///
  /// In Creator mode the timeline is `max(longest audio element, video)`,
  /// recomputed in full so a video *shorter* than the placeholder default
  /// still bounds the playhead — the engine's frame counter free-runs with
  /// no media to stop it, so a video-only session would otherwise sail past
  /// the video's end (ES-220). In Playback/QC the IAMF length already bounds
  /// the timeline, so we only ever extend for a longer video and never
  /// shrink below the audio.
  void _reconcileTimelineDuration() {
    final transport = ref.read(transportProvider);
    final engine = ref.read(eclipsaStudioEngineProvider);
    final transportRate = engine?.currentSampleRate ?? transport.sampleRate;

    final videoDuration = state.duration;
    final videoFrames = videoDuration != null
        ? (videoDuration.inMilliseconds / 1000.0 * transportRate).ceil()
        : 0;

    if (ref.read(workspaceModeProvider) == WorkspaceMode.creator) {
      final audioSeconds = longestAudioSeconds(ref.read(elementsProvider));
      final audioFrames = (audioSeconds * transportRate).ceil();
      final maxFrames = audioFrames > videoFrames ? audioFrames : videoFrames;
      if (maxFrames > 0) {
        ref
            .read(transportProvider.notifier)
            .updateDuration(maxFrames, transportRate);
      }
      return;
    }

    // Playback/QC: the IAMF length (published on open) is the floor;
    // extend only for a longer video.
    if (videoFrames > transport.durationSamples) {
      ref
          .read(transportProvider.notifier)
          .updateDuration(videoFrames, transportRate);
    }
  }

  /// Seek to a position in seconds.
  ///
  /// While popped out the picture lives in the pop-out window's own backend,
  /// so we forward there; the in-app backend is fully unloaded during pop-out
  /// (only one backend runs at a time) and [exitPopOut] reloads it on pop-in.
  Future<void> seekTo(double seconds) async {
    if (_shutDown || !state.hasVideo) return;
    if (state.isPoppedOut) {
      _sendToPopout('seek', (seconds * 1000).round());
      return;
    }
    await _backend.seekTo(seconds);
  }

  /// Start playback (synced from transport).
  Future<void> play() async {
    if (_shutDown || !state.hasVideo) {
      // Should not happen now the backend is reused (not recreated) across
      // switches; kept as a warning so a regression to the stranded-
      // notifier bug (ES-226) is caught immediately.
      Log.w(
        LogCat.video,
        'play() ignored (shutDown=$_shutDown hasVideo=${state.hasVideo})',
      );
      return;
    }
    Log.d(LogCat.video, 'play()');
    if (state.isPoppedOut) {
      _sendToPopout('play');
      return;
    }
    await _backend.play();
  }

  /// Pause playback (synced from transport).
  Future<void> pause() async {
    if (_shutDown || !state.hasVideo) return;
    Log.d(LogCat.video, 'pause()');
    if (state.isPoppedOut) {
      _sendToPopout('pause');
      return;
    }
    await _backend.pause();
  }

  /// Reconcile the video to the audio-thread playhead. Called from the tick
  /// loop during playback; forwards to the backend's sync strategy.
  ///
  /// [audioSeconds] is the audio-thread playhead (the master clock). While
  /// popped out we forward the master clock to the pop-out window so its
  /// backend can sync (a *pull-based* backend such as AVFoundation needs the
  /// per-tick clock to advance at all), and skip the hidden main backend.
  Future<void> syncToAudio(double audioSeconds, {required bool playing}) async {
    if (_shutDown || !state.hasVideo) return;
    if (state.isPoppedOut) {
      _sendToPopout('sync', {'seconds': audioSeconds, 'playing': playing});
      return;
    }
    await _backend.syncToAudio(audioSeconds, playing: playing);
  }

  /// Toggle panel visibility (only meaningful in inline mode).
  void toggleVisible() {
    if (!state.isInline) return;
    state = state.copyWith(visible: !state.visible);
  }

  /// Re-push the current frame to the active backend's render surface.
  ///
  /// A *pull-based* backend (AVFoundation) only produces a frame on demand,
  /// so its [Texture] composites black after the render surface is rebuilt —
  /// e.g. when the main window enters or leaves native (app) fullscreen with
  /// the video inline — until something renders again. This nudges the
  /// current frame back out. Only needed while paused: during playback the
  /// per-tick [syncToAudio] re-renders on its own (and a seek mid-playback
  /// would cause a needless hitch). A harmless re-seek for the free-running
  /// backends.
  void refreshSurfaceFrame() {
    if (_shutDown || !state.hasVideo || state.isPoppedOut) return;
    if (ref.read(playingProvider)) return;
    unawaited(_backend.seekTo(ref.read(transportProvider).seconds));
  }

  /// Pop the video out into a separate window.
  ///
  /// The pop-out runs its own Flutter engine, so it builds a fresh backend of
  /// the currently-active kind ([_activeKind]) — passed in the window args —
  /// and renders the picture there; the main window's panel is hidden. When
  /// [bounds] is given the window is placed at that frame before showing —
  /// a display's full bounds for the "open fullscreen on external display"
  /// affordance, or a previous pop-out's frame for the backend-switch
  /// recreate — and when [fullscreen] is set it enters native fullscreen
  /// there.
  Future<void> enterPopOut({Rect? bounds, bool fullscreen = false}) =>
      // Queued, so the window opens on the file that pending loads and
      // unloads leave, and its backend release follows them (ES-841).
      _serialized(() => _enterPopOut(bounds: bounds, fullscreen: fullscreen));

  Future<void> _enterPopOut({Rect? bounds, bool fullscreen = false}) async {
    if (!ref.mounted || _shutDown) return;
    if (state.isPoppedOut || !state.hasVideo) return;
    try {
      final w = state.videoWidth;
      final h = state.videoHeight;
      final args = encodePopoutArgs(
        state.filePath!,
        backendKind: _activeKind,
        fullscreen: fullscreen,
        bounds: bounds,
        videoSize: w != null && h != null && w > 0 && h > 0
            ? Size(w.toDouble(), h.toDouble())
            : null,
      );
      _popoutReady = false;
      // Listen for 'closed' / 'requestSync' before the window exists. The
      // pop-out sends 'requestSync' once, after opening the file; if it
      // arrived before this handler, the pop-out would never be marked
      // ready and every later transport message would be dropped.
      _popoutChannel.setMethodCallHandler(_handlePopoutCall);
      _popoutWindow = await WindowController.create(
        WindowConfiguration(arguments: args),
      );
      await _popoutWindow!.show();
      // While the window was being created and shown, the notifier may
      // have been disposed or shut down: stop here, so nothing writes
      // state or unloads the backend after shutdown. The 'close' this
      // sends reaches the window only if the shutdown came after create()
      // returned; one during create() leaves the window open (ES-893). Or
      // the pop-out may have sent 'closed', whose exitPopOut already set
      // the inline mode and cleared _popoutWindow.
      if (!ref.mounted || _shutDown) {
        _closePopoutWindow();
        return;
      }
      if (_popoutWindow == null) return;
      state = state.copyWith(mode: VideoMode.popOut, visible: false);
      // Only one backend runs at a time. The pop-out owns the visible picture
      // on its own backend, so fully *release* the in-app backend's decoder
      // (file handle, GPU texture, any HW-decode session) rather than leaving
      // a second one parked and resource-holding behind an invisible panel.
      // exitPopOut reloads it on pop-in. Done after the window is up so a
      // failed pop-out (the catch below) leaves the inline backend intact.
      await _backend.unload();
      // The pop-out pulls the current playhead itself once it has opened the
      // file (see its 'requestSync'); the per-tick `sync` only runs while
      // playing, so without that a pop-out opened while paused would sit on
      // frame 0 until the transport next moves.
    } on Exception catch (e) {
      Log.e(LogCat.video, 'Failed to create pop-out window', e);
      if (!state.isPoppedOut) {
        _popoutWindow = null;
        _popoutChannel.setMethodCallHandler(null);
      }
    }
  }

  /// Close the pop-out window and return to inline.
  ///
  /// The in-app backend was fully released on pop-out (only one backend runs
  /// at a time — see [enterPopOut]), so reload the clip into it, paint the
  /// frame at the current playhead, and resume if the transport is rolling as
  /// the inline panel comes back.
  Future<void> exitPopOut() async {
    _closePopoutWindow();
    state = state.copyWith(mode: VideoMode.inline, visible: true);
    if (_shutDown || !state.hasVideo) return;
    final path = state.filePath!;
    // A load or unload queued before this pop-in owns the backend when
    // it has run: reload only if the file is still the current one.
    bool stillCurrent() =>
        ref.mounted &&
        !_shutDown &&
        !state.isPoppedOut &&
        state.filePath == path;
    final err = await _serialized(
      () async => stillCurrent() ? _openInBackend(path) : null,
    );
    if (!stillCurrent()) return;
    if (err != null) {
      ref
          .read(importNoticeProvider.notifier)
          .showWarning(err, title: "Couldn't Load Video");
      return;
    }
    await seekTo(ref.read(transportProvider).seconds);
    if (ref.read(playingProvider)) await play();
  }

  Future<dynamic> _handlePopoutCall(MethodCall call) async {
    switch (call.method) {
      case 'closed':
        _popoutWindow = null; // Already closing — skip sending 'close' back.
        _popoutReady = false;
        await exitPopOut();
      case 'requestSync':
        _popoutReady = true;
        // The pop-out finished loading and is asking for the current
        // playhead (its handler may not have been ready for the push at
        // open time). Reply with the master clock + play state, and the
        // appearance, so a pop-out opened mid-session draws in the
        // current theme even before the preferences file is written.
        _sendToPopout('sync', {
          'seconds': ref.read(transportProvider).seconds,
          'playing': ref.read(playingProvider),
        });
        _sendAppearance();
    }
  }

  void _closePopoutWindow() {
    // Send 'close' BEFORE unregistering our handler. The channel is a
    // bidirectional pair and only members may invoke on it, so unregistering
    // first gets the 'close' rejected (CHANNEL_UNREGISTERED) and the pop-out
    // window stays open as an orphan — no sync, unclosable from here — that
    // also keeps holding one of the channel's two registration slots, making
    // every later pop-out open deaf (CHANNEL_LIMIT_REACHED). Both calls
    // enqueue platform messages on the same underlying channel in call
    // order, so the close reaches the registry before the unregister. (The
    // pop-out's answering 'closed' notify then finds us unregistered and
    // fails on its side — benign, we initiated, and it must NOT trigger
    // _handlePopoutCall's exitPopOut reload on top of the caller's own.)
    if (_popoutWindow != null) {
      _sendToPopout('close');
      _popoutWindow = null;
    }
    _popoutReady = false;
    _popoutChannel.setMethodCallHandler(null);
  }

  void _sendToPopout(String method, [dynamic arguments]) {
    if (_popoutWindow == null) return;
    if (dropPopoutMessage(method, ready: _popoutReady)) return;
    // invokeMethod is async — channel/platform failures arrive as a future
    // error, not a synchronous throw, so attach catchError rather than wrap
    // in try/catch. Fire-and-forget transport, so the future isn't awaited.
    unawaited(
      _popoutChannel.invokeMethod<void>(method, arguments).catchError((
        Object e,
      ) {
        if (isUnregisteredPopoutRejection(method, e)) {
          Log.d(LogCat.video, 'Pop-out had no handler for $method');
        } else {
          Log.w(LogCat.video, 'Pop-out channel error ($method)', e);
        }
      }),
    );
  }
}

/// Whether a message for the pop-out is dropped rather than sent. Until
/// the pop-out has opened its file and sent its first 'requestSync',
/// whose reply carries the playhead and appearance, transport messages
/// are dropped (ES-786). 'close' always goes through. 'appearance' does
/// too: a pop-out whose file fails to load never sends 'requestSync',
/// and it still has to follow the main window's theme and font size. An
/// 'appearance' that arrives before the pop-out registers its handler is
/// rejected; the pop-out starts in the theme and font size it read from
/// the preferences file in main(), and a successful load also gets them
/// in the 'requestSync' reply.
@visibleForTesting
bool dropPopoutMessage(String method, {required bool ready}) =>
    !ready && method != 'close' && method != appearanceMethod;

/// Whether [error] is the rejection of a message that reached the pop-out
/// while it had no handler registered: after it unregistered while
/// closing, or, for 'appearance' and 'shutdownForQuit', before it
/// registered at launch. A per-tick 'sync' or a 'seek' can race the
/// close; that is expected and logged at debug. A rejected 'close' is
/// not: it leaves an orphan window (see `_closePopoutWindow`), so it stays
/// a warning (ES-786).
@visibleForTesting
bool isUnregisteredPopoutRejection(String method, Object error) =>
    method != 'close' &&
    error is WindowChannelException &&
    error.code == 'CHANNEL_UNREGISTERED';

/// Provider for the video track state.
final videoProvider = NotifierProvider<VideoNotifier, VideoState>(
  VideoNotifier.new,
);
