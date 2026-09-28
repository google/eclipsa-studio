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

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';
import '../util/focus_utils.dart';
import '../widgets/app_button.dart';

/// Full-screen output routing surface, launched from Monitoring settings.
///
/// The matrix is a spreadsheet that needs room to breathe — a curated set
/// of switchable targets side by side, each patched into the device's
/// channels — so it lives on its own screen rather than cramped inside the
/// settings dialog. Same isolate as the rest of the app, so it reads and
/// writes the live monitoring providers directly (no cross-window sync).
class RoutingMatrixView extends ConsumerStatefulWidget {
  const RoutingMatrixView({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const RoutingMatrixView(),
      ),
    );
  }

  @override
  ConsumerState<RoutingMatrixView> createState() => _RoutingMatrixViewState();
}

class _RoutingMatrixViewState extends ConsumerState<RoutingMatrixView> {
  // Held so dispose() doesn't touch `ref` after the element is defunct.
  late final NoiseInjectionNotifier _noise;

  @override
  void initState() {
    super.initState();
    _noise = ref.read(noiseInjectionProvider.notifier);
  }

  @override
  void dispose() {
    // Noise injection is a transient calibration aid scoped to this view;
    // clear every toggle on exit. Deferred past teardown so we don't mutate
    // provider state mid-dispose. This is the backstop for non-button dismiss
    // paths (system back); Done/Escape kill it up-front via _dismiss().
    WidgetsBinding.instance.addPostFrameCallback((_) => _noise.killAll());
    super.dispose();
  }

  // Stop calibration noise immediately, then close. dispose() runs only after
  // the route's close transition (~300 ms for a fullscreen dialog), so killing
  // here is what makes the noise stop the instant the user clicks Done / hits
  // Escape rather than lingering through the animation.
  void _dismiss() {
    _noise.killAll();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final config = ref.watch(monitoringConfigProvider);
    final devCh = ref.watch(outputDeviceChannelsProvider);

    // A raw key handler rather than CallbackShortcuts: Space must be
    // ignored while the noise-level field is being edited (typing is
    // never hijacked — ES-79), and CallbackShortcuts consumes a matched
    // key unconditionally, which would eat the keystroke even when the
    // transport toggle stands down.
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          _dismiss();
          return KeyEventResult.handled;
        }
        // Space toggles transport here too (ES-79) — this screen is a
        // route above the shell, so its shortcut scope doesn't reach
        // us. Same isolate, so the shared toggle applies directly.
        if (event.logicalKey == LogicalKeyboardKey.space &&
            !textInputHasFocus()) {
          ref.read(playingProvider.notifier).toggleTransport();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: T.bgBase,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Output Routing',
                    style: TextStyle(
                      fontSize: T.fontTitle,
                      color: T.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${config.activeLayout.label} live · $devCh device ch',
                    style: T.styleCaption,
                  ),
                  const Spacer(),
                  AppButton(
                    label: 'Done',
                    role: AppButtonRole.affirmative,
                    size: AppButtonSize.compact,
                    onPressed: _dismiss,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _NoiseLevelField(),
              const SizedBox(height: 8),
              const Flexible(child: _RoutingMatrix()),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pink-noise reference level ─────────────────────────────────────────────
class _NoiseLevelField extends ConsumerStatefulWidget {
  const _NoiseLevelField();

  @override
  ConsumerState<_NoiseLevelField> createState() => _NoiseLevelFieldState();
}

class _NoiseLevelFieldState extends ConsumerState<_NoiseLevelField> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    final v = ref.read(monitoringConfigProvider).noiseDbfs;
    _ctrl = TextEditingController(text: v.toStringAsFixed(1));
    _focus = FocusNode()
      ..addListener(() {
        if (!_focus.hasFocus) _commit();
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = double.tryParse(_ctrl.text.replaceAll('−', '-'));
    if (parsed != null) {
      ref
          .read(monitoringConfigProvider.notifier)
          .setNoiseDbfs(parsed.clamp(-60.0, 0.0));
    }
    _syncText();
  }

  void _syncText() {
    final v = ref.read(monitoringConfigProvider).noiseDbfs;
    _ctrl.text = v.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    ref.listen(monitoringConfigProvider.select((c) => c.noiseDbfs), (_, v) {
      if (!_focus.hasFocus) _ctrl.text = v.toStringAsFixed(1);
    });
    return Row(
      children: [
        Text('Noise reference', style: T.styleBodySecondary),
        const SizedBox(width: T.gapSm),
        Tooltip(
          message: 'Double-click to reset to default',
          child: GestureDetector(
            onDoubleTap: () {
              ref
                  .read(monitoringConfigProvider.notifier)
                  .setNoiseDbfs(MonitoringConfig.kDefaultNoiseDbfs);
              _syncText();
            },
            child: SizedBox(
              width: 64,
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                textAlign: TextAlign.center,
                style: T.styleValue,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                onSubmitted: (_) => _commit(),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  filled: true,
                  fillColor: T.bgDeep,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(3),
                    borderSide: BorderSide(color: T.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(3),
                    borderSide: BorderSide(color: T.purple),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: T.gapSm),
        Text('dBFS RMS', style: T.styleCaption),
      ],
    );
  }
}

// Multi-target routing matrix: exposed targets are side-by-side column
// groups (active highlighted, header switches active); device channels are
// rows; cells are independent cross-point toggles (splits + sums). Pink-noise
// calibration overlays the headers symmetrically: a noise row in the pinned
// header (per input channel) and a noise column in the pinned gutter (per
// device channel); the static corner holds the kill-all that clears both.
//
// Frozen panes: the header (top) and gutter (left) stay pinned — they're
// synchronized with the cell body's two scroll controllers via
// translation, so they can't desync — while the body scrolls in both
// axes. Scrollbars show only when an axis overflows.
class _RoutingMatrix extends ConsumerStatefulWidget {
  const _RoutingMatrix();

  @override
  ConsumerState<_RoutingMatrix> createState() => _RoutingMatrixState();
}

class _RoutingMatrixState extends ConsumerState<_RoutingMatrix> {
  static const double _cellW = 28;
  static const double _noiseColW = 28;
  // Editable name slot: wide enough for custom loudspeaker labels and
  // driver-reported names; longer names ellipsize with a tooltip. The
  // channel-index chip sits beside it (see _indexWidth), so the full
  // width stays available for the name.
  static const double _labelW = 96;
  static const double _indexGap = 4;

  // Index-chip width: sized to the widest channel number of the current
  // device at the active font scale (mono digits are ~0.62 em), so
  // 3-digit devices (large aggregates, Dante) don't clip. Getters, not
  // consts — they follow the device and font mode across rebuilds.
  double get _indexW {
    final digits = '${ref.read(outputDeviceChannelsProvider)}'.length;
    return math.max(18.0, digits * T.fontCaption * 0.62 + 6);
  }

  double get _gutterW => _indexW + _indexGap + _labelW + _noiseColW;
  static const double _rowH = 18;
  static const double _groupLabelH = 18;
  static const double _chLabelH = 16;
  // Label block (group + channel labels) sits above the per-input-channel
  // noise row; together they form the pinned header.
  static const double _labelBlockH = _groupLabelH + _chLabelH;
  static const double _headerH = _labelBlockH + _rowH;
  static const double _gap = 8;
  static const double _viewMaxH = 280;
  // Trailing margin reserved inside the body so the overlay scrollbars don't
  // cover the last row / column of cells.
  static const double _barInset = 14;

  // One grid, two axes: an outer vertical and inner horizontal scroll view,
  // each driven by its own controller so the matching scrollbar can show.
  final _v = ScrollController();
  final _h = ScrollController();

  @override
  void dispose() {
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final config = ref.watch(monitoringConfigProvider);
    final devCh = ref.watch(outputDeviceChannelsProvider);
    final noise = ref.watch(noiseInjectionProvider);
    final targets = config.targets;
    final active = config.activeLayout;

    final bodyW = _targetsWidth(targets);
    final bodyH = devCh * _rowH;
    final contentH = _headerH + bodyH;

    return Container(
      width: double.infinity,
      decoration: T.decoInset(),
      padding: const EdgeInsets.all(8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Grow into the height we're handed (the full-screen view gives us
          // a bounded box), capped at the content; compact fallback if the
          // height is unbounded.
          final maxH = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : _viewMaxH;
          final viewH = math.min(contentH, maxH).toDouble();
          // The cell body fills everything right of the gutter and below the
          // header; the header and gutter are pinned overlays.
          final bodyViewW = constraints.maxWidth - _gutterW;
          final bodyViewH = viewH - _headerH;
          final needH = bodyW > bodyViewW + 0.5;
          final needV = bodyH > bodyViewH + 0.5;

          return SizedBox(
            height: viewH,
            child: Stack(
              children: [
                // Cell body — the only freely 2D-scrolling quadrant. The
                // horizontal bar tracks the inner scroll view via depth == 1.
                Positioned(
                  left: _gutterW,
                  top: _headerH,
                  right: 0,
                  bottom: 0,
                  child: Scrollbar(
                    controller: _v,
                    thumbVisibility: needV,
                    child: Scrollbar(
                      controller: _h,
                      thumbVisibility: needH,
                      notificationPredicate: (notif) => notif.depth == 1,
                      child: SingleChildScrollView(
                        controller: _v,
                        child: SingleChildScrollView(
                          controller: _h,
                          scrollDirection: Axis.horizontal,
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: needV ? _barInset : 0,
                              bottom: needH ? _barInset : 0,
                            ),
                            child: _bodyGrid(targets, devCh, bodyW),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Pinned channel-label header — follows the horizontal scroll.
                Positioned(
                  left: _gutterW,
                  top: 0,
                  right: 0,
                  height: _headerH,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: 0,
                      maxWidth: double.infinity,
                      child: AnimatedBuilder(
                        animation: _h,
                        child: _headerStrip(targets, active, noise, bodyW),
                        builder: (_, child) => Transform.translate(
                          offset: Offset(-_offset(_h), 0),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
                // Pinned device-label gutter — follows the vertical scroll.
                Positioned(
                  left: 0,
                  top: _headerH,
                  width: _gutterW,
                  bottom: 0,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minHeight: 0,
                      maxHeight: double.infinity,
                      child: AnimatedBuilder(
                        animation: _v,
                        child: _gutterStrip(devCh, noise),
                        builder: (_, child) => Transform.translate(
                          offset: Offset(0, -_offset(_v)),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
                // Static corner.
                Positioned(
                  left: 0,
                  top: 0,
                  width: _gutterW,
                  height: _headerH,
                  child: _gutterCorner(noise),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static double _offset(ScrollController c) => c.hasClients ? c.offset : 0.0;

  double _targetsWidth(List<OutputTarget> targets) {
    var w = 0.0;
    for (var i = 0; i < targets.length; i++) {
      if (i > 0) w += _gap;
      w += targets[i].layout.channels * _cellW;
    }
    return w;
  }

  // Top frozen pane: target group labels, per-channel labels, then the
  // per-input-channel noise row (mirrors the gutter's per-device noise cell).
  Widget _headerStrip(
    List<OutputTarget> targets,
    OarLayout active,
    NoiseInjection noise,
    double w,
  ) {
    return SizedBox(
      width: w,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: _groupLabelRow(targets, active)),
          Row(children: _channelLabelRow(targets)),
          Row(children: _noiseRow(targets, active, noise)),
        ],
      ),
    );
  }

  // Left frozen pane: one editable label + noise cell per device channel.
  Widget _gutterStrip(int devCh, NoiseInjection noise) {
    return SizedBox(
      width: _gutterW,
      child: Column(
        children: [for (var d = 0; d < devCh; d++) _gutterDeviceRow(d, noise)],
      ),
    );
  }

  // Scrolling body: one cell row per device channel.
  Widget _bodyGrid(List<OutputTarget> targets, int devCh, double w) {
    return SizedBox(
      width: w,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var d = 0; d < devCh; d++) Row(children: _deviceRow(targets, d)),
        ],
      ),
    );
  }

  // --- Header ---

  List<Widget> _groupLabelRow(List<OutputTarget> targets, OarLayout active) {
    final mon = ref.read(monitoringConfigProvider.notifier);
    final out = <Widget>[];
    for (var i = 0; i < targets.length; i++) {
      if (i > 0) out.add(const SizedBox(width: _gap));
      final t = targets[i];
      final isActive = t.layout == active;
      out.add(
        GestureDetector(
          onTap: isActive ? null : () => mon.setActive(t.layout),
          child: MouseRegion(
            cursor: isActive ? MouseCursor.defer : SystemMouseCursors.click,
            child: Container(
              width: t.layout.channels * _cellW,
              height: _groupLabelH,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isActive ? T.purpleDim : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                isActive ? '${t.layout.label} ●' : t.layout.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: T.fontMeter,
                  color: isActive ? T.purpleLight : T.textTertiary,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return out;
  }

  List<Widget> _channelLabelRow(List<OutputTarget> targets) {
    final out = <Widget>[];
    for (var i = 0; i < targets.length; i++) {
      if (i > 0) out.add(const SizedBox(width: _gap));
      for (final label in targets[i].layout.speakerLabels) {
        out.add(
          SizedBox(
            width: _cellW,
            height: _chLabelH,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: T.monoFamily,
                  fontSize: T.fontMeter,
                  color: T.textTertiary,
                ),
              ),
            ),
          ),
        );
      }
    }
    return out;
  }

  // --- Body ---

  List<Widget> _noiseRow(
    List<OutputTarget> targets,
    OarLayout active,
    NoiseInjection noise,
  ) {
    final noiseN = ref.read(noiseInjectionProvider.notifier);
    final out = <Widget>[];
    for (var i = 0; i < targets.length; i++) {
      if (i > 0) out.add(const SizedBox(width: _gap));
      final t = targets[i];
      final isActive = t.layout == active;
      for (var ch = 0; ch < t.layout.channels; ch++) {
        out.add(
          isActive
              ? _toggleCell(
                  on: noise.rowOn(ch),
                  noise: true,
                  onTap: () => noiseN.toggleRow(ch),
                )
              : _disabledCell(),
        );
      }
    }
    return out;
  }

  List<Widget> _deviceRow(List<OutputTarget> targets, int devCh) {
    final mon = ref.read(monitoringConfigProvider.notifier);
    final out = <Widget>[];
    for (var i = 0; i < targets.length; i++) {
      if (i > 0) out.add(const SizedBox(width: _gap));
      final t = targets[i];
      for (var ch = 0; ch < t.layout.channels; ch++) {
        final on = (t.routing[ch] >> devCh) & 1 == 1;
        out.add(
          _toggleCell(
            on: on,
            noise: false,
            onTap: () => mon.toggleCell(t.layout, ch, devCh),
          ),
        );
      }
    }
    return out;
  }

  // --- Gutter cells (lead each row) ---

  Widget _gutterCorner(NoiseInjection noise) {
    return SizedBox(
      height: _headerH,
      child: Column(
        children: [
          SizedBox(
            height: _labelBlockH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: _indexW + _indexGap + _labelW,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      'Device Outputs ↓',
                      style: TextStyle(
                        fontSize: T.fontMeter,
                        color: T.textGhost,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: _noiseColW, height: _labelBlockH),
              ],
            ),
          ),
          _gutterNoiseRow(noise),
        ],
      ),
    );
  }

  Widget _gutterNoiseRow(NoiseInjection noise) {
    final noiseN = ref.read(noiseInjectionProvider.notifier);
    return SizedBox(
      height: _rowH,
      child: Row(
        children: [
          SizedBox(width: _indexW + _indexGap + _labelW),
          SizedBox(
            width: _noiseColW,
            height: _rowH,
            child: Center(
              child: Tooltip(
                message: 'Clear all noise',
                child: GestureDetector(
                  onTap: noise.anyOn ? noiseN.killAll : null,
                  child: MouseRegion(
                    cursor: noise.anyOn
                        ? SystemMouseCursors.click
                        : MouseCursor.defer,
                    child: Container(
                      width: 14,
                      height: 14,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: noise.anyOn
                            ? T.errorRed.withValues(alpha: 0.85)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(
                          color: noise.anyOn
                              ? Colors.transparent
                              : T.borderLight,
                          width: 0.5,
                        ),
                      ),
                      child: Icon(
                        Icons.close,
                        size: 10,
                        color: noise.anyOn ? T.white : T.textGhost,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _gutterDeviceRow(int devCh, NoiseInjection noise) {
    final noiseN = ref.read(noiseInjectionProvider.notifier);
    return SizedBox(
      height: _rowH,
      child: Row(
        children: [
          // Index chip: the physical output number stays visible no
          // matter what the name slot shows (driver name / custom
          // label), so rows remain addressable as outputs by number.
          SizedBox(
            width: _indexW,
            child: Text(
              '${devCh + 1}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: T.monoFamily,
                fontSize: T.fontCaption,
                color: T.textGhost,
              ),
            ),
          ),
          const SizedBox(width: _indexGap),
          SizedBox(
            width: _labelW,
            child: _EditableOutputLabel(key: ValueKey(devCh), channel: devCh),
          ),
          _toggleCell(
            on: noise.colOn(devCh),
            noise: true,
            onTap: () => noiseN.toggleCol(devCh),
          ),
        ],
      ),
    );
  }

  // --- Cells ---

  Widget _toggleCell({
    required bool on,
    required bool noise,
    VoidCallback? onTap,
  }) {
    final fill = noise ? T.pink : T.textValue;
    final dot = Container(
      width: 12,
      height: 12,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? fill : Colors.transparent,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(
          color: on ? Colors.transparent : T.borderLight,
          width: 0.5,
        ),
      ),
      // Noise cells always carry the ~ glyph so they read as noise
      // injectors before any cell is lit; ghosted when off.
      child: noise
          ? Text(
              '~',
              style: TextStyle(
                fontSize: T.fontMeter,
                height: 1.0,
                fontWeight: FontWeight.bold,
                color: on ? T.bgDeep : T.textGhost,
              ),
            )
          : null,
    );
    final cell = SizedBox(
      width: _cellW,
      height: _rowH,
      child: Center(child: dot),
    );
    if (onTap == null) return cell;
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: cell),
    );
  }

  Widget _disabledCell() {
    return SizedBox(
      width: _cellW,
      height: _rowH,
      child: Center(
        child: Container(
          width: 3,
          height: 3,
          decoration: BoxDecoration(
            color: T.textGhost.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

// ── Editable device-channel label ──────────────────────────────────────────
// Inline-editable name for one physical output channel, shown in the matrix
// gutter beside the fixed index chip. Reads as the channel label until
// clicked, then commits to [outputLabelsProvider] on submit or focus loss; a
// blank value clears the custom name and the hint takes over — the driver-
// reported channel name when the device has one (ES-349), else `Out N` so the
// row still reads as an output. The tooltip always spells out all three:
// `Out N · <driver name> · <custom>`. Self-contained controller + focus so
// it survives the frequent gutter rebuilds (cell/noise toggles).
class _EditableOutputLabel extends ConsumerStatefulWidget {
  final int channel;
  const _EditableOutputLabel({super.key, required this.channel});

  @override
  ConsumerState<_EditableOutputLabel> createState() =>
      _EditableOutputLabelState();
}

class _EditableOutputLabelState extends ConsumerState<_EditableOutputLabel> {
  static const int _maxLabel = 16;
  late final TextEditingController _ctrl;
  late final FocusNode _focus;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: ref.read(outputLabelsProvider)[widget.channel] ?? '',
    );
    _focus = FocusNode()
      ..addListener(() {
        if (_focus.hasFocus != _focused) {
          setState(() => _focused = _focus.hasFocus);
        }
        if (!_focus.hasFocus) _commit();
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    ref
        .read(outputLabelsProvider.notifier)
        .setLabel(widget.channel, _ctrl.text);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final custom = ref.watch(
      outputLabelsProvider.select((m) => m[widget.channel] ?? ''),
    );
    // Mirror external changes (e.g. Reset to Defaults) into the field unless
    // the user is mid-edit.
    ref.listen(outputLabelsProvider.select((m) => m[widget.channel] ?? ''), (
      _,
      v,
    ) {
      if (!_focus.hasFocus && _ctrl.text != v) _ctrl.text = v;
    });
    final hw = ref.watch(
      outputChannelHardwareNamesProvider.select(
        (names) => widget.channel < names.length ? names[widget.channel] : '',
      ),
    );
    final parts = <String>['Out ${widget.channel + 1}'];
    if (hw.isNotEmpty) parts.add(hw);
    if (custom.isNotEmpty && custom != hw) parts.add(custom);
    return Tooltip(
      message: parts.join(' · '),
      child: TextField(
        controller: _ctrl,
        focusNode: _focus,
        maxLength: _maxLabel,
        maxLines: 1,
        onSubmitted: (_) {
          _commit();
          _focus.unfocus();
        },
        cursorWidth: 1,
        cursorColor: T.purple,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        style: TextStyle(
          fontFamily: T.monoFamily,
          fontSize: T.fontCaption,
          color: _focused ? T.textValue : T.textTertiary,
        ),
        decoration: InputDecoration.collapsed(
          hintText: hw.isEmpty ? 'Out ${widget.channel + 1}' : hw,
          hintStyle: TextStyle(
            fontFamily: T.monoFamily,
            fontSize: T.fontCaption,
            color: T.textGhost,
          ),
        ),
      ),
    );
  }
}
