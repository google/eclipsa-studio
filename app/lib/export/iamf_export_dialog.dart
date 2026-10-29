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
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ffi_bridge.dart';
import '../logging/log.dart';
import '../loudness/loudness_fingerprint.dart';
import '../loudness/loudness_measurement.dart';
import '../loudness/loudness_report_provider.dart';
import '../meters/meter_provider.dart' show eclipsaStudioEngineProvider;
import '../playback/iamf_probe_full.dart';
import '../session/folder_bookmarks.dart';
import '../session/session_provider.dart';
import '../state.dart';
import '../theme.dart';
import '../util/text_width.dart';
import '../util/time_format.dart';
import '../video/still_image_backend.dart' show isStillImagePath;
import '../video/video_provider.dart';
import '../widgets/app_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/console_widgets.dart' show ConsoleSelector, raisedField;
import '../widgets/dialog_shell.dart';
import '../widgets/profile_selector.dart';
import '../widgets/status_tag.dart';
import '../workspace/workspace_actions.dart' show openIamfForQc;
import 'element_clip_stats.dart';
import 'element_overload_rows.dart';
import 'export_disk_space.dart';
import 'export_output_path.dart';
import 'iamf_encode_isolate.dart';
import 'iamf_export_config.dart';
import 'iamf_export_validator.dart';
import 'iamf_mux_isolate.dart';
import 'still_export_frame.dart';
import 'still_video_isolate.dart';
import 'user_metadata_builder.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Export state
// ─────────────────────────────────────────────────────────────────────────────

enum _ExportPhase { idle, measuring, encoding, muxing, done, failed, cancelled }

enum _StepStatus { pending, active, done, failed }

/// What the dialog produces. [iamfOnly] writes a bare `.iamf` bitstream;
/// [mp4] appends a mux step that combines that bitstream with the session
/// video into a single IAMF-in-ISOBMFF `.mp4`. An optional YouTube upload
/// step can follow an MP4 export (not yet implemented — surfaced as a
/// coming-soon toggle under the MP4 target).
enum ExportTarget { iamfOnly, mp4 }

/// Allowed values for `num_samples_per_frame` in the IAMF codec config
/// (LPCM only — Opus is fixed at [kOpusFramesPerCodedBlock]).
/// iamf-tools defaults to 1024; smaller values trade container overhead
/// for finer seek granularity.
const List<int> _kFramesPerCodedBlockOptions = [512, 1024, 2048, 4096];

/// Sentinel that lets `_ExportState.copyWith` tell "caller passed null
/// to clear the field" apart from "caller didn't pass anything".
const Object _kUnset = Object();

/// One shipped-vs-measured loudness comparison row (ES-492): the value
/// Eclipsa Studio measured (and stamped into the encoder's metadata)
/// against the `loudness_info` that actually shipped in the exported
/// file — iamf-tools always recomputes and overwrites, so the two can
/// legitimately differ by a small residual.
class ShippedLoudnessRow {
  final String label;
  final double measuredLufs;
  final double measuredDigitalPeakDbfs;
  final double? measuredTruePeakDbtp;
  final double shippedLufs;
  final double shippedDigitalPeakDbfs;
  final double? shippedTruePeakDbtp;

  const ShippedLoudnessRow({
    required this.label,
    required this.measuredLufs,
    required this.measuredDigitalPeakDbfs,
    this.measuredTruePeakDbtp,
    required this.shippedLufs,
    required this.shippedDigitalPeakDbfs,
    this.shippedTruePeakDbtp,
  });

  /// Shipped minus measured integrated loudness — the divergence signal.
  double get deltaLu => shippedLufs - measuredLufs;
}

/// Pairs the measured per-layout loudness in [mixes] (the export
/// config's mixes, exactly what the metadata builder stamped) with the
/// shipped `loudness_info` read back from the artifact by [probe].
/// Matching is positional — the builder writes mixes, sub-mixes, and
/// layouts in session order and the probe reports them in file order.
/// Rows are emitted only where both sides exist.
List<ShippedLoudnessRow> shippedLoudnessRows(
  List<Mix> mixes,
  IamfFullProbe probe,
) {
  final rows = <ShippedLoudnessRow>[];
  for (var m = 0; m < mixes.length; m++) {
    if (m >= probe.mixPresentations.length) break;
    final mix = mixes[m];
    final shippedMix = probe.mixPresentations[m];
    for (var s = 0; s < mix.subMixes.length; s++) {
      if (s >= shippedMix.subMixes.length) break;
      final sub = mix.subMixes[s];
      final shippedSub = shippedMix.subMixes[s];
      for (var l = 0; l < sub.layouts.length; l++) {
        if (l >= shippedSub.layouts.length) break;
        final layout = sub.layouts[l];
        final shipped = shippedSub.layouts[l].loudness;
        rows.add(
          ShippedLoudnessRow(
            label:
                '${mix.name}'
                '${mix.subMixes.length > 1 ? ' / ${sub.label}' : ''}'
                ' · ${layout.soundSystem.uiLabel}',
            measuredLufs: layout.loudness.integratedLoudness,
            measuredDigitalPeakDbfs: layout.loudness.digitalPeak,
            measuredTruePeakDbtp: layout.loudness.truePeak,
            shippedLufs: shipped.integratedLoudness,
            shippedDigitalPeakDbfs: shipped.digitalPeak,
            shippedTruePeakDbtp: shipped.truePeak,
          ),
        );
      }
    }
  }
  return rows;
}

class _ExportState {
  final _ExportPhase phase;
  // Phase that was running when the export stopped (failed or cancelled).
  final _ExportPhase? stoppedAt;
  final String outputPath;
  final ExportValidationResult? validation;
  final int measuredLayouts;
  final int totalLayouts;

  /// Encode progress in [0, 1], polled from the engine while the
  /// encoding phase runs. 0 until the first poll lands — the encode
  /// step bar shows indeterminate until then.
  final double encodeProgress;

  final String? errorMessage;

  // ── Codec settings (user-adjustable) ──────────────────────────────────
  final IamfCodec codec;
  final int framesPerCodedBlock;
  final int opusBitratePerChannel;

  /// What the dialog produces (chosen via the in-dialog selector).
  final ExportTarget target;

  /// Post-export read-back (ES-492), populated asynchronously after the
  /// terminal `done`: the shipped-vs-measured comparison rows, or the
  /// probe failure message. Both null while the read-back runs.
  final List<ShippedLoudnessRow>? shippedRows;
  final String? shippedProbeError;

  /// Signal-overload rows from the encode pass (ES-470) — counted on the
  /// PCM actually written into the artifact, so these are the
  /// authoritative numbers (the pre-encode gate's measure-pass numbers
  /// are the prediction). Rendered only in the `done` receipt.
  final List<ElementOverloadRow>? encodeOverloads;

  const _ExportState({
    this.phase = _ExportPhase.idle,
    this.stoppedAt,
    this.outputPath = '',
    this.validation,
    this.measuredLayouts = 0,
    this.totalLayouts = 0,
    this.encodeProgress = 0.0,
    this.errorMessage,
    this.codec = IamfCodec.lpcm,
    this.framesPerCodedBlock = kDefaultFramesPerCodedBlock,
    this.opusBitratePerChannel = kDefaultOpusBitratePerChannel,
    this.target = ExportTarget.iamfOnly,
    this.shippedRows,
    this.shippedProbeError,
    this.encodeOverloads,
  });

  /// `num_samples_per_frame` actually used by the export: Opus is
  /// fixed at 960 (20 ms) regardless of the LPCM frame-size selection.
  int get effectiveFramesPerCodedBlock =>
      codec == IamfCodec.opus ? kOpusFramesPerCodedBlock : framesPerCodedBlock;

  /// Pass `errorMessage: null` to explicitly clear the error; omit it
  /// to preserve the current value. The [_kUnset] sentinel encodes
  /// "argument not provided" distinctly from "null was passed".
  _ExportState copyWith({
    _ExportPhase? phase,
    _ExportPhase? stoppedAt,
    String? outputPath,
    ExportValidationResult? validation,
    int? measuredLayouts,
    int? totalLayouts,
    double? encodeProgress,
    Object? errorMessage = _kUnset,
    IamfCodec? codec,
    int? framesPerCodedBlock,
    int? opusBitratePerChannel,
    ExportTarget? target,
    List<ShippedLoudnessRow>? shippedRows,
    String? shippedProbeError,
    List<ElementOverloadRow>? encodeOverloads,
  }) {
    return _ExportState(
      phase: phase ?? this.phase,
      stoppedAt: stoppedAt ?? this.stoppedAt,
      outputPath: outputPath ?? this.outputPath,
      validation: validation ?? this.validation,
      measuredLayouts: measuredLayouts ?? this.measuredLayouts,
      totalLayouts: totalLayouts ?? this.totalLayouts,
      encodeProgress: encodeProgress ?? this.encodeProgress,
      errorMessage: identical(errorMessage, _kUnset)
          ? this.errorMessage
          : errorMessage as String?,
      codec: codec ?? this.codec,
      framesPerCodedBlock: framesPerCodedBlock ?? this.framesPerCodedBlock,
      opusBitratePerChannel:
          opusBitratePerChannel ?? this.opusBitratePerChannel,
      target: target ?? this.target,
      shippedRows: shippedRows ?? this.shippedRows,
      shippedProbeError: shippedProbeError ?? this.shippedProbeError,
      encodeOverloads: encodeOverloads ?? this.encodeOverloads,
    );
  }

  bool get isRunning =>
      phase == _ExportPhase.measuring ||
      phase == _ExportPhase.encoding ||
      phase == _ExportPhase.muxing;

  /// Phases that can be aborted: measure polls the cancel flag between
  /// layouts, and the push encode honors the engine cancel once per
  /// coded frame (ES-480), removing the partial output. Only the mux
  /// remains un-interruptible (a single libgpac call).
  bool get isCancellable =>
      phase == _ExportPhase.measuring || phase == _ExportPhase.encoding;

  bool get hasStarted => phase != _ExportPhase.idle;
}

// ─────────────────────────────────────────────────────────────────────────────
// Dialog
// ─────────────────────────────────────────────────────────────────────────────

class IamfExportDialog extends ConsumerStatefulWidget {
  const IamfExportDialog({
    super.key,
    this.initialTarget = ExportTarget.iamfOnly,
  });

  /// Which target the in-dialog selector starts on. The user can switch
  /// targets once the dialog is open; this is only the initial selection
  /// (e.g. the Playback "Export to YouTube" button opens straight on
  /// [ExportTarget.mp4], where the optional upload step lives). Falls back
  /// to [ExportTarget.iamfOnly] when MP4 has no usable video.
  final ExportTarget initialTarget;

  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    ExportTarget initialTarget = ExportTarget.iamfOnly,
  }) async {
    // The dialog pops with the written file path when the user chose
    // "Open in Playback" (null on Close). Run the switch here, from the
    // caller's context/ref — the dialog and its own ref are gone by now.
    // Either target returns a path: openIamfForQc accepts both a bare
    // `.iamf` (audio QC) and an `.mp4` (the engine demuxes the embedded
    // IAMF and rides the picture on the transport — ES-225).
    final exportedPath = await showAppDialog<String>(
      context: context,
      escape: DialogEscape.none,
      id: IamfExportDialog,
      builder: (_) => IamfExportDialog(initialTarget: initialTarget),
    );
    if (exportedPath != null && exportedPath.isNotEmpty && context.mounted) {
      await openIamfForQc(context, ref, path: exportedPath);
    }
  }

  @override
  ConsumerState<IamfExportDialog> createState() => _IamfExportDialogState();
}

class _IamfExportDialogState extends ConsumerState<IamfExportDialog> {
  _ExportState _state = const _ExportState();

  /// macOS sandbox only allows writing to paths the user explicitly
  /// picked via NSSavePanel (power-box ticket). Auto-computed default
  /// paths lack this permission — we invoke the save panel at Export
  /// time if this flag is false.
  bool _pathConfirmed = false;

  /// True when the session folder is bookmarked, granting grant-free
  /// writes anywhere inside it. A folder bookmark survives swapping the
  /// output extension on a target switch; a file-specific save-panel
  /// ticket does not, so [_onTargetChanged] drops [_pathConfirmed] unless
  /// this is set.
  bool _folderGrantActive = false;

  /// Directory and stem of the auto-derived default output path, or null
  /// once the user has picked a path in the save panel. While set, a
  /// target switch and New Export recompute the path with [_uniquePath]
  /// instead of reusing it, so the path does not name an existing file
  /// or the session's source video.
  ({String dir, String stem})? _autoBase;

  /// The last save-panel answer that [normalizeSavePanelPath] left
  /// unchanged. Only this path may replace an existing file without the
  /// save panel being shown again. An answer the dialog had to change is
  /// not recorded: the panel's overwrite check ran against the name
  /// before the change.
  String? _pickedPath;

  /// A problem with the output path, shown under the Output row. Set
  /// when the save panel's answer names the session's source video or an
  /// existing file the panel did not confirm; cleared by the next pick,
  /// target switch or New Export.
  String? _pathNotice;

  /// Captured at pause time so dispose can release the pause without
  /// touching `ref` (forbidden once the widget is being torn down — see
  /// the "Using ref when a widget is about to or has been unmounted is
  /// unsafe" Riverpod error).
  EclipsaStudioEngine? _pausedEngine;

  /// Set when the user clicks Cancel during a running export. The
  /// measure loop polls it between layouts and bails out; the encode
  /// cancels via the engine, which honors it once per coded frame and
  /// removes the partial output (surfaced back as rc -99).
  bool _cancelRequested = false;

  /// Synchronous re-entrancy guard for [_runExport]. `_state.isRunning`
  /// flips only at the first `setState` *after* an `await`, so the
  /// Export button and the Enter shortcut stay armed for a beat after a
  /// click — a double-invoke in that window would start two concurrent
  /// measure passes, and the offline OAR render must run one at a time
  /// (ES-44). Set before the first `await`; cleared on the pre-start
  /// early returns (save panel dismissed, engine unavailable) so the
  /// user can try again, and defensively on the failed/cancelled
  /// terminal paths — those currently offer no re-run affordance (the
  /// button row collapses to Close), so the terminal clears only
  /// matter if a Retry button is ever added.
  bool _exportInvoked = false;

  /// The video path the libgpac container probe last ran for, and its
  /// result: 0 when the muxer can read the file, negative otherwise, null
  /// while a probe is in flight or when the path needs no probe. See
  /// [_probeVideo].
  String? _probedVideoPath;
  int? _videoProbeRc;

  /// Polls the engine's per-coded-frame encode progress into
  /// [_ExportState.encodeProgress] while the encoding phase runs.
  Timer? _encodeProgressTimer;

  @override
  void initState() {
    super.initState();
    _state = _state.copyWith(target: widget.initialTarget);
    Log.i(
      LogCat.export,
      'Export dialog opened: target=${widget.initialTarget.name}',
    );
    // Stop transport + pause the live OAR for the lifetime of this
    // dialog. Both have to wait for post-frame: Riverpod forbids
    // mutating a provider during initState (playingProvider), and the
    // OAR pause is grouped with it for symmetry / single dispatch.
    //
    // Transport-pause alone silences element playback but the audio
    // thread keeps cycling and calling OAR with silence — concurrent
    // with the offline mix renderer's transient OAR instances, that
    // races OBR and has been observed to corrupt the heap (ES-44). The
    // OAR pause is what actually fixes the crash; the transport stop
    // is a UX layer so the playhead doesn't advance under the user.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      ref.read(playingProvider.notifier).set(false);
      final engine = ref.read(eclipsaStudioEngineProvider);
      if (engine != null) {
        engine.setExportPaused(true);
        _pausedEngine = engine;
      }
      // If opened on the MP4 target (e.g. the Playback "Export to YouTube"
      // button) but there's no usable video — or the session profile is
      // one the GPAC muxer can't parse — fall back to IAMF so the
      // selector doesn't start on a disabled option.
      final videoPath = ref.read(videoProvider).filePath;
      var resolvedTarget = _state.target;
      if (resolvedTarget == ExportTarget.mp4 &&
          (!_videoUsable(videoPath) ||
              !_isMuxSupportedProfile(ref.read(iamfProfileProvider)))) {
        resolvedTarget = ExportTarget.iamfOnly;
      }
      unawaited(_probeVideo(videoPath));
      // Compute the default output path with the resolved target's
      // extension, then apply target + path together in one setState.
      final session = ref.read(sessionProvider);
      final defaultPath = _defaultOutputPath(session, _extFor(resolvedTarget));
      setState(() {
        _state = _state.copyWith(
          target: resolvedTarget,
          outputPath: defaultPath,
        );
      });
      _validate();
      // If the session folder is bookmarked (grant-free writes into it), the
      // default output is already writable — pre-confirm so Export doesn't
      // force a redundant Browse pick. The user can still Browse elsewhere.
      final folder = session.folder;
      if (defaultPath.isNotEmpty &&
          folder != null &&
          await FolderBookmarks.ensureAccess(folder)) {
        if (mounted) {
          setState(() {
            _pathConfirmed = true;
            _folderGrantActive = true;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _encodeProgressTimer?.cancel();
    _pausedEngine?.setExportPaused(false);
    // The export outcome (done/failed/cancelled) is logged where it
    // happens; this catches the common "opened the dialog, then closed it
    // without exporting" case so the log reflects it.
    if (!_state.hasStarted) {
      Log.i(LogCat.export, 'Export dialog closed without exporting');
    }
    super.dispose();
  }

  // ── Target / video ──────────────────────────────────────────────────

  /// Output extension for [t]: `mp4` when muxing with video, `iamf` for a
  /// bare bitstream.
  String _extFor(ExportTarget t) => t == ExportTarget.mp4 ? 'mp4' : 'iamf';

  /// Output extension for the current target.
  String get _outputExt => _extFor(_state.target);

  /// libgpac stream-copies the video out of an ISOBMFF container; it can't
  /// demux `.mkv`/`.webm`/`.mxf`. A usable video is one that is loaded and
  /// already `.mp4`/`.mov` — or a still image (ES-192), which is first
  /// rendered into a video-only MP4 of the audio's length (see
  /// `still_export_frame.dart` / `eclipsa_studio_still_video_encode`) and then
  /// muxed like any other video. Static so callers thread the
  /// watched/read [filePath] in rather than each re-reading the provider.
  static bool _videoUsableFor(String? filePath) {
    if (filePath == null) return false;
    if (isStillImagePath(filePath)) return true;
    final ext = p.extension(filePath).toLowerCase();
    return ext == '.mp4' || ext == '.mov';
  }

  /// Why the MP4 target is unavailable, for the selector's disabled note.
  /// Empty when a usable video or still image is present.
  static String _videoUnavailableReasonFor(String? filePath) {
    if (filePath == null) {
      return 'Load a video or still image into the session to enable this.';
    }
    final ext = p.extension(filePath).toLowerCase();
    if (!isStillImagePath(filePath) && ext != '.mp4' && ext != '.mov') {
      return 'The session video must be MP4 or MOV (current: $ext).';
    }
    return '';
  }

  /// [_videoUsableFor] plus the container probe: false once libgpac has
  /// reported it cannot read the loaded video. A probe still in flight
  /// counts as usable; the mux itself remains the final check.
  bool _videoUsable(String? filePath) =>
      _videoUsableFor(filePath) && !_videoProbeBlocks(filePath);

  bool _videoProbeBlocks(String? filePath) =>
      filePath != null &&
      filePath == _probedVideoPath &&
      _videoProbeRc != null &&
      _videoProbeRc != 0;

  /// [_videoUnavailableReasonFor] plus the probe's verdict.
  String _videoUnavailableReason(String? filePath) {
    final formatReason = _videoUnavailableReasonFor(filePath);
    if (formatReason.isNotEmpty || !_videoProbeBlocks(filePath)) {
      return formatReason;
    }
    final name = p.basename(filePath!);
    switch (_videoProbeRc) {
      case -12:
        return 'The MP4 muxer can\'t read the container of "$name". '
            'Rewrite the file without re-encoding, for example with '
            'ffmpeg -i in.mp4 -c copy out.mp4, and load the result.';
      case -13:
        return '"$name" has no video track.';
      case -3:
        return '"$name" is missing from disk.';
      default:
        return 'The MP4 muxer can\'t open "$name" '
            '(error $_videoProbeRc). Check the log for details.';
    }
  }

  /// Open the loaded video with the muxer's own libgpac reader (ES-742) so
  /// a container it cannot parse, such as the sample table VLC writes,
  /// disables the MP4 target with an explanation instead of failing after
  /// the encode. Still images and non-MP4/MOV files are gated by
  /// [_videoUsableFor] and not probed. Runs on a worker isolate; a result
  /// for a video that has since been replaced is dropped. When the probe
  /// fails while the MP4 target is selected and nothing has started, the
  /// target falls back to IAMF so the selector does not sit on a disabled
  /// option.
  Future<void> _probeVideo(String? filePath) async {
    if (filePath == _probedVideoPath) return;
    final needsProbe =
        filePath != null &&
        !isStillImagePath(filePath) &&
        _videoUsableFor(filePath);
    setState(() {
      _probedVideoPath = filePath;
      _videoProbeRc = null;
    });
    if (!needsProbe) return;
    final int rc;
    try {
      rc = await runVideoContainerProbeOnIsolate(filePath);
    } on Object catch (e) {
      // The worker could not open or bind the engine library. The probe
      // stays undecided and the mux reports its own error if it fails.
      Log.w(LogCat.export, 'video container probe failed to run', e);
      return;
    }
    if (!mounted || _probedVideoPath != filePath) return;
    if (rc == 0) {
      Log.i(LogCat.export, 'video container probe: ${p.basename(filePath)} ok');
    } else {
      Log.w(
        LogCat.export,
        'video container probe: ${p.basename(filePath)} rc=$rc',
      );
    }
    setState(() => _videoProbeRc = rc);
    if (rc != 0 && _state.target == ExportTarget.mp4 && !_state.hasStarted) {
      _onTargetChanged(ExportTarget.iamfOnly);
    }
  }

  /// Replace the extension of [path] with [newExt], preserving the
  /// directory and stem. Returns [path] unchanged when it is empty.
  String _swapExt(String path, String newExt) {
    if (path.isEmpty) return path;
    final stem = p.basenameWithoutExtension(path);
    return p.join(p.dirname(path), '$stem.$newExt');
  }

  /// Switch the export target from the selector. Keeps the output path's
  /// extension in sync with the new target and re-validates. An
  /// auto-derived path is recomputed with [_uniquePath] for the new
  /// extension; a picked path has its extension swapped. A file-specific
  /// save-panel grant covers only the exact path it was issued for, so
  /// swapping the extension invalidates it — drop the confirmation
  /// (forcing a re-pick at Export) unless a folder bookmark makes the
  /// whole directory writable. The confirmation is also dropped when the
  /// new path must not be written without the save panel (ES-846).
  void _onTargetChanged(ExportTarget t) {
    if (t == _state.target) return;
    setState(() {
      final ext = _extFor(t);
      final base = _autoBase;
      final path = base != null
          ? _uniquePath(base.dir, base.stem, ext)
          : _swapExt(_state.outputPath, ext);
      _pathNotice = null;
      if (!_folderGrantActive || _needsSavePanel(path, confirmed: true)) {
        _pathConfirmed = false;
      }
      _state = _state.copyWith(target: t, outputPath: path);
    });
    _validate();
  }

  /// Whether writing [path] needs the save panel first; see
  /// [outputNeedsSavePanel].
  bool _needsSavePanel(String path, {required bool confirmed}) {
    return outputNeedsSavePanel(
      outputPath: path,
      confirmed: confirmed,
      pickedPath: _pickedPath,
      sourceVideoPath: ref.read(videoProvider).filePath,
      exists: (f) => File(f).existsSync(),
    );
  }

  // ── Default path logic ──────────────────────────────────────────────

  String _defaultOutputPath(SessionState session, String ext) {
    // A saved session defaults its export into the session folder
    // (dirname of the .esp) — the canonical home for the session's outputs.
    final folder = session.folder;
    if (folder != null) {
      final stem = p.basenameWithoutExtension(session.filePath!);
      _autoBase = (dir: folder, stem: stem);
      return _uniquePath(folder, stem, ext);
    }
    // No session file: prefer the last directory the user picked via
    // the save panel (it has a sandbox grant and is somewhere they
    // can actually find). If we have nothing — or the dir no longer
    // exists — return empty so the field shows "No output path" and
    // the Export button stays disabled until the user clicks Browse.
    // The HOME fallback used to land in the sandbox container which
    // confused users who couldn't find the file afterwards.
    final lastDir = ref.read(lastExportDirProvider);
    if (lastDir != null && Directory(lastDir).existsSync()) {
      final stem = session.name.isEmpty ? 'Untitled' : session.name;
      _autoBase = (dir: lastDir, stem: stem);
      return _uniquePath(lastDir, stem, ext);
    }
    return '';
  }

  /// If `dir/stem.ext` exists or is the session's source video, try
  /// `dir/stem-01.ext`, `-02`, etc.
  String _uniquePath(String dir, String stem, String ext) {
    return uniqueOutputPath(
      dir,
      stem,
      ext,
      exists: (f) => File(f).existsSync(),
      avoid: ref.read(videoProvider).filePath,
    );
  }

  // ── Duration ────────────────────────────────────────────────────────

  /// Longest element length in TARGET-rate frames, across the current
  /// session (mirrors the conversion in [_buildConfig] so the duration
  /// panel matches what the export will actually produce). Returns 0
  /// when no element has readable WAV metadata yet.
  int _longestElementFrames() {
    final elements = ref.read(elementsProvider);
    var longest = 0;
    for (final e in elements) {
      final wav = e.wavInfo;
      if (wav == null || wav.sampleRate <= 0) continue;
      final n = (wav.totalSamples * kIamfTargetSampleRate / wav.sampleRate)
          .round();
      if (n > longest) longest = n;
    }
    return longest;
  }

  /// Session video length in TARGET-rate frames (0 = none/unknown yet).
  int _videoEndFrames() {
    final d = ref.read(videoProvider).duration;
    if (d == null) return 0;
    return (d.inMilliseconds * kIamfTargetSampleRate / 1000).round();
  }

  /// [effectiveExportFrames] with the target and video length filled
  /// in from the current dialog/session state.
  int _effectiveExportFrames(int longest) => effectiveExportFrames(
    longestFrames: longest,
    videoFrames: _videoEndFrames(),
    isMp4: _state.target == ExportTarget.mp4,
  );

  // ── Validation ──────────────────────────────────────────────────────

  void _validate() {
    final elements = ref.read(elementsProvider);
    final mixes = ref.read(mixesNotifierProvider);
    final profile = ref.read(iamfProfileProvider);
    final engine = ref.read(eclipsaStudioEngineProvider);

    if (engine == null) {
      setState(() {
        _state = _state.copyWith(
          validation: ExportValidationResult(const [
            ExportIssue(
              severity: ExportSeverity.error,
              code: ExportIssueCode.engineUnavailable,
              message: 'Audio engine not available.',
            ),
          ]),
        );
      });
      return;
    }

    final config = _buildConfig(
      elements,
      mixes,
      profile,
      kIamfTargetSampleRate,
    );
    final result = validateIamfExport(
      config,
      muxToMp4: _state.target == ExportTarget.mp4,
    );
    setState(() {
      _state = _state.copyWith(validation: result);
    });
  }

  IamfExportConfig _buildConfig(
    List<AudioElement> elements,
    List<Mix> mixes,
    IamfProfile profile,
    int sampleRate,
  ) {
    final wavBasenames = uniqueWavBasenames(elements);
    // iamf-tools requires one identical samples_to_trim_at_end across
    // every substream. We pad every element to the same target
    // (exportPadTarget — frame-aligned, minus the codec delay for
    // Opus, ES-485) and set the trim to just the alignment pad — shorter
    // elements naturally trail in silence, which iamf-tools treats as
    // part of the real audio.
    //
    // Lengths are in TARGET-rate frames: the element stream resamples
    // each source to [sampleRate], so a source's contribution is its
    // frame count scaled by targetRate / sourceRate.
    final frame = _state.effectiveFramesPerCodedBlock;
    var longest = 0;
    for (final e in elements) {
      final wav = e.wavInfo;
      if (wav == null || wav.sampleRate <= 0) continue;
      final n = (wav.totalSamples * sampleRate / wav.sampleRate).round();
      if (n > longest) longest = n;
    }
    // MP4 clamp (ES-457): render only up to the video end. The stream's
    // pad_to_frames truncation cuts every source there, so downstream
    // (measure, trim math, encode, mux) sees the clamped length as if
    // it were the whole session.
    final effLength = _effectiveExportFrames(longest);
    final isPartial = effLength < longest;
    final paddedFrames = exportPadTarget(
      lengthFrames: effLength,
      framesPerCodedBlock: frame,
      codec: _state.codec,
    );
    return IamfExportConfig(
      profile: profile,
      sampleRate: sampleRate,
      elements: elements,
      mixes: mixes,
      wavBasenames: wavBasenames,
      outputPath: _state.outputPath,
      framesPerCodedBlock: frame,
      codec: _state.codec,
      opusBitratePerChannel: _state.opusBitratePerChannel,
      paddedFrames: paddedFrames,
      longestSourceFrames: effLength,
      isPartialRange: isPartial,
    );
  }

  // ── Browse ──────────────────────────────────────────────────────────

  Future<void> _browse() async {
    final picked = await _pickOutputPath();
    if (picked == null) return;
    // The save panel is an async gap; the dialog may have been dismissed
    // (e.g. Enter before the panel grabbed focus) — bail before touching
    // setState/ref, matching every other async path in this file.
    if (!mounted) return;
    final path = picked.path;
    setState(() {
      _acceptPick(picked);
      // The save panel grants a power-box ticket for this exact file URL
      // only — not the directory, and not the swapped-extension sibling.
      // Clear the folder grant so a later target switch re-invokes the
      // save panel rather than writing to an unauthorized path. (The
      // session-folder bookmark, if any, is independent and still applies
      // at write time via FolderBookmarks.)
      _folderGrantActive = false;
    });
    ref.read(lastExportDirProvider.notifier).set(File(path).parent.path);
  }

  /// Applies a save-panel answer to the dialog state. Call inside
  /// `setState`. Sets [_pathNotice] when the path must not be written
  /// without another save-panel pick.
  void _acceptPick(({String path, bool unchanged}) picked) {
    _state = _state.copyWith(outputPath: picked.path);
    _pathConfirmed = true;
    _pickedPath = picked.unchanged ? picked.path : null;
    _autoBase = null;
    _pathNotice = _pathNoticeFor(picked.path);
  }

  /// The message for [_pathNotice], or null when [path] may be written
  /// as it stands.
  String? _pathNoticeFor(String path) {
    if (!_needsSavePanel(path, confirmed: true)) return null;
    final name = p.basename(path);
    if (isSameOutputPath(path, ref.read(videoProvider).filePath)) {
      return '"$name" is the session video and must not be replaced. '
          'Click Export or Browse to choose another name.';
    }
    return '"$name" already exists and the save panel did not confirm '
        'replacing it. Click Export or Browse to choose a name.';
  }

  /// Opens the native save panel pre-filled with the current output
  /// path. Returns the picked path with the target extension, and
  /// whether [normalizeSavePanelPath] left the panel's answer unchanged,
  /// or null if cancelled. Picking grants the sandbox write entitlement.
  Future<({String path, bool unchanged})?> _pickOutputPath() async {
    final ext = _outputExt; // 'mp4' or 'iamf'
    final dotExt = '.$ext';
    final current = _state.outputPath;
    final initialDir = current.isEmpty ? null : File(current).parent.path;
    // Strip any matching suffix from the pre-fill; file_picker's
    // NSSavePanel re-adds the allowed extension and can otherwise
    // produce "name.mp4.mp4".
    final preName = current.isEmpty ? 'Untitled' : p.basename(current);
    final suggested = preName.toLowerCase().endsWith(dotExt)
        ? preName.substring(0, preName.length - dotExt.length)
        : preName;
    final picked = await FilePicker.saveFile(
      dialogTitle: _state.target == ExportTarget.mp4
          ? 'Export to MP4'
          : 'Export IAMF',
      fileName: suggested,
      initialDirectory: initialDir,
      allowedExtensions: [ext],
      type: FileType.custom,
    );
    if (picked == null) return null;
    final out = normalizeSavePanelPath(picked, ext);
    return (path: out, unchanged: out == picked);
  }

  // ── Export ──────────────────────────────────────────────────────────

  Future<void> _runExport() async {
    if (_exportInvoked) return;
    _exportInvoked = true;

    // macOS sandbox: require a user-selected path so we get a
    // power-box ticket for writing the .iamf. If the user never
    // clicked Browse, invoke the save panel now. It is also shown when
    // the path names an existing file the user did not pick there, or
    // the session's source video (ES-846).
    if (_needsSavePanel(_state.outputPath, confirmed: _pathConfirmed)) {
      final picked = await _pickOutputPath();
      if (picked == null) {
        _exportInvoked = false; // nothing started; allow another attempt
        return;
      }
      if (!mounted) return;
      setState(() => _acceptPick(picked));
      ref
          .read(lastExportDirProvider.notifier)
          .set(File(picked.path).parent.path);
    }
    // First source-video check: the save panel's answer can name the
    // session video or an existing file the panel did not confirm. Stop
    // before any work, show the reason under the Output row and leave
    // Export armed for another pick.
    final notice = _pathNoticeFor(_state.outputPath);
    if (notice != null) {
      setState(() => _pathNotice = notice);
      _exportInvoked = false;
      return;
    }

    final elements = ref.read(elementsProvider);
    final mixes = ref.read(mixesNotifierProvider);
    final profile = ref.read(iamfProfileProvider);
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) {
      _exportInvoked = false; // nothing started; allow another attempt
      return;
    }

    final config = _buildConfig(
      elements,
      mixes,
      profile,
      kIamfTargetSampleRate,
    );

    if (!await _confirmDiskSpace(engine, config)) {
      _exportInvoked = false; // nothing started; allow another attempt
      return;
    }
    if (!mounted) return;

    final totalLayouts = mixes.fold<int>(
      0,
      (n, m) => n + m.subMixes.fold<int>(0, (k, s) => k + s.layouts.length),
    );
    Log.i(
      LogCat.export,
      'IAMF export started: out=${_state.outputPath} '
      'elements=${elements.length} mixes=${mixes.length} '
      'layouts=$totalLayouts profile=${profile.name} '
      'sr=${config.sampleRate}',
    );
    // The MP4 clamp (ES-457) fails open: an unresolved video duration
    // exports the full timeline (the muxer's edit list still bounds
    // playback). Log it so this case is distinguishable from "video is
    // longer than the audio" post-mortem. A still image legitimately has
    // no duration — its video is rendered to the audio's length, so the
    // unresolved case is expected there, not log-worthy.
    final mediaPath = ref.read(videoProvider).filePath;
    final stillImageExport =
        _state.target == ExportTarget.mp4 &&
        mediaPath != null &&
        isStillImagePath(mediaPath);
    if (_state.target == ExportTarget.mp4 &&
        !stillImageExport &&
        _videoEndFrames() == 0) {
      Log.w(
        LogCat.export,
        'MP4 export: video duration unresolved — audio render not '
        'clamped to the video length',
      );
    }

    _cancelRequested = false;

    Directory? scratchDir;
    try {
      // Holds only the MP4 target's intermediates (.iamf, still video,
      // muxed mp4); a bare .iamf export leaves it empty (ES-484 removed
      // the bounced-WAV staging).
      scratchDir = await Directory.systemTemp.createTemp(
        'eclipsa_studio_iamf_',
      );

      // The measure phase exists only to feed the loudness metadata —
      // both it and the encoder stream from the source WAVs (ES-480,
      // ES-484); no temp WAVs are staged. When a current Loudness Report
      // already measured this exact session (fingerprint match + full
      // tagged-layout coverage), its values are reused and the export
      // goes straight to encode: no multi-second measure pass. A
      // clamped MP4 export always re-measures: cached measurements
      // cover the full timeline, not the clamped length (R128 must be
      // measured over what actually ships).
      final IamfExportConfig measuredConfig;
      final Map<int, ElementClipStats> measureClipStats;
      final report = ref.read(loudnessReportProvider);
      if (canReuseLoudnessReport(
        report: report,
        currentFingerprint: loudnessFingerprint(
          elements: config.elements,
          mixes: config.mixes,
          sampleRate: config.sampleRate,
        ),
        sampleRate: config.sampleRate,
        isPartialRange: config.isPartialRange,
        mixes: config.mixes,
      )) {
        Log.i(
          LogCat.export,
          'Reusing Loudness Report measurements '
          '(${report!.results.length} layouts) — skipping the measure '
          'phase',
        );
        setState(() {
          _state = _state.copyWith(errorMessage: null);
        });
        measuredConfig = _configWithMixes(
          config,
          mixesWithMeasuredLoudness(config.mixes, report.results),
        );
        // The cached report carries the measure pass's clip stats, so
        // the overload gate below works identically on this path.
        measureClipStats = report.elementClipStats;
      } else {
        final measured = await _measureLoudness(config);
        if (measured == null) return; // failed, already reported
        (measuredConfig, measureClipStats) = measured;
      }

      // Persist measured loudness back into mixesNotifierProvider so the
      // values surface in mix_view / inspector_view immediately and stick
      // if the user saves the session. Done before encode so a downstream
      // encode failure does not discard a successful measurement. A
      // clamped export is measured over the clamped length only — its
      // values go into the exported bitstream but must not overwrite
      // the session's full-timeline loudness.
      if (!measuredConfig.isPartialRange) {
        ref.read(mixesNotifierProvider.notifier).set(measuredConfig.mixes);
        ref.read(sessionProvider.notifier).markDirty();
      }

      // Encode.
      if (!mounted) return;
      if (_cancelRequested) {
        _cancelled();
        return;
      }

      // Enter the encoding phase BEFORE the overload gate: the gate's
      // modal awaits user input, and with the phase still idle (the
      // cached-report reuse path never left it) or measuring, the
      // dialog underneath would show no checklist / enabled settings,
      // and a gate-cancel would record a stoppedAt whose checklist
      // rendering marks the completed measure as pending. As
      // "encoding", the checklist shows measure done + encode active
      // while the modal is up, and a gate-cancel reads as "stopped
      // before the encode ran".
      setState(() {
        _state = _state.copyWith(
          phase: _ExportPhase.encoding,
          encodeProgress: 0.0,
        );
      });

      // Signal-overload gate (ES-470): if any element's stream output
      // exceeded full scale during measure, warn before anything is
      // written — the encoder hard-clips those samples into the file.
      final overloads = clipGateRows(measureClipStats, measuredConfig.elements);
      if (overloads.isNotEmpty) {
        Log.w(
          LogCat.export,
          'Signal overload on ${overloads.length} element(s): '
          '${overloads.map((r) => r.message).join('; ')}',
        );
        final proceed = await _confirmSignalOverload(overloads);
        if (!mounted) return;
        if (_cancelRequested) {
          _cancelled(); // cancel raced the modal
          return;
        }
        if (!proceed) {
          _cancelled();
          return;
        }
      }

      final textproto = buildUserMetadataTextproto(measuredConfig);
      Log.d(
        LogCat.export,
        'IAMF export textproto: ${textproto.length} bytes, '
        'paddedFrames=${measuredConfig.paddedFrames}, '
        'longestSource=${measuredConfig.longestSourceFrames}, '
        'trim=${measuredConfig.paddedFrames - measuredConfig.longestSourceFrames}, '
        'partialRange=${measuredConfig.isPartialRange}',
      );

      // Dump the textproto to Application Support (always writable
      // under sandbox) for post-mortem inspection when the encode
      // fails. Scratch dir is wiped in the finally block.
      try {
        final supportDir = await getApplicationSupportDirectory();
        final debugPath = p.join(supportDir.path, 'last_export.textproto');
        await File(debugPath).writeAsString(textproto);
        Log.d(LogCat.export, 'Wrote debug textproto to $debugPath');
      } catch (e) {
        Log.w(LogCat.export, 'Failed to dump textproto: $e');
      }

      // For an MP4 export the .iamf is only an intermediate: write it into
      // the scratch dir (sandbox-writable, auto-cleaned in the finally
      // block) and mux it with the video into the picked .mp4 afterwards.
      // A bare .iamf export writes straight to the chosen directory.
      final outputDir = _state.target == ExportTarget.mp4
          ? scratchDir.path
          : File(_state.outputPath).parent.path;
      // Where the encoder writes: the legacy path derives this same name
      // from file_name_prefix (the outputPath stem); the push path takes
      // it explicitly.
      final iamfPath = p.join(
        outputDir,
        '${p.basenameWithoutExtension(_state.outputPath)}.iamf',
      );

      // Encode on a background isolate so the dialog stays responsive.
      // Each element streams from its source WAV through the engine's
      // stream pipeline straight into the encoder (ES-480). The exporter
      // state is process-global, so this isolate can poll its
      // per-coded-frame progress while the encode isolate runs.
      Log.i(LogCat.export, 'Encoding IAMF: -> $iamfPath');
      _encodeProgressTimer = Timer.periodic(const Duration(milliseconds: 100), (
        _,
      ) {
        final engine = _pausedEngine;
        if (engine == null || !mounted) return;
        setState(() {
          _state = _state.copyWith(
            encodeProgress: engine.iamfExportProgress().clamp(0.0, 1.0),
          );
        });
      });
      final IamfPushEncodeResult encodeResult;
      try {
        encodeResult = await runIamfPushEncodeOnIsolate(
          configTextproto: textproto,
          outputIamfPath: iamfPath,
          elements: [
            // pushableElements is the shared definition of this subset;
            // encodeOverloadRows aligns the result stats against it.
            for (final e in pushableElements(measuredConfig.elements))
              IamfPushElement(
                wavBasename: measuredConfig.basenameFor(e.id, e.wavPath!),
                sourceWavPath: e.wavPath!,
                gainDb: e.gain,
                routing: e.inputRouting ?? const [],
                padToFrames: measuredConfig.paddedFrames,
                outputSampleRate: measuredConfig.sampleRate,
              ),
          ],
        );
      } finally {
        _encodeProgressTimer?.cancel();
        _encodeProgressTimer = null;
      }
      final rc = encodeResult.rc;

      if (!mounted) return;
      // Authoritative overload numbers — counted on the PCM actually
      // written. Stored regardless of rc; rendered only in `done`.
      setState(() {
        _state = _state.copyWith(
          encodeOverloads: encodeOverloadRows(
            measuredConfig.elements,
            encodeResult.elementStats,
          ),
        );
      });
      if (rc == 0 && _cancelRequested) {
        // The cancel lost the race with the encode: it landed after the
        // pre-encode check but before the engine armed the request, so
        // the engine dropped it as stale and completed. The user saw
        // "Cancelling…" — honor it: remove the output and report
        // cancelled, exactly as if the engine had returned -99.
        try {
          await File(iamfPath).delete();
        } catch (_) {}
        _cancelled();
        return;
      }
      if (rc == 0) {
        if (_state.target == ExportTarget.mp4) {
          // Mux the intermediate .iamf (in the scratch dir) with the
          // session video into the picked .mp4. _muxToMp4 sets the
          // terminal phase itself. For a still image it first renders a
          // video of the exported audio's length, so the two tracks end
          // together.
          await _muxToMp4(
            iamfPath,
            audioSeconds:
                measuredConfig.longestSourceFrames / measuredConfig.sampleRate,
          );
          // Read back the picked .mp4, not the intermediate .iamf — the
          // scratch dir is deleted on return (the probe demuxes the
          // iamf track itself, same as opening an .mp4 for QC).
          if (_state.phase == _ExportPhase.done) {
            unawaited(
              _verifyShippedLoudness(_state.outputPath, measuredConfig),
            );
          }
        } else {
          Log.i(LogCat.export, 'IAMF export succeeded: ${_state.outputPath}');
          setState(() {
            _state = _state.copyWith(phase: _ExportPhase.done);
          });
          unawaited(_verifyShippedLoudness(iamfPath, measuredConfig));
        }
      } else if (rc == -99) {
        // Engine reports the encode was cancelled (checked once per
        // coded frame, so this covers cancels mid-encode).
        _cancelled();
      } else {
        _fail(
          'IAMF encode failed (error $rc). '
          'Check the log for details.',
        );
      }
    } catch (e, st) {
      Log.e(LogCat.export, 'IAMF export exception: $e\n$st');
      if (mounted) _fail('Export failed: $e');
    } finally {
      if (scratchDir != null) {
        try {
          await scratchDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Mux the just-encoded intermediate [iamfPath] together with the session
  /// video into a `.mp4` in the scratch dir, then copy that result to the
  /// user-picked output. Runs on a background isolate so the dialog stays
  /// responsive. Both intermediates live in the scratch dir and are removed
  /// with it. Sets the terminal phase.
  ///
  /// Mux into scratch rather than straight to the picked path: GPAC writes a
  /// sibling temp (`<out>.muxed`) next to its output and swaps it in, but the
  /// macOS save-panel grant covers only the exact picked file URL — a sibling
  /// write in an unbookmarked directory is denied with EPERM (ES-211). Muxing
  /// in the always-writable scratch dir and copying the finished file across
  /// keeps the single write on the granted path; it also means a failed mux
  /// never touches the user's path.
  /// Monotonic run counter: "New Export" bumps it so a shipped-loudness
  /// probe still in flight from the previous run cannot paint its late
  /// result into the fresh settings view or a newer run's receipt.
  int _runToken = 0;

  /// Return to the editable settings view after a terminal state (the
  /// "New Export" / "Try Again" buttons). User selections survive —
  /// target, output path (its sandbox grant is still held), codec
  /// settings, validation; everything the finished run produced is
  /// dropped with the fresh [_ExportState].
  void _resetForNewExport() {
    _runToken++;
    _exportInvoked = false;
    _cancelRequested = false;
    // An auto-derived path now names the file the finished run wrote;
    // pick the next free name so the next run does not replace it. A
    // picked path is kept.
    final base = _autoBase;
    final outputPath = base != null
        ? _uniquePath(base.dir, base.stem, _outputExt)
        : _state.outputPath;
    setState(() {
      _pathNotice = null;
      _state = _ExportState(
        outputPath: outputPath,
        validation: _state.validation,
        codec: _state.codec,
        framesPerCodedBlock: _state.framesPerCodedBlock,
        opusBitratePerChannel: _state.opusBitratePerChannel,
        target: _state.target,
      );
    });
    _validate();
  }

  /// ES-492: the `loudness_info` that ships is iamf-tools' own no-limiter
  /// measurement — it always overwrites the values stamped from the
  /// measure phase. Read the final artifact back and surface shipped vs
  /// measured, so the export summary shows the numbers a downstream
  /// compliance check will see. Never fails the export: a probe error
  /// only annotates the summary.
  Future<void> _verifyShippedLoudness(
    String artifactPath,
    IamfExportConfig measuredConfig,
  ) async {
    final token = _runToken;
    try {
      final probe = await probeIamfFull(artifactPath);
      if (!mounted || token != _runToken) return;
      if (!probe.ok) {
        setState(() {
          _state = _state.copyWith(
            shippedProbeError: probe.errorMessage ?? 'probe failed',
          );
        });
        return;
      }
      final rows = shippedLoudnessRows(measuredConfig.mixes, probe);
      var maxDelta = 0.0;
      for (final row in rows) {
        maxDelta = math.max(maxDelta, row.deltaLu.abs());
      }
      final summary = rows
          .map(
            (r) =>
                '${r.label}: measured '
                '${r.measuredLufs.toStringAsFixed(2)} LUFS, shipped '
                '${r.shippedLufs.toStringAsFixed(2)} LUFS',
          )
          .join('; ');
      if (maxDelta > 0.5) {
        Log.w(
          LogCat.export,
          'Shipped loudness diverges from measured by '
          '${maxDelta.toStringAsFixed(2)} LU (expected on hot mixes: '
          'measurement is limited at -1 dBFS, the encoded file is '
          'not) — $summary',
        );
      } else {
        Log.i(LogCat.export, 'Shipped loudness verified: $summary');
      }
      setState(() {
        _state = _state.copyWith(shippedRows: rows);
      });
    } catch (e) {
      Log.w(LogCat.export, 'Shipped-loudness read-back failed: $e');
      if (mounted && token == _runToken) {
        setState(() {
          _state = _state.copyWith(shippedProbeError: '$e');
        });
      }
    }
  }

  Future<void> _muxToMp4(
    String iamfPath, {
    required double audioSeconds,
  }) async {
    var videoPath = ref.read(videoProvider).filePath;
    if (videoPath == null) {
      _fail('Export to MP4: no source video.');
      return;
    }
    final mp4Path = _state.outputPath;
    // Second source-video check: the copy at the end replaces [mp4Path].
    // The first check in [_runExport] ran before the measure and encode
    // phases, and the session video is read again here, so this guards
    // the one write that could destroy it (ES-846).
    if (isSameOutputPath(mp4Path, videoPath)) {
      _fail('The export must not replace the session video.');
      return;
    }
    setState(() {
      _state = _state.copyWith(phase: _ExportPhase.muxing);
    });
    await _yieldToUi();

    // A still image has no video track to copy — render one first (ES-192):
    // decode + downscale on this isolate, then encode a video-only MP4 of
    // the audio's length on a worker isolate, and mux that like any other
    // video. The intermediate lives next to the .iamf in the scratch dir.
    if (isStillImagePath(videoPath)) {
      final frame = await renderStillExportFrame(videoPath);
      if (!mounted) return;
      if (frame == null) {
        _fail(
          'Could not decode the still image '
          '"${p.basename(videoPath)}" for the video track.',
        );
        return;
      }
      final stillMp4 = p.setExtension(iamfPath, '.still_video.mp4');
      Log.i(
        LogCat.export,
        'Rendering still video: ${p.basename(videoPath)} '
        '${frame.width}x${frame.height} for '
        '${audioSeconds.toStringAsFixed(2)}s -> $stillMp4',
      );
      final rc = await runStillVideoEncodeOnIsolate(
        rgba: frame.rgba,
        width: frame.width,
        height: frame.height,
        fps: kStillExportFps,
        // Floor: a degenerate zero-length export still needs one frame.
        durationSeconds: audioSeconds > kStillExportMinDurationSeconds
            ? audioSeconds
            : kStillExportMinDurationSeconds,
        outputMp4: stillMp4,
      );
      if (!mounted) return;
      if (rc != 0) {
        _fail(
          rc == -100
              ? 'Rendering a video from a still image is not supported '
                    'on this platform yet.'
              : 'Rendering the still image video failed (error $rc). '
                    'Check the log for details.',
        );
        return;
      }
      videoPath = stillMp4;
    }

    // Scratch sibling of the intermediate .iamf (same dir + stem, .mp4).
    final scratchMp4 = p.setExtension(iamfPath, '.mp4');
    // The mux stages the video twice in the scratch dir (ES-742); log the
    // numbers a post-mortem of an I/O error needs.
    var videoBytes = -1;
    try {
      videoBytes = await File(videoPath).length();
    } catch (_) {}
    if (!mounted) return;
    final scratchFree = ref
        .read(eclipsaStudioEngineProvider)
        ?.volumeInfo(p.dirname(scratchMp4))
        ?.freeBytes;
    Log.i(
      LogCat.export,
      'Muxing MP4: $iamfPath + $videoPath -> $scratchMp4 '
      '(video ${videoBytes < 0 ? 'size unknown' : formatBytes(videoBytes)}, '
      'scratch volume free '
      '${scratchFree == null ? 'unknown' : formatBytes(scratchFree)})',
    );
    final rc = await runIamfMuxOnIsolate(
      inputIamf: iamfPath,
      inputVideo: videoPath,
      outputMp4: scratchMp4,
    );
    if (!mounted) return;
    if (rc != 0) {
      _fail('MP4 mux failed (error $rc). Check the log for details.');
      return;
    }
    // The only write to the sandbox-granted destination URL.
    try {
      await File(scratchMp4).copy(mp4Path);
    } catch (e) {
      _fail('Could not write the MP4 to its destination: $e');
      return;
    }
    if (!mounted) return;
    Log.i(LogCat.export, 'MP4 export succeeded: $mp4Path');
    setState(() {
      _state = _state.copyWith(phase: _ExportPhase.done);
    });
  }

  void _fail(String message) {
    Log.e(LogCat.export, 'IAMF export: $message');
    _exportInvoked = false;
    if (mounted) {
      setState(() {
        _state = _state.copyWith(
          stoppedAt: _state.phase,
          phase: _ExportPhase.failed,
          errorMessage: message,
        );
      });
    }
  }

  /// Hand control back to the event loop so a frame scheduled by the
  /// preceding [setState] can actually paint. A zero-duration timer (a
  /// macrotask) is required — a microtask would run before the next
  /// render and the progress bar would still freeze.
  Future<void> _yieldToUi() => Future<void>.delayed(Duration.zero);

  /// User asked to abort. The measure loop notices [_cancelRequested]
  /// between layouts; the engine cancel steers a running encode, which
  /// checks it once per coded frame, aborts with -99, and removes the
  /// partial output.
  void _requestCancel() {
    if (_cancelRequested) return;
    _cancelRequested = true;
    _pausedEngine?.iamfExportCancel();
    Log.i(LogCat.export, 'IAMF export: cancel requested');
    if (mounted) setState(() {});
  }

  /// Blocking signal-overload gate (ES-470): shown between the measure
  /// and encode phases when any element exceeds full scale. Returns
  /// true to export anyway, false to abort. A background click cannot
  /// close it (app-wide policy, ES-639) and Escape pops it with null,
  /// which resolves to false: the export never proceeds past the
  /// warning without a button press.
  Future<bool> _confirmSignalOverload(List<ElementOverloadRow> rows) {
    return _confirmExportWarning(
      title: 'Signal Overload',
      intro:
          'These elements exceed full scale and will clip in the '
          'exported file:',
      rows: [for (final row in rows) row.message],
      footer:
          'Reduce the element gain or source level to avoid '
          'clipping, or export anyway to keep these levels.',
    );
  }

  /// Blocking warning gate shared by the signal-overload and low-disk-
  /// space checks: a title, an intro line, one warning row per string in
  /// [rows], a caption, and Cancel / Export Anyway. Returns true to
  /// export anyway. A background click cannot close it (app-wide
  /// policy, ES-639) and Escape pops it with null, which resolves to
  /// false: the export never proceeds past the warning without a button
  /// press.
  Future<bool> _confirmExportWarning({
    required String title,
    required String intro,
    required List<String> rows,
    required String footer,
  }) async {
    final proceed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.bgElevated,
        title: Text(title, style: T.styleTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(intro, style: T.styleBodySecondary),
              const SizedBox(height: T.gapMd),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: T.gapSm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 14,
                        color: T.meterYellow,
                      ),
                      const SizedBox(width: T.gapSm),
                      Expanded(child: Text(row, style: T.styleBodySecondary)),
                    ],
                  ),
                ),
              const SizedBox(height: T.gapSm),
              Text(
                footer,
                style: TextStyle(
                  fontSize: T.fontCaption,
                  color: T.textTertiary,
                ),
              ),
            ],
          ),
        ),
        actions: [
          AppButton(
            label: 'Cancel',
            role: AppButtonRole.quiet,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            label: 'Export Anyway',
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  /// Disk-space gate (ES-742): estimate what the export writes on the
  /// scratch volume and the destination volume, compare with what is
  /// free, and ask before running when either is short. A full disk
  /// surfaces from libgpac as a bare I/O error after the encode, so the
  /// question is asked up front. Returns true to proceed. When a volume
  /// cannot be measured (the destination folder is outside the sandbox
  /// grant, say) the export proceeds without the check.
  Future<bool> _confirmDiskSpace(
    EclipsaStudioEngine engine,
    IamfExportConfig config,
  ) async {
    final muxToMp4 = _state.target == ExportTarget.mp4;
    final totalChannels = config.elements.fold<int>(
      0,
      (n, e) => n + channelCountForLayout(e),
    );
    final iamfBytes = estimateIamfBytes(
      codec: config.codec,
      bitDepth: config.bitDepth,
      sampleRate: config.sampleRate,
      totalChannels: totalChannels,
      frames: _effectiveExportFrames(_longestElementFrames()),
      opusBitratePerChannel: config.opusBitratePerChannel,
    );
    // A still image's rendered video is small next to the audio; only a
    // real video file is counted.
    var videoBytes = 0;
    final videoPath = ref.read(videoProvider).filePath;
    if (muxToMp4 && videoPath != null && !isStillImagePath(videoPath)) {
      try {
        videoBytes = await File(videoPath).length();
      } catch (e) {
        Log.w(LogCat.export, 'disk space: cannot size $videoPath: $e');
      }
      if (!mounted) return false;
    }
    final need = ExportSpaceNeed.compute(
      muxToMp4: muxToMp4,
      iamfBytes: iamfBytes,
      videoBytes: videoBytes,
    );

    VolumeSpace? volumeFor(String path) {
      final info = engine.volumeInfo(path);
      if (info == null) {
        Log.w(LogCat.export, 'disk space: cannot measure volume of $path');
        return null;
      }
      return VolumeSpace(
        path: path,
        freeBytes: info.freeBytes,
        volumeId: info.volumeId,
      );
    }

    final scratch = muxToMp4 ? volumeFor(Directory.systemTemp.path) : null;
    final destination = volumeFor(File(_state.outputPath).parent.path);
    Log.i(
      LogCat.export,
      'disk space: need scratch ${formatBytes(need.scratchBytes)}, '
      'destination ${formatBytes(need.destinationBytes)}; free scratch '
      '${scratch == null ? 'unknown' : formatBytes(scratch.freeBytes)}, '
      'destination '
      '${destination == null ? 'unknown' : formatBytes(destination.freeBytes)}',
    );
    if (destination == null) return true;
    final shortfalls = diskSpaceShortfalls(
      need: need,
      scratch: scratch,
      destination: destination,
    );
    if (shortfalls.isEmpty) return true;
    return _confirmLowDiskSpace(shortfalls);
  }

  /// Blocking low-disk-space gate. Returns true to export anyway.
  Future<bool> _confirmLowDiskSpace(List<DiskSpaceShortfall> rows) {
    return _confirmExportWarning(
      title: 'Low Disk Space',
      intro: 'The export needs more space than is free:',
      rows: [
        for (final row in rows)
          '${row.path}: needs ${formatBytes(row.neededBytes)}, '
              '${formatBytes(row.freeBytes)} free.',
      ],
      footer:
          'An MP4 export stages the video twice beside the audio on '
          'the startup disk before copying the result to its '
          'destination. Free up space, or export anyway; a full disk '
          'stops the export partway through.',
    );
  }

  void _cancelled() {
    Log.i(LogCat.export, 'IAMF export cancelled');
    _exportInvoked = false;
    if (mounted) {
      setState(() {
        _state = _state.copyWith(
          stoppedAt: _state.phase,
          phase: _ExportPhase.cancelled,
        );
      });
    }
  }

  // ── Button row ──────────────────────────────────────────────────────

  List<Widget> _buildActions(BuildContext context, bool canExport) {
    final phase = _state.phase;
    if (phase == _ExportPhase.done ||
        phase == _ExportPhase.failed ||
        phase == _ExportPhase.cancelled) {
      final exported =
          phase == _ExportPhase.done && _state.outputPath.isNotEmpty;
      return [
        // One affirmative per footer: Done is it unless Open in
        // Playback, below, takes the role.
        AppButton(
          label: 'Done',
          role: exported ? AppButtonRole.standard : AppButtonRole.affirmative,
          onPressed: () => Navigator.of(context).pop(),
        ),
        // Back to the editable settings view, selections preserved —
        // export the other target, tweak the codec, or retry a
        // failed/cancelled run.
        AppButton(
          label: phase == _ExportPhase.done ? 'New Export' : 'Try Again',
          onPressed: _resetForNewExport,
        ),
        // Open-in-Playback for either target: a bare .iamf opens for
        // audio QC, and an .mp4 export carries the IAMF audio (+ video)
        // the engine demuxes on open, so it QCs too (ES-225).
        if (exported)
          // Hand the written path back to show(), which opens it in
          // Playback once this dialog has closed (so the workspace switch
          // runs on the caller's context, not this disposed one).
          AppButton(
            label: 'Open in Playback',
            role: AppButtonRole.affirmative,
            onPressed: () => Navigator.of(context).pop(_state.outputPath),
          ),
      ];
    }

    // Idle or running. Cancel aborts a running export — cooperatively
    // during measure, via the engine during encode, disabled during
    // the un-interruptible mux — or dismisses the dialog when idle.
    final running = _state.isRunning;
    final String cancelLabel;
    final VoidCallback? cancelHandler;
    if (running) {
      cancelLabel = _cancelRequested ? 'Cancelling…' : 'Cancel';
      cancelHandler = (_state.isCancellable && !_cancelRequested)
          ? _requestCancel
          : null;
    } else {
      cancelLabel = 'Cancel';
      cancelHandler = () => Navigator.of(context).pop();
    }

    return [
      AppButton(
        label: cancelLabel,
        role: AppButtonRole.quiet,
        onPressed: cancelHandler,
      ),
      AppButton(
        label: 'Export',
        role: AppButtonRole.affirmative,
        onPressed: canExport ? _runExport : null,
      ),
    ];
  }

  // ── Loudness measurement ───────────────────────────────────────────

  /// Render each mix × layout through OAR and measure loudness via the
  /// shared orchestrator (see [measureMixLoudness]) — bounded-parallel
  /// background-isolate renders with per-layout progress.
  ///
  /// Returns the config with measured loudness folded in, plus the
  /// pass's per-element clip stats for the signal-overload gate
  /// (ES-470); null when the pass failed or was cancelled (already
  /// reported).
  Future<(IamfExportConfig, Map<int, ElementClipStats>)?> _measureLoudness(
    IamfExportConfig config,
  ) async {
    // Count total layouts across all mixes.
    var totalLayouts = 0;
    for (final mix in config.mixes) {
      for (final sub in mix.subMixes) {
        totalLayouts += sub.layouts.length;
      }
    }

    setState(() {
      _state = _state.copyWith(
        phase: _ExportPhase.measuring,
        measuredLayouts: 0,
        totalLayouts: totalLayouts,
        errorMessage: null,
      );
    });

    final outcome = await measureMixLoudness(
      mixes: config.mixes,
      elements: config.elements,
      paddedFrames: config.paddedFrames,
      sampleRate: config.sampleRate,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _state = _state.copyWith(measuredLayouts: done);
        });
      },
      isCancelled: () => _cancelRequested || !mounted,
    );
    if (!mounted) return null;
    switch (outcome.status) {
      case LoudnessPassStatus.cancelled:
        _cancelled();
        return null;
      case LoudnessPassStatus.failed:
        _fail(
          'Loudness measurement failed for '
          '${outcome.failedLayoutLabel}. '
          'Check the log for details.',
        );
        return null;
      case LoudnessPassStatus.completed:
        break;
    }

    return (
      _configWithMixes(
        config,
        mixesWithMeasuredLoudness(config.mixes, outcome.results),
      ),
      outcome.elementClipStats,
    );
  }

  /// [config] with its mixes replaced (IamfExportConfig has no copyWith).
  static IamfExportConfig _configWithMixes(
    IamfExportConfig config,
    List<Mix> mixes,
  ) {
    return IamfExportConfig(
      profile: config.profile,
      sampleRate: config.sampleRate,
      bitDepth: config.bitDepth,
      framesPerCodedBlock: config.framesPerCodedBlock,
      codec: config.codec,
      opusBitratePerChannel: config.opusBitratePerChannel,
      elements: config.elements,
      mixes: mixes,
      wavBasenames: config.wavBasenames,
      outputPath: config.outputPath,
      paddedFrames: config.paddedFrames,
      longestSourceFrames: config.longestSourceFrames,
      isPartialRange: config.isPartialRange,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Self-track theme + font size: the dialog sits in its own route,
    // so nothing above it rebuilds while it's open — without these
    // watches a theme or font switch would leave its T.* styling stale
    // until an unrelated state change forces a rebuild.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final validation = _state.validation;
    final profile = ref.watch(iamfProfileProvider);
    // Watch the video so the MP4 target's enabled/disabled state in the
    // selector tracks loading or removing a session video live, and so
    // the duration panel re-resolves the MP4 clamp (ES-457) when the
    // video duration arrives asynchronously.
    final videoPath = ref.watch(videoProvider.select((v) => v.filePath));
    ref.watch(videoProvider.select((v) => v.duration));
    ref.listen(videoProvider.select((v) => v.filePath), (_, next) {
      unawaited(_probeVideo(next));
    });
    final videoUsable = _videoUsable(videoPath);
    final muxProfileOk = _isMuxSupportedProfile(profile);
    final target = _state.target;
    final canExport = _canExport(videoUsable, muxProfileOk);
    final longestFrames = _longestElementFrames();
    final effFrames = _effectiveExportFrames(longestFrames);
    // Terminal states render as a receipt: the settings sections are
    // hidden (not merely disabled) and the dialog shows only what ran —
    // checklist, result, shipped loudness — plus the action row. "New
    // Export" / "Try Again" (_resetForNewExport) returns to the
    // settings view with all selections preserved.
    final terminal =
        _state.phase == _ExportPhase.done ||
        _state.phase == _ExportPhase.failed ||
        _state.phase == _ExportPhase.cancelled;

    final dialog = DialogShell(
      title: 'Export',
      width: 800,
      bodyFit: DialogBodyFit.flexible,
      footerDivider: true,
      actions: _buildActions(context, canExport),
      // The unified form is tall (target selector + IAMF settings +
      // step checklist during export); scroll rather than overflow when
      // the dialog can't fit the screen height.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Settings (hidden in terminal states) ──────────
            if (!terminal) ...[
              // ── Target selector ─────────────────────────────
              _TargetSelector(
                selected: target,
                enabled: !_state.isRunning,
                videoUsable: videoUsable,
                videoReason: _videoUnavailableReason(videoPath),
                muxProfileOk: muxProfileOk,
                profileReason:
                    'Not available for the ${profile.label} profile. '
                    'The MP4 muxer (GPAC) supports Simple, Base, and '
                    'Base-Enhanced only.',
                onChanged: _onTargetChanged,
              ),
              const SizedBox(height: 20),

              // ── Output path ───────────────────────────────────
              _OutputPathRow(
                path: _state.outputPath,
                enabled: !_state.isRunning,
                onBrowse: _browse,
                notice: _pathNotice,
              ),
              const SizedBox(height: 16),

              // ── Profile ───────────────────────────────────────
              _ProfilePanel(
                profile: profile,
                enabled: !_state.isRunning,
                onChanged: (p) {
                  ref.read(iamfProfileProvider.notifier).set(p);
                  _validate();
                },
              ),
              const SizedBox(height: 16),

              // ── Duration ──────────────────────────────────────
              _DurationPanel(
                frames: effFrames,
                sampleRate: kIamfTargetSampleRate,
                clampedToVideo: effFrames < longestFrames,
              ),
              const SizedBox(height: 16),

              // ── Codec settings ────────────────────────────────
              _CodecPanel(
                codec: _state.codec,
                framesPerCodedBlock: _state.framesPerCodedBlock,
                opusBitratePerChannel: _state.opusBitratePerChannel,
                totalChannels: ref
                    .watch(elementsProvider)
                    .fold<int>(0, (n, e) => n + channelCountForLayout(e)),
                enabled: !_state.isRunning,
                onCodecChanged: (c) => setState(() {
                  _state = _state.copyWith(codec: c);
                }),
                onFramesChanged: (n) => setState(() {
                  _state = _state.copyWith(framesPerCodedBlock: n);
                }),
                onBitrateChanged: (b) => setState(() {
                  _state = _state.copyWith(opusBitratePerChannel: b);
                }),
              ),
              const SizedBox(height: 16),

              // ── Optional YouTube upload (MP4 only) ─────────────
              if (target == ExportTarget.mp4) ...[
                // Not const: _UploadStep reads T.* and must rebuild on a
                // theme/font switch, and a const instance is never
                // rebuilt by its parent.
                _UploadStep(),
                const SizedBox(height: 16),
              ],

              // ── Validation ────────────────────────────────────
              if (validation != null && validation.issues.isNotEmpty) ...[
                _ValidationPanel(validation: validation),
                const SizedBox(height: 16),
              ],
            ],

            // ── Step checklist ────────────────────────────────
            if (_state.hasStarted) ...[
              _StepChecklist(
                state: _state,
                target: target,
                stillImage: videoPath != null && isStillImagePath(videoPath),
              ),
              const SizedBox(height: 16),
            ],
            if (_state.phase == _ExportPhase.done) ...[
              _ResultRow(
                icon: Icons.check_circle_outline,
                color: T.indicatorGreen,
                label: 'Export complete',
                detail: _state.outputPath,
              ),
              const SizedBox(height: T.gapMd),
              if (_state.encodeOverloads case final overloads?
                  when overloads.isNotEmpty) ...[
                _OverloadPanel(rows: overloads),
                const SizedBox(height: T.gapMd),
              ],
              ShippedLoudnessPanel(
                rows: _state.shippedRows,
                error: _state.shippedProbeError,
              ),
            ],
            if (_state.phase == _ExportPhase.failed)
              _ResultRow(
                icon: Icons.error_outline,
                color: T.errorRed,
                label: 'Export failed',
                detail: _state.errorMessage ?? '',
              ),
            if (_state.phase == _ExportPhase.cancelled)
              _ResultRow(
                icon: Icons.cancel_outlined,
                color: T.textSecondary,
                label: 'Export cancelled',
                detail: '',
              ),
          ],
        ),
      ),
    );

    // Block route dismissal while an export runs. The route is shown
    // with DialogEscape.none, so neither the barrier nor the app-wide
    // Escape binding can pop it, but that does not stop a programmatic
    // pop (Cmd-W, a menu action, the Escape mapping below).
    // If the route were popped mid-measure, dispose() would resume the
    // live OAR (setExportPaused(false)) while an offline measure isolate
    // is still rendering — reopening the ES-44 heap-corruption race. The
    // only way out of a running export stays the cooperative Cancel
    // (also reachable via Escape), which keeps the live OAR paused until
    // the dialog closes on its own terms.
    final scoped = PopScope(canPop: !_state.isRunning, child: dialog);

    // Enter triggers Export, Escape dismisses — both mirroring the
    // matching button so the dialog is fully keyboard-drivable. The
    // autofocus Focus puts a non-button node in the focus chain so the
    // shortcuts fire; a focused button still handles Enter/Space itself,
    // so there's no double-trigger.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _onSubmit,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _onSubmit,
        const SingleActivator(LogicalKeyboardKey.escape): _onDismiss,
      },
      child: Focus(autofocus: true, skipTraversal: true, child: scoped),
    );
  }

  /// Whether the primary Export button is currently enabled: a valid
  /// config with an output path, and no export already in flight.
  /// [videoUsable] and [muxProfileOk] are threaded in from the caller's
  /// provider reads so this stays free of provider access.
  bool _canExport(bool videoUsable, bool muxProfileOk) {
    // MP4 muxing needs a usable (.mp4/.mov) session video and a profile
    // the GPAC muxer can parse.
    if (_state.target == ExportTarget.mp4 && (!videoUsable || !muxProfileOk)) {
      return false;
    }
    final validation = _state.validation;
    return validation != null &&
        validation.canExport &&
        _state.outputPath.isNotEmpty &&
        !_state.isRunning;
  }

  /// Start an export in response to the Enter key, gated on the same
  /// conditions that enable the primary button: a valid config with an
  /// output path, and only from the idle state — never mid-run, and not
  /// after a finished run (where [_canExport] goes true again but the
  /// primary button has already become Close / Open in Playback).
  void _onSubmit() {
    final videoUsable = _videoUsable(ref.read(videoProvider).filePath);
    final muxProfileOk = _isMuxSupportedProfile(ref.read(iamfProfileProvider));
    if (_canExport(videoUsable, muxProfileOk) && !_state.hasStarted) {
      _runExport();
    }
  }

  /// Dismiss in response to the Escape key, mirroring the secondary
  /// (Cancel / Done) button. While an export is in flight the dialog
  /// must not pop — that would resume the live OAR mid-render (ES-44) — so
  /// Escape instead requests a cooperative cancel when one is possible,
  /// exactly as the Cancel button does, and is a no-op during the
  /// un-interruptible mux. PopScope is the backstop either way.
  void _onDismiss() {
    if (_state.isRunning) {
      if (_state.isCancellable && !_cancelRequested) _requestCancel();
      return;
    }
    Navigator.of(context).maybePop();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _OutputPathRow extends StatelessWidget {
  final String path;
  final bool enabled;
  final VoidCallback onBrowse;

  /// Shown under the row in the error colour when non-null.
  final String? notice;

  const _OutputPathRow({
    required this.path,
    required this.enabled,
    required this.onBrowse,
    this.notice,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Output', style: T.styleEyebrow),
        const SizedBox(height: T.gapPair),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: raisedField(T.radiusSm) ?? T.decoControl(),
                child: Text(
                  path.isEmpty ? 'No output path' : path,
                  style: TextStyle(
                    color: path.isEmpty ? T.textTertiary : T.textPrimary,
                    fontSize: T.fontBody,
                    fontFamily: T.monoFamily,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: enabled ? onBrowse : null,
              child: MouseRegion(
                cursor: enabled
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: T.decoControl(),
                  child: Text(
                    'Browse...',
                    style: TextStyle(
                      color: enabled ? T.textPrimary : T.textTertiary,
                      fontSize: T.fontBody,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (notice != null) ...[
          const SizedBox(height: T.gapPair),
          Text(
            notice!,
            style: TextStyle(color: T.errorRed, fontSize: T.fontSmall),
          ),
        ],
      ],
    );
  }
}

/// Whether the MP4 mux path can carry this profile. iamf-tools encodes
/// all six profiles, so the standalone .iamf target is never gated —
/// but GPAC's IAMF demuxer (engine/iamf/iamf_muxer.cc) only parses
/// bitstreams up to Base-Enhanced (primary_profile <= 2); Base-Advanced
/// and Advanced bitstreams fail the mux filter-session setup
/// (IamfMuxer::Mux returns -11, verified against GPAC master
/// 2026-07-04). Gate the MP4 target on this until GPAC learns the
/// IAMF v2.0 profiles.
bool _isMuxSupportedProfile(IamfProfile p) =>
    p.profileIndex <= IamfProfile.baseEnhanced.profileIndex;

class _ProfilePanel extends StatelessWidget {
  final IamfProfile profile;
  final bool enabled;
  final ValueChanged<IamfProfile> onChanged;

  const _ProfilePanel({
    required this.profile,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final mp4Unavailable = !_isMuxSupportedProfile(profile);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Profile', style: T.styleEyebrow),
        const SizedBox(height: T.gapPair),
        _LabeledControl(
          label: 'IAMF bitstream profile',
          control: ProfileSelector(
            width: 220,
            enabled: enabled,
            value: profile,
            onChanged: onChanged,
          ),
        ),
        if (mp4Unavailable) ...[
          const SizedBox(height: T.gapPair),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: T.iconXs,
                color: T.meterYellow,
              ),
              const SizedBox(width: T.gapPair),
              Expanded(
                child: Text(
                  'MP4 export is unavailable for this profile. The MP4 '
                  'muxer (GPAC) supports Simple, Base, and Base-Enhanced '
                  'only. Standalone IAMF export is unaffected.',
                  style: TextStyle(
                    color: T.textSecondary,
                    fontSize: T.fontCaption,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _DurationPanel extends StatelessWidget {
  final int frames;
  final int sampleRate;

  /// True when the MP4 target clamped the export to the video length
  /// (ES-457): [frames] is the video end, not the longest element.
  final bool clampedToVideo;

  const _DurationPanel({
    required this.frames,
    required this.sampleRate,
    required this.clampedToVideo,
  });

  @override
  Widget build(BuildContext context) {
    final seconds = sampleRate > 0 ? frames / sampleRate : 0.0;
    final hasData = frames > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Duration', style: T.styleEyebrow),
        const SizedBox(height: T.gapPair),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: raisedField(T.radiusSm) ?? T.decoControl(),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  hasData
                      ? '${formatDuration(seconds)}  '
                            '($frames samples @ $sampleRate Hz)'
                      : 'No audio elements with readable WAV metadata.',
                  style: TextStyle(
                    color: hasData ? T.textPrimary : T.textTertiary,
                    fontSize: T.fontBody,
                    fontFamily: T.monoFamily,
                  ),
                ),
              ),
              Text(
                clampedToVideo ? 'video length' : 'auto',
                style: TextStyle(
                  color: T.textTertiary,
                  fontSize: T.fontCaption,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          clampedToVideo
              ? 'Trimmed to the video length. Audio past the last '
                    'frame of picture is not exported to MP4.'
              : 'Uses the longest element WAV; shorter elements will be '
                    'padded with silence. Custom span coming soon.',
          style: TextStyle(
            color: T.textTertiary,
            fontSize: T.fontCaption,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _CodecPanel extends StatelessWidget {
  final IamfCodec codec;
  final int framesPerCodedBlock;
  final int opusBitratePerChannel;

  /// Total channel count across the session's elements — drives the
  /// Opus total-bitrate preview.
  final int totalChannels;
  final bool enabled;
  final ValueChanged<IamfCodec> onCodecChanged;
  final ValueChanged<int> onFramesChanged;
  final ValueChanged<int> onBitrateChanged;

  const _CodecPanel({
    required this.codec,
    required this.framesPerCodedBlock,
    required this.opusBitratePerChannel,
    required this.totalChannels,
    required this.enabled,
    required this.onCodecChanged,
    required this.onFramesChanged,
    required this.onBitrateChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isOpus = codec == IamfCodec.opus;
    // Coupled pairs get 2x the per-channel rate (coupling adjustment
    // stays at iamf-tools' 1.0 default), so the stream total is simply
    // per-channel rate x channel count.
    final totalKbps = (opusBitratePerChannel * totalChannels / 1000).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Codec', style: T.styleEyebrow),
        const SizedBox(height: T.gapPair),
        Row(
          children: [
            _LabeledControl(
              label: 'Format',
              control: ConsoleSelector<IamfCodec>(
                width: 180,
                enabled: enabled,
                value: codec,
                items: IamfCodec.values.map((c) => (c, c.label)).toList(),
                onChanged: onCodecChanged,
              ),
            ),
            const SizedBox(width: 24),
            if (isOpus)
              _LabeledControl(
                label: 'Bitrate per channel',
                control: ConsoleSelector<int>(
                  width: 120,
                  enabled: enabled,
                  value: opusBitratePerChannel,
                  items: kOpusBitratePerChannelOptions
                      .map((b) => (b, '${b ~/ 1000} kbps'))
                      .toList(),
                  onChanged: onBitrateChanged,
                ),
              )
            else
              _LabeledControl(
                label: 'Samples per frame',
                control: ConsoleSelector<int>(
                  width: 120,
                  enabled: enabled,
                  value: framesPerCodedBlock,
                  items: _kFramesPerCodedBlockOptions
                      .map((n) => (n, '$n'))
                      .toList(),
                  onChanged: onFramesChanged,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          isOpus
              ? '${codec.description} 20 ms frames. '
                    'Audio total ≈ $totalKbps kbps '
                    '($totalChannels channels).'
              : codec.description,
          style: TextStyle(
            color: T.textTertiary,
            fontSize: T.fontCaption,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _LabeledControl extends StatelessWidget {
  final String label;
  final Widget control;

  const _LabeledControl({required this.label, required this.control});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: T.textTertiary, fontSize: T.fontCaption),
        ),
        const SizedBox(height: 4),
        control,
      ],
    );
  }
}

/// Post-export loudness verification block (ES-492): the loudness that
/// actually shipped in the exported file (iamf-tools' own measurement,
/// which overwrites the stamped values) next to what Eclipsa Studio
/// measured, per layout. Shows a pending caption while the read-back
/// probe runs and a non-fatal notice if it fails.
///
/// Public so the column-width widget test can pump it on its own.
class ShippedLoudnessPanel extends StatefulWidget {
  final List<ShippedLoudnessRow>? rows;
  final String? error;
  const ShippedLoudnessPanel({
    super.key,
    required this.rows,
    required this.error,
  });

  /// Column headers, in grid order. Also the input to [columnWidth].
  static const headers = ['LUFS', 'Δ LU', 'PK dBFS', 'TP dBTP'];

  /// Value cell style; [color] is applied at the render site.
  static TextStyle _valueStyle({Color? color}) => TextStyle(
    fontFamily: T.monoFamily,
    fontSize: T.fontBody,
    color: color ?? T.textPrimary,
  );

  /// Width of every value column, measured from the widest header and
  /// the widest value at the current font-size mode (ES-621): a fixed
  /// width fits one font mode only. Values print with two decimals, so
  /// "-100.00" is the longest string a cell shows.
  static double columnWidth(BuildContext context) =>
      math.max(
        widestTextWidth(context, headers, T.styleEyebrow),
        widestTextWidth(context, const ['-100.00'], _valueStyle()),
      ) +
      T.gapMd;

  @override
  State<ShippedLoudnessPanel> createState() => _ShippedLoudnessPanelState();
}

class _ShippedLoudnessPanelState extends State<ShippedLoudnessPanel> {
  /// Cap the output list at roughly six outputs (label line + two value
  /// lines each); beyond that the list scrolls inside the panel so the
  /// dialog height stays stable and the buttons stay reachable.
  static const double _maxListHeight = 340;

  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // maxLines 1 + softWrap false on both cell kinds: text wider than the
  // measured column clips instead of wrapping, so an over-tight column
  // fails visibly in review and in the width test.
  Widget _value(double col, String text, {Color? color}) => SizedBox(
    width: col,
    child: Text(
      text,
      textAlign: TextAlign.right,
      maxLines: 1,
      softWrap: false,
      style: ShippedLoudnessPanel._valueStyle(color: color),
    ),
  );

  Widget _header(double col, String text) => SizedBox(
    width: col,
    child: Text(
      text,
      textAlign: TextAlign.right,
      maxLines: 1,
      softWrap: false,
      style: T.styleEyebrow,
    ),
  );

  String _peak(double? v) => v == null ? '—' : v.toStringAsFixed(2);

  /// One output: a label line, then paired measured / shipped value
  /// lines under the LUFS / TP / PK columns; Δ LU sits on the shipped
  /// line.
  Widget _output(ShippedLoudnessRow row, double col) {
    Widget line(
      String source,
      double lufs,
      double? tp,
      double pk, {
      Widget? delta,
      required Color color,
    }) => Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: T.gapMd),
            child: Text(
              source,
              style: TextStyle(color: T.textTertiary, fontSize: T.fontCaption),
            ),
          ),
        ),
        _value(col, lufs.toStringAsFixed(2), color: color),
        delta ?? _value(col, ''),
        _value(col, pk.toStringAsFixed(2), color: color),
        _value(col, _peak(tp), color: color),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          row.label,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: T.textSecondary, fontSize: T.fontBody),
        ),
        line(
          'measured',
          row.measuredLufs,
          row.measuredTruePeakDbtp,
          row.measuredDigitalPeakDbfs,
          color: T.textSecondary,
        ),
        line(
          'exported',
          row.shippedLufs,
          row.shippedTruePeakDbtp,
          row.shippedDigitalPeakDbfs,
          color: T.textPrimary,
          delta: _value(
            col,
            '${row.deltaLu >= 0 ? '+' : ''}${row.deltaLu.toStringAsFixed(2)}',
            color: row.deltaLu.abs() > 0.5 ? T.meterYellow : T.textTertiary,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final col = ShippedLoudnessPanel.columnWidth(context);
    final Widget body;
    if (widget.error != null) {
      body = Text(
        "Couldn't read the exported file back to verify its loudness: "
        '${widget.error}',
        style: TextStyle(color: T.textSecondary, fontSize: T.fontBody),
      );
    } else if (rows == null) {
      body = Text(
        'Reading the exported file back to verify its loudness…',
        style: TextStyle(color: T.textTertiary, fontSize: T.fontBody),
      );
    } else if (rows.isEmpty) {
      body = Text(
        'No loudness information found in the exported file.',
        style: TextStyle(color: T.textSecondary, fontSize: T.fontBody),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Text('EXPORTED LOUDNESS', style: T.styleEyebrow)),
              for (final h in ShippedLoudnessPanel.headers) _header(col, h),
            ],
          ),
          const SizedBox(height: T.gapPair),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _maxListHeight),
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scroll,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final row in rows) ...[
                      _output(row, col),
                      const SizedBox(height: T.gapSm),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Text(
            'Integrated loudness (LUFS) with its exported-minus-measured '
            'difference (Δ LU), then digital peak (dBFS) and true peak '
            '(dBTP), as measured here and as written to the file. '
            'Measurement runs through the -1 dBFS limiter and the file '
            'is encoded without it, so on a hot mix the exported values '
            'read higher and peaks can exceed -1 dBTP.',
            style: TextStyle(color: T.textTertiary, fontSize: T.fontCaption),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.gapMd),
      decoration: BoxDecoration(
        color: T.bgControls,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: T.borderLight),
      ),
      child: body,
    );
  }
}

/// Post-export signal-overload receipt (ES-470): the elements whose PCM
/// exceeded full scale during the encode — counted on what was actually
/// written, so these samples ARE hard-clipped in the artifact. Shown in
/// the `done` receipt only; the pre-encode gate already covered the
/// failed/cancelled paths.
class _OverloadPanel extends StatelessWidget {
  final List<ElementOverloadRow> rows;
  const _OverloadPanel({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.gapMd),
      decoration: BoxDecoration(
        color: T.bgControls,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: T.meterYellow.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('SIGNAL OVERLOAD', style: T.styleEyebrow),
          const SizedBox(height: T.gapPair),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: T.meterYellow,
                  ),
                  const SizedBox(width: T.gapSm),
                  Expanded(
                    child: Text(
                      row.message,
                      style: TextStyle(
                        color: T.textSecondary,
                        fontSize: T.fontBody,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Text(
            'Samples above full scale were hard-clipped by the encoder '
            'and are part of the exported file. Reduce the element gain '
            'or source level and export again to avoid it.',
            style: TextStyle(color: T.textTertiary, fontSize: T.fontCaption),
          ),
        ],
      ),
    );
  }
}

class _ValidationPanel extends StatelessWidget {
  final ExportValidationResult validation;
  const _ValidationPanel({required this.validation});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.gapMd),
      decoration: BoxDecoration(
        color: T.bgControls,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(
          color: validation.canExport
              ? T.meterYellow.withValues(alpha: 0.3)
              : T.errorRed.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final issue in validation.issues)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    issue.severity == ExportSeverity.error
                        ? Icons.cancel
                        : Icons.warning_amber_rounded,
                    size: T.iconXs,
                    color: issue.severity == ExportSeverity.error
                        ? T.errorRed
                        : T.meterYellow,
                  ),
                  const SizedBox(width: T.gapPair),
                  Expanded(
                    child: Text(
                      issue.message,
                      style: TextStyle(
                        color: T.textSecondary,
                        fontSize: T.fontBody,
                        height: 1.3,
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
}

class _StepChecklist extends StatelessWidget {
  final _ExportState state;
  final ExportTarget target;

  /// True when the session media is a still image — the mux step then
  /// also renders the video track from it (ES-192).
  final bool stillImage;
  const _StepChecklist({
    required this.state,
    required this.target,
    required this.stillImage,
  });

  _StepStatus _statusFor(_ExportPhase stepPhase) {
    final p = state.phase;
    const order = {
      _ExportPhase.measuring: 0,
      _ExportPhase.encoding: 1,
      _ExportPhase.muxing: 2,
    };
    final stepIdx = order[stepPhase]!;

    if (p == _ExportPhase.failed) {
      final failedIdx = order[state.stoppedAt] ?? -1;
      if (stepIdx < failedIdx) return _StepStatus.done;
      if (stepIdx == failedIdx) return _StepStatus.failed;
      return _StepStatus.pending;
    }
    if (p == _ExportPhase.cancelled) {
      // Steps before the aborted one finished; the aborted step and any
      // later ones stay pending (no error marker — the user stopped it).
      final stoppedIdx = order[state.stoppedAt] ?? -1;
      return stepIdx < stoppedIdx ? _StepStatus.done : _StepStatus.pending;
    }
    if (p == _ExportPhase.done) return _StepStatus.done;
    final currentIdx = order[p] ?? -1;
    if (stepIdx < currentIdx) return _StepStatus.done;
    if (stepIdx == currentIdx) return _StepStatus.active;
    return _StepStatus.pending;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepRow(
          label: 'Measure loudness',
          detail: state.totalLayouts > 0
              ? '${state.measuredLayouts} / ${state.totalLayouts}'
              : '',
          progress: state.totalLayouts > 0
              ? state.measuredLayouts / state.totalLayouts
              : null,
          status: _statusFor(_ExportPhase.measuring),
        ),
        const SizedBox(height: T.gapSm),
        _StepRow(
          label: 'Encode IAMF',
          // The last poll rarely lands on 1.0 before the encode
          // returns — once the step is done, drop the stale percentage
          // and show a full bar instead.
          detail:
              _statusFor(_ExportPhase.encoding) == _StepStatus.done ||
                  state.encodeProgress <= 0
              ? ''
              : '${(state.encodeProgress * 100).round()}%',
          // Per-coded-frame progress polled from the engine (ES-480);
          // indeterminate only until the first poll lands.
          progress: _statusFor(_ExportPhase.encoding) == _StepStatus.done
              ? 1.0
              : (state.encodeProgress > 0 ? state.encodeProgress : null),
          status: _statusFor(_ExportPhase.encoding),
          indeterminateWhenActive: state.encodeProgress <= 0,
        ),
        if (target == ExportTarget.mp4) ...[
          const SizedBox(height: T.gapSm),
          _StepRow(
            label: stillImage ? 'Render still video + mux' : 'Mux video',
            detail: '',
            progress: null,
            status: _statusFor(_ExportPhase.muxing),
            indeterminateWhenActive: true,
          ),
        ],
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  final String label;
  final String detail;
  final double? progress;
  final _StepStatus status;
  final bool indeterminateWhenActive;

  const _StepRow({
    required this.label,
    required this.detail,
    required this.progress,
    required this.status,
    this.indeterminateWhenActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = status == _StepStatus.active;
    final isDone = status == _StepStatus.done;
    final isFailed = status == _StepStatus.failed;
    final isPending = status == _StepStatus.pending;

    final labelColor = isPending ? T.textTertiary : T.textPrimary;
    final labelWeight = isActive ? FontWeight.w600 : FontWeight.w500;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(width: T.iconSm, height: T.iconSm, child: _statusIcon()),
            const SizedBox(width: T.gapSm),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: labelColor,
                  fontSize: T.fontBody,
                  fontWeight: labelWeight,
                ),
              ),
            ),
            if (detail.isNotEmpty)
              Text(
                detail,
                style: TextStyle(
                  color: isPending ? T.textTertiary : T.textSecondary,
                  fontSize: T.fontBody,
                  fontFamily: T.monoFamily,
                ),
              ),
          ],
        ),
        const SizedBox(height: T.gapPair),
        Padding(
          padding: EdgeInsets.only(left: T.iconSm + 10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: _barValue(isActive, isDone, isFailed),
              backgroundColor: T.bgControls,
              valueColor: AlwaysStoppedAnimation(
                _barColor(isActive, isDone, isFailed),
              ),
              minHeight: 3,
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusIcon() {
    switch (status) {
      case _StepStatus.pending:
        return Icon(
          Icons.radio_button_unchecked,
          size: T.iconSm,
          color: T.textTertiary,
        );
      case _StepStatus.active:
        return CircularProgressIndicator(
          strokeWidth: 2,
          color: T.purple,
          value: indeterminateWhenActive ? null : progress,
        );
      case _StepStatus.done:
        return Icon(
          Icons.check_circle,
          size: T.iconSm,
          color: T.indicatorGreen,
        );
      case _StepStatus.failed:
        return Icon(Icons.cancel, size: T.iconSm, color: T.errorRed);
    }
  }

  double? _barValue(bool isActive, bool isDone, bool isFailed) {
    if (isDone) return 1.0;
    if (isFailed) return progress ?? 1.0;
    if (isActive) {
      if (indeterminateWhenActive) return null;
      return progress ?? 0.0;
    }
    return 0.0; // pending
  }

  Color _barColor(bool isActive, bool isDone, bool isFailed) {
    if (isFailed) return T.errorRed;
    if (isDone) return T.indicatorGreen;
    if (isActive) return T.purple;
    return T.bgControls; // pending (invisible against bg)
  }
}

class _ResultRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String detail;

  const _ResultRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: T.iconMd, color: color),
        const SizedBox(width: T.gapSm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: T.fontBodyL,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    color: T.textSecondary,
                    fontSize: T.fontBody,
                    fontFamily: T.monoFamily,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Target selector
// ─────────────────────────────────────────────────────────────────────────────

/// Radio-list of the export targets. MP4 is gated on a usable session
/// video (disabled with [videoReason] otherwise) and on a profile the
/// GPAC muxer can parse (disabled with [profileReason] otherwise; the
/// video reason wins when both apply). The optional YouTube upload step
/// is rendered separately, under the MP4 form.
class _TargetSelector extends StatelessWidget {
  final ExportTarget selected;
  final bool enabled;
  final bool videoUsable;
  final String videoReason;
  final bool muxProfileOk;
  final String profileReason;
  final ValueChanged<ExportTarget> onChanged;

  const _TargetSelector({
    required this.selected,
    required this.enabled,
    required this.videoUsable,
    required this.videoReason,
    required this.muxProfileOk,
    required this.profileReason,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Export to', style: T.styleEyebrow),
        const SizedBox(height: 8),
        _TargetCard(
          selected: selected == ExportTarget.iamfOnly,
          enabled: enabled,
          title: 'IAMF file',
          description: 'A standalone .iamf bitstream (audio only).',
          onTap: () => onChanged(ExportTarget.iamfOnly),
        ),
        const SizedBox(height: 8),
        _TargetCard(
          selected: selected == ExportTarget.mp4,
          enabled: enabled && videoUsable && muxProfileOk,
          title: 'MP4 video',
          // No compatibility audio track by design (ES-451): the MP4 targets
          // YouTube ingestion, and a fallback track would double the render
          // for players this export does not aim at.
          description:
              'IAMF audio muxed with the session video into a single .mp4. '
              'Audio playback requires an IAMF decoder. YouTube and '
              'Eclipsa Studio play it; players without one show silent '
              'video.',
          disabledReason: !videoUsable
              ? videoReason
              : (!muxProfileOk ? profileReason : null),
          onTap: () => onChanged(ExportTarget.mp4),
        ),
      ],
    );
  }
}

class _TargetCard extends StatelessWidget {
  final bool selected;
  final bool enabled;
  final String title;
  final String description;
  final String? disabledReason;
  final VoidCallback onTap;

  const _TargetCard({
    required this.selected,
    required this.enabled,
    required this.title,
    required this.description,
    required this.onTap,
    this.disabledReason,
  });

  @override
  Widget build(BuildContext context) {
    final titleColor = enabled ? T.textPrimary : T.textTertiary;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? T.purple.withValues(alpha: 0.12) : T.bgControls,
            borderRadius: BorderRadius.circular(T.radiusMd),
            border: Border.all(color: selected ? T.purple : T.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: T.iconSm,
                color: selected
                    ? T.purple
                    : (enabled ? T.textSecondary : T.textTertiary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: titleColor,
                        fontSize: T.fontBodyL,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: TextStyle(
                        color: T.textSecondary,
                        fontSize: T.fontBody,
                        height: 1.35,
                      ),
                    ),
                    if (!enabled && disabledReason != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        disabledReason!,
                        style: TextStyle(
                          color: T.meterYellow,
                          fontSize: T.fontCaption,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Optional YouTube upload step (MP4 only)
// ─────────────────────────────────────────────────────────────────────────────

/// The optional "upload to YouTube" step that runs after an MP4 export.
/// The upload path isn't wired up yet, so the toggle is shown disabled
/// with a "Coming soon" badge — it advertises the step in place without
/// offering a dead-end action. When implemented this becomes a live
/// checkbox that appends an upload phase after the mux.
class _UploadStep extends StatelessWidget {
  const _UploadStep();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: T.bgControls,
        borderRadius: BorderRadius.circular(T.radiusMd),
        border: Border.all(color: T.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.check_box_outline_blank,
            size: T.iconSm,
            color: T.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Upload to YouTube after export',
                      style: TextStyle(
                        color: T.textSecondary,
                        fontSize: T.fontBodyL,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const StatusTag('Coming soon'),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Upload the muxed .mp4 straight to YouTube once the export '
                  'finishes. Requires Google sign-in (YouTube Data API).',
                  style: TextStyle(
                    color: T.textTertiary,
                    fontSize: T.fontBody,
                    height: 1.35,
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
