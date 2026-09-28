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
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'logging/log.dart';
import 'session/app_preferences.dart';
import 'window_geometry.dart';

/// Requests the main window to close, the way every "quit" affordance
/// (titlebar X, Exit menu item) should.
///
/// In a workspace, `AppShell` sets `preventClose`, so a plain `close()`
/// is intercepted and routed through its unsaved-changes confirmation —
/// we must NOT bypass that, so we still call `close()` there. With
/// nothing intercepting (the landing screen), we terminate directly.
///
/// On Windows the direct path is a hard process kill, not `destroy()`
/// or even `exit(0)`. On shutdown, GL plugins (`flutter_angle`, and
/// media_kit's video output before it was retired) delete GL resources
/// on an already-dying ANGLE display
/// and crash there (`libGLESv2!glDeleteQueries…`, `0xC0000005` /
/// `0xC000041D`). `destroy()` (→ `DestroyWindow` → view-controller
/// teardown) triggers it, and so does `exit(0)` (which still runs the
/// orderly Dart/Flutter/plugin teardown). `TerminateProcess` kills every
/// thread immediately without running any teardown, so the crashing GL
/// cleanup never executes; the OS reclaims the GL context, audio device,
/// and handles. macOS uses Metal (no ANGLE) and quits fine via
/// `close()`, so it is left on the proven path.
///
/// We call `TerminateProcess(GetCurrentProcess(), 0)` via FFI rather than
/// `Process.killPid(pid, sigkill)`: both map to `TerminateProcess`, but
/// `killPid` exits with a nonzero code, which makes a normal user quit
/// look like a crash to `build.ps1`'s `exit $proc.ExitCode`. Passing `0`
/// keeps a clean exit while still skipping teardown.
///
/// Because the kill runs no teardown, anything buffered behind an
/// unawaited timer dies with the process — so we first flush the
/// debounced window-geometry save (awaited) and the pending log lines
/// (a synchronous write). Nothing tears the window down before the
/// kill, so the GL render threads keep running normally (no teardown =
/// no crash trigger) during the await.
///
/// This works around an unresolved upstream ANGLE disposal bug. It was
/// first seen through media_kit (https://github.com/media-kit/media-kit/
/// issues/1324, and ES-857), but media_kit's retirement did NOT retire this
/// workaround: `flutter_angle` is a dependency of the 3D renderer
/// (`lib/renderer/`, via `three_js`) and hits the same ANGLE GL-teardown
/// crash on quit independently. Only a real upstream ANGLE disposal fix
/// (unfixed as of flutter_angle 0.4.0) or removing the GL renderer
/// retires the hard kill.
Future<void> requestWindowClose() async {
  if (await windowManager.isPreventClose()) {
    await windowManager.close();
  } else if (Platform.isWindows) {
    // Persist pending state before the teardown-skipping hard exit.
    await WindowStatePersister().flushNow();
    Log.instance.flush();
    try {
      _terminateCurrentProcess(0);
    } on Object catch (e) {
      // FFI lookup should never fail; if it somehow does, fall back to
      // destroy() so the window/process still goes away (it may hit the
      // GL teardown crash, but a stuck process is worse).
      Log.e(LogCat.app, 'TerminateProcess failed; falling back', e);
      await windowManager.destroy();
    }
  } else {
    await windowManager.close();
  }
}

/// Terminates the current process immediately with [exitCode] via Win32
/// `TerminateProcess`, skipping all DLL-detach / atexit / plugin
/// teardown. Windows-only — do not call elsewhere. Does not return.
void _terminateCurrentProcess(int exitCode) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getCurrentProcess = kernel32
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  final terminateProcess = kernel32
      .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>(
        'TerminateProcess',
      );
  terminateProcess(getCurrentProcess(), exitCode);
}

/// Exits the process with [exitCode], skipping Flutter/plugin teardown
/// on Windows the same way [requestWindowClose] does.
///
/// Dart's `exit()` still runs the orderly engine/plugin shutdown, and
/// on Windows that path wedges in the ANGLE GL teardown described
/// above — observed as a window-less zombie process that even an
/// external `TerminateProcess` cannot reap (ES-389). On other platforms
/// this is a plain `exit()`. The kill runs no teardown: this writes
/// the pending log lines, and callers must flush preferences first.
Never hardExit(int exitCode) {
  Log.instance.flush();
  if (Platform.isWindows) {
    try {
      _terminateCurrentProcess(exitCode);
    } on Object {
      // FFI lookup failure — fall through to exit(), which may hit the
      // teardown wedge, but a slow death beats no death at all.
    }
  }
  exit(exitCode);
}

/// Persists the main window's position, size, and full-screen state in
/// [AppPreferences], and restores them on subsequent launches, fitted
/// to the display work area (ES-613).
///
/// Usage:
///   1. Call [restoreBeforeShow] *after* `windowManager.ensureInitialized()`
///      and *before* `windowManager.show()` to apply the stored geometry
///      or, with nothing stored, the default.
///   2. Call [attach] once after `runApp` so move/resize events start
///      being persisted (debounced).
class WindowStatePersister {
  WindowStatePersister._();
  static final WindowStatePersister _instance = WindowStatePersister._();
  factory WindowStatePersister() => _instance;

  static const Duration _saveDebounce = Duration(milliseconds: 500);

  Timer? _saveTimer;
  _WindowListener? _listener;

  /// Applies the window geometry for this launch: the stored bounds
  /// fitted into the work area of the display they overlap most, or
  /// the default (the clamped minimum, centred in the primary work
  /// area) when nothing usable is stored. The minimum size is reduced
  /// to the work area as well, so a 13" display at default scaling,
  /// whose work area is under 900 pt tall, gets a window that fits it.
  /// The minimum is applied once here and by [resetToDefault]; it does
  /// not follow the window across displays.
  Future<void> restoreBeforeShow(Map<String, dynamic> prefs) async {
    final stored = _readStoredBounds(prefs);
    final fs = prefs[AppPreferences.kWindowFullScreen] == true;
    final areas = await _queryWorkAreas();

    if (areas == null) {
      // No display information: apply the stored bounds as they are,
      // under the preferred minimum, so the failure mode is the one
      // every launch had before the work-area fit.
      await windowManager.setMinimumSize(kPreferredMinWindowSize);
      if (stored == null) {
        await windowManager.setSize(kPreferredMinWindowSize);
        await windowManager.center();
        Log.i(LogCat.app, 'Window state: default size (no display info)');
      } else {
        await windowManager.setBounds(stored);
        Log.i(LogCat.app, 'Window state restored unfitted: $stored');
      }
    } else {
      final workArea = pickWorkArea(stored, areas.all, areas.primary);
      final minimum = clampMinimumSize(workArea);
      final bounds = stored == null
          ? defaultWindowBounds(workArea, minimum)
          : fitWindowBounds(stored, workArea, minimum);
      await windowManager.setMinimumSize(minimum);
      await windowManager.setBounds(bounds);
      Log.i(
        LogCat.app,
        'Window state: ${stored == null ? 'default' : 'restored $stored ->'}'
        ' $bounds in work area $workArea (min $minimum) fs=$fs',
      );
    }

    if (fs) {
      await windowManager.setFullScreen(true);
    }
  }

  /// Window → Reset Window Size: the default geometry on the display
  /// the window is on now. A full-screen window only leaves full
  /// screen; the exit animates, and a frame set during it is dropped,
  /// so the size reset needs a second invocation once it has left.
  Future<void> resetToDefault() async {
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
      Log.i(LogCat.app, 'Window reset: left full screen');
      return;
    }
    final areas = await _queryWorkAreas();
    if (areas == null) {
      await windowManager.setMinimumSize(kPreferredMinWindowSize);
      await windowManager.setSize(kPreferredMinWindowSize);
      await windowManager.center();
      Log.i(LogCat.app, 'Window reset: default size (no display info)');
      return;
    }
    final current = await windowManager.getBounds();
    final workArea = pickWorkArea(current, areas.all, areas.primary);
    final minimum = clampMinimumSize(workArea);
    final bounds = defaultWindowBounds(workArea, minimum);
    await windowManager.setMinimumSize(minimum);
    await windowManager.setBounds(bounds);
    Log.i(LogCat.app, 'Window reset: $bounds in work area $workArea');
  }

  /// The stored rectangle, or null when any of the four values is
  /// missing or no display could have produced it.
  Rect? _readStoredBounds(Map<String, dynamic> prefs) {
    final x = _readDouble(prefs[AppPreferences.kWindowX]);
    final y = _readDouble(prefs[AppPreferences.kWindowY]);
    final w = _readDouble(prefs[AppPreferences.kWindowW]);
    final h = _readDouble(prefs[AppPreferences.kWindowH]);
    if (x == null || y == null || w == null || h == null) return null;
    final r = Rect.fromLTWH(x, y, w, h);
    return isSaneStoredBounds(r) ? r : null;
  }

  /// Work areas of every display, in the top-left logical space
  /// `window_manager` uses for bounds. Null when the query fails or
  /// the primary display reports no geometry.
  Future<({List<Rect> all, Rect primary})?> _queryWorkAreas() async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      final primaryDisplay = await screenRetriever.getPrimaryDisplay();
      // The primary display's frame starts at the origin of this
      // space, so a missing visible position there means (0, 0).
      final primary = _workAreaOf(primaryDisplay, originIfMissing: true);
      if (primary == null) return null;
      final all = <Rect>[for (final d in displays) ?_workAreaOf(d)];
      if (all.isEmpty) all.add(primary);
      return (all: all, primary: primary);
    } on Object catch (e) {
      Log.w(LogCat.app, 'Display query failed; window not fitted', e);
      return null;
    }
  }

  static Rect? _workAreaOf(Display d, {bool originIfMissing = false}) {
    final size = d.visibleSize ?? d.size;
    final pos = d.visiblePosition ?? (originIfMissing ? Offset.zero : null);
    if (pos == null) return null;
    final r = Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);
    return isSaneStoredBounds(r) ? r : null;
  }

  /// Subscribes to window move/resize/full-screen events and persists
  /// the resulting state to preferences (debounced). Call once on
  /// startup after the window is visible.
  void attach() {
    if (_listener != null) return;
    _listener = _WindowListener(_onWindowChanged);
    windowManager.addListener(_listener!);
  }

  void detach() {
    if (_listener == null) return;
    windowManager.removeListener(_listener!);
    _listener = null;
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  void _onWindowChanged() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _saveNow);
  }

  /// Cancels any pending debounced save and persists the current window
  /// state synchronously. Call before a teardown-skipping hard exit on
  /// Windows quit so a resize made within the debounce window is not
  /// lost (the debounce timer would otherwise die with the process).
  Future<void> flushNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _saveNow();
  }

  Future<void> _saveNow() async {
    try {
      final bounds = await windowManager.getBounds();
      final fs = await windowManager.isFullScreen();
      await AppPreferences.setAll({
        AppPreferences.kWindowX: bounds.left,
        AppPreferences.kWindowY: bounds.top,
        AppPreferences.kWindowW: bounds.width,
        AppPreferences.kWindowH: bounds.height,
        AppPreferences.kWindowFullScreen: fs,
      });
    } on Object catch (e, st) {
      Log.e(LogCat.app, 'Failed to persist window state: $e', st);
    }
  }

  double? _readDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return null;
  }
}

class _WindowListener extends WindowListener {
  _WindowListener(this._onChanged);
  final VoidCallback _onChanged;

  @override
  void onWindowMove() => _onChanged();
  @override
  void onWindowResize() => _onChanged();
  @override
  void onWindowEnterFullScreen() => _onChanged();
  @override
  void onWindowLeaveFullScreen() => _onChanged();
  @override
  void onWindowMaximize() => _onChanged();
  @override
  void onWindowUnmaximize() => _onChanged();
}
