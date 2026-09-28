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

import '../logging/log.dart';
import '../theme.dart';
import '../util/time_format.dart';
import '../widgets/track_lanes.dart';
import 'peak_cache.dart';
import 'wav_decoder.dart';
import 'waveform_style.dart';
import 'waveform_widget.dart';

/// Displays all channels of a WAV file stacked vertically, expanding
/// to fill the parent height. Info labelling is the caller's job
/// (the timeline renders its own edge-sticking block label).
///
/// Supports optional routing-aware rendering: when [inputRouting] and
/// [outputChannelCount] are provided, the widget draws one row per
/// output (IAMF dest) channel in the element's layout order, each
/// row pulling waveform data from the routed WAV source channel
/// (`inputRouting[dest]`). Rows with `-1` (silenced) render a faint
/// placeholder so the layout stays spatially consistent.
class MultiChannelWaveform extends StatefulWidget {
  final String filePath;
  final WaveformStyle style;
  final PeakCache? cache;
  final List<String>? channelLabels;

  /// Per-element input routing: `inputRouting[dest] = src`, `-1` =
  /// silence. When null, the widget renders one row per WAV source
  /// channel in source order (identity).
  final List<int>? inputRouting;

  /// Number of output (dest) channels to render when [inputRouting]
  /// is set. Required whenever [inputRouting] is non-null — typically
  /// the element's IAMF layout channel count (e.g. 12 for 7.1.4).
  final int? outputChannelCount;

  /// Linear amplitude multiplier (e.g. converted from element gain in
  /// dB). Applied uniformly to every channel row at draw time.
  final double amplitudeScale;

  /// When false, channel labels are not drawn over the waveform rows —
  /// for hosts that render them in their own gutter (the timeline's
  /// fixed label column). Silenced rows then show just "off".
  final bool showChannelLabels;

  /// Vertical gap between channel rows: 2 px in the flat chrome, the
  /// beveled and raised 1 px divider otherwise (`trackLaneSpacing`).
  static double get spacing => trackLaneSpacing();

  /// Lane height for [n] channel rows in [available] vertical space —
  /// the single source of truth, shared with hosts that render a
  /// lane-aligned gutter (the timeline's label column). Hosts must
  /// hand this the *same* available height the waveform sees (mind
  /// enclosing decoration borders: a Container border insets its
  /// child).
  static double laneHeight(double available, int n) =>
      ((available - spacing * (n - 1)) / n).clamp(4.0, 200.0);

  const MultiChannelWaveform({
    super.key,
    required this.filePath,
    this.style = const WaveformStyle(),
    this.cache,
    this.channelLabels,
    this.inputRouting,
    this.outputChannelCount,
    this.amplitudeScale = 1.0,
    this.showChannelLabels = true,
  });

  @override
  State<MultiChannelWaveform> createState() => _MultiChannelWaveformState();
}

class _MultiChannelWaveformState extends State<MultiChannelWaveform> {
  late PeakCache _cache;
  WavInfo? _info;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cache = widget.cache ?? PeakCache();
    _loadInfo();
  }

  @override
  void didUpdateWidget(MultiChannelWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cache != null && widget.cache != oldWidget.cache) {
      _cache = widget.cache!;
    }
    if (oldWidget.filePath != widget.filePath) _loadInfo();
  }

  Future<void> _loadInfo() async {
    try {
      final info = await WavDecoder.readInfo(widget.filePath);
      if (mounted) setState(() => _info = info);
    } on FormatException catch (e) {
      Log.w(LogCat.waveform, 'Invalid WAV ${widget.filePath}', e);
      if (mounted) setState(() => _error = e.toString());
    } on FileSystemException catch (e) {
      Log.w(LogCat.waveform, 'Cannot read ${widget.filePath}', e);
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          'Error: $_error',
          style: TextStyle(color: T.meterRed, fontSize: T.fontBodyL),
        ),
      );
    }

    if (_info == null) {
      return const SizedBox(height: 40);
    }

    // When routing is active, the row count follows the element's
    // output layout (dest channels), not the WAV's source channel
    // count. Otherwise, fall back to the raw WAV layout.
    final routing = widget.inputRouting;
    final outCh = widget.outputChannelCount;
    final routingActive = routing != null && outCh != null;
    final channelCount = routingActive ? outCh : _info!.channels;

    return LayoutBuilder(
      builder: (_, constraints) {
        return _buildChannels(
          channelCount,
          MultiChannelWaveform.laneHeight(constraints.maxHeight, channelCount),
        );
      },
    );
  }

  Widget _buildChannels(int channelCount, double chHeight) {
    final routing = widget.inputRouting;
    final routingActive = routing != null && widget.outputChannelCount != null;
    final srcCount = _info!.channels;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(channelCount, (row) {
        final bottom = row < channelCount - 1
            ? MultiChannelWaveform.spacing
            : 0.0;
        // Resolve which source channel feeds this row. Without
        // routing, row == src (identity). With routing, look up
        // `routing[row]`; out-of-range defaults to silenced.
        final int srcCh = routingActive
            ? (row < routing.length ? routing[row] : -1)
            : row;
        final bool silenced = routingActive && (srcCh < 0 || srcCh >= srcCount);
        final label = _channelLabel(row, channelCount);
        return Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: silenced
              ? _buildSilencedRow(
                  chHeight,
                  widget.showChannelLabels ? '$label · off' : 'off',
                )
              : WaveformWidget(
                  filePath: widget.filePath,
                  channel: srcCh,
                  style: widget.style,
                  height: chHeight,
                  cache: _cache,
                  label: widget.showChannelLabels ? label : null,
                  amplitudeScale: widget.amplitudeScale,
                ),
        );
      }),
    );
  }

  /// Placeholder for an output channel with `routing[row] == -1`.
  /// Keeps [text] visible so the user sees which IAMF destination is
  /// silenced ("<label> \u00B7 off", or just "off" when the host renders
  /// labels in its own gutter), but draws no waveform data.
  Widget _buildSilencedRow(double height, String text) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: T.bgDeep.withValues(alpha: 0.3),
        border: Border(
          bottom: BorderSide(
            color: T.textGhost.withValues(alpha: 0.1),
            width: 0.5,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: TextStyle(
              color: T.textGhost.withValues(alpha: 0.6),
              fontSize: T.fontCaption,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ),
    );
  }

  String _channelLabel(int row, int total) {
    if (widget.channelLabels != null && row < widget.channelLabels!.length) {
      return widget.channelLabels![row];
    }
    return standardChannelLabel(row, total);
  }
}

/// Builds a compact info string for a WAV file
/// (e.g. "file.wav · 24bit · 48000 Hz · 1:23").
String fileInfoLabel(WavInfo info, String? fileName, {int? engineRate}) {
  final depth = info.audioFormat == 3
      ? '${info.bitsPerSample}bit float'
      : '${info.bitsPerSample}bit';
  // File rate ≠ engine rate → the per-chain resampler converts this
  // file (informational, by design); annotate the rate accordingly.
  final resampled = engineRate != null && engineRate != info.sampleRate;
  final rate = resampled
      ? '${info.sampleRate} → $engineRate Hz'
      : '${info.sampleRate} Hz';
  final parts = <String>[
    ?fileName,
    '${info.channels}ch',
    depth,
    rate,
    formatDuration(info.durationSeconds),
  ];
  return parts.join(' · ');
}

/// IAMF short-form channel labels by channel count.
///
/// Orders and positions match OBR's authoritative layout map
/// (the `oar` Bazel module,
/// `obr_src/obr/renderer/loudspeaker_layouts.h`),
/// which in turn follows the IAMF spec (ITU-R BS.2051-3 sound systems).
/// Count-ambiguous layouts (e.g. 6ch covers both 5.1 and 3.1.2, 10ch
/// covers both 5.1.4 and 7.1.2) fall back to the "primary" layout here;
/// callers with a layout hint should use [iamfChannelLabels] in
/// `widgets/routing_labels.dart` to override.
String standardChannelLabel(int ch, int total) {
  const labels = {
    // Mono (OBR: C). "M" kept for DAW familiarity.
    1: ['M'],
    // Stereo (OBR: L30, R30).
    2: ['L', 'R'],
    // 5.1 (OBR: L30 R30 C LFE L110 R110).
    6: ['L', 'R', 'C', 'LFE', 'Ls', 'Rs'],
    // 7.1 (OBR: L30 R30 C LFE L90 R90 L135 R135).
    // 8-channel is also 5.1.2 (L110 surrounds + UL30 heights);
    // see iamfChannelLabels() for that disambiguation.
    8: ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Lrs', 'Rrs'],
    // 5.1.4 (OBR: L30 R30 C LFE L110 R110 UL45 UR45 UL135 UR135).
    10: ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Ltf', 'Rtf', 'Ltr', 'Rtr'],
    // 7.1.4 (OBR: ... UL45 UR45 UL135 UR135).
    12: [
      'L',
      'R',
      'C',
      'LFE',
      'Ls',
      'Rs',
      'Lrs',
      'Rrs',
      'Ltf',
      'Rtf',
      'Ltr',
      'Rtr',
    ],
    // 9.1.6 (OBR: L60 R60 C LFE1 L135 R135 L30 R30 L90 R90
    //             UL45 UR45 UL135 UR135 UL90 UR90).
    // Labels: front wide pair first (L/R = L60/R60), then rear (Lrs/Rrs),
    // then front-of-center (Lc/Rc = L30/R30), then side (Lss/Rss = L90/R90),
    // then heights — top front, top rear, top side.
    16: [
      'L',
      'R',
      'C',
      'LFE',
      'Lrs',
      'Rrs',
      'Lc',
      'Rc',
      'Lss',
      'Rss',
      'Ltf',
      'Rtf',
      'Ltr',
      'Rtr',
      'Ltss',
      'Rtss',
    ],
    // 7.1.5.4 (OBR: L30 R30 C LFE L90 R90 L135 R135 UL45 UR45 T
    //               UL135 UR135 BL45 BR45 BL135 BR135).
    // Tc = top center; Lbf/Rbf = bottom front; Lbr/Rbr = bottom rear.
    17: [
      'L',
      'R',
      'C',
      'LFE',
      'Lss',
      'Rss',
      'Lrs',
      'Rrs',
      'Ltf',
      'Rtf',
      'Tc',
      'Ltr',
      'Rtr',
      'Lbf',
      'Rbf',
      'Lbr',
      'Rbr',
    ],
  };

  if (labels.containsKey(total) && ch < labels[total]!.length) {
    return labels[total]![ch];
  }
  return 'Ch ${ch + 1}';
}

/// ACN channel labels for ambisonics elements.
List<String> ambisonicsLabels(int channels) =>
    List.generate(channels, (i) => 'ACN $i');

/// Full name for a short channel label, for tooltips. Covers the fixed
/// vocabulary of [standardChannelLabel] / `iamfChannelLabels` plus the
/// generated `ACN n` / `Ch n` forms; unknown labels echo back.
///
/// Every label the loudspeaker layouts render is pinned against the
/// `[names]` glossary in `engine/renderer/oar_output_channels.txt` by
/// `test/renderer/oar_output_channels_test.dart`, which also fails if a
/// layout ever uses a label this map has no entry for — that case would
/// silently echo the short label back as its own tooltip (ES-592). The
/// entries beyond those layouts (7.1.5.4's `Tc`/`Lbf`/`Rbf`/`Lbr`/`Rbr`,
/// and `M`) live only here.
///
/// Note `Ls`/`Rs` deliberately reads as the generic "surround": in the
/// 5.1 family it denotes the L110/R110 rear pair, in the 7.1 family
/// the L90/R90 side pair (standard DAW convention; the OBR positions
/// differ, the short label does not).
String channelFullName(String label) {
  const names = {
    'M': 'Mono',
    'L': 'Left',
    'R': 'Right',
    'C': 'Center',
    'LFE': 'Low-frequency effects',
    'Ls': 'Left surround',
    'Rs': 'Right surround',
    'Lrs': 'Left rear surround',
    'Rrs': 'Right rear surround',
    'Lss': 'Left side surround',
    'Rss': 'Right side surround',
    'Lc': 'Left front center',
    'Rc': 'Right front center',
    'Ltf': 'Left top front',
    'Rtf': 'Right top front',
    'Ltr': 'Left top rear',
    'Rtr': 'Right top rear',
    'Ltss': 'Left top side',
    'Rtss': 'Right top side',
    'Tc': 'Top center',
    'Lbf': 'Left bottom front',
    'Rbf': 'Right bottom front',
    'Lbr': 'Left bottom rear',
    'Rbr': 'Right bottom rear',
  };
  final direct = names[label];
  if (direct != null) return direct;
  final acn = RegExp(r'^ACN (\d+)$').firstMatch(label);
  if (acn != null) return 'Ambisonics channel ${acn[1]} (ACN order)';
  final ch = RegExp(r'^Ch (\d+)$').firstMatch(label);
  if (ch != null) return 'Channel ${ch[1]}';
  return label;
}
