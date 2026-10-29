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
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../meters/multichannel_meter_painter.dart';
import '../state.dart';
import '../theme.dart';
import '../util/monitoring_tooltips.dart';
import '../widgets/console_widgets.dart' show SelectorChrome;
import '../widgets/solo_mute_button.dart';

/// The Renderer view's output meter: one bar per output channel of the
/// monitoring target, in monitoring channel order, with solo and mute
/// for each channel (ES-999). Hovering a channel label opens a small panel
/// with that channel's S and M buttons above the label strip, and the
/// label of a soloed or muted channel takes the solo or the mute colour.
class OutputMeter extends ConsumerStatefulWidget {
  const OutputMeter({super.key});

  /// How long the panel stays open once the pointer has left both the
  /// labels and the panel, so it can cross the gap between them.
  static const closeDelay = Duration(milliseconds: 250);

  /// How long the pointer rests on another label before the open panel
  /// moves to it, so a pointer crossing labels on its way to the panel
  /// does not move the panel to another channel.
  static const switchDelay = Duration(milliseconds: 150);

  @override
  ConsumerState<OutputMeter> createState() => _OutputMeterState();
}

class _OutputMeterState extends ConsumerState<OutputMeter> {
  final _panel = OverlayPortalController();

  /// The label the panel is open for, in the meter's coordinates.
  MeterLabelHit? _open;

  /// Another label under the pointer while the panel is open, and the
  /// timer that moves the panel to it.
  MeterLabelHit? _next;
  Timer? _switchTimer;
  Timer? _closeTimer;

  @override
  void dispose() {
    _switchTimer?.cancel();
    _closeTimer?.cancel();
    super.dispose();
  }

  void _onLabelHover(MeterLabelHit? hit) {
    if (hit == null) {
      _cancelSwitch();
      _scheduleClose();
      return;
    }
    _cancelClose();
    final open = _open;
    if (open == null) {
      _show(hit);
    } else if (hit.channel == open.channel) {
      _cancelSwitch();
      if (hit != open) setState(() => _open = hit);
    } else {
      if (hit.channel != _next?.channel) {
        _switchTimer?.cancel();
        _switchTimer = Timer(OutputMeter.switchDelay, _switchToNext);
      }
      _next = hit;
    }
  }

  void _show(MeterLabelHit hit) {
    setState(() => _open = hit);
    if (!_panel.isShowing) _panel.show();
  }

  void _switchToNext() {
    _switchTimer = null;
    final next = _next;
    _next = null;
    if (next != null && mounted) _show(next);
  }

  void _cancelSwitch() {
    _switchTimer?.cancel();
    _switchTimer = null;
    _next = null;
  }

  void _scheduleClose() {
    if (_open == null || _closeTimer != null) return;
    _closeTimer = Timer(OutputMeter.closeDelay, _close);
  }

  void _cancelClose() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  void _close() {
    _cancelClose();
    _cancelSwitch();
    if (!mounted) return;
    if (_panel.isShowing) _panel.hide();
    if (_open != null) setState(() => _open = null);
  }

  @override
  Widget build(BuildContext context) {
    // Close on a target switch: the open channel index names a different
    // channel on the new target.
    ref.listen(
      monitoringConfigProvider.select((c) => c.layout),
      (_, _) => _close(),
    );
    final layout = ref.watch(monitoringConfigProvider.select((c) => c.layout));
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _panel,
      overlayChildBuilder: (context, info) => _buildPanel(info, layout),
      // The meter rebuilds with the levels every frame; the panel does
      // not.
      child: Consumer(builder: (context, ref, _) => _buildMeter(ref, layout)),
    );
  }

  Widget _buildMeter(WidgetRef ref, OarLayout layout) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final metrics = ref.watch(animatedMetricsProvider);
    final soloMute = ref.watch(outputSoloMuteProvider);
    final n = layout.channels;
    // Labels must come from the active layout, not the count-based
    // default: the bars are the engine's output bus in monitoring
    // channel order, and 8 channels alone can't tell 5.1.2 from 7.1
    // (ES-552). 9.1.6 gets the familiar names alone here (ES-960).
    final labels = layout.meterLabels;
    return MultichannelMeter(
      levels: metrics.meters.length >= n
          ? metrics.meters.sublist(0, n)
          : List.filled(n, 0.0),
      peaks: metrics.meterPeakHolds.length >= n
          ? metrics.meterPeakHolds.sublist(0, n)
          : null,
      clipped: metrics.outputClips.length >= n
          ? metrics.outputClips.sublist(0, n)
          : null,
      labels: labels,
      // Mute wins over solo, as in the engine.
      labelColors: [
        for (var c = 0; c < labels.length; c++)
          soloMute.muted.contains(c)
              ? T.meterRed
              : soloMute.soloed.contains(c)
              ? T.meterYellow
              : null,
      ],
      onClipClear: () => ref.read(clipClearEpochProvider.notifier).bump(),
      onLabelHover: _onLabelHover,
    );
  }

  Widget _buildPanel(OverlayChildLayoutInfo info, OarLayout layout) {
    final open = _open;
    if (open == null || open.channel >= layout.channels) {
      return const SizedBox.shrink();
    }
    final anchor = MatrixUtils.transformPoint(
      info.childPaintTransform,
      Offset(open.rect.center.dx, open.stripTop),
    );
    return CustomSingleChildLayout(
      delegate: _PanelLayout(anchor),
      child: MouseRegion(
        onEnter: (_) {
          _cancelClose();
          _cancelSwitch();
        },
        onExit: (_) => _scheduleClose(),
        child: _OutputSoloMutePanel(
          channel: open.channel,
          // The full name, `Lw (FL)` at 9.1.6, where the meter shows `Lw`.
          label: layout.speakerLabels[open.channel],
        ),
      ),
    );
  }
}

/// Places the solo and mute panel centred on its label and 2 px above
/// the top of the label strip, [anchor], so it covers no label, kept
/// 4 px inside the overlay.
class _PanelLayout extends SingleChildLayoutDelegate {
  const _PanelLayout(this.anchor);

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (anchor.dx - childSize.width / 2).clamp(
      4.0,
      math.max(4.0, size.width - childSize.width - 4),
    ),
    math.max(4.0, anchor.dy - childSize.height - 2),
  );

  @override
  bool shouldRelayout(_PanelLayout oldDelegate) => oldDelegate.anchor != anchor;
}

/// The floating panel for one output channel: its name and its S and M
/// buttons, on the menus' ground and rim.
class _OutputSoloMutePanel extends ConsumerWidget {
  const _OutputSoloMutePanel({required this.channel, required this.label});

  final int channel;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final state = ref.watch(outputSoloMuteProvider);
    final notifier = ref.read(outputSoloMuteProvider.notifier);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: SelectorChrome.menuColor,
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: Border.all(color: T.border, width: T.borderWidth),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: T.fontCaption,
                  color: T.textSecondary,
                ),
              ),
            ),
            SoloMuteButton(
              label: 'S',
              tooltip: outputSoloTooltip(label),
              active: state.soloed.contains(channel),
              activeColor: T.meterYellow,
              onTap: () => notifier.toggleSolo(channel),
            ),
            const SizedBox(width: 2),
            SoloMuteButton(
              label: 'M',
              tooltip: outputMuteTooltip(label),
              active: state.muted.contains(channel),
              activeColor: T.meterRed,
              onTap: () => notifier.toggleMute(channel),
            ),
          ],
        ),
      ),
    );
  }
}
