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

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../import/adm_detect.dart';
import '../import/adm_import_flow.dart';
import '../logging/log.dart';
import '../session/session.dart';
import '../state.dart';
import '../theme.dart';
import '../whats_new/whats_new_dialog.dart';
import '../widgets/app_button.dart';
import '../widgets/chrome_surface.dart';
import '../widgets/eclipsa_audio_lockup.dart';
import '../widgets/eclipsa_studio_lockup.dart';
import '../widgets/eyebrow_label.dart';
import '../widgets/import_error_dialog.dart';
import 'workspace_actions.dart';

/// Shown when `workspaceModeProvider == WorkspaceMode.none`.
///
/// Two cards side-by-side: Creator (WAV authoring) and Playback
/// (IAMF listening / QC). Each card carries its own "Recent" list.
class LandingScreen extends ConsumerWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // LandingScreen is constructed as `const LandingScreen()` upstream,
    // so parent rebuilds short-circuit at Element.updateChild. Watch
    // theme + font mode here so the screen tracks them on its own.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);

    return Scaffold(
      // Transparent over the ground the app root paints behind the
      // window while this screen shows (LandingGround).
      backgroundColor: const Color(0x00000000),
      body: SafeArea(
        child: Stack(
          children: [
            // Scrollable: at the Large font mode, or in a window shorter
            // than the cards, a fixed column squeezes the card heads and
            // clips their last entry button away.
            //
            // minHeight is what keeps it centred while it fits. A bare
            // SingleChildScrollView lays its child out with an unbounded
            // height, so the Center shrink-wraps and the column pins to
            // the top.
            LayoutBuilder(
              // No explicit Scrollbar: this screen has no ScrollController
              // to give one, and MaterialScrollBehavior already wraps the
              // viewport in a working scrollbar on every desktop platform.
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Each lockup row centres on its own: the
                            // app's lockup above, the caption and the
                            // Eclipsa Audio lockup as one row below.
                            // 42 px of type, an 82 px mark: the app's
                            // lockup sized so its wordmark's cap height
                            // (30.5) stands in the golden ratio to the
                            // Eclipsa Audio wordmark's under it (18.8
                            // at a 32 px symbol). A one-off size, not
                            // a font token.
                            // FittedBox: in a window too narrow for the
                            // lockup at this size, scale it down rather
                            // than overflow. At Large the row is 490 px.
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: EclipsaStudioLockup(
                                fontSize: T.fs(42),
                                labelFontSize: T.fontSmall,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const _EclipsaAudioAttribution(),
                            const SizedBox(height: 40),
                            const IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(child: _CreatorCard()),
                                  SizedBox(width: 24),
                                  Expanded(child: _PlaybackCard()),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // The version, and the way into the release notes, as one
            // pill in the corner: a status item, not part of the
            // pitch. It floats over the scroll view, so in a window
            // shorter than the cards it overlaps their last rows.
            Positioned(
              right: T.gapLg,
              bottom: T.gapLg,
              child: _VersionButton(version: ref.watch(appVersionProvider)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The landing card's corner radius: the theme's `T.radius` for the
/// chrome and outlined cards, 12 for the flat and floating ones.
/// `_DropAcceptCard` insets its ring 2 px outside this.
double _cardRadius() => switch (T.cardStyle) {
  CardStyle.flat || CardStyle.floating => 12,
  CardStyle.chrome || CardStyle.outlined => T.radius,
};

/// The colours one landing card draws with. The card is one drawing in
/// every theme; what varies is the ground it sits on and, with it, the
/// ink. Light puts the card on the `chromeBg` ground the top bar
/// uses, so every colour on it comes from the chrome tokens, the set
/// chosen against that ground.
///
/// `chromeInk` at full strength is 8.01:1 on `chromeBg`, and it is the
/// only ink on that ground: dimming it for hierarchy the way the dark
/// themes dim `textSecondary` puts a 75% blend at 4.25:1, under the
/// 4.5:1 floor for text at these sizes, so the chrome card separates
/// its ranks by size and weight instead. `chromeInk on chromeBg` is a
/// rule in app/design/tokens/contrast.json, so the gate holds it there.
class _CardInk {
  const _CardInk({
    required this.ground,
    required this.border,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.muted,
    required this.hairline,
    required this.hover,
  });

  /// The card's fill.
  final Color ground;

  /// The card's border, null for none.
  final BoxBorder? border;

  /// Titles, entry-button labels and Recent file names.
  final Color primary;

  /// Subtitles and the Recent eyebrow.
  final Color secondary;

  /// Recent folder lines and the empty-state label.
  final Color tertiary;

  /// The drop hint and its icon.
  final Color muted;

  /// The line between the head and the Recent block.
  final Color hairline;

  /// The Recent row's hover fill.
  final Color hover;

  static _CardInk of(CardStyle style) => switch (style) {
    CardStyle.flat => _onElevated(Border.all(color: T.border)),
    // No border: the card stands on its shading, drawn in
    // _LandingCard, over the glow (ES-755).
    CardStyle.floating => _onElevated(null),
    CardStyle.outlined => _onElevated(
      Border.all(color: T.borderStrong, width: T.borderWidth),
    ),
    // The hover fill is chromeBg pulled 40% toward chromeRim, the
    // blend the top bar's raised buttons take on hover.
    // A `chromeRim` hairline: on Light the card is 1.13:1 against
    // bgBase, and the rim is the line the chrome bar draws under
    // itself.
    CardStyle.chrome => _CardInk(
      ground: T.chromeBg,
      border: Border.all(color: T.chromeRim),
      primary: T.chromeInk,
      secondary: T.chromeInk,
      tertiary: T.chromeInk,
      muted: T.chromeInk,
      hairline: T.chromeRim,
      hover: T.chromeHoverFace,
    ),
  };

  /// The card on `bgElevated` with the text tokens, which the flat,
  /// floating and outlined styles share. The border differs, and the
  /// floating card's ground is a gradient that _LandingCard draws.
  static _CardInk _onElevated(BoxBorder? border) => _CardInk(
    ground: T.bgElevated,
    border: border,
    primary: T.textPrimary,
    secondary: T.textSecondary,
    tertiary: T.textTertiary,
    muted: T.textMuted,
    hairline: T.border,
    hover: T.bgHover,
  );
}

/// The Eclipsa Audio lockup under the app's own lockup, after the
/// caption "Authoring for": the format's brand beneath the app's.
///
/// The lockup keeps the brand's fixed greys, in the colourway for the
/// landing ground it is drawn on: `landingGroundTop`, the end of the
/// ground nearer the lockup. Both ends of every theme's ground pick
/// the same colourway, so where the column sits in the window does not
/// change it.
///
/// The caption is `textSecondary`, at `fontBodyL` so it reads as a line
/// of its own, on the wordmark's baseline. contrast.json holds
/// `textSecondary` at 4.5:1 or more on `landingGroundBottom` in every
/// theme, which on Light is the darker end of the gradient.
///
/// The gap between the caption and the lockup is half the symbol's
/// width, 18 px at this size; the brand files in app/design/brand
/// record no clear-space rule, and a full symbol width read as a break
/// between the two.
///
/// Reads `T.*` and is constructed `const`, so no parent rebuild reaches
/// it and it watches theme mode itself.
class _EclipsaAudioAttribution extends ConsumerWidget {
  const _EclipsaAudioAttribution();

  /// The symbol's height at the medium font mode, scaled with the mode
  /// like the app's lockup above so the two keep their ratio: at 32 the
  /// wordmark's cap height is 18.8 px, 1/1.62 of the app wordmark's
  /// 30.5 at 42 px of type, and the lockup is 193 px wide. Not one of
  /// the brand's on-screen symbol sizes (20, 24, 40, 48), which are for
  /// the symbol alone; none of them gives the ratio.
  static const double _symbolHeight = 32;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final colorway = EclipsaAudioColorway.forGround(T.landingGroundTop);
    final height = T.fs(_symbolHeight);
    // The caption shares the wordmark's baseline, which the brand
    // geometry fixes at 265/324 of the symbol's height. Baseline places
    // the text's alphabetic baseline at that distance from the row's
    // top at every font mode; centring the caption on the symbol box
    // put its baseline 8 px above the wordmark's.
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Baseline(
          baseline:
              height *
              EclipsaAudioGeometry.baseline /
              EclipsaAudioGeometry.boxHeight,
          baselineType: TextBaseline.alphabetic,
          child: Text(
            'Authoring for',
            style: TextStyle(color: T.textSecondary, fontSize: T.fontBodyL),
          ),
        ),
        SizedBox(width: height * EclipsaAudioGeometry.symbolAspect / 2),
        EclipsaAudioLockup(height: height, colorway: colorway),
      ],
    );
  }
}

/// The version pill in the lower right corner. It is the way into the
/// release notes: it draws the card buttons' face and hovers as they
/// do, the tooltip names the action, and a click or Enter opens the
/// release-notes dialog. Release Notes stays in the Help menu, so the
/// pill is a shortcut. Its label is `fontSmall` monospace text in
/// `textSecondary` (`chromeInk` on the chrome card style), smaller than
/// the entry cards' titles.
///
/// Reads `T.*` getters that change on a theme or font-mode switch.
/// Construct it without `const` at the call site so each parent rebuild
/// creates a new instance; a const instance is canonicalised and keeps
/// the old colours.
class _VersionButton extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  _VersionButton({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) => ChromePressable(
    onTap: () => WhatsNewDialog.showAll(context),
    tooltip: 'Release Notes',
    semanticLabel: 'Release Notes, version $version',
    builder: (context, state) => _pill(state),
  );

  /// The pill in the card buttons' face (AppButtonFace), with their
  /// hover, press and focus: the label keeps its colour and the face
  /// takes it at 8% on hover and 16% while pressed, except Light's
  /// RaisedFace, which tints its own face; focus rings it in the label
  /// colour.
  Widget _pill(PressableState state) {
    final style = T.cardStyle;
    final chrome = style == CardStyle.chrome;
    final color = chrome ? T.chromeInk : T.textSecondary;
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.notes, size: T.iconXs, color: color),
        const SizedBox(width: T.gapPair),
        Text(
          'v$version',
          style: TextStyle(
            color: color,
            fontSize: T.fontSmall,
            fontFamily: T.monoFamily,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
    final radius = chrome ? T.radius : T.radiusSm;
    final overlay = chrome
        ? null
        : state.pressed
        ? color.withValues(alpha: 0.16)
        : (state.hovered ? color.withValues(alpha: 0.08) : null);
    Widget box(BoxDecoration decoration) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: decoration,
      child: label,
    );
    final face = switch (style) {
      CardStyle.chrome => RaisedFace(
        radius: radius,
        pressed: state.pressed,
        face: state.hovered && !state.pressed ? T.chromeHoverFace : null,
        // The rims take 3 px of each side.
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          child: label,
        ),
      ),
      CardStyle.floating => box(
        AppButton.raisedButtonFace(pressed: state.pressed, enabled: true),
      ),
      CardStyle.flat => box(recessedWell(radius: radius)),
      CardStyle.outlined => box(T.decoControl()),
    };
    return Container(
      foregroundDecoration: overlay == null && !state.focused
          ? null
          : BoxDecoration(
              color: overlay,
              borderRadius: BorderRadius.circular(radius),
              border: state.focused ? Border.all(color: color, width: 2) : null,
            ),
      child: face,
    );
  }
}

class _CreatorCard extends ConsumerWidget {
  const _CreatorCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Constructed const in LandingScreen, so it watches theme and font
    // mode itself.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final recents = ref.watch(recentSessionsProvider);

    // Three peer entry points into the Creator workflow, distinguished
    // only by the source of the starting material. Equal visual
    // weight — no implied default — matches the Xcode/Android Studio
    // launcher pattern.
    return _DropAcceptCard(
      acceptedExtensions: const ['.esp', '.wav'],
      onAccept: (path) => _handleCreatorDrop(context, ref, path),
      child: _LandingCard(
        icon: Icons.edit_note,
        title: 'Creator',
        subtitle: 'Build IAMF deliverables from WAV or ADM audio.',
        actions: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _EntryButton(
              icon: Icons.add,
              label: 'New Session',
              onPressed: () => startNewCreatorSession(context, ref),
            ),
            const SizedBox(height: 8),
            _EntryButton(
              icon: Icons.file_upload_outlined,
              label: 'Import ADM…',
              onPressed: () => startImportAdmFlow(context, ref),
            ),
            const SizedBox(height: 8),
            _EntryButton(
              icon: Icons.folder_open,
              label: 'Open Existing Session…',
              onPressed: () => openCreatorSession(context, ref),
            ),
          ],
        ),
        recents: recents,
        onRecentTap: (path) => openCreatorSession(context, ref, path: path),
        recentEmptyLabel: 'No recent sessions',
        recentEmptyHint: 'Open or create a session to see it here.',
        dragHint:
            'Or drop a .esp session or a .wav file anywhere on this card.',
      ),
    );
  }
}

/// Routes a file dropped on the Creator card: a `.esp` opens that
/// session; a `.wav` is sniffed for ADM metadata — an ADM master
/// enters the Import ADM flow with the picker pre-skipped, a plain
/// WAV seeds a fresh session with the file as its first element.
Future<void> _handleCreatorDrop(
  BuildContext context,
  WidgetRef ref,
  String path,
) async {
  if (p.extension(path).toLowerCase() != '.wav') {
    return openCreatorSession(context, ref, path: path);
  }
  final isAdm = await wavHasAdmMetadata(path);
  Log.i(
    LogCat.app,
    'landing drop: ${p.basename(path)} -> '
    '${isAdm ? 'ADM import' : 'new session'}',
  );
  if (!context.mounted) return;
  if (isAdm) return startImportAdmFlow(context, ref, path: path);
  return startCreatorSessionWithWav(context, ref, path);
}

class _PlaybackCard extends ConsumerWidget {
  const _PlaybackCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Constructed const in LandingScreen, so it watches theme and font
    // mode itself.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final recents = ref.watch(recentQcFilesProvider);

    // Single entry point, but styled as a peer of the Creator card's
    // entry buttons for visual consistency across the landing.
    return _DropAcceptCard(
      acceptedExtensions: const ['.iamf', '.mp4'],
      onAccept: (path) => openIamfForQc(context, ref, path: path),
      child: _LandingCard(
        icon: Icons.headphones,
        title: 'Playback',
        subtitle:
            'Listen to finished IAMF files, or QC an .mp4 with its video. '
            'No edits to the source.',
        actions: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _EntryButton(
              icon: Icons.play_circle_outline,
              label: 'Open IAMF or MP4 for Playback…',
              onPressed: () => openIamfForQc(context, ref),
            ),
          ],
        ),
        recents: recents,
        onRecentTap: (path) => openIamfForQc(context, ref, path: path),
        recentEmptyLabel: 'No recent files',
        recentEmptyHint: 'Open an IAMF or MP4 file to see it here.',
        dragHint: 'Or drop a .iamf or .mp4 file anywhere on this card.',
      ),
    );
  }
}

/// Wraps a [_LandingCard] with a Finder drag-and-drop target.
///
/// On hover-with-file the card gets a 2 px purple ring; on drop the
/// first file matching [acceptedExtensions] is forwarded to
/// [onAccept]. If no dropped file matches, the ring briefly turns
/// red — the desktop_drop API doesn't expose file types during the
/// drag on macOS, so we accept-then-reject rather than pre-filter
/// the cursor. Inline feedback (rather than a SnackBar) keeps the
/// rejection signal localised to the card the user dropped on.
class _DropAcceptCard extends StatefulWidget {
  const _DropAcceptCard({
    required this.acceptedExtensions,
    required this.onAccept,
    required this.child,
  });

  final List<String> acceptedExtensions;
  final void Function(String path) onAccept;
  final Widget child;

  @override
  State<_DropAcceptCard> createState() => _DropAcceptCardState();
}

class _DropAcceptCardState extends State<_DropAcceptCard> {
  static const _rejectFlashDuration = Duration(milliseconds: 900);

  bool _hovering = false;
  bool _rejecting = false;
  Timer? _rejectTimer;

  @override
  void dispose() {
    _rejectTimer?.cancel();
    super.dispose();
  }

  void _handleDone(DropDoneDetails details) {
    if (!mounted) return;
    final accepted = details.files.where((f) {
      final ext = p.extension(f.path).toLowerCase();
      return widget.acceptedExtensions.contains(ext);
    }).toList();
    if (accepted.isEmpty) {
      _rejectTimer?.cancel();
      setState(() {
        _hovering = false;
        _rejecting = true;
      });
      _rejectTimer = Timer(_rejectFlashDuration, () {
        if (!mounted) return;
        setState(() => _rejecting = false);
      });
      // The red ring flash alone reads as "the drop didn't register";
      // name the reason in a modal too (ES-184). The importNoticeProvider
      // listener lives in AppShell, which isn't mounted on the landing
      // screen, so show the dialog directly.
      final formats = widget.acceptedExtensions
          .map((e) => e.replaceFirst('.', ''))
          .join(', ');
      showImportErrorDialog(
        context,
        details.files.length == 1
            ? 'The dropped file is not a format this card can open.\n\n'
                  'Accepted formats: $formats.'
            : 'None of the dropped files are formats this card can '
                  'open.\n\nAccepted formats: $formats.',
      );
      return;
    }
    setState(() => _hovering = false);
    if (accepted.length > 1) {
      Log.w(
        LogCat.app,
        'landing drop: ${accepted.length} matching files; '
        'opening first, ignoring rest',
      );
    }
    widget.onAccept(accepted.first.path);
  }

  @override
  Widget build(BuildContext context) {
    final ringColor = _rejecting
        ? T.errorRed
        : (_hovering ? T.purple : T.purple.withValues(alpha: 0));
    return DropTarget(
      onDragEntered: (_) {
        if (!mounted) return;
        setState(() => _hovering = true);
      },
      onDragExited: (_) {
        if (!mounted) return;
        setState(() => _hovering = false);
      },
      onDragDone: _handleDone,
      child: AnimatedContainer(
        duration: T.motionFast,
        decoration: BoxDecoration(
          // The card sits 4 px inside: this draws a 2 px border, which
          // paints inside the box, and then pads 2 px. Concentric means
          // matching that, not the padding alone.
          borderRadius: BorderRadius.circular(_cardRadius() + 4),
          border: Border.all(color: ringColor, width: 2),
        ),
        padding: const EdgeInsets.all(2),
        child: widget.child,
      ),
    );
  }
}

class _LandingCard extends StatelessWidget {
  const _LandingCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actions,
    required this.recents,
    required this.onRecentTap,
    required this.recentEmptyLabel,
    this.recentEmptyHint,
    this.dragHint,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget actions;
  final List<String> recents;

  final Future<void> Function(String path)? onRecentTap;
  final String recentEmptyLabel;
  final String? recentEmptyHint;

  /// Inline tip surfacing the drag-and-drop affordance — first-time
  /// users won't otherwise know they can drop a file onto the card.
  /// Shown under [actions].
  final String? dragHint;

  /// Subtitle line height, explicit so the reserved two-line block
  /// below is exact arithmetic at every font scale.
  static const double _subtitleLineHeight = 1.35;

  /// The number of Recent rows each card reserves, filled or not. The
  /// recent stores keep up to 10 entries and a card shows the first 5.
  /// A fixed count keeps both cards, and the lockup above them, at the
  /// same size and position whatever the lists hold.
  static const int _recentSlots = 5;

  @override
  Widget build(BuildContext context) {
    final ink = _CardInk.of(T.cardStyle);

    // The card is one column of two sections. The head takes the slack
    // (the cards are stretched to equal heights by the IntrinsicHeight
    // row), so the boundary between the sections lands at the same y in
    // both cards and the hairline reads as one line across the pair.
    //
    // What keeps the head from being squeezed into the clip below is
    // the scroll view in LandingScreen: this column has no way to
    // overflow safely on its own.
    //
    // No clip: with a single ground nothing paints outside the rounded
    // rect, and Container insets its child by the border it draws, so
    // the bordered and borderless cards lay their content out the same.
    // The floating card is shaded like its raised buttons, at card
    // scale: a face lighter at the top, from bgControls to the card's
    // ground, over a soft drop shadow (ES-755).
    final floating = T.cardStyle == CardStyle.floating;
    return Container(
      decoration: BoxDecoration(
        color: floating ? null : ink.ground,
        gradient: floating
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [T.bgControls, ink.ground],
              )
            : null,
        borderRadius: BorderRadius.circular(_cardRadius()),
        border: ink.border,
        boxShadow: floating
            ? const [
                BoxShadow(
                  color: Color(0x4D000000),
                  offset: Offset(0, 4),
                  blurRadius: 12,
                ),
                BoxShadow(
                  color: Color(0x33000000),
                  offset: Offset(0, 16),
                  blurRadius: 32,
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _head(ink)),
          _recents(context, ink),
        ],
      ),
    );
  }

  /// Icon, title, subtitle, entry buttons and the drop hint.
  Widget _head(_CardInk ink) {
    final subtitleStyle = T.styleBodySecondary.copyWith(
      color: ink.secondary,
      height: _subtitleLineHeight,
    );
    final hintStyle = T.styleLabel.copyWith(color: ink.muted);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: ink.primary, size: T.iconXl),
              const SizedBox(width: 12),
              // Upper-cased in every theme. All-caps labels take
              // letter spacing.
              // Flexible because caps widen it by
              // about 15% and it is the first thing to run out of room
              // in a narrow window.
              Flexible(
                child: Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    color: ink.primary,
                    fontSize: T.fontTitle,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.6,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Reserve two subtitle lines in both cards so the action
          // buttons start at the same height regardless of how each
          // card's subtitle wraps.
          ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: 2 * T.fontBody * _subtitleLineHeight,
            ),
            child: Text(subtitle, style: subtitleStyle),
          ),
          const SizedBox(height: 20),
          actions,
          if (dragHint != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.move_to_inbox_outlined,
                  size: T.iconSm,
                  color: ink.muted,
                ),
                const SizedBox(width: T.gapPair),
                Expanded(child: Text(dragHint!, style: hintStyle)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// The Recent list. Always [_recentSlots] rows tall, so both cards'
  /// blocks are the same height and the section boundary lines up
  /// across the pair. An empty list shows its empty state in the first
  /// row; rows past the last entry stay blank.
  Widget _recents(BuildContext context, _CardInk ink) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(height: 1, color: ink.hairline),
          const SizedBox(height: 12),
          EyebrowLabel('Recent', color: ink.secondary),
          const SizedBox(height: 4),
          for (var i = 0; i < _recentSlots; i++)
            if (recents.isEmpty && i == 0)
              _EmptyRecents(
                label: recentEmptyLabel,
                hint: recentEmptyHint,
                ink: ink,
              )
            else if (i < recents.length)
              _RecentRow(
                path: recents[i],
                ink: ink,
                onTap: onRecentTap == null
                    ? null
                    : () => onRecentTap!(recents[i]),
              )
            else
              SizedBox(height: _RecentRow.heightOf(context)),
        ],
      ),
    );
  }
}

/// First-launch empty state for the Recent list. Occupies exactly one
/// Recent slot ([_RecentRow.height]) so an empty card's Recent block
/// aligns with a populated one.
class _EmptyRecents extends StatelessWidget {
  const _EmptyRecents({required this.label, required this.ink, this.hint});

  final String label;
  final _CardInk ink;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _RecentRow.heightOf(context),
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: ink.tertiary,
                fontSize: T.fontBody,
                height: _RecentRow.lineHeight,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(
                hint!,
                style: T.styleLabel.copyWith(
                  color: ink.muted,
                  height: _RecentRow.lineHeight,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.path,
    required this.ink,
    required this.onTap,
  });

  final String path;
  final _CardInk ink;
  final VoidCallback? onTap;

  /// Explicit text line height so [height] is exact arithmetic.
  static const double lineHeight = 1.2;

  /// Fixed slot height — identical for every row (with or without a
  /// folder line) and computed from the scaled font tokens, so the two
  /// cards' Recent blocks align at every font-size mode: 2×10 vertical
  /// padding + name line + 2 gap + folder line, plus a 2 px cushion
  /// (per-line box rounding can consume the whole ceil() headroom).
  /// Honours the OS text scaler — Windows forwards accessibility text
  /// scale, and a fixed row must grow with it or clip.
  static double heightOf(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final lines = scaler.scale(T.fontBody) + scaler.scale(T.fontSmall);
    return (22 + lines * lineHeight).ceilToDouble() + 2;
  }

  @override
  Widget build(BuildContext context) {
    final name = p.basename(path);
    final folder = p.dirname(path);
    return Tooltip(
      message: path,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(T.radiusSm),
        hoverColor: ink.hover,
        mouseCursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: SizedBox(
          width: double.infinity,
          height: heightOf(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: T.styleBody.copyWith(
                    color: ink.primary,
                    height: lineHeight,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (folder.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    folder,
                    style: TextStyle(
                      color: ink.tertiary,
                      fontSize: T.fontSmall,
                      height: lineHeight,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Equal-weight entry button: an [AppButton] in the card's ink, left
/// aligned and stretched to the card. Rendered as peers so the entry
/// paths read as a row of choices rather than a default plus
/// alternates.
class _EntryButton extends StatelessWidget {
  const _EntryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => AppButton(
    label: label,
    icon: icon,
    onPressed: onPressed,
    foreground: _CardInk.of(T.cardStyle).primary,
    mainAxisAlignment: MainAxisAlignment.start,
    face: switch (T.cardStyle) {
      CardStyle.floating || CardStyle.chrome => AppButtonFace.raised,
      CardStyle.flat => AppButtonFace.recessed,
      CardStyle.outlined => AppButtonFace.flat,
    },
  );
}
