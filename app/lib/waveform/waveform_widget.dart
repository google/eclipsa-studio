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
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../logging/log.dart';
import '../theme.dart';
import 'peak_cache.dart';
import 'peak_data.dart';
import 'wav_decoder.dart';
import 'waveform_painter.dart';
import 'waveform_style.dart';

/// A single-channel waveform widget that loads a WAV file and renders peaks.
///
/// Renders the full file span passively: zoom and pan come from the
/// parent's geometry (the timeline positions and stretches the widget
/// from `timelineViewportProvider`), so the widget itself handles no
/// gestures. It must not — a widget-private scale/drag recognizer
/// here claims trackpad pinches and pans and desyncs the row from
/// the shared viewport (ES-549).
class WaveformWidget extends StatefulWidget {
  final String filePath;
  final int channel;
  final WaveformStyle style;
  final double height;
  final PeakCache? cache;
  final String? label;

  /// Linear amplitude multiplier applied at draw time (e.g. element gain).
  /// 1.0 = identity.
  final double amplitudeScale;

  const WaveformWidget({
    super.key,
    required this.filePath,
    this.channel = 0,
    this.style = const WaveformStyle(),
    this.height = 80,
    this.cache,
    this.label,
    this.amplitudeScale = 1.0,
  });

  @override
  State<WaveformWidget> createState() => _WaveformWidgetState();
}

class _WaveformWidgetState extends State<WaveformWidget>
    with SingleTickerProviderStateMixin {
  late PeakCache _cache;
  ChannelPeaks? _peaks;
  String? _error;
  bool _loading = true;

  late final AnimationController _shimmerCtrl;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _cache = widget.cache ?? PeakCache();
    _loadPeaks();
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(WaveformWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cache != null && widget.cache != oldWidget.cache) {
      _cache = widget.cache!;
    }
    if (oldWidget.filePath != widget.filePath ||
        oldWidget.channel != widget.channel ||
        oldWidget.cache != widget.cache) {
      _loadPeaks();
    }
  }

  Future<void> _loadPeaks() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Pure validation: surfaces a per-row "Invalid WAV file" /
      // "Cannot read file" error (getPeaks degrades to an empty
      // result on failure, which would misreport as missing peaks).
      await WavDecoder.readInfo(widget.filePath);
      final pyramids = await _cache.getPeaks(widget.filePath);
      if (!mounted) return;
      if (pyramids.isEmpty || widget.channel >= pyramids.length) {
        setState(() {
          _error = 'No peak data for channel ${widget.channel}';
          _loading = false;
        });
        return;
      }
      setState(() {
        _peaks = pyramids[widget.channel].levels.first;
        _loading = false;
      });
    } on FormatException catch (e) {
      Log.w(LogCat.waveform, 'Invalid WAV ${widget.filePath}', e);
      if (!mounted) return;
      setState(() {
        _error = 'Invalid WAV file';
        _loading = false;
      });
    } on FileSystemException catch (e) {
      Log.w(LogCat.waveform, 'Cannot read ${widget.filePath}', e);
      if (!mounted) return;
      setState(() {
        _error = 'Cannot read file';
        _loading = false;
      });
    } on RangeError catch (e) {
      Log.w(LogCat.waveform, 'Peak error ${widget.filePath}', e);
      if (!mounted) return;
      setState(() {
        _error = 'Error loading peaks';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (_loading) {
            return AnimatedBuilder(
              animation: _shimmerCtrl,
              builder: (context, _) {
                final t = _shimmerCtrl.value;
                return Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      widget.style.borderRadius,
                    ),
                    gradient: LinearGradient(
                      begin: Alignment(-1.0 + 2.0 * t, 0),
                      end: Alignment(-0.5 + 2.0 * t, 0),
                      colors: [
                        (widget.style.waveColor).withValues(alpha: 0.04),
                        (widget.style.waveColor).withValues(alpha: 0.12),
                        (widget.style.waveColor).withValues(alpha: 0.04),
                      ],
                    ),
                  ),
                );
              },
            );
          }

          if (_error != null) {
            return Container(
              decoration: BoxDecoration(
                color: T.meterRed.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(widget.style.borderRadius),
              ),
              child: Center(
                child: Text(
                  _error!,
                  style: TextStyle(color: T.meterRed, fontSize: T.fontBodyL),
                ),
              ),
            );
          }

          if (_peaks == null) return const SizedBox.shrink();

          return Stack(
            children: [
              CustomPaint(
                size: Size(constraints.maxWidth, widget.height),
                painter: WaveformPainter(
                  peaks: _peaks!,
                  style: widget.style,
                  startPeak: 0,
                  endPeak: _peaks!.length,
                  amplitudeScale: widget.amplitudeScale,
                ),
              ),
              if (widget.label != null)
                Positioned(
                  left: 6,
                  top: 4,
                  child: Text(
                    widget.label!,
                    style: TextStyle(
                      color: widget.style.waveColor.withValues(alpha: 0.7),
                      // Rows shrink with channel count (12 channels →
                      // ~20 px); a fixed fontSmall plus the 4 px top
                      // offset overflows the row and the Stack clips
                      // the glyphs. Scale the label down with the row,
                      // bottoming out at fontMeter. height: 1.0 keeps
                      // the line box equal to the font size so the
                      // fit holds across font modes.
                      fontSize: math.min(
                        T.fontSmall,
                        math.max(T.fontMeter, widget.height * 0.42),
                      ),
                      height: 1.0,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
