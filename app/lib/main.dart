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

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, MissingPluginException, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'import/adm_import_flow.dart';
import 'logging/log.dart';
import 'meters/meter_provider.dart';
import 'renderer/modules/ambient_particles.dart';
import 'renderer/modules/correlation_ribbons.dart';
import 'renderer/modules/energy_shell.dart';
import 'renderer/modules/intensity_vector.dart';
import 'renderer/modules/mollweide_overlay.dart';
import 'renderer/modules/soundfield_sphere.dart';
import 'renderer/modules/wavefronts.dart';
import 'renderer/viz_module.dart';
import 'session/app_preferences.dart';
import 'session/recent_sessions.dart';
import 'state.dart';
import 'theme.dart';
import 'video/video_backend_kind.dart';
import 'debug/control_channel.dart';
import 'video/popout_size.dart';
import 'video/video_popout_app.dart';
import 'video/video_popout_chrome.dart';
import 'video/video_provider.dart';
import 'widgets/app_menu_bar.dart';
import 'widgets/dev_shortcuts.dart';
import 'widgets/app_shell.dart';
import 'widgets/engine_unavailable_screen.dart';
import 'widgets/window_titlebar.dart';
import 'window_state.dart';
import 'workspace/landing_ground.dart';
import 'workspace/landing_screen.dart';
import 'workspace/workspace_close.dart';
import 'workspace/workspace_mode.dart';
import 'widgets/licenses_dialog.dart';

/// App support directory, resolved in [main] and read by the debug
/// control channel. Not a preference — it is the same directory the
/// JSONL log is opened in.
String? _stateDir;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // Determine which window we are before initialising file logging: the
  // video pop-out runs its own Flutter engine and re-enters main(), so it
  // must log to a separate file rather than truncate (and concurrently write
  // to) the main window's log.
  final controller = await WindowController.fromCurrentEngine();
  final arguments = controller.arguments;
  final popoutArgs = parsePopoutArgs(arguments);

  // Start file logging (JSONL in app support directory). The
  // resolved path is logged at INFO so it shows up in `flutter run`
  // stdout — copy-paste it into `tail -F`. Both debug and release
  // builds are sandboxed, so the path lives under ~/Library/
  // Containers/com.eclipsa.studio/...
  final appSupport = await getApplicationSupportDirectory();
  Log.instance.initFile(
    appSupport.path,
    fileName: popoutArgs.isVideoPopout
        ? 'eclipsa_studio_popout_log.jsonl'
        : 'eclipsa_studio_log.jsonl',
  );
  Log.i(LogCat.app, 'log file: ${Log.instance.logFilePath}');
  // Where the debug control channel writes its port and token,
  // beside the log so both are found the same way.
  _stateDir = appSupport.path;

  // Capture Flutter framework errors (e.g. RenderFlex overflow).
  FlutterError.onError = (details) {
    Log.e(LogCat.flutter, details.exceptionAsString(), details.stack);
    // Keep default console output in debug mode.
    FlutterError.presentError(details);
  };

  // Capture uncaught async errors.
  PlatformDispatcher.instance.onError = (error, stack) {
    Log.e(LogCat.flutter, error.toString(), stack);
    return true;
  };

  // Load the theme and font preferences before the first frame to avoid
  // a flash. Before the pop-out branch: the pop-out draws its title bar
  // in the theme's chrome (ES-744).
  final prefs = await AppPreferences.load();
  final storedTheme = prefs[AppPreferences.kThemeMode];
  if (storedTheme is String) {
    // themeModeFromId resolves enum names and token ids; a preference
    // stored under any other name falls back to the default.
    T.setMode(themeModeFromId(storedTheme) ?? T.defaultMode);
  }
  final storedFontSize = prefs[AppPreferences.kFontSizeMode];
  if (storedFontSize is String) {
    final mode = FontSizeMode.values.firstWhere(
      (m) => m.name == storedFontSize,
      orElse: () => FontSizeMode.medium,
    );
    T.setFontMode(mode);
  }

  if (popoutArgs.isVideoPopout) {
    final bounds = popoutArgs.bounds;
    final fullscreen = popoutArgs.fullscreen;
    // Size the window to the picture plus its two strips when the main
    // window passed the picture size and no frame was given, so the
    // clip opens with no letterbox. Otherwise 960 x 540 until the
    // pop-out's own backend reports the size (see _fitToVideo).
    var size = const Size(960, 540);
    final videoSize = popoutArgs.videoSize;
    if (bounds == null && videoSize != null) {
      try {
        final display = await screenRetriever.getPrimaryDisplay();
        size = fitPopoutSize(
          videoSize,
          display.visibleSize ?? display.size,
          chrome: PopoutChrome.chromeHeight,
        );
      } on Exception catch (e) {
        Log.w(LogCat.video, 'pop-out display query failed', e);
      }
    }
    final windowOptions = WindowOptions(
      size: size,
      center: true,
      backgroundColor: Colors.black,
      titleBarStyle: TitleBarStyle.hidden,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      // Place the window on the requested display *before* showing so an
      // external-display fullscreen never flashes on the primary first
      // (the window is created hidden — WindowConfiguration.hiddenAtLaunch).
      if (bounds != null) {
        await windowManager.setBounds(bounds);
      }
      // window_manager binds to this engine's own window (the view's
      // NSWindow on macOS, the view's root HWND on Windows), so the
      // title names the pop-out in Mission Control and the taskbar.
      await windowManager.setTitle(p.basename(popoutArgs.videoPath));
      await windowManager.show();
      await windowManager.focus();
      if (fullscreen) {
        await windowManager.setFullScreen(true);
      }
    });
    runApp(VideoPopoutApp(args: popoutArgs));
    return;
  }

  // Main window.
  // Register visualizer modules. Must happen before the first scene
  // build and before vizStateProvider hydrates — but after the video
  // pop-out early return above, which has no use for the registry.
  VizRegistry.register(EnergyShellModule());
  VizRegistry.register(CorrelationRibbonsModule());
  VizRegistry.register(WavefrontsModule());
  VizRegistry.register(AmbientParticlesModule());
  VizRegistry.register(SoundfieldSphereModule());
  VizRegistry.register(IntensityVectorModule());
  VizRegistry.register(MollweideOverlayModule());

  // On Windows the native titlebar is stripped here so the Flutter-drawn
  // WindowTitlebar owns the top of the window, matching the macOS
  // treatment (which hides its native bar in MainFlutterWindow.swift).
  // macOS is left untouched — the Swift side already hides its bar
  // before the first frame, so routing it through window_manager would
  // be redundant.
  if (Platform.isWindows) {
    const windowOptions = WindowOptions(titleBarStyle: TitleBarStyle.hidden);
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    // Intercept native close messages (Alt+F4, taskbar Close) for the
    // whole process lifetime: an un-intercepted WM_CLOSE runs the
    // orderly plugin teardown, which wedges in the ANGLE GL teardown
    // (window_state.dart) and leaves an unkillable zombie process
    // (ES-390). With a workspace open, AppShell's listener handles the
    // close (unsaved-changes flow); otherwise
    // _EclipsaStudioAppState.onWindowClose quits the hard-kill way.
    await windowManager.setPreventClose(true);
  }

  // Parse CLI args: --session <path>, --iamf <path>
  // Try both main() args and Platform.executableArguments.
  String? autoLoadSession;
  String? autoLoadIamf;
  final allArgs = [...args, ...Platform.executableArguments];
  for (var i = 0; i < allArgs.length - 1; i++) {
    if (allArgs[i] == '--session') {
      autoLoadSession = allArgs[i + 1];
    } else if (allArgs[i] == '--iamf') {
      autoLoadIamf = allArgs[i + 1];
    }
  }
  // Also check environment variable as fallback.
  autoLoadIamf ??= Platform.environment['ECLIPSA_STUDIO_IAMF'];
  if (autoLoadIamf != null) {
    Log.i(LogCat.app, 'CLI --iamf: $autoLoadIamf');
  }
  // Also check environment variable as fallback.
  autoLoadSession ??= Platform.environment['ECLIPSA_STUDIO_SESSION'];
  // Also check a "startup command" file in app support.
  if (autoLoadSession == null) {
    final startupFile = File(p.join(appSupport.path, 'startup_session.txt'));
    if (startupFile.existsSync()) {
      autoLoadSession = startupFile.readAsStringSync().trim();
      startupFile.deleteSync(); // one-shot
    }
  }
  // --iamf opens directly into Playback mode; it takes precedence over any
  // resolved session (CLI / env / startup file) so the two startup paths
  // can't fight over the workspace mode.
  if (autoLoadIamf != null) autoLoadSession = null;
  if (autoLoadSession != null) {
    Log.i(LogCat.session, 'CLI --session: $autoLoadSession');
  }

  // Smoke-test hook: `--quit-after-load` (or ECLIPSA_STUDIO_QUIT_AFTER_LOAD=1)
  // exits the app once the auto-loaded session is up — exit 0 on
  // success, 1 on load failure, 2 when no session was given to load.
  // The exit itself happens in AppShell after the auto-load completes.
  final quitAfterLoad =
      allArgs.contains('--quit-after-load') ||
      Platform.environment['ECLIPSA_STUDIO_QUIT_AFTER_LOAD'] == '1';

  // Decide the startup workspace mode and (if any) session to
  // auto-load. Creator-bootstrap is triggered by either:
  //   (1) --session / ECLIPSA_STUDIO_SESSION / startup_session.txt pointing
  //       at an existing file, or
  //   (2) kReopenLastProject (default off) with a non-empty recent-
  //       sessions list whose most-recent entry still exists.
  // Otherwise workspaceMode stays `none` and the Consumer below
  // mounts the landing screen. The resolved session path (if any)
  // is threaded through autoLoadSessionProvider so AppShell's
  // existing auto-load path can load it without re-deciding —
  // `AppShell` does not re-check kReopenLastProject.
  final bootstrap = await _computeBootstrap(
    autoLoadSession: autoLoadSession,
    prefs: prefs,
  );
  Log.i(
    LogCat.app,
    'startup workspace mode: ${bootstrap.mode.name}'
    '${bootstrap.sessionToLoad != null ? ' (loading ${bootstrap.sessionToLoad})' : ''}',
  );

  if (quitAfterLoad && bootstrap.sessionToLoad == null) {
    Log.e(
      LogCat.app,
      '--quit-after-load: no session resolved '
      '(--session not given, or the path does not exist) — exit 2',
    );
    // hardExit, not exit(): on Windows exit() runs the plugin teardown
    // that wedges instead of exiting (ES-389).
    hardExit(2);
  }

  // Apply the window geometry: the stored bounds fitted into the work
  // area of the display they were on, or the default (the minimum
  // size, itself reduced to the display, centred) when nothing usable
  // is stored (ES-613).
  final persister = WindowStatePersister();
  await persister.restoreBeforeShow(prefs);
  // Start persisting move/resize/full-screen changes.
  persister.attach();

  // Register the third-party licenses the app ships that Flutter does
  // not embed itself: the engine's statically linked libraries, the
  // libraries and frameworks shipped beside the app, and the bundled
  // typefaces. The Third-Party Licenses window
  // (widgets/licenses_dialog.dart) shows them alongside the Dart
  // package NOTICES. Generated by scripts/collect_third_party_notices.py.
  LicenseRegistry.addLicense(() async* {
    List<Map<String, dynamic>> components;
    try {
      final raw = await rootBundle.loadString(
        'assets/third_party_notices.json',
      );
      components =
          ((jsonDecode(raw) as Map<String, dynamic>)['components'] as List)
              .cast<Map<String, dynamic>>();
    } on Exception catch (e) {
      Log.w(LogCat.app, 'Failed to load third-party notices', e);
      return;
    }
    for (final c in components) {
      final label = '${c['name']} — ${c['license']}';
      LicensesDialog.nativeKinds[label] = c['kind'] as String? ?? 'engine';
      yield LicenseEntryWithLineBreaks([label], c['text'] as String);
    }
  });

  runApp(
    ProviderScope(
      overrides: [
        if (bootstrap.sessionToLoad != null)
          autoLoadSessionProvider.overrideWithValue(bootstrap.sessionToLoad),
        if (autoLoadIamf != null)
          autoLoadIamfProvider.overrideWithValue(autoLoadIamf),
        if (quitAfterLoad) quitAfterLoadProvider.overrideWithValue(true),
        workspaceModeProvider.overrideWith(
          () => _StartupWorkspaceModeNotifier(bootstrap.mode),
        ),
        // Seed the selected video backend from prefs so the first backend
        // built is the right one — otherwise the provider starts on `auto`
        // (the platform default) and only swaps on first load, spinning up
        // a throwaway player when a different backend is selected.
        videoBackendProvider.overrideWith(
          () => _StartupVideoBackendNotifier(
            videoBackendFromName(
              prefs[AppPreferences.kVideoBackend] as String?,
              currentTargetOs(),
            ),
          ),
        ),
      ],
      child: const EclipsaStudioApp(),
    ),
  );
}

typedef _BootstrapResult = ({WorkspaceMode mode, String? sessionToLoad});

/// Resolve the startup workspace mode and optional session path from
/// CLI args / preferences. Pure function — no side effects on
/// provider state. The session-load happens later in AppShell's init.
Future<_BootstrapResult> _computeBootstrap({
  required String? autoLoadSession,
  required Map<String, dynamic> prefs,
}) async {
  if (autoLoadSession != null && File(autoLoadSession).existsSync()) {
    return (mode: WorkspaceMode.creator, sessionToLoad: autoLoadSession);
  }
  final reopen = prefs[AppPreferences.kReopenLastProject] as bool? ?? false;
  if (reopen) {
    final recents = await RecentSessions.load();
    if (recents.isNotEmpty && File(recents.first).existsSync()) {
      return (mode: WorkspaceMode.creator, sessionToLoad: recents.first);
    }
  }
  return (mode: WorkspaceMode.none, sessionToLoad: null);
}

/// Override for [workspaceModeProvider] that seeds the initial mode
/// from the startup bootstrap decision. Used only from `main()`.
class _StartupWorkspaceModeNotifier extends WorkspaceModeNotifier {
  _StartupWorkspaceModeNotifier(this._initial);
  final WorkspaceMode _initial;
  @override
  WorkspaceMode build() => _initial;
}

/// Override for [videoBackendProvider] that seeds the selected backend from
/// preferences at startup (see the override site in `main()`). Used only
/// from `main()`. `AppShell` still calls `restore` later — a harmless no-op
/// that sets the same value.
class _StartupVideoBackendNotifier extends VideoBackendNotifier {
  _StartupVideoBackendNotifier(this._initial);
  final VideoBackendKind _initial;
  @override
  VideoBackendKind build() => _initial;
}

class EclipsaStudioApp extends ConsumerStatefulWidget {
  const EclipsaStudioApp({super.key});

  @override
  ConsumerState<EclipsaStudioApp> createState() => _EclipsaStudioAppState();
}

class _EclipsaStudioAppState extends ConsumerState<EclipsaStudioApp>
    with WindowListener {
  DebugControlChannel? _control;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    // macOS: the app delegate asks this engine, on its own channel, before
    // the app terminates (ES-844); see _confirmAndTearDownForExit. Windows
    // quits through a teardown-skipping hard kill instead.
    if (Platform.isMacOS) {
      _appExitChannel.setMethodCallHandler(_handleAppExitCall);
    }
    windowManager.addListener(this);
    // The one call site. kDebugControlChannelEnabled is a compile-time
    // const, so in release this collapses and control_channel.dart is
    // tree-shaken out of the binary entirely (ES-688).
    if (kDebugControlChannelEnabled) {
      final dir = _stateDir;
      if (dir != null) {
        DebugControlChannel.start(
          navigatorKey: _navigatorKey,
          stateDir: dir,
        ).then((c) {
          // dispose() can run before this resolves — a hot restart
          // or a quick quit right after launch, which is this
          // feature's own usage pattern. Without the check the
          // server is assigned to a dead State and its port is
          // never released.
          if (_disposed) {
            c?.close();
          } else {
            _control = c;
          }
        });
      }
    }
  }

  @override
  void dispose() {
    if (Platform.isMacOS) _appExitChannel.setMethodCallHandler(null);
    _disposed = true;
    _control?.close();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    // Windows only: main() armed setPreventClose for the whole process
    // lifetime (ES-390), so every native close (Alt+F4, taskbar Close)
    // lands here as well as on any other registered listener. With a
    // workspace mounted, AppShell's listener owns the close (it runs
    // the unsaved-changes flow) — stay out of its way. Otherwise
    // (landing or engine-unavailable screen, which have no state to
    // lose) quit the hard-kill way, mirroring the tail of
    // AppShell._handleWindowClose.
    if (!Platform.isWindows) return;
    final engineUp = ref.read(engineLoadProvider).engine != null;
    if (engineUp && ref.read(workspaceModeProvider) != WorkspaceMode.none) {
      return;
    }
    unawaited(() async {
      await windowManager.setPreventClose(false);
      await requestWindowClose();
    }());
  }

  static const _appExitChannel = MethodChannel('eclipsa/app_exit');

  /// Answers the macOS app delegate's `requestExit`. The reply must be
  /// exactly "exit" or "cancel": AppDelegate.applicationShouldTerminate
  /// keeps the app running only on "cancel".
  Future<Object?> _handleAppExitCall(MethodCall call) async {
    if (call.method != 'requestExit') {
      throw MissingPluginException('eclipsa/app_exit: ${call.method}');
    }
    try {
      return await _confirmAndTearDownForExit() ? 'exit' : 'cancel';
    } on Object catch (e, st) {
      // The app delegate treats any reply other than 'cancel' as consent
      // to terminate, so a failure in the prompt or the save must keep
      // the app running rather than quit without the teardown.
      Log.e(LogCat.app, 'Quit failed; the app stays open: $e', st);
      return 'cancel';
    }
  }

  /// macOS quit: every `terminate:` (Cmd+Q, the Quit menu, the Dock, the
  /// last window closing) arrives here through the app delegate. Asks
  /// about unsaved changes, then tears down the native subsystems that
  /// hold Dart FFI callbacks, the video backends and the audio engine,
  /// *before* the Dart VM shuts down. Their provider `ref.onDispose` hooks
  /// do not run on `terminate:`, so a decoder thread or the engine's log
  /// callback could otherwise call into a half-shut-down VM and abort the
  /// process (ES-203). Returns false when the user cancels.
  Future<bool> _confirmAndTearDownForExit() async {
    final container = ProviderScope.containerOf(context, listen: false);

    // Quit arrives here without passing the window's close handler, so
    // ask about unsaved changes (ES-844). A window close that already asked
    // marked the exit confirmed, and confirmExit then skips.
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext != null) {
      // Quit is often pressed with the video pop-out in front, or with the
      // main window minimised: bring the window that asks to the front
      // (show() also restores a minimised window).
      if (exitWouldPrompt(ref)) {
        await windowManager.show();
        await windowManager.focus();
      }
      if (!dialogContext.mounted || !await confirmExit(dialogContext, ref)) {
        Log.i(LogCat.app, 'Exit cancelled at the unsaved-changes prompt');
        return false;
      }
    }

    Log.i(LogCat.app, 'Exit requested — disposing video player and engine');
    // Tear the video player and engine down INDEPENDENTLY: a failure or
    // hang in one must not skip the other. The engine's audio thread + log
    // NativeCallable are the more important things to stop before the VM
    // goes away (issue ES-203). The video dispose is awaited only up to a
    // timeout so a wedged decoder thread can't trap the user in an
    // un-quittable app — we proceed to exit regardless.
    if (container.exists(videoProvider)) {
      // The pop-out's own engine and decoder first: the main video's
      // shutdown below only sends the pop-out 'close' and does not wait.
      // Once the pop-out has shut its backend down, its window stays up,
      // empty, until the process exits.
      await container.read(videoProvider.notifier).shutdownPopoutForQuit();
      try {
        await container
            .read(videoProvider.notifier)
            .shutdown()
            .timeout(const Duration(seconds: 3));
      } on Object catch (e, st) {
        Log.e(LogCat.app, 'Video shutdown failed/timed out: $e', st);
      }
    }
    try {
      // Awaited: shutdown() yields one event-loop turn so the final log
      // drain's listener messages run before the NativeCallable closes.
      await container.read(eclipsaStudioEngineProvider)?.shutdown();
    } on Object catch (e, st) {
      Log.e(LogCat.app, 'Engine shutdown failed: $e', st);
    }
    // The ADM import bridge runs native render workers that must be joined
    // before the engine dylib unloads — same shutdown race as the engine.
    // Only created once an import has run, so guard on `exists`.
    if (container.exists(admImportBridgeProvider)) {
      try {
        container.read(admImportBridgeProvider).shutdown();
      } on Object catch (e, st) {
        Log.e(LogCat.app, 'ADM bridge shutdown failed: $e', st);
      }
    }
    // The app terminates after the reply: write the pending log lines.
    Log.instance.flush();
    return true;
  }

  // Held as a field, not built per-build: a GlobalKey recreated on
  // every build detaches and reattaches the Navigator, losing its
  // route stack.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    // Watch theme mode to rebuild entire app on theme change.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);

    return MaterialApp(
      title: 'Eclipsa Studio',
      debugShowCheckedModeBanner: false,
      theme: eclipsaStudioTheme(),
      navigatorKey: _navigatorKey,
      // Above the Navigator, so the debug-only `t` / `g` keys work over
      // dialogs as well as the workspace — `g` has to reach the gallery
      // route to close it. It therefore has no Navigator in its own
      // context, hence the key. Compiled out of release builds.
      builder: (context, child) =>
          DevShortcuts(navigatorKey: _navigatorKey, child: child!),
      // The native titlebar is hidden (macOS: MainFlutterWindow.swift;
      // Windows: TitleBarStyle.hidden in main()), so WindowTitlebar owns
      // the very top strip of the window across all screens — landing,
      // workspace, and engine-unavailable alike. On Windows it also
      // carries the Flutter-drawn menu bar at its left; on macOS the
      // menus live in the system menu bar (AppMenuBar).
      home: Stack(
        // Expand: the Column below had the route's tight constraints
        // before the glow went behind it, and keeps them.
        fit: StackFit.expand,
        children: [
          // The landing ground, behind the whole window: the titlebar,
          // with the Windows menu bar in it, and the landing screen draw
          // transparent over it (LandingGround).
          Positioned.fill(
            child: Consumer(
              builder: (_, ref, _) => ref.watch(landingVisibleProvider)
                  ? const LandingGround()
                  : const SizedBox.shrink(),
            ),
          ),
          Column(
            children: [
              const WindowTitlebar(),
              Expanded(
                child: AppMenuBar(
                  child: StartupRestore(
                    child: Consumer(
                      builder: (ctx, ref, _) {
                        // The app is not operational without the native
                        // engine: block the whole workspace (landing
                        // included) behind a diagnostic screen rather than
                        // limp along half-working.
                        final engineLoad = ref.watch(engineLoadProvider);
                        if (engineLoad.engine == null) {
                          return const EngineUnavailableScreen();
                        }
                        return ref.watch(landingVisibleProvider)
                            ? const LandingScreen()
                            : const AppShell();
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
