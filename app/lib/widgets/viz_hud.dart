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
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ffi_bridge.dart' show kStatsCorrMaxChannels;
import '../meters/meter_colors.dart';
import '../renderer/element_stats.dart';
import '../renderer/speaker_layout.dart';
import '../state.dart';
import '../theme.dart';
import 'eyebrow_label.dart';

/// Per-element diagnostic overlay.
///
/// Sections:
///   • Header — element name/layout + cycling arrows across all
///     channel-based elements.
///   • Energy bars — one bar per channel, dB-mapped with the same
///     floor convention as the meters. Onset flag flashes the bar.
///   • Coherence — 3-band mini polar readout per channel.
///   • Correlation — small heatmap (packed triangle) for the first
///     min(N, kStatsCorrMaxChannels) channels.
///
/// Re-uses the same [ElementStats] snapshot the scene bridge feeds in.
class VizHud extends ConsumerStatefulWidget {
  final List<ElementStats> stats;
  final List<AudioElement> elements;

  const VizHud({super.key, required this.stats, required this.elements});

  @override
  ConsumerState<VizHud> createState() => _VizHudState();
}

class _VizHudState extends ConsumerState<VizHud> {
  int _targetIndex = 0;

  List<int> get _targets {
    final out = <int>[];
    for (var i = 0; i < widget.elements.length; i++) {
      final t = widget.elements[i].type.toLowerCase();
      if (t.contains('object') || t.contains('scene')) continue;
      out.add(i);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final targets = _targets;
    if (targets.isEmpty) return const SizedBox.shrink();
    if (_targetIndex >= targets.length) _targetIndex = 0;
    final idx = targets[_targetIndex];
    if (idx >= widget.stats.length) return const SizedBox.shrink();

    final el = widget.elements[idx];
    final stats = widget.stats[idx];
    final layout = SpeakerLayout.byName(el.layout);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: T.gapMd,
          vertical: T.gapSm,
        ),
        // Border-only separation from the canvas behind — follows the
        // project's "no decorative drop shadows" convention.
        decoration: BoxDecoration(
          color: T.bgDeep.withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: Border.all(color: T.borderLight),
        ),
        child: DefaultTextStyle(
          style: TextStyle(
            fontSize: T.fontCaption,
            color: T.textPrimary,
            height: 1.2,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                element: el,
                layout: layout,
                index: _targetIndex + 1,
                total: targets.length,
                onPrev: targets.length > 1
                    ? () => setState(
                        () => _targetIndex =
                            (_targetIndex - 1 + targets.length) %
                            targets.length,
                      )
                    : null,
                onNext: targets.length > 1
                    ? () => setState(
                        () =>
                            _targetIndex = (_targetIndex + 1) % targets.length,
                      )
                    : null,
              ),
              if (stats.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'No stats yet. Start playback.',
                    style: TextStyle(color: T.textMuted),
                  ),
                )
              else ...[
                const SizedBox(height: 8),
                EyebrowLabel('Energy · onsets'),
                const SizedBox(height: 4),
                _EnergyGrid(stats: stats, layout: layout),
                const SizedBox(height: 8),
                EyebrowLabel('Coherence (γ² lo · mid · hi)'),
                const SizedBox(height: 4),
                _CoherenceGrid(stats: stats, layout: layout),
                if (stats.channelCount >= 2) ...[
                  const SizedBox(height: 8),
                  EyebrowLabel('Correlation ρ'),
                  const SizedBox(height: 4),
                  _CorrelationMatrix(stats: stats, layout: layout),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AudioElement element;
  final SpeakerLayout? layout;
  final int index;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const _Header({
    required this.element,
    required this.layout,
    required this.index,
    required this.total,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: aeTypeColor(element.type),
            shape: BoxShape.circle,
          ),
        ),
        Expanded(
          child: Text(
            '${element.name}  ·  ${SpeakerLayout.displayName(element.layout)}'
            '${layout != null ? '  (${layout!.channelCount} ch)' : ''}',
            style: TextStyle(
              fontSize: T.fontSmall,
              fontWeight: FontWeight.w600,
              color: T.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (total > 1) ...[
          _CycleButton(icon: Icons.chevron_left, onPressed: onPrev),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('$index / $total', style: T.styleCaption),
          ),
          _CycleButton(icon: Icons.chevron_right, onPressed: onNext),
        ],
      ],
    );
  }
}

class _CycleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  const _CycleButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          icon,
          size: T.iconSm,
          color: onPressed == null ? T.textMuted : T.textSecondary,
        ),
      ),
    );
  }
}

/// Per-channel energy bar row — bar width = dB-mapped value, label
/// below, onset hinted with a filled dot.
class _EnergyGrid extends StatelessWidget {
  final ElementStats stats;
  final SpeakerLayout? layout;

  const _EnergyGrid({required this.stats, required this.layout});

  @override
  Widget build(BuildContext context) {
    final n = math.min(
      stats.channelCount,
      layout?.speakers.length ?? stats.channelCount,
    );
    const floorDb = -60.0;

    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: List.generate(n, (c) {
        final e = stats.energy[c];
        final db = e > 1e-12 ? 10.0 * (math.log(e) / math.ln10) : floorDb;
        final t = ((db - floorDb) / -floorDb).clamp(0.0, 1.0);
        final label = layout != null && c < layout!.speakers.length
            ? layout!.speakers[c].label
            : '$c';
        final onset = stats.onset[c] != 0;

        return SizedBox(
          width: 80,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: onset
                          ? T.purple
                          : T.textMuted.withValues(alpha: 0.25),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: T.fontMeter,
                        color: T.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    db > floorDb ? db.toStringAsFixed(0) : '—',
                    style: TextStyle(
                      fontSize: T.fontMeter,
                      color: T.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: t,
                  minHeight: 3,
                  backgroundColor: T.borderLight.withValues(alpha: 0.4),
                  valueColor: AlwaysStoppedAnimation<Color>(_levelColor(t)),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  // Same normalized −60..0 dB scale as the level meters, so the shared
  // green/yellow/amber zone mapping applies directly.
  Color _levelColor(double t) => MeterColors.zoneColor(t);
}

/// Three little 8-px squares per channel, one per band, filled by
/// coherence. High = bright, low = dim.
class _CoherenceGrid extends StatelessWidget {
  final ElementStats stats;
  final SpeakerLayout? layout;

  const _CoherenceGrid({required this.stats, required this.layout});

  @override
  Widget build(BuildContext context) {
    final n = math.min(
      stats.channelCount,
      layout?.speakers.length ?? stats.channelCount,
    );
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: List.generate(n, (c) {
        final label = layout != null && c < layout!.speakers.length
            ? layout!.speakers[c].label
            : '$c';
        return SizedBox(
          width: 80,
          child: Row(
            children: [
              SizedBox(
                width: 20,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: T.fontMeter,
                    color: T.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _BandCell(value: stats.cohLo[c]),
              const SizedBox(width: 2),
              _BandCell(value: stats.cohMid[c]),
              const SizedBox(width: 2),
              _BandCell(value: stats.cohHi[c]),
            ],
          ),
        );
      }),
    );
  }
}

class _BandCell extends StatelessWidget {
  final double value;

  const _BandCell({required this.value});

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return Container(
      width: 14,
      height: 10,
      decoration: BoxDecoration(
        color: T.purple.withValues(alpha: 0.15 + 0.7 * v),
        border: Border.all(
          color: T.borderLight.withValues(alpha: 0.5),
          width: 0.5,
        ),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// Correlation heatmap — rendered with a CustomPaint so we can draw a
/// compact NxN grid cheaply. Colors: blue → white → red for −1 → 0 → +1.
class _CorrelationMatrix extends StatelessWidget {
  final ElementStats stats;
  final SpeakerLayout? layout;

  const _CorrelationMatrix({required this.stats, required this.layout});

  @override
  Widget build(BuildContext context) {
    final n = math.min(
      math.min(stats.channelCount, kStatsCorrMaxChannels),
      layout?.speakers.length ?? stats.channelCount,
    );
    if (n < 2) return const SizedBox.shrink();
    final labels = [
      for (var c = 0; c < n; c++)
        (layout != null && c < layout!.speakers.length)
            ? layout!.speakers[c].label
            : '$c',
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          height: 140,
          child: CustomPaint(
            painter: _CorrelationPainter(
              stats: stats,
              n: n,
              labels: labels,
              baseTextColor: T.textMuted,
              gridColor: T.borderLight.withValues(alpha: 0.4),
              fontMode: T.fontMode,
              themeMode: T.mode,
            ),
          ),
        ),
        const SizedBox(width: 12),
        _CorrelationLegend(),
      ],
    );
  }
}

class _CorrelationLegend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ρ scale',
          style: TextStyle(fontSize: T.fontMeter, color: T.textMuted),
        ),
        const SizedBox(height: 3),
        Container(
          width: 90,
          height: 8,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            gradient: LinearGradient(
              colors: [T.corrNeg, T.corrZero, T.corrPos],
            ),
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: 90,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '-1',
                style: TextStyle(fontSize: T.fontMeter, color: T.textMuted),
              ),
              Text(
                '0',
                style: TextStyle(fontSize: T.fontMeter, color: T.textMuted),
              ),
              Text(
                '+1',
                style: TextStyle(fontSize: T.fontMeter, color: T.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CorrelationPainter extends CustomPainter {
  final ElementStats stats;
  final int n;
  final List<String> labels;
  final Color baseTextColor;
  final Color gridColor;
  final FontSizeMode fontMode;
  final AppThemeMode themeMode;

  _CorrelationPainter({
    required this.stats,
    required this.n,
    required this.labels,
    required this.baseTextColor,
    required this.gridColor,
    required this.fontMode,
    required this.themeMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Reserve a small axis strip for labels.
    const labelStrip = 16.0;
    final gridX = labelStrip;
    final gridY = labelStrip;
    final gridW = size.width - gridX;
    final gridH = size.height - gridY;
    final cellW = gridW / n;
    final cellH = gridH / n;

    // Cells.
    final paint = Paint();
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        final rho = i == j ? 1.0 : stats.correlation(i, j);
        paint.color = _rhoToColor(rho);
        final r = Rect.fromLTWH(
          gridX + j * cellW,
          gridY + i * cellH,
          cellW,
          cellH,
        );
        canvas.drawRect(r, paint);
      }
    }
    // Grid lines.
    final line = Paint()
      ..color = gridColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    for (var i = 0; i <= n; i++) {
      final y = gridY + i * cellH;
      canvas.drawLine(Offset(gridX, y), Offset(gridX + gridW, y), line);
      final x = gridX + i * cellW;
      canvas.drawLine(Offset(x, gridY), Offset(x, gridY + gridH), line);
    }
    // Axis labels — only draw first character of each label when cell is
    // narrow; saves visual clutter for 10+ channels.
    final textStyle = TextStyle(
      color: baseTextColor,
      fontSize: T.fontMeter,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final short = cellW < 14;
    for (var i = 0; i < n; i++) {
      final label = short
          ? (labels[i].isNotEmpty ? labels[i][0] : '$i')
          : labels[i];
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: cellW);
      // Top row.
      tp.paint(
        canvas,
        Offset(
          gridX + i * cellW + (cellW - tp.width) / 2,
          (labelStrip - tp.height) / 2,
        ),
      );
      // Left column.
      tp.paint(
        canvas,
        Offset(
          (labelStrip - tp.width) / 2,
          gridY + i * cellH + (cellH - tp.height) / 2,
        ),
      );
    }
  }

  Color _rhoToColor(double rho) {
    final r = rho.clamp(-1.0, 1.0);
    if (r >= 0) {
      return Color.lerp(T.corrZero, T.corrPos, r)!;
    }
    return Color.lerp(T.corrZero, T.corrNeg, -r)!;
  }

  @override
  // Always repaint: `stats` is a pool-reused ElementStats mutated in
  // place each frame (see element_stats.dart), so identity comparison
  // against the old delegate would freeze the heatmap after the first
  // paint. The HUD is rebuilt per tick only while visible, so an
  // unconditional repaint costs exactly one small grid per frame.
  bool shouldRepaint(covariant _CorrelationPainter oldDelegate) => true;
}
