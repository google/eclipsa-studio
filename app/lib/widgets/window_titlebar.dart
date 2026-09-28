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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../playback/playback_session.dart';
import '../session/session_provider.dart';
import '../state.dart';
import '../theme.dart';
import '../window_state.dart';
import '../workspace/workspace_mode.dart';
import 'app_menu_bar.dart';
import 'chrome_surface.dart';

/// Title shown in the window titlebar (and mirrored to the OS so
/// Mission Control / the Dock stay correct). Mode-dependent so the
/// user can tell at a glance which workspace is loaded; read-only
/// IAMF playback omits the dirty marker the Creator-mode session uses.
final _windowTitleProvider = Provider<String>((ref) {
  switch (ref.watch(workspaceModeProvider)) {
    case WorkspaceMode.playback:
      final path = ref.watch(playbackSessionProvider.select((s) => s?.path));
      return path != null ? p.basename(path) : 'Eclipsa Studio';
    case WorkspaceMode.creator:
      return ref.watch(
        sessionProvider.select((s) => s.dirty ? '${s.name} — Edited' : s.name),
      );
    case WorkspaceMode.none:
      return 'Eclipsa Studio';
  }
});

/// Custom window titlebar, VS Code style.
///
/// The native titlebar is hidden on both desktop platforms — macOS via
/// `MainFlutterWindow.swift` (`titlebarAppearsTransparent` +
/// `fullSizeContentView`), Windows via `TitleBarStyle.hidden` in
/// `main()`. This strip then owns the top of the window: themed
/// background, centered title, a drag region for moving the window, and
/// double-click to zoom.
///
/// The two platforms differ only in what flanks the title. macOS leaves
/// its native traffic-light buttons floating over the left edge, so a
/// fixed inset reserves that space. Windows has no native controls left,
/// so this strip draws its own minimize / maximize / close cluster on
/// the right; a matching spacer on the left keeps the title centered.
///
/// Mounted once at the app root (above landing + workspace alike), and
/// the single place that pushes the resolved title to the OS via
/// `windowManager.setTitle`. The strip itself is [WindowFrameStrip],
/// which the video pop-out window draws too (ES-744).
class WindowTitlebar extends ConsumerStatefulWidget {
  const WindowTitlebar({super.key});

  @override
  ConsumerState<WindowTitlebar> createState() => _WindowTitlebarState();
}

class _WindowTitlebarState extends ConsumerState<WindowTitlebar> {
  // Last value passed to `windowManager.setTitle` so we don't hit the
  // platform channel on every unrelated rebuild (theme, font, video).
  String? _lastSetTitle;

  @override
  void initState() {
    super.initState();
    // Push the initial title after the first frame — ref.listen (in build)
    // only fires on subsequent changes, never for the starting value.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final title = ref.read(_windowTitleProvider);
      _lastSetTitle = title;
      windowManager.setTitle(title);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);

    // Keep build() pure: push title changes to the OS via a listener that
    // fires after the frame, not synchronously during build. The initial
    // value is pushed once from initState's post-frame callback.
    ref.listen<String>(_windowTitleProvider, (_, next) {
      if (next == _lastSetTitle) return;
      _lastSetTitle = next;
      windowManager.setTitle(next);
    });
    final title = ref.watch(_windowTitleProvider);
    final onLanding = ref.watch(landingVisibleProvider);

    return WindowFrameStrip(
      title: title,
      onClose: requestWindowClose,
      // Windows has no system menu bar for the app, so the menus sit at
      // the left of this strip, as they do in other Windows apps with a
      // custom titlebar. macOS puts them in the system menu bar.
      leading: Platform.isWindows ? const FlutterMenuBar() : null,
      // On the landing screen the strip is part of the page's
      // ground rather than a bar of its own: transparent over the
      // ground the app root paints behind the window
      // (LandingGround). A session keeps the chrome, where the
      // strip is one surface with the top bar.
      ground: onLanding ? const SizedBox.expand() : null,
    );
  }
}

/// The window's top strip with the platform's window controls: the
/// drag region, the centred [title], the macOS traffic-light inset on
/// the left or the Windows caption cluster on the right, drawn by
/// [TitlebarStrip] in the theme's chrome.
///
/// Holds no app state, so a window without the main window's providers
/// draws it too: [WindowTitlebar] builds it for the main window with the
/// session's title, and the video pop-out draws it above its picture
/// with the file name. [onClose] is what the Windows close button runs;
/// macOS closes through its native buttons.
///
/// Collapses to nothing on platforms whose native titlebar is left in
/// place (Linux), where the strip would duplicate it; callers that sync
/// the title to the OS do so above this widget.
class WindowFrameStrip extends StatefulWidget {
  const WindowFrameStrip({
    super.key,
    required this.title,
    required this.onClose,
    this.ground,
    this.leading,
  });

  final String title;
  final Future<void> Function() onClose;

  /// Drawn at the left of the strip on Windows: the main window's menu
  /// bar. Ignored on macOS, where the traffic lights take that side.
  final Widget? leading;

  /// See [TitlebarStrip.ground].
  final Widget? ground;

  /// Width of the macOS traffic-light cluster (three buttons + margins).
  static const double trafficLightInset = 78;

  /// Width of a single Windows caption button.
  static const double captionButtonWidth = 46;

  @override
  State<WindowFrameStrip> createState() => _WindowFrameStripState();
}

class _WindowFrameStripState extends State<WindowFrameStrip>
    with WindowListener {
  // Tracks the maximize/restore state so the middle caption button can
  // swap its glyph. Windows only.
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
      windowManager.isMaximized().then((value) {
        if (mounted) setState(() => _isMaximized = value);
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasCustomBar = Platform.isMacOS || Platform.isWindows;
    if (!hasCustomBar) {
      return const SizedBox.shrink();
    }

    // Material supplies the AnimatedDefaultTextStyle ancestor the Text
    // below needs: this strip mounts above any Scaffold, and without it
    // debug builds paint the yellow "no Material" double-underline
    // fallback style. Transparent: the surface is the strip's own, per
    // theme.
    return Material(
      type: MaterialType.transparency,
      child: TitlebarStrip(
        title: widget.title,
        ground: widget.ground,
        // Under the row, not around it: see TitlebarStrip.dragRegion.
        // DragToMoveArea handles double-click zoom/restore with its own
        // internal GestureDetector — don't add another one here, it
        // would lose the gesture arena and silently never fire.
        dragRegion: const DragToMoveArea(child: SizedBox.expand()),
        // The macOS traffic lights float over the left edge, so their
        // width is reserved on both sides. TitlebarStrip centres the
        // title on the window whatever the two sides' widths are.
        leading: Platform.isMacOS
            ? const SizedBox(width: WindowFrameStrip.trafficLightInset)
            : widget.leading ?? const SizedBox.shrink(),
        trailing: Platform.isWindows
            ? _WindowsCaptionButtons(
                isMaximized: _isMaximized,
                onClose: widget.onClose,
              )
            : const SizedBox(width: WindowFrameStrip.trafficLightInset),
      ),
    );
  }
}

/// Windows minimize / maximize-restore / close cluster, right-aligned.
///
/// Sits over the strip's drag region rather than inside it, so a click
/// reaches only the button; dragging anywhere else on the strip still
/// moves the window.
class _WindowsCaptionButtons extends StatelessWidget {
  const _WindowsCaptionButtons({
    required this.isMaximized,
    required this.onClose,
  });

  final bool isMaximized;
  final Future<void> Function() onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          icon: Icons.remove,
          tooltip: 'Minimize',
          onPressed: windowManager.minimize,
        ),
        _CaptionButton(
          icon: isMaximized ? Icons.filter_none : Icons.crop_square,
          // filter_none is two offset squares — shrink it so it reads
          // as the standard "restore" glyph rather than oversized.
          iconSize: isMaximized ? 11 : 13,
          tooltip: isMaximized ? 'Restore' : 'Maximize',
          onPressed: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        _CaptionButton(
          icon: Icons.close,
          tooltip: 'Close',
          onPressed: onClose,
          isClose: true,
        ),
      ],
    );
  }
}

/// A single caption button, with a face under the pointer and while
/// held. Close gets the Windows red; minimize and maximize take
/// [titlebarHoverFace].
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 13,
    this.isClose = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;
  final bool isClose;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  void _setPressed(bool v) {
    if (mounted && _pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    // Close takes the Windows caption colours: red under the pointer,
    // lighter while held, with a white glyph. Minimize and maximize take
    // the titlebar's own hover face, as the menu titles beside them do,
    // and their glyphs are in chromeInk like the title.
    const closeRed = Color(0xFFE81123);
    const closePressed = Color(0xFFF1707A);
    final Color bg;
    if (widget.isClose) {
      bg = _pressed
          ? closePressed
          : _hovered
          ? closeRed
          : Colors.transparent;
    } else {
      bg = _pressed
          ? titlebarHoverFace(pressed: true)
          : _hovered
          ? titlebarHoverFace()
          : Colors.transparent;
    }
    final iconColor = widget.isClose && (_hovered || _pressed)
        ? T.white
        : T.chromeInk;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          child: Container(
            width: WindowFrameStrip.captionButtonWidth,
            height: T.titlebar,
            color: bg,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: widget.iconSize, color: iconColor),
          ),
        ),
      ),
    );
  }
}
