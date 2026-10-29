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

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../loudness/loudness_report_dialog.dart';
import '../loudness/qc_loudness_report_provider.dart';
import '../meters/meter_provider.dart';
import '../theme.dart';
import '../state.dart';
import '../util/device_rate_tool.dart';
import '../util/monitoring_tooltips.dart';
import '../util/text_width.dart';
import '../workspace/workspace_mode.dart';
import 'chrome_surface.dart';
import 'session_settings_dialog.dart';
import 'theme_cycle.dart';
import 'settings_dialog.dart';

class Statusbar extends ConsumerWidget {
  const Statusbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    final engine = ref.watch(eclipsaStudioEngineProvider);
    final metrics = ref.watch(animatedMetricsProvider);
    final profile = ref.watch(iamfProfileProvider);
    final monConfig = ref.watch(monitoringConfigProvider);
    final audio = ref.watch(audioSettingsProvider);
    final mismatch = ref.watch(sampleRateMismatchProvider);
    final version = ref.watch(appVersionProvider);
    final hasEngine = engine != null;
    // Session Settings only exists in Creator (matches the menu's
    // gating); the audio settings and the Renderer tab are available in
    // every workspace mode.
    final isCreator = ref.watch(workspaceModeProvider) == WorkspaceMode.creator;
    void openAudioSettings() =>
        SettingsDialog.show(context, initialTab: SettingsDialog.tabAudio);
    final fpsColor = metrics.fps < 30
        ? T.meterRed
        : metrics.fps < 50
        ? T.meterYellow
        : StatusbarStrip.ink;
    final engColor = metrics.engineCpu > 70
        ? T.meterRed
        : metrics.engineCpu > 50
        ? T.meterYellow
        : StatusbarStrip.ink;
    final gap = SizedBox(width: StatusbarStrip.gap);

    return StatusbarStrip(
      children: [
        if (hasEngine) ...[
          _StatusLabel(
            _deviceName(ref, audio),
            tooltip: ref.watch(followSystemDefaultProvider)
                ? 'Audio output device (following the system '
                      'default) — double-click for Settings > Audio'
                : 'Audio output device — double-click for '
                      'Settings > Audio',
            onDoubleTap: openAudioSettings,
          ),
          gap,
          if (mismatch == null)
            _StatusLabel(
              '${audio.sampleRate} Hz',
              tooltip: 'Sample rate — double-click for Settings > Audio',
              onDoubleTap: openAudioSettings,
            )
          else
            _StatusLabel(
              '${mismatch.engineRate} → ${mismatch.hwRate} Hz',
              tooltip:
                  'Device hardware runs at ${mismatch.hwRate} Hz while '
                  'the engine runs at ${mismatch.engineRate} Hz, so output '
                  'is being resampled. Change the device rate in '
                  '$deviceRateTool. Double-click for Settings > Audio.',
              color: T.meterYellow,
              onDoubleTap: openAudioSettings,
            ),
          gap,
          _StatusLabel(
            '${audio.bufferSize} smp',
            tooltip: 'Buffer size — double-click for Settings > Audio',
            onDoubleTap: openAudioSettings,
          ),
          gap,
        ],
        StatusbarValue(
          label: 'FPS',
          value: '${metrics.fps}',
          widest: '999',
          color: fpsColor,
          tooltip: 'UI frames per second',
        ),
        if (hasEngine) ...[
          SizedBox(width: StatusbarStrip.pairGap),
          StatusbarValue(
            label: 'Engine',
            value: '${metrics.engineCpu}%',
            widest: '100%',
            color: engColor,
            tooltip: 'Audio engine CPU load',
          ),
          gap,
          _StatusLabel(
            profile.label,
            tooltip: isCreator
                ? 'IAMF profile — double-click for Session Settings'
                : 'IAMF profile',
            onDoubleTap: isCreator
                ? () => SessionSettingsDialog.show(context)
                : null,
          ),
          gap,
          _StatusLabel(
            monConfig.layout.label,
            tooltip: 'Output layout — double-click to open the Renderer view',
            onDoubleTap: () => ref
                .read(activeTabProvider.notifier)
                .set(WorkspaceTabs.renderer),
          ),
          gap,
          const _DimStatus(),
          if (ref.watch(
            outputSoloMuteProvider.select(
              (s) => s.soloed.isNotEmpty || s.muted.isNotEmpty,
            ),
          )) ...[
            gap,
            const OutputSoloMuteStatus(),
          ],
          if (ref.watch(
            runningLoudnessMeasureProvider.select((s) => s != null),
          )) ...[
            gap,
            const _MeasureStatus(),
          ],
        ],
        if (!hasEngine) ...[
          gap,
          _StatusLabel(
            'Engine unavailable',
            tooltip:
                'C++ engine not loaded; run with '
                '${Platform.isWindows ? r'.\build.ps1 run' : './build.sh run'}',
          ),
        ],
        const Spacer(),
        // Which theme is active, and a way to step through them.
        // Ships in every build: all four themes are offered in
        // Settings, so the readout names what the user picked and the
        // double-click is the same affordance as pressing T.
        //
        // A status-bar readout stays visible while the key is held
        // down. A toast would cover the surface under comparison and
        // then disappear.
        _StatusLabel(
          kThemeMeta[T.mode]!.label,
          tooltip: 'Active theme. Double-click, or press T, for the next one',
          onDoubleTap: () => ThemeCycle.next(ref),
        ),
        gap,
        _StatusLabel(
          'Eclipsa Studio v$version',
          tooltip: 'Application version',
        ),
      ],
    );
  }

  static String _deviceName(WidgetRef ref, AudioSettings audio) {
    final devices = ref.watch(audioDevicesProvider);
    if (devices.isEmpty) return '\u2014';
    final idx = audio.deviceIndex.clamp(0, devices.length - 1);
    // Mark follow-system-default mode (ES-467) so the pinned and
    // following states are distinguishable at a glance.
    return ref.watch(followSystemDefaultProvider)
        ? 'System: ${devices[idx].name}'
        : devices[idx].name;
  }
}

/// Monitor DIM in the status bar (ES-629): the engaged state, visible
/// from every view, and a single-click toggle so a dimmed output is
/// never mistaken for a missing one. Unlike the double-click labels
/// around it, this is a control, so it shows a click cursor.
class _DimStatus extends ConsumerWidget {
  const _DimStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Self-track both modes: this widget is const-constructed by its
    // parent, so the parent's rebuild on a theme switch skips it.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final dim = ref.watch(monitorDimProvider);
    return Tooltip(
      message: kMonitorDimTooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => ref.read(monitorDimProvider.notifier).toggle(),
          child: Text(
            dim ? 'DIM −20 dB' : 'DIM',
            style: statusbarTextStyle(
              color: dim ? T.objAmber : null,
              weight: dim ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// Output-channel solo and mute (ES-999) in the status bar while either is
/// engaged. The Renderer view's output meter is the only other place
/// that shows them, and a muted channel stays silent in every view, so
/// the item names the channels in its tooltip and a click clears both.
@visibleForTesting
class OutputSoloMuteStatus extends ConsumerWidget {
  const OutputSoloMuteStatus({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Self-track both modes: this widget is const-constructed.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final soloMute = ref.watch(outputSoloMuteProvider);
    if (soloMute.soloed.isEmpty && soloMute.muted.isEmpty) {
      return const SizedBox.shrink();
    }
    final labels = ref
        .watch(monitoringConfigProvider.select((c) => c.layout))
        .meterLabels;
    List<String> names(Set<int> channels) => [
      for (final c in channels.toList()..sort())
        c < labels.length ? labels[c] : '${c + 1}',
    ];
    return Tooltip(
      message: outputSoloMuteStatusTooltip(
        names(soloMute.soloed),
        names(soloMute.muted),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => ref.read(outputSoloMuteProvider.notifier).clear(),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'OUT', style: statusbarTextStyle()),
                if (soloMute.soloed.isNotEmpty)
                  TextSpan(
                    text: ' SOLO',
                    style: statusbarTextStyle(
                      color: T.meterYellow,
                      weight: FontWeight.w700,
                    ),
                  ),
                if (soloMute.muted.isNotEmpty)
                  TextSpan(
                    text: ' MUTE',
                    style: statusbarTextStyle(
                      color: T.meterRed,
                      weight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A running Loudness Report pass, creator or QC, visible from every
/// view since the pass is not modal: the device output is silent and
/// transport cannot start until it ends. A click opens the report for
/// the current workspace mode, which has Cancel. A pass that is already
/// cancelling takes no click: it can belong to the other workspace
/// mode, and opening the current mode's report would start a new pass.
class _MeasureStatus extends ConsumerWidget {
  const _MeasureStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final m = ref.watch(runningLoudnessMeasureProvider);
    if (m == null) return const SizedBox.shrink();
    final text = m.cancelRequested
        ? 'Cancelling loudness measurement…'
        : m.total > 0
        ? 'Measuring loudness ${m.done}/${m.total}…'
        : 'Measuring loudness…';
    return Tooltip(
      message: m.cancelRequested
          ? 'The Loudness Report is stopping its measurement. Monitoring '
                'is silent and transport cannot start until it ends.'
          : 'The Loudness Report is measuring the programme. Monitoring is '
                'silent and transport cannot start until it ends. Click to '
                'open the report, which has Cancel.',
      child: MouseRegion(
        cursor: m.cancelRequested
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: m.cancelRequested
              ? null
              : () => LoudnessReportDialog.show(context),
          child: Text(
            text,
            style: statusbarTextStyle(
              color: T.objAmber,
              weight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Status bar item with a fixed-width numeric portion so the label
/// doesn't shift when values change (e.g. "9%" -> "12%"). The box is
/// measured from [widest] in the bar's own text style, so it holds the
/// value at every font-size mode and in every chrome style: a constant
/// 28 fit neither "100%" at `fontBody` nor the tracking the beveled
/// and raised bars add (3% of the size), and the value
/// wrapped onto a second line. Public so `statusbar_strip_test` can measure
/// one without the engine the Engine readout needs.
class StatusbarValue extends StatelessWidget {
  final String label;
  final String value;

  /// The widest value this readout shows, which sizes the box.
  final String widest;
  final Color color;
  final String tooltip;
  const StatusbarValue({
    super.key,
    required this.label,
    required this.value,
    required this.widest,
    required this.color,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final valueStyle = statusbarTextStyle(
      color: color,
    ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label ', style: statusbarTextStyle(color: color)),
          SizedBox(
            width: widestTextWidth(context, [widest], valueStyle),
            child: Text(
              value,
              style: valueStyle,
              textAlign: TextAlign.right,
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  final String text;
  final String tooltip;
  final Color? color;

  /// Optional double-click action (e.g. jump to the settings that own
  /// this value). Deliberately no click cursor or hover styling: these
  /// are hidden shortcuts, not single-click controls — the tooltip
  /// ("double-click for ...") is the discoverability channel.
  final VoidCallback? onDoubleTap;

  const _StatusLabel(
    this.text, {
    required this.tooltip,
    this.color,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget child = Text(text, style: statusbarTextStyle(color: color));
    if (onDoubleTap != null) {
      child = GestureDetector(onDoubleTap: onDoubleTap, child: child);
    }
    return Tooltip(message: tooltip, child: child);
  }
}

/// The status bar's ground and row: a [ChromeSlice.statusbar] surface
/// with [children] laid out horizontally inside the bar's inset.
/// `Statusbar` binds the app's readouts to it; the Theme Gallery renders
/// it with fixed labels.
///
/// Every style spaces the items [gap] apart, with [pairGap] between a
/// paired label and value, inside a 24 px inset on both sides.
class StatusbarStrip extends StatelessWidget {
  const StatusbarStrip({super.key, required this.children});

  final List<Widget> children;

  /// Space between two items, the same in every theme; a component's
  /// size does not vary by theme, only how it is drawn and
  /// coloured.
  static const double gap = T.gapXl;

  /// Space between the two items of a pair (FPS and Engine).
  static const double pairGap = T.gapMd;

  /// The bar's neutral text colour: `textMuted` in the beveled style (`#898989`
  /// to within 1/255), and `chromeInk` in the others: the raised style's light
  /// bar (`#44413C`) and the recessed and outlined bars, whose chrome ink is
  /// set for their bar.
  static Color get ink => switch (T.chromeStyle) {
    ChromeStyle.beveled => T.textMuted,
    ChromeStyle.raised ||
    ChromeStyle.recessed ||
    ChromeStyle.outlined => T.chromeInk,
  };

  @override
  Widget build(BuildContext context) => ChromeSurface(
    slice: ChromeSlice.statusbar,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: T.gapXl),
      child: Row(children: children),
    ),
  );
}

/// Text in the status bar, at `fontBody` (12) in every style. [color]
/// and [weight] default to the bar's neutral ink and regular weight,
/// which a state colour (a warning, an engaged DIM) overrides.
///
/// The beveled and raised styles track the text at 3% of its size. At
/// 14 px the readouts read too large against the rest of the app, so
/// every style keeps `fontBody`. The weight is regular in every theme,
/// so a text role has one weight across the themes.
TextStyle statusbarTextStyle({Color? color, FontWeight? weight}) => TextStyle(
  fontSize: T.fontBody,
  color: color ?? StatusbarStrip.ink,
  fontWeight: weight,
  letterSpacing: switch (T.chromeStyle) {
    ChromeStyle.beveled || ChromeStyle.raised => T.tracking(T.fontBody, 3),
    ChromeStyle.recessed || ChromeStyle.outlined => null,
  },
);
