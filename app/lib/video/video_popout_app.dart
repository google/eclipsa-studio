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
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../logging/log.dart';
import '../theme.dart';
import '../util/time_format.dart';
import 'popout_appearance.dart';
import 'popout_size.dart';
import 'video_backend.dart';
import 'video_backend_factory.dart';
import 'video_backend_kind.dart';
import 'video_popout_chrome.dart';

/// Channel for transport sync between main and pop-out window.
const _channel = WindowMethodChannel('eclipsa/video_popout');

/// Whether the pop-out still handles [method] once its backend teardown
/// has started. Only 'shutdownForQuit': it must wait for that teardown so
/// the app does not terminate with the decoder still running (ES-203).
@visibleForTesting
bool handledAfterPopoutTeardown(String method) => method == 'shutdownForQuit';

/// Arguments handed to the pop-out window via [encodePopoutArgs].
///
/// The pop-out runs its own Flutter engine, so it can't read the main app's
/// state — everything it needs (which file, which backend, where to place
/// the window) is serialised through the window arguments.
class PopoutArgs {
  /// Local path of the video to play. Empty when the secondary window is not
  /// a video pop-out (used by `main()` to route the window).
  final String videoPath;

  /// The backend the main window is running, rebuilt in the pop-out so the
  /// pop-out shows the same decode path.
  final VideoBackendKind backendKind;

  /// Enter native fullscreen on launch (the "open on external display" flow).
  final bool fullscreen;

  /// Place the window at this frame (logical pixels) before showing — a
  /// display's full bounds for the external-display fullscreen flow, or the
  /// previous pop-out's frame when a backend switch recreates the window.
  /// Null centres on the primary display.
  final Rect? bounds;

  /// The clip's picture size in pixels, when the main window knows it
  /// at pop-out time, so `main()` sizes the window to the picture
  /// before showing it. Null when the metadata has not resolved; the
  /// pop-out then fits itself once its own backend reports the size.
  final Size? videoSize;

  const PopoutArgs({
    required this.videoPath,
    this.backendKind = kHardFallbackBackend,
    this.fullscreen = false,
    this.bounds,
    this.videoSize,
  });

  bool get isVideoPopout => videoPath.isNotEmpty;
}

/// Entry point for the pop-out video window.
///
/// Builds a [VideoBackend] of [args] kind in its own engine and renders its
/// surface, mirroring the main window's transport over [_channel].
class VideoPopoutApp extends StatelessWidget {
  final PopoutArgs args;

  const VideoPopoutApp({super.key, required this.args});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        // Match the main window's tooltip timing so hovering the
        // pop-out's controls feels the same as the docked panel.
        tooltipTheme: const TooltipThemeData(waitDuration: T.tooltipWait),
      ),
      home: _VideoPopoutWindow(args: args),
    );
  }
}

class _VideoPopoutWindow extends StatefulWidget {
  final PopoutArgs args;
  const _VideoPopoutWindow({required this.args});

  @override
  State<_VideoPopoutWindow> createState() => _VideoPopoutWindowState();
}

class _VideoPopoutWindowState extends State<_VideoPopoutWindow>
    with WindowListener {
  /// The backend rendering the picture in this window. Rebuilt to
  /// [kHardFallbackBackend] if the selected kind fails to initialise here
  /// (e.g. a native controller not registered in the sub-window) so the
  /// pop-out never goes black.
  late VideoBackend _backend;

  bool _disposed = false;

  /// The status strip's text, recomputed from the playhead the main
  /// window pushes and the backend's duration. A listenable rather than
  /// state, since `sync` arrives per tick while playing: only the
  /// readout's text rebuilds, not the window.
  final _readout = ValueNotifier<String>(formatDuration(0));

  /// The window's width-to-height ratio for the fitted picture, or 0
  /// before the picture size is known. Set on the window outside
  /// fullscreen so a resize keeps the picture's shape; cleared while
  /// fullscreen.
  double _aspect = 0;

  /// Whether the window has been fitted to the picture (from the launch
  /// args or from the backend's metadata), so a later metadata update
  /// does not resize it again.
  bool _fitted = false;

  /// Entry mutex for [_handleWindowClose]. Set synchronously before its first
  /// await so the close sequence can't run twice when the OS close, the main
  /// window's 'close' message, and the title bar's close button all race
  /// across the awaits.
  /// ([_disposed] is set only at backend teardown, several awaits in, so it
  /// can't guard this.)
  bool _closing = false;
  bool _loaded = false;

  /// Whether the window is in native fullscreen. Seeded from the launch args
  /// (an external-display pop-out opens straight into fullscreen, before our
  /// enter-fullscreen listener is attached) and set directly on entering
  /// fullscreen and, on Windows, on leaving it. On Windows, window_manager
  /// never emits enter/leave-full-screen for programmatic transitions (its
  /// WM_SIZE heuristic watches for SIZE_MAXIMIZED, but SetFullScreen resizes
  /// via SetWindowPos, which arrives as SIZE_RESTORED), so waiting for the
  /// events leaves this stale. On macOS a leave clears it from
  /// [onWindowLeaveFullScreen], or after [_leaveFullscreen]'s timeout. The
  /// listeners also cover OS-initiated transitions (macOS green button /
  /// Spaces). Drives the chrome, which is hidden in fullscreen.
  bool _isFullscreen = false;

  /// Completed by [onWindowLeaveFullScreen] so [_leaveFullscreen] can wait
  /// for macOS to tear the fullscreen Space down: before a close, since
  /// closing a window while it is still fullscreen orphans it (a frozen,
  /// unresponsive zombie), and before the chrome is drawn again (ES-788).
  Completer<void>? _leaveFsCompleter;

  /// The leave-fullscreen transition started by [_leaveFullscreen], while
  /// it runs. A second Esc or double-click and a close all join it, so the
  /// window is never closed or re-toggled mid-transition (ES-268).
  Future<void>? _leavingFullscreen;

  /// Last transport position/state pushed from the main window. Re-applied
  /// once [loadFile] finishes, since `sync` messages can arrive while the
  /// backend is still opening the file.
  double _pendingSeconds = 0;
  bool _pendingPlaying = false;

  @override
  void initState() {
    super.initState();
    // main() enters fullscreen after it shows the window. A second
    // request that lands before AppKit sets the window's fullscreen flag
    // toggles the window back out, so none is made here. Seeding the
    // flag hides the chrome from the first frame.
    _isFullscreen = widget.args.fullscreen;
    Log.i(
      LogCat.video,
      'pop-out started: backend=${widget.args.backendKind.name} '
      'fullscreen=${widget.args.fullscreen} bounds=${widget.args.bounds}',
    );
    // A backend whose native constructor throws must not crash the pop-out
    // window outright — fall back to [kHardFallbackBackend], which is always
    // available (pure Dart + FFI, no per-window native controller). (The
    // async loadFile-failure fallback in _loadVideo covers the runtime case.)
    try {
      _backend = createVideoBackend(widget.args.backendKind);
    } on Object catch (e) {
      Log.w(
        LogCat.video,
        'pop-out backend ${widget.args.backendKind.name} init failed; '
        'using ${kHardFallbackBackend.name}',
        e,
      );
      _backend = createVideoBackend(kHardFallbackBackend);
    }
    _attachBackend();

    // The main window knew the picture size: main() sized the window
    // to it, so only the aspect ratio is left to apply.
    final videoSize = widget.args.videoSize;
    if (videoSize != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_fitToVideo(videoSize)),
      );
    }

    // Load video and paint the first frame.
    _loadVideo();

    // Listen for transport commands from the main window.
    _channel.setMethodCallHandler(_handleMethod);

    windowManager.setPreventClose(true);
    windowManager.addListener(this);
  }

  /// Wires the backend's callbacks: errors to the log, and metadata to
  /// the window fit and the status readout.
  void _attachBackend() {
    _backend.onError = (msg) =>
        Log.w(LogCat.video, 'pop-out backend error: $msg');
    _backend.onMetaChanged = _onMeta;
  }

  void _onMeta(VideoMeta meta) {
    if (_disposed) return;
    final w = meta.width;
    final h = meta.height;
    if (w != null && h != null && w > 0 && h > 0) {
      unawaited(_fitToVideo(Size(w.toDouble(), h.toDouble())));
    }
    _refreshReadout();
  }

  /// Sizes the window to [video] once: the picture plus the strips,
  /// scaled to fit the primary display, centred, and the aspect ratio
  /// set so a resize keeps the shape. The resize is skipped when the
  /// launch args placed the window (a display's bounds, a previous
  /// pop-out's frame) or already sized it from the main window's
  /// metadata; the aspect ratio is applied in every case.
  Future<void> _fitToVideo(Size video) async {
    if (_fitted || _disposed) return;
    _fitted = true;
    const chrome = PopoutChrome.chromeHeight;
    final placed = widget.args.bounds != null || widget.args.videoSize != null;
    try {
      // The ratio is the window's at the size it has, not the
      // picture's pixel ratio, which differs once the fit scales it.
      if (!placed && !_isFullscreen) {
        final display = await screenRetriever.getPrimaryDisplay();
        final size = fitPopoutSize(
          video,
          display.visibleSize ?? display.size,
          chrome: chrome,
        );
        Log.i(
          LogCat.video,
          'pop-out fit: video=${video.width.round()}x'
          '${video.height.round()} window=${size.width.round()}x'
          '${size.height.round()}',
        );
        await windowManager.setSize(size);
        await windowManager.center();
        _aspect = size.width / size.height;
      } else {
        final width = (await windowManager.getSize()).width;
        _aspect = popoutAspectRatio(video, width: width, chrome: chrome);
      }
    } on Exception catch (e) {
      Log.w(LogCat.video, 'pop-out fit failed', e);
    }
    await _applyAspect(fullscreen: _isFullscreen);
  }

  /// Sets the window's aspect ratio for the windowed state, or clears
  /// it (0) for fullscreen, where the display sets the shape.
  /// window_manager binds the ratio to this engine's own window. Not
  /// during a close, whose fullscreen exit must not re-apply it.
  Future<void> _applyAspect({required bool fullscreen}) async {
    if (_aspect <= 0 || _disposed || _closing) return;
    try {
      await windowManager.setAspectRatio(fullscreen ? 0 : _aspect);
    } on Exception catch (e) {
      Log.w(LogCat.video, 'pop-out aspect ratio failed', e);
    }
  }

  /// The status strip's text: the playhead, then the clip's duration
  /// when the backend has resolved it.
  String _formatReadout() {
    final position = formatDuration(_pendingSeconds);
    final duration = _backend.meta.duration;
    if (duration == null) return position;
    return '$position / ${formatDuration(duration.inMilliseconds / 1000)}';
  }

  void _refreshReadout() {
    if (_disposed) return;
    final next = _formatReadout();
    if (next != _readout.value) _readout.value = next;
  }

  Future<void> _loadVideo() async {
    var err = await _backend.loadFile(widget.args.videoPath);
    if (_disposed) return;
    // The selected backend couldn't run in this sub-window — fall back to
    // [kHardFallbackBackend] (always available via the plugin registrant) so
    // the pop-out still shows the picture. Not for a still image: the video
    // fallback can't decode one, and the image backend is pure Dart — if it
    // failed here it would have failed inline too.
    if (err != null &&
        widget.args.backendKind != kHardFallbackBackend &&
        widget.args.backendKind != VideoBackendKind.stillImage) {
      Log.w(
        LogCat.video,
        'pop-out backend ${widget.args.backendKind.name} failed ($err); '
        'falling back to ${kHardFallbackBackend.name}',
      );
      await _backend.shutdown();
      if (_disposed) return;
      _backend = createVideoBackend(kHardFallbackBackend);
      _attachBackend();
      err = await _backend.loadFile(widget.args.videoPath);
      if (_disposed) return;
    }
    _loaded = err == null;
    // A backend that resolved the picture size during loadFile without
    // an onMetaChanged call still fits the window.
    if (_loaded) _onMeta(_backend.meta);
    // Apply the latest transport position the main window pushed while we
    // were opening (load is muted + paused; transport sync drives playback).
    if (_loaded) {
      await _backend.syncToAudio(_pendingSeconds, playing: _pendingPlaying);
      // Pull the authoritative playhead from the main window now we can act
      // on it — the open-time push may have raced our handler setup, so this
      // is what positions a pop-out opened while paused.
      try {
        await _channel.invokeMethod('requestSync');
      } on Exception catch (e) {
        Log.w(LogCat.video, 'pop-out requestSync failed', e);
      }
    }
    if (mounted) setState(() {});
  }

  Future<dynamic> _handleMethod(MethodCall call) async {
    // A quit request still waits for a teardown the window close started:
    // the main window must not let the app terminate while this decoder
    // is still stopping (ES-203).
    if (_disposed && !handledAfterPopoutTeardown(call.method)) return null;
    switch (call.method) {
      case 'play':
        _pendingPlaying = true;
        if (_loaded) await _backend.play();
      case 'pause':
        _pendingPlaying = false;
        if (_loaded) await _backend.pause();
      case 'seek':
        final ms = call.arguments as int;
        _pendingSeconds = ms / 1000.0;
        _refreshReadout();
        if (_loaded) await _backend.seekTo(_pendingSeconds);
      case 'sync':
        final map = (call.arguments as Map).cast<String, dynamic>();
        _pendingSeconds = (map['seconds'] as num).toDouble();
        _pendingPlaying = map['playing'] as bool? ?? false;
        _refreshReadout();
        if (_loaded) {
          await _backend.syncToAudio(_pendingSeconds, playing: _pendingPlaying);
        }
      case appearanceMethod:
        // The main window's theme or font size changed (or answered
        // requestSync): draw the chrome in it. T is this engine's own.
        final next = decodeAppearance(call.arguments);
        if (next.theme != null) T.setMode(next.theme!);
        if (next.font != null) T.setFontMode(next.font!);
        if (mounted) setState(() {});
      case 'geometry':
        // The main window snapshots our frame + fullscreen state before a
        // backend-switch recreate (see VideoNotifier._runSwitchReloads), so
        // the replacement pop-out reopens where this one is. In fullscreen,
        // getBounds() reports the display frame — which is exactly what the
        // relaunch path needs to fullscreen on the same display.
        final b = await windowManager.getBounds();
        return {
          'x': b.left,
          'y': b.top,
          'w': b.width,
          'h': b.height,
          'fullscreen': _isFullscreen,
        };
      case 'close':
        await _handleWindowClose('main-window close message');
      case 'shutdownForQuit':
        // The app is quitting (macOS). This pop-out runs its own engine and
        // decoder, and its Dart VM goes down with the app: dispose the
        // backend first, so a player core thread cannot fire an FFI
        // callback into a half-shut-down VM (ES-203). The main window waits
        // for this reply before it lets the app terminate.
        await _shutdownBackend();
        // The process exits right after the reply: write this window's
        // buffered log entries now (ES-787).
        Log.instance.flush();
    }
    return null;
  }

  @override
  void onWindowClose() {
    unawaited(_handleWindowClose('window-close event'));
  }

  @override
  void onWindowEnterFullScreen() {
    Log.d(LogCat.video, 'pop-out window event: enter-full-screen');
    if (mounted) setState(() => _isFullscreen = true);
    unawaited(_applyAspect(fullscreen: true));
  }

  @override
  void onWindowLeaveFullScreen() {
    Log.d(LogCat.video, 'pop-out window event: leave-full-screen');
    if (!(_leaveFsCompleter?.isCompleted ?? true)) {
      _leaveFsCompleter!.complete();
    }
    if (mounted) setState(() => _isFullscreen = false);
    unawaited(_applyAspect(fullscreen: false));
  }

  // Breadcrumbs for OS-level maximize (Win+Up / Aero-snap-to-top): a
  // maximized window keeps its title bar (with the Restore glyph on
  // Windows) but fills the screen, and [_isFullscreen] stays false. Log it
  // so a maximized window can be told apart from a real fullscreen in a
  // report.
  @override
  void onWindowMaximize() {
    Log.i(LogCat.video, 'pop-out window event: maximize');
  }

  @override
  void onWindowUnmaximize() {
    Log.i(LogCat.video, 'pop-out window event: unmaximize');
  }

  /// [reason] is a breadcrumb for the log — which trigger started the
  /// close (the title bar's close button, the OS close, or the main
  /// window).
  Future<void> _handleWindowClose(String reason) async {
    if (_disposed || _closing) return;
    _closing = true;
    Log.i(
      LogCat.video,
      'pop-out close: reason=$reason fullscreen=$_isFullscreen',
    );
    // Leave fullscreen before closing: closing a window that is still in its
    // own fullscreen Space (e.g. an external-display pop-out) leaves a frozen,
    // unresponsive window behind on macOS.
    await _leaveFullscreen();
    // Tear the backend down before telling the main window, and before
    // closing. Shutdown is a multi-step async sequence for the native
    // backends (channel round-trip to a texture/decoder controller,
    // isolate teardown for FFmpeg): closing the window mid-flight races
    // GPU-resource release against window teardown (ES-203). Doing it before
    // 'closed' keeps the main window tracking this pop-out until the
    // decoder has stopped, so a Quit in that time sends 'shutdownForQuit'
    // and waits for this teardown; and the inline reload that 'closed'
    // triggers starts only once this decoder is gone.
    await _shutdownBackend();
    // Notify main window so it restores inline video.
    try {
      await _channel.invokeMethod('closed');
    } on Exception catch (e) {
      Log.w(LogCat.video, 'Failed to notify main window', e);
    }
    // Leave the channel pair only after 'closed': unregistering first gets
    // the notify rejected.
    _channel.setMethodCallHandler(null);
    // The pop-out writes its own log file through a line buffer; flush it
    // so the close and shutdown entries above reach the file (ES-787).
    Log.instance.flush();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void dispose() {
    _readout.dispose();
    unawaited(_shutdownBackend());
    _channel.setMethodCallHandler(null);
    windowManager.removeListener(this);
    super.dispose();
  }

  /// The teardown in progress or done. Every caller (the window close,
  /// the main window's 'close', 'shutdownForQuit', dispose) gets the same
  /// future, so none of those that await it goes on while the backend is
  /// still shutting down.
  Future<void>? _backendShutdown;

  /// Tear the backend down, awaiting its async shutdown. [dispose] can't
  /// await, so it calls this fire-and-forget; the window-close path and
  /// 'shutdownForQuit' await it before the window or the app goes away.
  Future<void> _shutdownBackend() => _backendShutdown ??= _doShutdownBackend();

  Future<void> _doShutdownBackend() async {
    _disposed = true;
    try {
      await _backend.shutdown();
    } on Exception catch (e) {
      Log.w(LogCat.video, 'pop-out backend shutdown failed', e);
    }
  }

  Future<void> _toggleFullscreen() async {
    // Use our own [_isFullscreen] rather than windowManager.isFullScreen():
    // besides the missing Windows events (see [_isFullscreen]), the plugin's
    // native fullscreen bookkeeping is a process-wide global shared with the
    // main window's engine, so the query can report the *main* window's
    // fullscreen state.
    if (_closing) return;
    if (_isFullscreen) return _leaveFullscreen();
    // The ratio is cleared before entering fullscreen, so the display's
    // shape wins, and restored after leaving it.
    await _applyAspect(fullscreen: true);
    await windowManager.setFullScreen(true);
    if (mounted) setState(() => _isFullscreen = true);
  }

  /// Leaves fullscreen: Esc, a double-click on the picture, or a close
  /// (closing a window still in its fullscreen Space leaves a frozen window
  /// on macOS). Callers that arrive while an exit runs join it. On macOS
  /// the chrome stays hidden until [onWindowLeaveFullScreen] reports that
  /// the window has left its fullscreen Space, so the title bar does not
  /// draw while the window still has the display's size (ES-788). If the
  /// event does not arrive within 1.2 s the flag is cleared anyway, which
  /// draws the chrome even if AppKit ignored the request (e.g. one made
  /// mid-enter). Windows sends no leave event, so there the flag is
  /// cleared when setFullScreen returns. During a close, [_applyAspect]
  /// returns early.
  Future<void> _leaveFullscreen() {
    final running = _leavingFullscreen;
    if (running != null) return running;
    // Our own flag, not windowManager.isFullScreen(): see
    // [_toggleFullscreen].
    if (!_isFullscreen) return Future.value();
    Log.i(LogCat.video, 'pop-out: leaving fullscreen');
    final leaving = _leavingFullscreen = _runLeaveFullscreen();
    // whenComplete runs asynchronously, so this cannot clear the field
    // before the assignment above.
    leaving.whenComplete(() => _leavingFullscreen = null).ignore();
    return leaving;
  }

  Future<void> _runLeaveFullscreen() async {
    try {
      if (Platform.isMacOS) {
        final completer = _leaveFsCompleter = Completer<void>();
        await windowManager.setFullScreen(false);
        await completer.future.timeout(
          const Duration(milliseconds: 1200),
          onTimeout: () => Log.w(
            LogCat.video,
            'pop-out: no leave-full-screen event after 1.2 s',
          ),
        );
      } else {
        await windowManager.setFullScreen(false);
      }
      // Already cleared by onWindowLeaveFullScreen when it arrived.
      if (_isFullscreen) {
        if (mounted) setState(() => _isFullscreen = false);
        await _applyAspect(fullscreen: false);
      }
    } on Exception catch (e) {
      Log.w(LogCat.video, 'pop-out leave-fullscreen failed', e);
    } finally {
      _leaveFsCompleter = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.bgDeep,
      // The window's own title bar (with the platform's window
      // controls and drag to move) heads the picture and a status strip
      // with the playhead follows it, outside fullscreen. The title bar's
      // TitleBarStyle is hidden in main(), the same as the main window's,
      // so WindowFrameStrip owns the top of this window too (ES-744).
      // PopoutChrome also consumes key presses (ES-797).
      body: PopoutChrome(
        title: p.basename(widget.args.videoPath),
        fullscreen: _isFullscreen,
        readout: _readout,
        onClose: () => _handleWindowClose('title bar close'),
        onToggleFullscreen: () => unawaited(_toggleFullscreen()),
        onLeaveFullscreen: () => unawaited(_leaveFullscreen()),
        picture: _backend.buildSurface(context, fill: T.bgDeep),
      ),
    );
  }
}

/// Parse the pop-out window arguments. Returns a [PopoutArgs] with an empty
/// [PopoutArgs.videoPath] for any non-video-pop-out window so `main()` can
/// route on [PopoutArgs.isVideoPopout].
PopoutArgs parsePopoutArgs(String arguments) {
  if (arguments.isEmpty) return const PopoutArgs(videoPath: '');
  final json = jsonDecode(arguments) as Map<String, dynamic>;
  if (json['businessId'] != 'video_popout') {
    return const PopoutArgs(videoPath: '');
  }
  final kindName = json['backendKind'] as String?;
  final kind = VideoBackendKind.values.firstWhere(
    (k) => k.name == kindName,
    orElse: () => kHardFallbackBackend,
  );
  Rect? bounds;
  final b = json['bounds'];
  if (b is Map) {
    bounds = Rect.fromLTWH(
      (b['x'] as num).toDouble(),
      (b['y'] as num).toDouble(),
      (b['w'] as num).toDouble(),
      (b['h'] as num).toDouble(),
    );
  }
  Size? videoSize;
  final v = json['videoSize'];
  if (v is Map) {
    videoSize = Size((v['w'] as num).toDouble(), (v['h'] as num).toDouble());
  }
  return PopoutArgs(
    videoPath: json['videoPath'] as String? ?? '',
    backendKind: kind,
    fullscreen: json['fullscreen'] as bool? ?? false,
    bounds: bounds,
    videoSize: videoSize,
  );
}

/// Encode arguments for the pop-out window.
String encodePopoutArgs(
  String videoPath, {
  required VideoBackendKind backendKind,
  bool fullscreen = false,
  Rect? bounds,
  Size? videoSize,
}) {
  return jsonEncode({
    'businessId': 'video_popout',
    'videoPath': videoPath,
    'backendKind': backendKind.name,
    'fullscreen': fullscreen,
    if (videoSize != null)
      'videoSize': {'w': videoSize.width, 'h': videoSize.height},
    if (bounds != null)
      'bounds': {
        'x': bounds.left,
        'y': bounds.top,
        'w': bounds.width,
        'h': bounds.height,
      },
  });
}
