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

import 'dart:io' show FileSystemException;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../export/iamf_profile_rules.dart'
    show profileAllowedConfigsForChannelCount;
import '../logging/log.dart';
import '../meters/meter_provider.dart' show eclipsaStudioEngineProvider;
import '../playback/iamf_probe.dart';
import '../playback/iamf_probe_full.dart' show IamfFullProbe;
import '../playback/playback_session.dart';
import '../session/recent_qc_files.dart';
import '../session/session_provider.dart';
import '../state.dart'
    show
        activeTabProvider,
        IamfProfile,
        iamfProfileProvider,
        importNoticeProvider,
        transportProvider,
        WorkspaceTabs;
import '../views/elements_view.dart'
    show addNewElementFromWav, wavImportErrorMessage;
import '../waveform/wav_decoder.dart' show WavDecoder, WavInfo;
import '../widgets/app_dialog.dart';
import '../widgets/element_format_dialog.dart' show showElementFormatDialog;
import '../theme.dart';
import '../video/video_provider.dart';
import '../widgets/ok_dialog.dart';
import 'workspace_close.dart';
import 'workspace_mode.dart';

/// Shared workspace entry points used by both the landing screen and
/// the in-shell File menu. Every action that changes which workspace
/// is open routes through [prepareForWorkspaceSwitch] so dirty-state
/// prompts and engine teardown are applied consistently regardless of
/// the user's current mode.

/// Publish an IAMF file's timeline ([fileFrames] at [fileRate]) to the
/// transport. The file describes its own timeline, but the transport
/// clocks at the engine output rate (the per-chain resamplers
/// convert), so the duration is rebased onto the engine rate — the
/// identity for a matched-rate file. Both the open path and the
/// lazy-scan completion poll route through here so the two can never
/// publish in different units (ES-34).
void publishPlaybackDuration(
  WidgetRef ref, {
  required int fileFrames,
  required int fileRate,
}) {
  final engine = ref.read(eclipsaStudioEngineProvider);
  if (engine == null) return;
  final engineRate = engine.currentSampleRate;
  final engineFrames = fileRate > 0
      ? (fileFrames * engineRate / fileRate).round()
      : fileFrames;
  ref.read(transportProvider.notifier).updateDuration(engineFrames, engineRate);
}

/// Open a new empty Creator session. Confirms unsaved changes if
/// switching from a dirty Creator session.
Future<void> startNewCreatorSession(BuildContext context, WidgetRef ref) async {
  if (!await prepareForWorkspaceSwitch(
    context,
    ref,
    target: WorkspaceMode.creator,
  )) {
    return;
  }
  // Flip mode before newSession() so its writes pass the Creator-only
  // guards on engineOrder/elements/mixes. Mirrors the ordering in
  // SessionNotifier.loadFile, which calls enterCreator() before
  // _applySession for the same reason.
  ref.read(workspaceModeProvider.notifier).enterCreator();
  ref.read(sessionProvider.notifier).newSession();
}

/// Start a fresh Creator session seeded with [wavPath] as its first
/// element — the landing card's plain-WAV drop path (an ADM WAV routes
/// through startImportAdmFlow instead), and the Import ADM dialog's
/// Open as Plain WAV for a WAV without ADM metadata (ES-1008). The log
/// lines say "WAV drop" for both.
///
/// Everything user-visible resolves *before* the workspace switch,
/// while the landing screen (and its context) is still mounted and the
/// current session is still intact: WAV validation, then the
/// element-format dialog (ES-152) run with `allowProfileBump` — it
/// resolves the interpretation *and* any IAMF profile switch the pick
/// requires in one surface. The resolved profile is stamped on the new
/// session (`newSession()` deliberately keeps the profile provider, so
/// without a stamp the session would inherit a stale choice). Only
/// failures after the switch (e.g. an engine sync reject) go through
/// importNoticeProvider, whose listener lives in the now-mounted
/// AppShell.
Future<void> startCreatorSessionWithWav(
  BuildContext context,
  WidgetRef ref,
  String wavPath,
) async {
  // The switch below unmounts the landing widget that owns `ref`;
  // capture the app-scoped container up front and use it for all
  // post-switch provider work (the startImportAdmFlow pattern).
  final container = ProviderScope.containerOf(context, listen: false);

  Future<void> reject(Object e) async {
    Log.w(LogCat.elements, 'WAV drop rejected: $wavPath', e);
    if (context.mounted) {
      await showOkDialog(
        context,
        title: 'Could Not Import WAV',
        message: wavImportErrorMessage(wavPath, e),
      );
    }
  }

  WavInfo info;
  try {
    info = await WavDecoder.readInfo(wavPath);
  } on FormatException catch (e) {
    return reject(e);
  } on FileSystemException catch (e) {
    return reject(e);
  }

  // Decodable (readInfo caps at 32 ch) but beyond every profile — the
  // budgets are not monotonic across profiles (Base-Enhanced allows
  // 28 ch, Base-Advanced 18), so scan rather than assume "higher fits
  // more".
  bool fits(IamfProfile prof) =>
      profileAllowedConfigsForChannelCount(prof, info.channels).isNotEmpty;
  if (!IamfProfile.values.any(fits)) {
    return reject(
      FormatException(
        'no IAMF profile supports a ${info.channels}-channel element',
      ),
    );
  }

  // Ambiguous channel counts (stereo vs binaural, 9.1.6 vs 3OA, …) go
  // through the element-format dialog. The file seeds a fresh session,
  // so interpretations beyond the active profile are offered too
  // (allowProfileBump): picking one carries the profile switch in
  // choice.bumpTo, and the dialog doubles as the confirmation when the
  // only viable interpretation needs it. With one in-profile
  // interpretation the call returns directly without UI.
  final active = container.read(iamfProfileProvider);
  if (!context.mounted) return;
  final choice = await showElementFormatDialog(
    context,
    fileName: p.basename(wavPath),
    channels: info.channels,
    profile: active,
    sampleRate: info.sampleRate,
    allowProfileBump: true,
  );
  if (choice == null) return; // Cancelled — nothing switched yet.
  final profile = choice.bumpTo ?? active;
  if (profile != active) {
    Log.i(
      LogCat.app,
      'WAV drop: ${choice.config.label} needs ${profile.label}; '
      'bumping the new session from ${active.label} (user-confirmed)',
    );
  }

  if (!context.mounted) return;
  if (!await prepareForWorkspaceSwitch(
    context,
    ref,
    target: WorkspaceMode.creator,
  )) {
    return;
  }
  container.read(workspaceModeProvider.notifier).enterCreator();
  container.read(sessionProvider.notifier).newSession();
  // Stamp the resolved profile (the ADM-import pattern): newSession()
  // resets elements/mixes but NOT the profile provider.
  container.read(iamfProfileProvider.notifier).set(profile);
  final err = await addNewElementFromWav(
    container,
    wavPath,
    configOverride: choice.config,
  );
  if (err != null) {
    // Rare (decode and profile fit were pre-validated) but possible,
    // e.g. an engine sync failure.
    Log.w(LogCat.elements, 'WAV drop: could not add element: $err');
    container.read(importNoticeProvider.notifier).showBlocker(err);
  }
}

/// Open an existing `.esp` session. Either loads [path] directly or
/// shows a file picker when [path] is null.
Future<void> openCreatorSession(
  BuildContext context,
  WidgetRef ref, {
  String? path,
}) async {
  if (!await prepareForWorkspaceSwitch(
    context,
    ref,
    target: WorkspaceMode.creator,
  )) {
    return;
  }
  if (path == null) {
    await ref.read(sessionProvider.notifier).open();
  } else {
    await ref.read(sessionProvider.notifier).loadFile(path);
  }
}

/// Single-flight latch for [openIamfForQc]. The "Analysing…" progress
/// dialog is a Flutter modal barrier, but on macOS the menu bar is a
/// native `PlatformMenuBar` whose items stay clickable behind it — so a
/// second File ▸ Open (Recent) could start a parallel open while the
/// first is still probing. Both flows would `pop()` the root navigator
/// (dismissing each other's dialogs) and both would `loadFile()` the one
/// shared video player, leaving the picture showing a different file
/// than the engine opened (ES-233). We drop the second invocation.
bool _qcOpenInFlight = false;

/// Drives the Playback open of a `.iamf` file or an MP4 with an IAMF
/// track: probe on a background isolate with a progress dialog, then
/// open the engine-side streaming session and flip workspace mode to
/// Playback. Used by the landing card, the File menu, the export's
/// "open in Playback" and the launch parameters. Re-entrant calls while
/// an open is in progress are ignored (see [_qcOpenInFlight]).
///
/// Returns whether the file opened. [showErrors] false logs a failure
/// without its dialog (the unattended `--quit-after-load` open).
Future<bool> openIamfForQc(
  BuildContext context,
  WidgetRef ref, {
  String? path,
  bool showErrors = true,
}) async {
  if (_qcOpenInFlight) {
    Log.i(LogCat.app, 'IAMF open: ignored — an open is already in progress');
    return false;
  }
  _qcOpenInFlight = true;
  try {
    if (!await prepareForWorkspaceSwitch(
      context,
      ref,
      target: WorkspaceMode.playback,
    )) {
      return false;
    }

    String resolvedPath;
    if (path == null) {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Open IAMF or MP4 for Playback',
        type: FileType.custom,
        // .mp4 carries IAMF audio + picture (the format YouTube ingests and
        // our own export produces); the engine reads the `iamf` track's
        // samples in place, and demuxes the track into memory only when
        // its sample data is stored in another file. Bare .iamf stays
        // audio-only.
        allowedExtensions: const ['iamf', 'mp4'],
        allowMultiple: false,
        // Starts in the last QC file's folder — that list already exists,
        // so no preference of its own is needed. QC material is a delivered
        // bitstream, so it shares no folder with sessions or source media.
        initialDirectory: await RecentQcFiles.lastDirectory(),
      );
      final picked = result?.files.single.path;
      if (picked == null) return false;
      resolvedPath = picked;
    } else {
      resolvedPath = path;
    }

    if (!context.mounted) return false;
    return await _runIamfOpen(
      context,
      ref,
      resolvedPath,
      showErrors: showErrors,
    );
  } finally {
    _qcOpenInFlight = false;
  }
}

/// Returns whether the file opened. With [showErrors] false a failure
/// is logged without its dialog, so an unattended startup open
/// (`--quit-after-load`) cannot wait on one.
Future<bool> _runIamfOpen(
  BuildContext context,
  WidgetRef ref,
  String path, {
  required bool showErrors,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.maybeOf(context);
  // Capture the dialog's own context so dismissal removes exactly the
  // analysing dialog. A blind top-of-stack pop() could dismiss a
  // different dialog pushed above it in the meantime — e.g. an import
  // blocker (ES-184) raised by a drop landing mid-probe (OS drops still
  // reach DropTarget under the modal barrier) — leaving this
  // non-dismissible dialog stuck.
  BuildContext? analysingCtx;
  showAppDialog<void>(
    context: context,
    escape: DialogEscape.none,
    builder: (ctx) {
      analysingCtx = ctx;
      return _AnalysingDialog(path: path);
    },
  );

  final phaseTimer = Stopwatch()..start();
  Log.i(LogCat.app, 'IAMF open: start path="$path"');

  // The C-struct probe collapses each presentation to its first
  // sub-mix; the full descriptor dump taken on the same isolate is merged
  // below so the session sees every sub-mix (element sets, gains, output
  // gains, param modes). If the full probe fails, the session keeps the
  // first sub-mix of each presentation (ES-282).
  IamfProbeReport report;
  IamfFullProbe fullProbe;
  try {
    (report, fullProbe) = await probeIamfWithFull(path);
  } finally {
    // If the probe finished before the dialog's route ever built,
    // analysingCtx is still null — let the pushed route build first
    // so the removal below can find it.
    if (analysingCtx == null) {
      await WidgetsBinding.instance.endOfFrame;
    }
    final ctx = analysingCtx;
    if (ctx != null && ctx.mounted) {
      final route = ModalRoute.of(ctx);
      if (route != null) navigator.removeRoute(route);
    }
  }
  final probeMs = phaseTimer.elapsedMilliseconds;
  Log.i(
    LogCat.app,
    'IAMF open: probe done in ${probeMs}ms '
    '(ok=${report.ok}, '
    'ae=${report.audioElements.length}, '
    'mix=${report.mixPresentations.length}, '
    'full=${fullProbe.ok})',
  );

  if (!report.ok) {
    Log.w(LogCat.app, 'IAMF probe failed for $path: ${report.errorMessage}');
    if (showErrors && context.mounted) {
      await _showProbeErrorDialog(context, path, report.errorMessage);
    }
    return false;
  }

  if (!fullProbe.ok) {
    Log.w(
      LogCat.app,
      'IAMF full probe failed (${fullProbe.errorMessage}); '
      'mix data limited to first sub-mixes',
    );
  }
  report = enrichReportWithFullProbe(report, fullProbe);
  Log.i(
    LogCat.app,
    'IAMF open: full probe merged '
    '(subMixes=${[for (final mp in report.mixPresentations) mp.subMixes.length]})',
  );

  // The engine's probe carries the authoritative per-AE renderable
  // verdict (ES-330). Zero renderable AEs is an exceptional condition
  // (future-spec types, decode gaps) — decline through the ordinary
  // error dialog with the engine's reasons, no bespoke concept.
  final renderable = report.audioElements.where((ae) => ae.renderable).length;
  if (renderable == 0) {
    Log.w(LogCat.app, 'IAMF has no renderable AEs ($path); declining to open');
    if (showErrors && context.mounted) {
      final reasons = report.audioElements
          .map((ae) => ae.skipReason.label)
          .where((r) => r.isNotEmpty)
          .toSet()
          .join('; ');
      await _showProbeErrorDialog(
        context,
        path,
        'None of the audio elements in this file can be played'
        '${reasons.isEmpty ? '' : ': $reasons'}.',
      );
    }
    return false;
  }

  final engine = ref.read(eclipsaStudioEngineProvider);
  if (engine == null) {
    Log.w(LogCat.app, 'IAMF open: engine not initialised');
    if (showErrors && context.mounted) {
      await _showProbeErrorDialog(
        context,
        path,
        'Audio engine is not initialised yet.',
      );
    }
    return false;
  }
  final engineStart = phaseTimer.elapsedMilliseconds;
  final open = engine.playbackOpen(path);
  final engineMs = phaseTimer.elapsedMilliseconds - engineStart;
  if (!open.ok) {
    Log.w(
      LogCat.app,
      'engine.playbackOpen failed for $path: ${open.errorMessage}',
    );
    if (showErrors && context.mounted) {
      await _showProbeErrorDialog(context, path, open.errorMessage);
    }
    return false;
  }
  Log.i(
    LogCat.app,
    'IAMF open: engine.playbackOpen done in ${engineMs}ms '
    '(ae=${open.audioElements.length})',
  );

  await RecentQcFiles.add(path);
  ref.read(recentQcFilesProvider.notifier).refresh();
  ref
      .read(playbackSessionProvider.notifier)
      .open(
        path: path,
        report: report,
        sampleRate: open.sampleRate,
        totalFrames: open.totalFrames,
        audioElements: open.audioElements,
      );
  publishPlaybackDuration(
    ref,
    fileFrames: open.totalFrames,
    fileRate: open.sampleRate,
  );

  // enterPlayback() rebuilds the workspace and unmounts the widget whose
  // `ref` we hold (the landing screen, or a menu host), so any `ref.read`
  // after the awaited video load below runs on a deactivated element and
  // throws "Using ref … unmounted" (ES-234). Capture the notifiers we still
  // need now — they live on the ProviderContainer, not the widget, so they
  // stay valid across the switch — and use them instead of `ref` afterward.
  final videoNotifier = ref.read(videoProvider.notifier);
  final tabNotifier = ref.read(activeTabProvider.notifier);
  ref.read(workspaceModeProvider.notifier).enterPlayback();

  // QC of an IAMF-in-MP4 deliverable: load the same container into the
  // muted video player so the picture rides the transport (the engine
  // already demuxed the audio). A bare .iamf has no picture — unload any
  // video left over from a previous QC open in this Playback session.
  if (p.extension(path).toLowerCase() == '.mp4') {
    final videoErr = await videoNotifier.loadFile(path);
    if (videoErr != null) {
      Log.w(LogCat.video, 'QC video load failed for $path: $videoErr');
    }
  } else {
    await videoNotifier.unload();
  }

  // QC opens on the renderer (auditioning the render is the task; the
  // inspector is reference detail). Force it on every open, including a
  // reopen within Playback — the mode doesn't change there, so the tab
  // would otherwise keep a prior selection such as the inspector.
  tabNotifier.set(WorkspaceTabs.renderer);
  Log.i(
    LogCat.app,
    'IAMF open: total ${phaseTimer.elapsedMilliseconds}ms '
    '(probe=${probeMs}ms, engine=${engineMs}ms)',
  );

  // Degraded open (ES-330): some AEs couldn't be registered for
  // rendering — an exceptional condition, surfaced once with the
  // engine's reasons.
  if (renderable < report.audioElements.length) {
    final skipped = report.audioElements.where((ae) => !ae.renderable).toList();
    final reasons = skipped
        .map((ae) => ae.skipReason.label)
        .where((r) => r.isNotEmpty)
        .toSet()
        .join('; ');
    messenger?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          'Loaded $renderable of ${report.audioElements.length} '
          'audio elements, ${skipped.length} skipped'
          '${reasons.isEmpty ? '' : ' ($reasons)'}.',
        ),
      ),
    );
  }
  return true;
}

/// Map raw engine probe errors to friendlier copy where we recognize
/// them. A plain-AAC MP4 fails the demux with "unsupported: no IAMF
/// audio track" (ES-184) — say what that means instead of echoing the
/// engine string.
String _friendlyProbeError(String path, String? reason) {
  if (reason != null && reason.contains('no IAMF audio track')) {
    final kind = p.extension(path).toLowerCase() == '.mp4' ? 'MP4' : 'file';
    return "This $kind doesn't contain an IAMF audio track.";
  }
  return reason ?? 'Unknown error.';
}

Future<void> _showProbeErrorDialog(
  BuildContext context,
  String path,
  String? reason,
) {
  return showOkDialog(
    context,
    title: 'Could Not Open File',
    message: '${p.basename(path)}\n\n${_friendlyProbeError(path, reason)}',
  );
}

class _AnalysingDialog extends StatelessWidget {
  const _AnalysingDialog({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.bgElevated,
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text('Analysing ${p.basename(path)}…', style: T.styleBody),
          ),
        ],
      ),
    );
  }
}
