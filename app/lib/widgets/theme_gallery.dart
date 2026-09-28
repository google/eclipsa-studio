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

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';
import '../video/video_strip.dart';
import '../video/video_track.dart';
import '../views/gain_slider.dart';
import 'app_button.dart';
import 'app_dialog.dart';
import 'chrome_surface.dart';
import 'component_index.dart';
import 'component_info.dart';
import 'console_widgets.dart';
import 'dialog_shell.dart';
import 'drop_zone.dart';
import 'eclipsa_audio_lockup.dart';
import 'eclipsa_studio_lockup.dart';
import 'eclipsa_studio_mark.dart';
import 'eclipsa_studio_wordmark.dart';
import 'eyebrow_label.dart';
import 'gain_knob.dart';
import 'solo_mute_button.dart';
import 'statusbar.dart';
import 'time_ruler.dart';
import 'topbar_selector.dart';
import 'topbar_tab.dart';
import 'track_lanes.dart';
import 'transport_clock.dart';
import 'transport_controls.dart';

/// The gallery's timeline demo: 16:44.231 long with the playhead at
/// 3:07.153, the clock card's readout.
const double _demoDuration = 1004.231;
const double _demoPlayhead = 187.153;

/// The lane demo's block border, `trackBlockDecoration`'s.
double get _laneBorder => trackBlockBorderWidth();

/// Dev-only theme gallery: every colour token and the primitives built
/// from them, on one screen, switchable across themes and font modes.
///
/// This is the surface you screenshot to compare the themes. It
/// exists because "did that theme change break light mode" is otherwise
/// a manual sweep of every dialog in the app. Neither `flutter analyze`
/// nor the token drift gate checks legibility.
///
/// Debug builds only. [ThemeGallery.show] is a no-op in release, and the
/// menu item that opens it is not built there either, so this never
/// reaches users.
class ThemeGallery extends ConsumerStatefulWidget {
  const ThemeGallery({super.key});

  // Tracked so `g` can close the gallery it opened. The dialog's own
  // context is kept rather than popping the root navigator, which
  // would shut whatever happens to be on top instead.
  static BuildContext? _dialogContext;

  /// Whether the gallery is currently on screen.
  static bool get isOpen => _dialogContext != null;

  // The open gallery's vertical scroll controller, set by _ZoomViewState
  // while it is mounted, so the debug control channel can scroll the
  // gallery to a component the running session cannot show.
  static ScrollController? _scroll;

  /// Scrolls the open gallery to [offset] logical pixels from the top,
  /// clamped to its extent, and returns the offset it landed on and
  /// the furthest it can go; null when no gallery is scrollable.
  static ({double offset, double max})? scrollTo(double offset) {
    final c = _scroll;
    if (c == null || !c.hasClients) return null;
    final max = c.position.maxScrollExtent;
    final next = offset.clamp(0.0, max);
    if (next != c.offset) c.jumpTo(next);
    return (offset: next, max: max);
  }

  /// Opens the gallery. No-op outside debug builds.
  static void show(BuildContext context) {
    if (!kThemeGalleryEnabled) return;
    // Kept alongside the id guard in showAppDialog: a dropped
    // call returns an already-complete future, and the
    // whenComplete below would clear _dialogContext while the
    // gallery is still up, leaving `g` with nothing to close.
    if (isOpen) return;
    showAppDialog<void>(
      context: context,
      id: ThemeGallery,
      builder: (ctx) {
        _dialogContext = ctx;
        return const ThemeGallery();
      },
    ).whenComplete(() => _dialogContext = null);
  }

  /// Opens the gallery, or closes it if it is already up.
  ///
  /// Bound to `g` in debug builds: the key that opens the gallery also
  /// closes it, without the Done button.
  static void toggle(BuildContext context) {
    if (!kThemeGalleryEnabled) return;
    final dialogContext = _dialogContext;
    if (dialogContext != null) {
      // Remove the gallery's own route: pop() would close whatever is on
      // top of it, such as a menu opened from a primitive in the gallery.
      final route = dialogContext.mounted ? ModalRoute.of(dialogContext) : null;
      if (route != null) Navigator.of(dialogContext).removeRoute(route);
      return;
    }
    show(context);
  }

  @override
  ConsumerState<ThemeGallery> createState() => _ThemeGalleryState();
}

class _ThemeGalleryState extends ConsumerState<ThemeGallery> {
  double _zoom = 1;

  @override
  Widget build(BuildContext context) {
    // Watched so this build re-runs when either mode changes. That is
    // necessary but not sufficient: the body below must also not be
    // `const`, or Element.updateChild short-circuits on the canonical
    // instance and the subtree keeps the old theme however often this
    // rebuilds. See _Body.
    final mode = ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);

    // Fills the window rather than sitting at a fixed 980x760: at 4x
    // the body is four screens wide, so the barrier is wasted space.
    // Clamped at the low end so a small window still gets a usable
    // dialog instead of a sliver. DialogShell takes `width` as an exact
    // size (minWidth == maxWidth), so there is no second constraint to
    // keep in step.
    final screen = MediaQuery.sizeOf(context);
    const margin = 24.0;
    final width = max(560.0, screen.width - margin * 2);
    final height = max(420.0, screen.height - margin * 2);

    return DialogShell(
      title: 'Theme Gallery',
      subtitle:
          'Debug builds only. Every token and primitive, rendered '
          'in the active theme.',
      width: width,
      maxHeight: height,
      insetPadding: const EdgeInsets.all(margin),
      // The body scrolls and must not grow past the dialog: with the
      // default `intrinsic` fit the inner scroll view gets unbounded
      // height and the whole gallery overflows off the bottom.
      bodyFit: DialogBodyFit.flexible,
      actions: [DialogShell.done(context)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Controls(
            mode: mode,
            zoom: _zoom,
            onZoom: (z) => setState(() => _zoom = z),
          ),
          const SizedBox(height: T.gapLg),
          Flexible(
            child: _ZoomView(zoom: _zoom, child: _Body()),
          ),
        ],
      ),
    );
  }
}

/// Scales the gallery body without breaking its layout, and pans it
/// with the middle mouse button.
///
/// [Transform.scale] alone would not do: it changes what is painted and
/// not what is measured, so the scroll views underneath keep the
/// unscaled extent and the magnified content is simply clipped. A
/// [FittedBox] given an explicitly widened box scales *and* reports the
/// scaled height, so both scroll axes get the right extent.
///
/// Middle-button panning is required. A mouse wheel only drives the
/// vertical axis, and Flutter's desktop [ScrollBehavior] leaves
/// [PointerDeviceKind.mouse] out of its drag devices, so the horizontal
/// axis has no input at all with a mouse — the content is reachable
/// only by trackpad. Adding mouse to `dragDevices` would fix that by
/// making any left-drag pan, which would fight every draggable
/// primitive in the gallery; the knobs are dragged to change their
/// value. The middle button collides with nothing.
///
/// Content follows the pointer, so dragging left moves the view right.
///
/// The magnification is a transform, so the primitives are re-rasterised
/// at device resolution and stay sharp. That is the right tool for
/// reading geometry — spacing, radii, where an arc starts — but it is
/// the wrong one for judging whether a control survives at its shipped
/// size, because antialiasing that would be mush at 28px comes out
/// clean here. For that question, look at 1x.
class _ZoomView extends StatefulWidget {
  const _ZoomView({required this.zoom, required this.child});

  final double zoom;
  final Widget child;

  @override
  State<_ZoomView> createState() => _ZoomViewState();
}

class _ZoomViewState extends State<_ZoomView> {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  bool _panning = false;

  @override
  void initState() {
    super.initState();
    ThemeGallery._scroll = _vertical;
  }

  @override
  void dispose() {
    if (identical(ThemeGallery._scroll, _vertical)) ThemeGallery._scroll = null;
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent e) {
    if (e.buttons & kMiddleMouseButton != 0) {
      setState(() => _panning = true);
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!_panning) return;
    _by(_horizontal, -e.delta.dx);
    _by(_vertical, -e.delta.dy);
  }

  void _onUp(PointerEvent e) {
    if (_panning) setState(() => _panning = false);
  }

  // jumpTo rather than animateTo: this runs once per pointer move, and
  // an animation per event would lag the cursor and fight the next one.
  void _by(ScrollController c, double delta) {
    if (!c.hasClients) return;
    final p = c.position;
    final next = (c.offset + delta).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (next != c.offset) c.jumpTo(next);
  }

  @override
  Widget build(BuildContext context) {
    final zoom = widget.zoom;
    Widget body;
    if (zoom == 1) {
      body = Scrollbar(
        controller: _vertical,
        child: SingleChildScrollView(
          controller: _vertical,
          child: widget.child,
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final base = constraints.maxWidth;
          return Scrollbar(
            controller: _vertical,
            child: SingleChildScrollView(
              controller: _vertical,
              child: Scrollbar(
                controller: _horizontal,
                // Both bars are always shown: at 4x the only cue that
                // there is more to the right is the bar itself.
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: base * zoom,
                    child: FittedBox(
                      fit: BoxFit.fitWidth,
                      alignment: Alignment.topLeft,
                      child: SizedBox(width: base, child: widget.child),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: MouseRegion(
        cursor: _panning ? SystemMouseCursors.grabbing : MouseCursor.defer,
        child: body,
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body();

  // No section here is `const`. Every section reads T.* at build time,
  // so a canonical const instance would let Element.updateChild skip
  // the rebuild and the gallery would keep the theme it was opened on.
  // The SizedBox spacers stay const: they read only T.gapLg, a static
  // const.
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Typography(),
        const SizedBox(height: T.gapLg),
        _TextRamp(),
        const SizedBox(height: T.gapLg),
        _Surfaces(),
        const SizedBox(height: T.gapLg),
        _Primitives(),
        const SizedBox(height: T.gapLg),
        _Meters(),
        const SizedBox(height: T.gapLg),
        _Swatches(),
      ],
    );
  }
}

/// Whether the gallery is available. [kDebugMode] is a compile-time
/// const, so in a release build every use of this collapses and the
/// gallery is tree-shaken out entirely — it is not merely hidden.
const bool kThemeGalleryEnabled = kDebugMode;

// ─────────────────────────────────────────────────────────────────────
// Controls
// ─────────────────────────────────────────────────────────────────────

class _Controls extends ConsumerWidget {
  const _Controls({
    required this.mode,
    required this.zoom,
    required this.onZoom,
  });

  final AppThemeMode mode;
  final double zoom;
  final ValueChanged<double> onZoom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        // Inline rather than a dropdown: every theme visible at once is
        // the point of the gallery, and unlike the Settings rows there
        // is room for it here. Scrollable so that stays true as design
        // themes accumulate — equal-width cells would otherwise start
        // overflowing somewhere around six, which is exactly how this
        // failed in Settings (console_segment_width_test).
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConsoleSegment<AppThemeMode>(
              value: mode,
              options: [
                for (final m in AppThemeMode.values) (m, kThemeMeta[m]!.label),
              ],
              onChanged: (v) => ref.read(themeModeProvider.notifier).set(v),
            ),
          ),
        ),
        const SizedBox(width: T.gapMd),
        ConsoleSegment<FontSizeMode>(
          value: ref.watch(fontSizeModeProvider),
          options: [for (final f in FontSizeMode.values) (f, f.label)],
          onChanged: (v) => ref.read(fontSizeModeProvider.notifier).set(v),
        ),
        const SizedBox(width: T.gapMd),
        ConsoleSegment<double>(
          value: zoom,
          options: const [(1.0, '1x'), (2.0, '2x'), (3.0, '3x'), (4.0, '4x')],
          onChanged: onZoom,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Sections
// ─────────────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The shared eyebrow recipe (ES-319), which also self-tracks the
        // theme and font mode.
        EyebrowLabel(title),
        const SizedBox(height: T.gapSm),
        child,
      ],
    );
  }
}

/// The bundled faces at every weight the app ships. If a row renders in
/// the system UI font instead, the family failed to load — which is the
/// failure bundling was meant to end, and the one thing the generator's
/// pubspec cross-check cannot catch on its own.
class _Typography extends StatelessWidget {
  const _Typography();

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Typography · ${T.uiFamily} + ${T.monoFamily}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (family, weights) in <(String, List<FontWeight>)>[
            (
              T.uiFamily,
              [
                FontWeight.w400,
                FontWeight.w500,
                FontWeight.w600,
                FontWeight.w700,
              ],
            ),
            (T.monoFamily, [FontWeight.w400, FontWeight.w700]),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Wrap(
                spacing: T.gapMd,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final w in weights)
                    Text(
                      '$family ${w.value} 0123',
                      style: TextStyle(
                        fontFamily: family,
                        fontWeight: w,
                        fontSize: T.fontBody,
                        color: T.textPrimary,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TextRamp extends StatelessWidget {
  const _TextRamp();

  @override
  Widget build(BuildContext context) {
    const ramp = <(String, String)>[
      ('textPrimary', 'Headings and primary copy'),
      ('textSecondary', 'Labels and descriptions'),
      ('textTertiary', 'Inactive and disabled'),
      ('textMuted', 'Subtle labels'),
      ('textGhost', 'Barely visible — grid lines'),
      ('textValue', 'Numeric readout −19.0 LUFS'),
      ('textValueDim', 'Secondary value −2.4 dBTP'),
      ('textInactive', 'Inactive control'),
    ];
    return _Section(
      title: 'Text',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (name, sample) in ramp)
            Padding(
              padding: const EdgeInsets.only(bottom: T.gapXs),
              child: Row(
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(
                      name,
                      style: TextStyle(
                        color: T.textMuted,
                        fontSize: T.fontCaption,
                        fontFamily: T.monoFamily,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      sample,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _textToken(name),
                        fontSize: T.fontBody,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static Color _textToken(String name) => switch (name) {
    'textPrimary' => T.textPrimary,
    'textSecondary' => T.textSecondary,
    'textTertiary' => T.textTertiary,
    'textMuted' => T.textMuted,
    'textGhost' => T.textGhost,
    'textValue' => T.textValue,
    'textValueDim' => T.textValueDim,
    _ => T.textInactive,
  };
}

class _Surfaces extends StatelessWidget {
  const _Surfaces();

  @override
  Widget build(BuildContext context) {
    final surfaces = <(String, Color)>[
      ('bgDeep', T.bgDeep),
      ('bgBase', T.bgBase),
      ('landingGroundTop', T.landingGroundTop),
      ('landingGroundBottom', T.landingGroundBottom),
      ('bgSurface', T.bgSurface),
      ('bgElevated', T.bgElevated),
      ('bgControls', T.bgControls),
      ('bgHover', T.bgHover),
      ('bgSelected', T.bgSelected),
    ];
    final borders = <(String, Color)>[
      ('border', T.border),
      ('borderLight', T.borderLight),
      ('borderStrong', T.borderStrong),
    ];
    return _Section(
      title: 'Surfaces and borders',
      child: Wrap(
        spacing: T.gapSm,
        runSpacing: T.gapSm,
        children: [
          for (final (name, c) in surfaces) _Chip(name: name, fill: c),
          for (final (name, c) in borders)
            _Chip(name: name, fill: T.bgBase, border: c),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.name, required this.fill, this.border});

  final String name;
  final Color fill;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 128,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(
          color: border ?? T.border,
          width: border != null ? 2 : 1,
        ),
      ),
      child: Text(
        name,
        style: TextStyle(
          color: T.textSecondary,
          fontSize: T.fontCaption,
          fontFamily: T.monoFamily,
        ),
      ),
    );
  }
}

class _Primitives extends StatefulWidget {
  const _Primitives();

  @override
  State<_Primitives> createState() => _PrimitivesState();
}

class _PrimitivesState extends State<_Primitives> {
  bool _toggle = true;
  int _seg = 0;
  int _sel = 0;
  double _fader = 0;
  int _tab = 0;
  int _mix = 0;
  bool _playing = false;
  bool _looping = false;
  // Three positions, because the knob's arc is the part that moves and a
  // single value hides both ends of it.
  final List<double> _gains = [-60, 0, 12];

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Components',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The chrome pieces with a theme-selected drawing (ChromeStyle)
          // come first, top to bottom as the window stacks them: they are
          // what differs most between the themes, and switching
          // theme above swaps the drawing in place, which is the
          // comparison the gallery is for.
          // The traffic lights are stand-ins: on macOS the real ones are
          // native and float over the strip; Windows draws caption
          // buttons at the right instead.
          _ComponentCard(
            id: 'WindowTitlebar',
            child: TitlebarStrip(
              title: 'Project_Name',
              leading: const _TrafficLights(),
              trailing: const SizedBox(width: _TrafficLights.width),
            ),
          ),
          _ComponentCard(
            id: 'EclipsaStudioMark',
            child: Wrap(
              spacing: T.gapXl,
              runSpacing: T.gapMd,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: const [
                EclipsaStudioMark(),
                EclipsaStudioMark(size: EclipsaStudioMark.kMarkLarge),
                EclipsaStudioMark(
                  size: EclipsaStudioMark.kMarkLarge,
                  showUnlitCells: false,
                ),
              ],
            ),
          ),
          _ComponentCard(
            id: 'EclipsaStudioLockup',
            child: Wrap(
              spacing: T.gapXl,
              runSpacing: T.gapMd,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const EclipsaStudioLockup(),
                EclipsaStudioLockup(
                  fontSize: T.fontHero,
                  labelFontSize: T.fontSmall,
                ),
              ],
            ),
          ),
          _ComponentCard(
            id: 'EclipsaStudioWordmark',
            child: Wrap(
              spacing: T.gapXl,
              runSpacing: T.gapMd,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const EclipsaStudioWordmark(),
                EclipsaStudioWordmark(
                  fontSize: T.fontHero,
                  labelFontSize: T.fontSmall,
                ),
              ],
            ),
          ),
          // The format's brand, not the app's: fixed greys in the
          // colourway for the theme's ground, so switching theme shows
          // the positive/reverse choice rather than a recolour.
          _ComponentCard(
            id: 'EclipsaAudioSymbol',
            child: Wrap(
              spacing: T.gapXl,
              runSpacing: T.gapMd,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: const [
                EclipsaAudioSymbol(),
                EclipsaAudioSymbol(size: 48),
              ],
            ),
          ),
          _ComponentCard(
            id: 'EclipsaAudioLockup',
            child: Wrap(
              spacing: T.gapXl,
              runSpacing: T.gapMd,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: const [
                EclipsaAudioLockup(),
                EclipsaAudioLockup(height: 48),
              ],
            ),
          ),
          _ComponentCard(
            id: 'TopbarTab',
            child: _TopbarStrip(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, label) in const [
                    (0, 'ELEMENTS'),
                    (1, 'MIX'),
                    (2, 'RENDERER'),
                  ])
                    TopbarTab(
                      label: label,
                      active: _tab == i,
                      onTap: () => setState(() => _tab = i),
                    ),
                ],
              ),
            ),
          ),
          // The mix presentation switcher with its label, as the top bar
          // places them. Its control is SelectorChrome, shared with
          // ConsoleSelector below, so the two cards must agree.
          _ComponentCard(
            id: 'TopbarSelector',
            child: _TopbarStrip(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const MixPresentationLabel(),
                  const SizedBox(width: 8),
                  TopbarSelector(
                    items: const ['Main Mix', 'Stereo Downmix', 'Dialogue'],
                    activeIndex: _mix,
                    emptyLabel: 'No mix presentations',
                    onSelect: (v) => setState(() => _mix = v),
                  ),
                ],
              ),
            ),
          ),
          _ComponentCard(
            id: 'AppButton',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final size in AppButtonSize.values) ...[
                  if (size != AppButtonSize.values.first)
                    const SizedBox(height: T.gapSm),
                  Wrap(
                    spacing: T.gapMd,
                    runSpacing: T.gapSm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final role in AppButtonRole.values)
                        AppButton(
                          label:
                              role.name[0].toUpperCase() +
                              role.name.substring(1),
                          role: role,
                          size: size,
                          onPressed: () {},
                        ),
                      AppButton(
                        label: 'Icon',
                        icon: Icons.add,
                        size: size,
                        onPressed: () {},
                      ),
                      AppButton(label: 'Off', size: size, onPressed: null),
                      AppButton(
                        label: 'Off',
                        role: AppButtonRole.affirmative,
                        size: size,
                        onPressed: null,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          _ComponentCard(
            id: 'ConsoleToggle',
            child: ConsoleToggle(
              value: _toggle,
              onChanged: (v) => setState(() => _toggle = v),
            ),
          ),
          _ComponentCard(
            id: 'ConsoleSegment',
            child: ConsoleSegment<int>(
              value: _seg,
              options: const [(0, 'Top'), (1, 'Front'), (2, '3D')],
              onChanged: (v) => setState(() => _seg = v),
            ),
          ),
          _ComponentCard(
            id: 'ConsoleSelector',
            child: ConsoleSelector<int>(
              value: _sel,
              items: const [(0, 'Stereo'), (1, '5.1'), (2, '7.1.4')],
              onChanged: (v) => setState(() => _sel = v),
            ),
          ),
          _ComponentCard(
            id: 'ConsoleLed',
            child: Wrap(
              spacing: T.gapMd,
              children: [ConsoleLed(on: true), ConsoleLed(on: false)],
            ),
          ),
          // The one painted control in the app. It draws from bgDeep,
          // bgControls, borderStrong, purple and textTertiary, none of
          // which a flat swatch shows in combination -- borderStrong on
          // bgDeep can vanish in a theme and every other surface still
          // look right.
          // One card, not three: which knob this draws is the theme's
          // choice now, so switching theme above swaps the instrument
          // in place. That is the comparison worth having.
          _ComponentCard(
            id: 'GainKnob',
            child: Wrap(
              spacing: T.gapMd,
              children: [
                for (var i = 0; i < _gains.length; i++)
                  GainKnob(
                    gainDb: _gains[i],
                    size: 28,
                    onChanged: (v) => setState(() => _gains[i] = v),
                  ),
              ],
            ),
          ),
          _ComponentCard(
            id: 'GainSlider',
            child: SizedBox(
              width: 260,
              child: GainSlider(
                value: _fader,
                min: -60,
                max: 12,
                onChanged: (v) => setState(() => _fader = v),
              ),
            ),
          ),
          // The transport's five buttons, with play and loop switchable.
          // TransportControls itself binds them to the transport; the
          // buttons are self-contained.
          _ComponentCard(
            id: 'TransportControls',
            child: _TopbarStrip(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TransportButton(
                    icon: Icons.skip_previous,
                    tooltip: 'Return to start',
                    onTap: () {},
                  ),
                  SizedBox(width: TransportButton.gap),
                  TransportPlayButton(
                    playing: _playing,
                    disabledTooltip: '',
                    onTap: () => setState(() => _playing = !_playing),
                  ),
                  SizedBox(width: TransportButton.gap),
                  TransportButton(
                    icon: Icons.stop,
                    tooltip: 'Stop',
                    onTap: () => setState(() => _playing = false),
                  ),
                  SizedBox(width: TransportButton.gap),
                  TransportButton(
                    icon: Icons.skip_next,
                    tooltip: 'Go to end',
                    onTap: () {},
                  ),
                  SizedBox(width: TransportButton.gap),
                  TransportButton(
                    icon: Icons.loop,
                    tooltip: _looping ? 'Disable loop' : 'Enable loop',
                    toggled: _looping,
                    onTap: () => setState(() => _looping = !_looping),
                  ),
                  SizedBox(width: T.gapLg),
                  TransportButton(
                    icon: Icons.skip_next,
                    tooltip: 'Disabled',
                    onTap: null,
                  ),
                ],
              ),
            ),
          ),
          // Not const: _TopbarStrip and TransportClock read T.* without
          // watching the theme, so a canonicalised instance would skip
          // its rebuild on a theme switch (the const-skip pattern).
          _ComponentCard(
            id: 'TransportClock',
            child: _TopbarStrip(
              // ignore: prefer_const_constructors, see above.
              child: TransportClock(
                position: '03:07.153',
                duration: '16:44.231',
              ),
            ),
          ),
          // The video strip in its empty state, at each layout's own
          // height, the header laid over the body: a drop-zone body in
          // the flat layout, the well on the beveled and raised
          // surface.
          _ComponentCard(
            id: 'VideoStrip',
            child: VideoStrip(
              // One height, so the card shows the drawing changing and
              // not the size.
              height: 160,
              fileName: null,
              hasMedia: false,
              isStillImage: false,
              visible: true,
              actions: [
                VideoStripAction(
                  icon: Icons.folder_open,
                  tooltip: 'Open video or image file',
                  onTap: () {},
                ),
                VideoStripAction(
                  icon: Icons.expand_less,
                  tooltip: 'Collapse video',
                  onTap: () {},
                ),
              ],
              body: VideoEmptyBody(
                dragOver: false,
                onTap: null,
                primaryLabel: 'Drop video or image, or click to browse',
                secondaryLabel: 'MP4 \u00B7 MOV \u00B7 PNG',
              ),
            ),
          ),
          // The area on its own, with the drag-over tint the strip above
          // cannot show without a file in flight. Not const: the area
          // reads T.* without watching the theme (the const-skip pattern).
          _ComponentCard(
            id: 'VideoEmptyBody',
            child: ColoredBox(
              color: T.videoBg,
              child: SizedBox(
                height: 236,
                child: Row(
                  children: [
                    Expanded(
                      child: VideoEmptyBody(
                        dragOver: false,
                        onTap: null,
                        primaryLabel: 'Drop video or image, or click to browse',
                        secondaryLabel: 'MP4 \u00B7 MOV \u00B7 PNG',
                      ),
                    ),
                    Expanded(
                      child: VideoEmptyBody(
                        dragOver: true,
                        onTap: null,
                        primaryLabel: 'Drop video or image',
                        secondaryLabel: null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // The time ruler over a lane, with the playhead at 3:07 of
          // 16:44 so the head and the line are both in view. Not const:
          // the strip and the painters read T.* without watching the
          // theme (the const-skip pattern).
          _ComponentCard(
            id: 'TimeRulerStrip',
            child: Column(
              children: [
                Stack(
                  children: [
                    Column(
                      children: [
                        TimeRulerStrip(
                          durationSeconds: _demoDuration,
                          playheadSeconds: _demoPlayhead,
                        ),
                        Container(height: 1, color: T.border),
                        SizedBox(height: 40, width: double.infinity),
                      ],
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: PlayheadPainter(
                            durationSeconds: _demoDuration,
                            playheadSeconds: _demoPlayhead,
                            zoomLevel: 1,
                            scrollOffset: 0,
                            color: T.playhead,
                            style: T.chromeStyle,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // The video's block on the timeline in its 52 px row, ending
          // short of the right edge so the past-end scrim shows. Not
          // const: the lane reads T.* without watching the theme.
          _ComponentCard(
            id: 'VideoLane',
            child: SizedBox(
              height: 52,
              child: VideoLane(
                barLeft: 0,
                barWidth: 620,
                label:
                    'file_name.mp4 \u00B7 03:27.280 \u00B7 3840\u00D72160@24',
              ),
            ),
          ),
          // One track's controls panel, over the sidebar strip it
          // sits on, with a second panel below it so the inset between
          // two cards is visible. The controls are stand-ins: the card
          // is what the drawing is. Not const: TrackPanel reads T.*
          // without watching the theme.
          _ComponentCard(
            id: 'TrackPanel',
            child: ColoredBox(
              color: trackPanelStripColor(),
              child: SizedBox(
                height: 132,
                child: Column(
                  children: [
                    for (final name in const ['Bed 7.1.4', 'Dialogue'])
                      SizedBox(
                        height: 66,
                        child: Row(
                          children: [
                            TrackPanel(
                              width: 180,
                              basePadding: kTrackPanelPadding,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name, style: T.styleBodySecondary),
                                  const SizedBox(height: 8),
                                  Text('0.0 dB', style: T.styleValueSmall),
                                ],
                              ),
                            ),
                            const Expanded(child: SizedBox()),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // An element's lanes: four channel cells in the gutter beside
          // a block of four 20 px lanes with the format chip, without a
          // waveform. Not const: the cells and the chip read T.* without
          // watching the theme.
          _ComponentCard(
            id: 'ChannelLabelCell',
            // The block's border insets its lanes; the gutter pads the
            // same amount so the cells stay level with them.
            child: SizedBox(
              height: 4 * 20 + 3 * trackLaneSpacing() + 2 * _laneBorder,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 34,
                    child: Column(
                      children: [
                        SizedBox(height: _laneBorder),
                        for (final (i, label) in const [
                          'L',
                          'R',
                          'C',
                          'LFE',
                        ].indexed)
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: i < 3 ? trackLaneSpacing() : 0,
                            ),
                            child: ChannelLabelCell(
                              label: label,
                              height: 20,
                              fontSize: T.fontSmall,
                              show: true,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.hardEdge,
                      decoration: trackBlockDecoration(T.typeChannel),
                      child: Stack(
                        children: [
                          Column(
                            children: [
                              for (var i = 0; i < 4; i++)
                                Padding(
                                  padding: EdgeInsets.only(
                                    bottom: i < 3 ? trackLaneSpacing() : 0,
                                  ),
                                  child: Container(
                                    height: 20,
                                    color: trackLaneFill(),
                                  ),
                                ),
                            ],
                          ),
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: TrackInfoChip(
                              text:
                                  'file_name.wav \u00B7 4c \u00B7 24bit '
                                  '\u00B7 48000 Hz \u00B7 16:44.167',
                              color: T.typeChannel,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // The chip on its own, over the lane fill it sits on in
          // Dark and Light. Not const: it reads T.* without watching
          // the theme.
          _ComponentCard(
            id: 'TrackInfoChip',
            child: ColoredBox(
              color: trackLaneFill() ?? T.bgBase,
              child: SizedBox(
                height: 20,
                child: TrackInfoChip(
                  text:
                      'file_name.wav \u00B7 12c \u00B7 24bit \u00B7 '
                      '48000 Hz \u00B7 16:44.167',
                  color: T.typeObject,
                ),
              ),
            ),
          ),
          // The add-track slot's drop target beside the same zone with a
          // drag over it. The flat slot is 80 px in the app, where the
          // zone scales its content down when it is taller than that;
          // the card's 104 px shows it at full size.
          // Not const: DropZone reads T.* without watching the theme.
          _ComponentCard(
            id: 'DropZone',
            child: SizedBox(
              height: max(DropZone.areaHeight, 104),
              child: Row(
                children: [
                  Expanded(
                    child: DropZone(
                      variant: DropZoneVariant.area,
                      icon: Icons.audio_file_outlined,
                      primaryLabel: 'Drop WAV files or click to browse',
                      secondaryLabel: 'WAV \u00B7 16/24/32 bit',
                      isDragOver: false,
                    ),
                  ),
                  const SizedBox(width: T.gapMd),
                  Expanded(
                    child: DropZone(
                      variant: DropZoneVariant.area,
                      icon: Icons.audio_file_outlined,
                      primaryLabel: 'Drop WAV files',
                      secondaryLabel: 'WAV \u00B7 16/24/32 bit',
                      isDragOver: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // The element card's S / M pair, off, engaged and disabled.
          // The Light theme gives the engaged face a rim and a dark ink,
          // which a flat swatch cannot show. Not const: SoloMuteButton reads
          // T.* without watching the theme.
          _ComponentCard(
            id: 'SoloMuteButton',
            child: Row(
              children: [
                SoloMuteButton(
                  label: 'S',
                  tooltip: 'Solo',
                  active: false,
                  activeColor: T.meterYellow,
                  onTap: () {},
                ),
                const SizedBox(width: T.gapSm),
                SoloMuteButton(
                  label: 'S',
                  tooltip: 'Solo, engaged',
                  active: true,
                  activeColor: T.meterYellow,
                  onTap: () {},
                ),
                const SizedBox(width: T.gapMd),
                SoloMuteButton(
                  label: 'M',
                  tooltip: 'Mute',
                  active: false,
                  activeColor: T.meterRed,
                  onTap: () {},
                ),
                const SizedBox(width: T.gapSm),
                SoloMuteButton(
                  label: 'M',
                  tooltip: 'Mute, engaged',
                  active: true,
                  activeColor: T.meterRed,
                  onTap: () {},
                ),
                const SizedBox(width: T.gapMd),
                SoloMuteButton(
                  label: 'M',
                  tooltip: 'Mute, unavailable',
                  active: false,
                  activeColor: T.meterRed,
                  onTap: () {},
                  enabled: false,
                ),
              ],
            ),
          ),
          // The status bar's ground and text with fixed readouts; the
          // live one is Statusbar below. Not const: the strip reads T.*
          // without watching the theme (the const-skip pattern).
          _ComponentCard(
            id: 'StatusbarStrip',
            child: StatusbarStrip(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (i, label) in const [
                            'MacBook Pro Speakers',
                            '48000 Hz',
                            '512 smp',
                            'FPS   120',
                            'Engine   0%',
                            'Eclipsa Studio v1.0',
                          ].indexed) ...[
                            if (i > 0) SizedBox(width: StatusbarStrip.gap),
                            Text(label, style: statusbarTextStyle()),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Chrome that needs app state (providers, engine, a session)
          // carries its reference block without a live demo rather than
          // being faked with stub data that would drift from the real
          // thing.
          for (final id in const [
            // KnobA has no demo of its own on purpose: it is Light's
            // knob and GainKnob above draws it when that theme is
            // selected. The block stays so its declaration and usages
            // are still listed here.
            'KnobA',
            'TransportScrubBar',
            'AppMenuBar',
            'Topbar',
            'Statusbar',
          ])
            _ComponentCard(id: id),
          const SizedBox(height: T.gapMd),
          Text(
            'Element type badges are drawn only in this gallery.',
            style: TextStyle(color: T.textGhost, fontSize: T.fontCaption),
          ),
          const SizedBox(height: T.gapSm),
          Wrap(
            spacing: T.gapMd,
            runSpacing: T.gapSm,
            children: [
              for (final (label, c) in <(String, Color)>[
                ('Object', T.typeObject),
                ('Channel', T.typeChannel),
                ('Scene', T.typeScene),
              ])
                _TypeBadge(label: label, color: c),
            ],
          ),
        ],
      ),
    );
  }
}

/// Stand-ins for the macOS traffic lights in the titlebar card, at the
/// system's colours and the strip's 78 px inset, so the title centres
/// as it does in the window.
class _TrafficLights extends StatelessWidget {
  const _TrafficLights();

  static const double width = 78;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Row(
      children: [
        const SizedBox(width: 10),
        for (final c in const [
          Color(0xFFFF5F57),
          Color(0xFFFEBC2E),
          Color(0xFF28C840),
        ]) ...[
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
        ],
      ],
    ),
  );
}

/// The top bar's own surface under a demo, so a top-bar piece is seen
/// on the ground it ships on. The horizontal padding stands in for the
/// wordmark and the spacers that flank the pieces in the real bar. A
/// demo wider than the card scales down to fit rather than
/// overflowing: the transport row is wider than a narrow window at the
/// large font size.
class _TopbarStrip extends StatelessWidget {
  const _TopbarStrip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ChromeSurface(
    slice: ChromeSlice.topbar,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: T.gapLg),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: child,
        ),
      ),
    ),
  );
}

/// One component's reference block: what to call it, where it is
/// declared, and every file that instantiates it.
///
/// Everything but [child] comes from [kComponentIndex], which is
/// generated — the usage list is read out of `app/lib/` by
/// `scripts/gen_component_index.py`, and its `--check` mode fails CI
/// when the list is out of date. Pass no [child] for a component that
/// needs app state to render.
class _ComponentCard extends StatefulWidget {
  const _ComponentCard({required this.id, this.child});

  /// Dart class name, and the key into [kComponentIndex].
  final String id;

  /// A live instance, or null when the component needs app state.
  final Widget? child;

  @override
  State<_ComponentCard> createState() => _ComponentCardState();
}

class _ComponentCardState extends State<_ComponentCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final info = kComponentIndex[widget.id];
    if (info == null) {
      // Only reachable if a card names a component the registry does
      // not carry. Say so on screen rather than rendering an empty box.
      return Padding(
        padding: const EdgeInsets.only(bottom: T.gapMd),
        child: Text(
          '${widget.id}: not in app/design/components.json',
          style: TextStyle(color: T.errorRed, fontSize: T.fontSmall),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: T.gapMd),
      child: Container(
        decoration: T.decoCard(),
        padding: const EdgeInsets.all(T.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SelectableText(
                    info.name,
                    style: TextStyle(
                      color: T.textPrimary,
                      fontSize: T.fontBodyL,
                      fontWeight: FontWeight.w600,
                      fontFamily: T.monoFamily,
                    ),
                  ),
                ),
                _UseCountChip(
                  info: info,
                  open: _open,
                  onTap: () => setState(() => _open = !_open),
                ),
              ],
            ),
            const SizedBox(height: 2),
            SelectableText(
              info.declaredIn,
              style: TextStyle(
                color: T.textMuted,
                fontSize: T.fontCaption,
                fontFamily: T.monoFamily,
              ),
            ),
            const SizedBox(height: T.gapXs),
            Text(
              info.summary,
              style: TextStyle(
                color: T.textSecondary,
                fontSize: T.fontSmall,
                height: 1.35,
              ),
            ),
            if (_open) ...[
              const SizedBox(height: T.gapSm),
              _UsageList(info: info),
            ],
            if (widget.child != null) ...[
              const SizedBox(height: T.gapMd),
              Container(
                width: double.infinity,
                decoration: T.decoInset(),
                padding: const EdgeInsets.all(T.gapMd),
                child: widget.child,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The "N uses in M files" affordance. Tapping it opens the file list.
class _UseCountChip extends StatelessWidget {
  const _UseCountChip({
    required this.info,
    required this.open,
    required this.onTap,
  });

  final ComponentInfo info;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final n = info.useCount;
    final files = info.usedIn.length;
    // Zero is a real answer, not a missing one: the scan excludes the
    // gallery, so zero means nothing in the product builds this widget.
    final label = n == 0
        ? 'no call sites'
        : '$n use${n == 1 ? '' : 's'} · '
              '$files file${files == 1 ? '' : 's'}';
    final color = n == 0 ? T.objAmber : T.textValue;

    return MouseRegion(
      cursor: n == 0 ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: n == 0 ? null : onTap,
        child: Container(
          decoration: T.decoControl(),
          padding: const EdgeInsets.symmetric(horizontal: T.gapSm, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: T.fontCaption,
                  fontFamily: T.monoFamily,
                ),
              ),
              if (n > 0) ...[
                const SizedBox(width: 2),
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  size: T.iconSm,
                  color: T.textTertiary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Every file that instantiates the component, with its per-file count.
class _UsageList extends StatelessWidget {
  const _UsageList({required this.info});

  final ComponentInfo info;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: T.decoInset(),
      padding: const EdgeInsets.all(T.gapSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in info.usedIn.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      e.key,
                      style: TextStyle(
                        color: T.textSecondary,
                        fontSize: T.fontCaption,
                        fontFamily: T.monoFamily,
                      ),
                    ),
                  ),
                  Text(
                    '×${e.value}',
                    style: TextStyle(
                      color: T.textMuted,
                      fontSize: T.fontCaption,
                      fontFamily: T.monoFamily,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(T.radiusSm),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: T.fontCaption),
      ),
    );
  }
}

class _Meters extends StatelessWidget {
  const _Meters();

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Meters, axes and correlation',
      // Wrap, not Row: twelve fixed-width bars plus group gaps overflow
      // horizontally as soon as the dialog is narrower than their sum,
      // and the font modes move that threshold.
      child: Wrap(
        spacing: T.gapLg,
        runSpacing: T.gapMd,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          // Meter level ramp: three zone tokens, then the red a meter
          // draws for the clip latch only (ES-191).
          _BarGroup(
            bars: [
              ('green', T.meterGreen),
              ('yellow', T.meterYellow),
              ('amber', T.meterAmber),
              ('red', T.meterRed),
            ],
          ),
          _BarGroup(
            bars: [('axisX', T.axisX), ('axisY', T.axisY), ('axisZ', T.axisZ)],
          ),
          _BarGroup(
            bars: [
              ('corrNeg', T.corrNeg),
              ('corrZero', T.corrZero),
              ('corrPos', T.corrPos),
            ],
          ),
          _BarGroup(
            bars: [
              ('objCyan', T.objCyan),
              ('objGreen', T.objGreen),
              ('objAmber', T.objAmber),
            ],
          ),
        ],
      ),
    );
  }
}

class _BarGroup extends StatelessWidget {
  const _BarGroup({required this.bars});

  final List<(String, Color)> bars;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [for (final (l, c) in bars) _Bar(label: l, color: c)],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 26, height: 54, color: color),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              color: T.textMuted,
              fontSize: T.fontMeter,
              fontFamily: T.monoFamily,
            ),
          ),
        ],
      ),
    );
  }
}

/// The colour tokens of [AppThemeData], by name and hex, including
/// those no other gallery section draws a sample for. The list is
/// written by hand, so a new token must be added to it.
class _Swatches extends StatelessWidget {
  const _Swatches();

  @override
  Widget build(BuildContext context) {
    final t = T.themeFor(T.mode);
    final all = <(String, Color)>[
      ('bgDeep', t.bgDeep),
      ('bgBase', t.bgBase),
      ('landingGroundTop', t.landingGroundTop),
      ('landingGroundBottom', t.landingGroundBottom),
      ('bgSurface', t.bgSurface),
      ('bgElevated', t.bgElevated),
      ('bgHover', t.bgHover),
      ('bgControls', t.bgControls),
      ('border', t.border),
      ('borderLight', t.borderLight),
      ('borderStrong', t.borderStrong),
      ('purple', t.purple),
      ('pink', t.pink),
      ('purpleLight', t.purpleLight),
      ('purpleDim', t.purpleDim),
      ('accentFg', t.accentFg),
      ('typeObject', t.typeObject),
      ('typeChannel', t.typeChannel),
      ('typeScene', t.typeScene),
      ('objCyan', t.objCyan),
      ('objGreen', t.objGreen),
      ('objAmber', t.objAmber),
      ('axisX', t.axisX),
      ('axisY', t.axisY),
      ('axisZ', t.axisZ),
      ('gizmoBg', t.gizmoBg),
      ('pastEndScrim', t.pastEndScrim),
      ('indicatorGreen', t.indicatorGreen),
      ('meterGreen', t.meterGreen),
      ('meterYellow', t.meterYellow),
      ('meterRed', t.meterRed),
      ('corrNeg', t.corrNeg),
      ('corrZero', t.corrZero),
      ('corrPos', t.corrPos),
      ('textPrimary', t.textPrimary),
      ('textSecondary', t.textSecondary),
      ('textTertiary', t.textTertiary),
      ('textMuted', t.textMuted),
      ('textGhost', t.textGhost),
      ('bgSelected', t.bgSelected),
      ('textValue', t.textValue),
      ('textValueDim', t.textValueDim),
      ('textInactive', t.textInactive),
      ('white', t.white),
      ('errorRed', t.errorRed),
    ];
    return _Section(
      title: 'All ${all.length} tokens · ${kThemeMeta[T.mode]!.label}',
      child: Wrap(
        spacing: T.gapSm,
        runSpacing: T.gapSm,
        children: [for (final (n, c) in all) _Swatch(name: n, color: c)],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Checkerboard behind the swatch so the alpha tokens (gizmoBg,
    // pastEndScrim, purpleDim) read as translucent rather than as a
    // flat colour that happens to look wrong.
    return SizedBox(
      width: 108,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 34,
            decoration: BoxDecoration(
              border: Border.all(color: T.border),
              borderRadius: BorderRadius.circular(T.radiusSm),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(T.radiusSm),
              child: Stack(
                children: [
                  Positioned.fill(child: CustomPaint(painter: _Checker())),
                  Positioned.fill(child: ColoredBox(color: color)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            name,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: T.textSecondary, fontSize: T.fontMeter),
          ),
          Text(
            _hex(color),
            style: TextStyle(
              color: T.textMuted,
              fontSize: T.fontMeter,
              fontFamily: T.monoFamily,
            ),
          ),
        ],
      ),
    );
  }

  static String _hex(Color c) {
    String q(double v) =>
        (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    final rgb = '${q(c.r)}${q(c.g)}${q(c.b)}'.toUpperCase();
    // Alpha suffixed only when it matters, matching the DTCG token files.
    return c.a < 1.0 ? '#$rgb${q(c.a).toUpperCase()}' : '#$rgb';
  }
}

/// Alpha checkerboard behind each swatch. Fixed neutral greys rather
/// than tokens on purpose: it exists to show alpha and must not change
/// with the theme.
class _Checker extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const s = 6.0;
    final a = Paint()..color = const Color(0xFF808080);
    final b = Paint()..color = const Color(0xFFB0B0B0);
    for (var y = 0.0; y < size.height; y += s) {
      for (var x = 0.0; x < size.width; x += s) {
        final odd = ((x / s).floor() + (y / s).floor()).isOdd;
        canvas.drawRect(Rect.fromLTWH(x, y, s, s), odd ? a : b);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Checker oldDelegate) => false;
}
