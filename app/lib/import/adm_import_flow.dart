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

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../logging/log.dart';
import '../meters/meter_provider.dart';
import '../renderer/speaker_layout.dart';
import '../session/session_provider.dart';
import '../state.dart';
import '../theme.dart';
import '../views/elements_view.dart' show addNewElementFromWav;
import '../widgets/app_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/console_widgets.dart' show ConsoleSelector;
import '../widgets/dialog_shell.dart';
import '../widgets/eyebrow_label.dart';
import '../widgets/ok_dialog.dart';
import '../widgets/youtube_support_badge.dart';
import '../workspace/workspace_actions.dart' show startCreatorSessionWithWav;
import '../workspace/workspace_close.dart';
import '../workspace/workspace_mode.dart';
import 'adm_import_bridge.dart';
import 'adm_import_warnings.dart';
import 'adm_probe_inspector.dart';
import 'adm_render_target.dart';

/// Owns the ADM import bridge lifecycle. Reading it registers an onDispose that
/// shuts the native render workers down (cancel + join) when the app tears down
/// — adm2iamf_ffi.h requires joining them before the shared engine dylib goes
/// away. Mirrors [eclipsaStudioEngineProvider]; created lazily, so if no import
/// ever runs there is nothing to stop. The bridge itself stays Riverpod-free
/// (it's a pure FFI wrapper); this provider is its single owner.
final admImportBridgeProvider = Provider<AdmImportBridge>((ref) {
  final bridge = AdmImportBridge.instance;
  ref.onDispose(bridge.shutdown);
  return bridge;
});

/// "Import ADM" — read an ADM-BWF master, render its bed via the engine's
/// adm2iamf_* C ABI, and seed a NEW session with the result as a single
/// audio element.
///
/// Renders a **7.1.4 channel bed** — the single fixed target
/// ([kAdmRenderTarget]); the retired binaural/ambisonic targets are parked in
/// adm-lab (ES-569). The element is typed from the target, never inferred from
/// the rendered WAV's channel count.
///
/// The import does **not** drive the mix presentation's output layout; the new
/// session keeps newSession()'s default. Deriving the mix layout from the
/// imported target is deferred until the layout/tag mapping is refined
/// (tracked in ES-17).
///
/// Flow: pick ADM → probe → config dialog → choose save location → render (with
/// progress/cancel) → verify channel count → dirty-guard → new session seeded
/// with the element → save. The render runs on a native worker thread, so
/// nothing here blocks the UI, and the current session is only replaced *after*
/// a successful render. A WAV without ADM metadata leaves the dialog through
/// "Open as Plain WAV" instead, into the landing card's plain-WAV path (ES-1008).

/// What the config dialog closes with: an import to run, or opening a WAV
/// without ADM metadata as a plain WAV (ES-1008).
sealed class _AdmDialogResult {
  const _AdmDialogResult();
}

/// The file has no ADM metadata, and the user chose to open it the way the
/// landing card opens a dropped plain WAV.
class _OpenAsPlainWav extends _AdmDialogResult {
  const _OpenAsPlainWav();
}

class _AdmImportConfig extends _AdmDialogResult {
  const _AdmImportConfig({
    required this.target,
    required this.profile,
    required this.destDir,
    required this.name,
  });
  final AdmRenderTarget target;
  // The IAMF profile to stamp on the new session.
  final IamfProfile profile;
  // Save location: the user-granted folder holds both the .esp and the bed WAV.
  final String destDir;
  final String name; // base name for both <name>.esp and <name>.wav
}

/// Entry point wired into the File menu ("Import ADM…") and the landing
/// card's drop target — pass [path] to skip the picker (step 1).
Future<void> startImportAdmFlow(
  BuildContext context,
  WidgetRef ref, {
  String? path,
}) async {
  // The originating widget (a landing card or the menu bar) may be disposed by
  // the workspace switch below, which would invalidate `ref` across the awaits.
  // Capture the app-scoped container up front and drive all provider work
  // through it; `ref` is only used for the pre-switch dirty-guard.
  final container = ProviderScope.containerOf(context, listen: false);

  // Own the bridge's lifecycle: this registers an onDispose that shuts the
  // native render workers down on app teardown. No-op until a render starts.
  container.read(admImportBridgeProvider);

  // 1. Pick the ADM-BWF file — skipped when the caller already resolved
  //    one (an ADM WAV dropped on the landing card).
  String? picked = path;
  if (picked == null) {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Import ADM',
      type: FileType.custom,
      allowedExtensions: const ['wav'],
      allowMultiple: false,
      initialDirectory: container.read(lastImportDirProvider),
    );
    picked = result?.files.single.path;
    if (picked == null) return;
  }
  // Rebind non-nullable: `picked` is read inside closures below (the config
  // dialog builder), where promotion of an assigned local doesn't apply.
  final inPath = picked;
  container.read(lastImportDirProvider.notifier).set(p.dirname(inPath));

  // 2. Start the probe on a background isolate, and open the config dialog
  //    on top of it rather than behind a spinner. Reading a master's
  //    metadata is dominated by parsing its axml — 1.2 s for a 17 MB one,
  //    7 s for a 107 MB one — and nothing the dialog asks for depends on
  //    it, so the profile, folder and session name can be filled in while
  //    it runs. The preview, channel table and report arrive when it lands.
  //    The probe measures image widths through a private OAR instance, so
  //    the live renderer is held offline-exclusive for as long as it runs.
  if (!context.mounted) return;
  final probing = holdRendererForImport(container, () => _probeAdm(inPath));

  // 3. Config dialog. Collects the IAMF profile, the destination folder and
  //    the session name for the new session (the bed format is fixed).
  // A click outside the panel does not close it (ES-612, app-wide since
  // ES-639): it would discard the folder and name and abandon the import.
  // Esc cancels, as the Cancel button does.
  final result = await showAppDialog<_AdmDialogResult>(
    context: context,
    builder: (_) => AdmImportConfigDialog(inPath: inPath, probing: probing),
  );
  final _AdmImportConfig cfg;
  switch (result) {
    case null:
      return;
    case _OpenAsPlainWav():
      // Nothing has switched yet, so the plain-WAV path runs its own
      // checks, format dialog and dirty-guard from here, as for a dropped
      // WAV.
      Log.i(
        LogCat.app,
        'ADM import: opening ${p.basename(inPath)} as plain WAV',
      );
      if (context.mounted) {
        await startCreatorSessionWithWav(context, ref, inPath);
      }
      return;
    case final _AdmImportConfig config:
      cfg = config;
  }
  // Import is only enabled once the probe has landed, so this is already
  // complete; awaiting it here keeps the flow's one reader of the probe map
  // (the summary below) off the dialog's state.
  final probe = (await probing).probe;
  final target = cfg.target;

  // 4. Resolve the destination folder + bed WAV + .esp path. The user-granted
  //    folder (chosen in the dialog) holds both the .esp and the bed.
  final destDir = cfg.destDir;
  final espPath = p.join(destDir, '${cfg.name}.$kSessionExtension');
  // The bed WAV is named after the ADM source file (+ target-label suffix),
  // independent of the session (.esp) name — which the user may rename. De-dupe
  // in the chosen folder so re-importing the same ADM never clobbers a prior bed.
  final wavBase = admBedWavBaseName(
    p.basenameWithoutExtension(inPath),
    target.label,
  );
  final bedWav = _uniqueWavPath(destDir, wavBase);

  // 5. Render (progress + cancel). The current session stays intact. (A
  //    same-named .esp in the chosen folder was already confirmed for overwrite
  //    inside the config dialog, before it closed.)
  if (!context.mounted) return;
  Log.i(
    LogCat.app,
    'ADM import: rendering ${target.label} (${target.element.type}) '
    '-> "$bedWav"',
  );
  final rendered = await _renderBedWithDialog(
    context,
    container,
    target.request(inPath: inPath, outPath: bedWav),
    target.label,
  );
  if (!rendered.ok) {
    if (rendered.error != null) {
      Log.w(LogCat.app, 'ADM import: render failed: ${rendered.error}');
    } else {
      Log.i(LogCat.app, 'ADM import: render cancelled');
    }
    _safeDelete(bedWav);
    if (rendered.error != null && context.mounted) {
      await _showError(context, inPath, rendered.error!);
    }
    return;
  }
  Log.i(LogCat.app, 'ADM import: render complete ($wavBase)');

  // 5a. The bed is always 48 kHz (the engine resamples other masters). A
  //     different rate is engine drift, not a broken element — the element
  //     still plays through the playback resampler — so log it and go on.
  if (rendered.sampleRate != null && rendered.sampleRate != kAdmBedSampleRate) {
    Log.w(
      LogCat.app,
      'ADM import: bed rendered at ${rendered.sampleRate} Hz, expected '
      '$kAdmBedSampleRate',
    );
  }

  // 5b. Explicit coupling: the element is typed from the chosen target, not the
  //     WAV's channel count, so a backend/config drift would silently mislabel
  //     it. Verify the engine produced the channel count the target expects
  //     before we touch the session. (Skip if the result omitted the count —
  //     older engines; the element typing still stands.)
  if (rendered.channels != null &&
      rendered.channels != target.expectedChannels) {
    Log.w(
      LogCat.app,
      'ADM import: rendered ${rendered.channels} channels, expected '
      '${target.expectedChannels} for ${target.label}',
    );
    _safeDelete(bedWav);
    if (context.mounted) {
      await _showError(
        context,
        inPath,
        'The engine rendered ${rendered.channels} channels but '
        '${target.label} expects ${target.expectedChannels}. This looks '
        'like an engine/configuration mismatch. Nothing was imported.',
      );
    }
    return;
  }

  // 6. Dirty-guard + switch into a fresh Creator session. If we back out here
  //    we still own the freshly rendered WAV — clean it up.
  if (!context.mounted) {
    _safeDelete(bedWav);
    return;
  }
  if (!await prepareForWorkspaceSwitch(
    context,
    ref,
    target: WorkspaceMode.creator,
  )) {
    _safeDelete(bedWav);
    return;
  }
  container.read(workspaceModeProvider.notifier).enterCreator();
  container.read(sessionProvider.notifier).newSession();
  // newSession() resets elements/mixes but NOT the profile provider, so stamp
  // the profile chosen in the dialog: the seeded element validates against it
  // (addNewElementFromWav) and the saved .esp carries it.
  container.read(iamfProfileProvider.notifier).set(cfg.profile);

  // 7. Seed the rendered element. The element is typed from the target
  //    (explicit coupling), not the WAV's channel count. (Transport duration is
  //    set by addNewElementFromWav -> _recalcDuration, which deliberately clocks
  //    at the engine rate, not the WAV rate.)
  final addError = await addNewElementFromWav(
    container,
    bedWav,
    configOverride: target.element,
  );
  if (addError != null) {
    Log.w(LogCat.app, 'ADM import: could not add element: $addError');
    _safeDelete(bedWav);
    if (context.mounted) await _showError(context, inPath, addError);
    return;
  }

  // We deliberately do NOT set the mix presentation's output layout from the
  // import; the session keeps its existing/default layout. Auto-deriving it
  // from the target (e.g. a 7.1.4 bed -> 7.1.4 monitoring) is deferred until
  // the layout/tag mapping is refined — tracked in ES-17.

  // 8. Persist: save the new session to the chosen location. On save failure
  //    saveToPath sets state.lastError, which app_shell surfaces via snackbar.
  final session = container.read(sessionProvider.notifier);
  final saved = await session.saveToPath(espPath);
  if (!saved) {
    Log.w(LogCat.app, 'ADM import: could not save session to "$espPath"');
    return;
  }
  Log.i(
    LogCat.app,
    'ADM import: ${p.basename(inPath)} -> ${target.label} '
    '${target.element.type} "${p.basename(bedWav)}"',
  );

  if (context.mounted) {
    final objects = (probe?['adm']?['objects'] as int?) ?? 0;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          'Imported ${p.basename(inPath)} → ${target.label}'
          '${objects > 0 ? ' ($objects objects baked in)' : ''}.',
        ),
      ),
    );
  }
}

/// A `<base>.wav` path in [dir] that doesn't collide with an existing file,
/// suffixing `-2`, `-3`, … so a re-import never clobbers a prior bed.
String _uniqueWavPath(String dir, String base) {
  var candidate = p.join(dir, '$base.wav');
  for (var n = 2; File(candidate).existsSync(); n++) {
    candidate = p.join(dir, '$base-$n.wav');
  }
  return candidate;
}

/// What the probe found, once it lands: the scene the dialog draws and the
/// warnings it lists, or the reason the file could not be read.
///
/// One record rather than a raw future of JSON, because the dialog opens
/// before the probe finishes and has to render every outcome — reading,
/// read, unreadable, no ADM metadata — without re-deriving them per frame.
///
/// `plainWav` is true for a WAV without ADM metadata (ES-1008): `data` then
/// holds its format and an empty scene, and the dialog offers to open the
/// file as a plain WAV in place of the import.
typedef AdmProbeOutcome = ({
  Map<String, dynamic>? probe,
  AdmProbeData? data,
  List<AdmImportWarning> warnings,
  String? error,
  bool plainWav,
});

/// Runs [body] with the live renderer held offline-exclusive, the way the
/// export dialog and the Loudness Report run their passes. The ADM probe
/// and the bed render each drive a private OAR instance (a helper isolate,
/// a native worker thread), and the live one must be out of OAR for as
/// long as they run: offline work takes exclusive use of the renderer.
/// Transport is stopped first and [admImportBusyProvider] keeps it from
/// starting into the silence; both holds end in `finally`, whatever [body]
/// does. The engine's hold is refcounted (ES-495), so this nests with an
/// export or a loudness pass. [setExportPaused] defaults to the engine's
/// call, absent when the engine failed to load; tests pass a recorder.
@visibleForTesting
Future<R> holdRendererForImport<R>(
  ProviderContainer container,
  Future<R> Function() body, {
  void Function(bool paused)? setExportPaused,
}) async {
  final pause =
      setExportPaused ??
      container.read(eclipsaStudioEngineProvider)?.setExportPaused;
  container.read(playingProvider.notifier).set(false);
  container.read(admImportBusyProvider.notifier).enter();
  pause?.call(true);
  try {
    return await body();
  } finally {
    pause?.call(false);
    container.read(admImportBusyProvider.notifier).exit();
  }
}

const _kUnreadable = 'Could not read the ADM metadata.';

AdmProbeOutcome _probeFailed(String error) => (
  probe: null,
  data: null,
  warnings: const <AdmImportWarning>[],
  error: error,
  plainWav: false,
);

/// Probes [path] off the UI isolate, decodes it, and logs its warnings.
///
/// Never throws and never rejects: every failure comes back as `error`, the
/// one string the dialog shows in place of the preview. The caller starts
/// this and shows the dialog immediately, so an error raised here has no
/// dialog to interrupt.
Future<AdmProbeOutcome> _probeAdm(String path) async {
  String json;
  try {
    json = await AdmImportBridge.probeJsonAsync(path);
  } on Object catch (e) {
    // The probe runs in a helper isolate (re-opens the dylib); a spawn/load
    // failure rejects the future.
    Log.w(LogCat.app, 'ADM probe isolate failed for $path', e);
    return _probeFailed(_kUnreadable);
  }
  return decodeAdmProbe(path, json);
}

/// Decodes the probe's [json] for [path] and logs its warnings. Never
/// throws: invalid JSON and a failed probe come back as `error`.
@visibleForTesting
AdmProbeOutcome decodeAdmProbe(String path, String json) {
  final Map<String, dynamic> probe;
  try {
    probe = jsonDecode(json) as Map<String, dynamic>;
  } on FormatException catch (e) {
    Log.w(LogCat.app, 'ADM probe returned invalid JSON', e);
    return _probeFailed(_kUnreadable);
  }
  if (probe['ok'] != true) {
    final err = probe['error'] as String? ?? 'Unknown error.';
    Log.w(LogCat.app, 'ADM probe failed for $path: $err');
    return _probeFailed(err);
  }
  // A WAV without an axml chunk probes as ok with `adm: null`, its format,
  // an empty scene and no warnings. The render would fail on it (ES-1008).
  final plainWav = probe['adm'] == null;
  if (plainWav) Log.i(LogCat.app, 'ADM probe: $path has no ADM metadata');

  // Import warnings (non-spec metadata, fallbacks, dropped channels): every
  // entry goes to the log, at its own severity — informational notices like
  // "an ignored `bext` chunk" are normal for a spec-clean master and would
  // otherwise fill the log with WARN lines. The dialog lists them all.
  final warnings = decodeAdmImportWarnings(probe);
  for (final w in warnings) {
    final line = 'ADM import [${w.code}]: ${w.message}';
    if (w.isInfo) {
      Log.i(LogCat.app, line);
    } else {
      Log.w(LogCat.app, line);
    }
  }
  final problems = warnings.where((w) => !w.isInfo).length;
  if (problems > 0) {
    Log.i(
      LogCat.app,
      'ADM probe surfaced $problems warning(s) for $path (details above)',
    );
  }
  return (
    probe: probe,
    data: AdmProbeData.decode(probe),
    warnings: warnings,
    error: null,
    plainWav: plainWav,
  );
}

void _safeDelete(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } on FileSystemException catch (e) {
    Log.w(LogCat.app, 'ADM import: could not remove $path', e);
  }
}

Future<void> _showError(BuildContext context, String path, String reason) =>
    showOkDialog(
      context,
      title: 'Could Not Import ADM',
      message: '${p.basename(path)}\n\n$reason',
    );

/// Confirms replacing an existing session file before an ADM import overwrites
/// it. Returns `true` to proceed with the overwrite, `false` to cancel.
Future<bool> _confirmOverwrite(BuildContext context, String espPath) async {
  final replace = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.bgElevated,
      title: Text('Replace Existing Session?', style: T.styleTitle),
      content: Text(
        '"${p.basename(espPath)}" already exists in this folder. '
        'Replacing it overwrites the existing session.',
        style: T.styleBodySecondary,
      ),
      actions: [
        AppButton(
          label: 'Cancel',
          role: AppButtonRole.quiet,
          onPressed: () => Navigator.pop(ctx, false),
        ),
        AppButton(
          label: 'Replace',
          role: AppButtonRole.destructive,
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
  return replace ?? false;
}

// ── Config dialog ────────────────────────────────────────────────────────────

/// A folder path shortened for the dialog's folder row: leading segments are
/// dropped for a leading ellipsis, so the folder just chosen — the end of the
/// path — stays readable. Ordinary end-elision cuts exactly that part off.
/// Returns [path] unchanged when it already fits [maxChars].
@visibleForTesting
String elideFolderPath(String path, {int maxChars = 64}) {
  if (path.length <= maxChars) return path;
  final segments = p.split(path).where((s) => s != p.separator).toList();
  if (segments.isEmpty) return path;
  final kept = <String>[];
  var length = 2; // the leading '…/'
  for (final segment in segments.reversed) {
    final next = length + segment.length + 1;
    if (kept.isNotEmpty && next > maxChars) break;
    kept.insert(0, segment);
    length = next;
  }
  // One segment longer than the whole budget: cut into it from the left, so
  // its end — what tells two long names apart — survives.
  if (kept.length == 1 && kept.first.length + 2 > maxChars) {
    return '…${kept.first.substring(kept.first.length - (maxChars - 1))}';
  }
  return '…${p.separator}${p.joinAll(kept)}';
}

/// The dialog's width, and the pane widths inside it.
///
/// 1000 less 48 of padding leaves a 952 px content box, less the 24 px gap
/// between panes = 928, divided in golden ratio: 928 × 0.618 = 574 for the
/// preview and 354 for the flow. The scene and the channel table are what
/// benefit from area; the flow is a stack of full-width rows that reflow at
/// any width. The app's window is at least 1400 × 900, so a 1000 px dialog
/// keeps a wide margin.
const double _kDialogW = 1000;
const double _kPreviewPaneW = 574;
const double _kFlowPaneW = 354;

/// The Import ADM dialog. It closes with an `_AdmImportConfig` from Import,
/// with `_OpenAsPlainWav` for a WAV without ADM metadata, or with null.
@visibleForTesting
class AdmImportConfigDialog extends ConsumerStatefulWidget {
  const AdmImportConfigDialog({
    super.key,
    required this.inPath,
    required this.probing,
  });
  final String inPath;

  /// The probe, still running when the dialog opens. Everything the dialog
  /// reads from the file — the preview, the channel table, the file's own
  /// numbers and the report — waits on this; the profile, folder and name
  /// do not.
  final Future<AdmProbeOutcome> probing;

  @override
  ConsumerState<AdmImportConfigDialog> createState() =>
      _AdmImportConfigDialogState();
}

class _AdmImportConfigDialogState extends ConsumerState<AdmImportConfigDialog> {
  String? _destDir;
  late final TextEditingController _nameCtl;

  // The IAMF profile stamped on the new session — chosen in the dialog. The
  // fixed 7.1.4 bed is legal under every profile, so the choice gates nothing
  // here; it only seeds the session.
  late IamfProfile _profile;

  /// Null until the probe lands. Set once and never again — the probe runs
  /// exactly once per dialog.
  AdmProbeOutcome? _probed;

  // Shared by the preview pane and the channel table so the two track one
  // scene while sitting in different parts of the layout: scrubbing moves
  // both, and hovering or selecting a row lights up the matching mark.
  final AdmInspectorState _inspector = AdmInspectorState();

  @override
  void initState() {
    super.initState();
    _profile = ref.read(iamfProfileProvider);
    _nameCtl = TextEditingController(text: _autoName());
    // Fill the pane in when the probe lands. The future is the flow's, not
    // this dialog's: cancelling the dialog leaves it running to completion
    // rather than orphaning an isolate, and the mounted check is what keeps
    // a late result from touching a disposed State.
    widget.probing.then((outcome) {
      if (mounted) setState(() => _probed = outcome);
    });
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _inspector.dispose();
    super.dispose();
  }

  // Suggested session (.esp) name: the master's basename, with no target-label
  // suffix — only the bed WAV carries the "_<label>" (added by
  // admBedWavBaseName at import time).
  String _autoName() => p.basenameWithoutExtension(widget.inPath);

  String _profileHint(IamfProfile p) {
    final n = p.maxAudioElements;
    final types = p.allowObjectBased
        ? 'channel, scene & objects'
        : 'channel & scene';
    return '$n element${n == 1 ? '' : 's'} · ${p.maxChannels} ch · $types';
  }

  // file_selector's getDirectoryPath sets canCreateDirectories on the macOS
  // NSOpenPanel, so the folder dialog shows a New Folder button — file_picker's
  // does not (ES-123). Picking a folder (rather than naming the .esp via a Save
  // panel) is also what lets the bed WAV be written alongside the .esp: under
  // the sandbox a Save-As grants the .esp file only, not its folder.
  // Opens where the *last import was saved*, not where the master was read
  // from: masters live in a delivery/library folder and sessions belong in a
  // projects folder, so reusing the source path (or the shared
  // lastImportDirProvider) would send this dialog to the wrong end every
  // time. The master's own folder is only the first-run fallback.
  Future<void> _chooseFolder() async {
    final dir = await fs.getDirectoryPath(
      initialDirectory:
          ref.read(lastAdmDestDirProvider) ?? p.dirname(widget.inPath),
      confirmButtonText: 'Choose',
      canCreateDirectories: true,
    );
    if (dir == null) return;
    // Remember on pick, as the export dialog does — the folder is the user's
    // stated intent even if they then cancel or the render fails.
    ref.read(lastAdmDestDirProvider.notifier).set(dir);
    if (mounted) setState(() => _destDir = dir);
  }

  // Confirm the import (the Import button). A new/untitled save into a folder
  // that already holds a same-named .esp would clobber it, so we prompt here —
  // before closing — and on a declined overwrite stay in the dialog with the
  // user's input intact so they can retitle or pick another folder.
  Future<void> _handleImport() async {
    final name = _nameCtl.text.trim();
    // Reachable only when canImport: _destDir != null and name is non-empty.
    final destDir = _destDir!;
    final cfg = _AdmImportConfig(
      target: kAdmRenderTarget,
      profile: _profile,
      destDir: destDir,
      name: name,
    );
    final espPath = p.join(destDir, '$name.$kSessionExtension');
    if (File(espPath).existsSync() &&
        !await _confirmOverwrite(context, espPath)) {
      return;
    }
    if (mounted) Navigator.pop(context, cfg);
  }

  /// What the preview should draw the probe's scene against: the fixed
  /// target's speakers.
  AdmPreviewTarget _previewTarget() =>
      AdmPreviewTarget(speakers: SpeakerLayout.byName(kAdmRenderTarget.label));

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final name = _nameCtl.text.trim();
    // A WAV without ADM metadata has a format but no scene (ES-1008): the
    // preview pane says so in place of the preview, and Import stays off.
    final plainWav = _probed?.plainWav ?? false;
    final data = plainWav ? null : _probed?.data;
    // Import waits for the probe: it is what says the file is readable, and
    // pressing it before the preview exists would commit to a render with
    // nothing seen. The folder and name can be filled in meanwhile.
    final canImport = data != null && _destDir != null && name.isNotEmpty;
    // Two full-height columns: the preview with the channel table under
    // it on one side, the import flow with the report under it on the
    // other (ES-448). Each column ends in a list that takes that column's
    // own slack, so neither side is left with dead space under a short
    // form. DialogShell + the panel footer vocabulary (a quiet AppButton
    // beside the affirmative one), matching the export dialog (ES-601).
    return DialogShell(
      title: 'Import ADM',
      width: _kDialogW,
      // A definite height is what lets the two lists take the slack:
      // without one the dialog hugs its content and both sit at their caps.
      height: math.min(900.0, MediaQuery.of(context).size.height - 80),
      bodyFit: DialogBodyFit.expand,
      actions: [
        AppButton(
          label: 'Cancel',
          role: AppButtonRole.quiet,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          label: 'Import',
          role: AppButtonRole.affirmative,
          onPressed: canImport ? _handleImport : null,
        ),
      ],
      child: Row(
        // Stretch so both columns run the dialog's full height and each
        // one's Expanded has something to divide.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _kPreviewPaneW,
            child: data == null
                ? _ProbePanePlaceholder(
                    error: _probed?.error,
                    onOpenAsPlainWav: plainWav
                        ? () => Navigator.pop(context, const _OpenAsPlainWav())
                        : null,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AdmProbeInspector(
                        data: data,
                        target: _previewTarget(),
                        state: _inspector,
                      ),
                      const SizedBox(height: T.gapSection),
                      const EyebrowLabel('Channels'),
                      const SizedBox(height: T.gapPair),
                      Expanded(
                        child: AdmProbeChannelTable(
                          data: data,
                          state: _inspector,
                          expand: true,
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(width: T.gapXl),
          SizedBox(
            width: _kFlowPaneW,
            child: _importFlowColumn(name, canImport, plainWav),
          ),
        ],
      ),
    );
  }

  /// The import flow itself (profile → bed (fixed) → folder → name →
  /// report). The report takes the column's leftover height.
  Widget _importFlowColumn(String name, bool canImport, bool plainWav) {
    const target = kAdmRenderTarget;
    // The bed WAV tracks the ADM source name (+ suffix), not the session name,
    // and is de-duped in the chosen folder exactly as the import is, so the
    // summary shows the real name — a -2/-3 suffix when a prior bed is present.
    final wavBase = admBedWavBaseName(
      p.basenameWithoutExtension(widget.inPath),
      target.label,
    );
    final wavName = _destDir != null
        ? p.basenameWithoutExtension(_uniqueWavPath(_destDir!, wavBase))
        : wavBase;
    final fileName = p.basename(widget.inPath);
    final data = _probed?.data;
    final fileSpecs = data == null ? '' : admFileSpecs(data);
    final creates = canImport ? 'Creates:\n$name.esp\n$wavName.wav' : null;
    final warnings = _probed?.warnings ?? const <AdmImportWarning>[];
    final fileSection = [
      // The file being imported, as a section of this column rather
      // than in the dialog's subtitle slot: a subtitle spans the whole
      // dialog and pushes the preview down a row for a line that only
      // needs one column's width.
      EyebrowLabel(plainWav ? 'File' : 'ADM file'),
      const SizedBox(height: T.gapPair),
      // Name and numbers on separate rows: run together they wrap at
      // whatever point the name happens to end, so the numbers start
      // mid-line and a longer name moves them. The full name is on
      // hover for when it elides.
      Tooltip(
        message: fileName,
        child: Text(
          fileName,
          style: T.styleBody,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(height: 2),
      // Held, not hidden, while the probe runs: the numbers land a second
      // or two after the dialog opens, and letting the row appear then
      // would shift every section under it down a line.
      Text(fileSpecs.isEmpty ? '—' : fileSpecs, style: T.styleBodySecondary),
    ];
    // A WAV without ADM metadata has nothing to import (ES-1008). Open as
    // Plain WAV would drop a profile, folder or name chosen here, and the
    // plain-WAV path asks for what it needs, so the column shows the file
    // alone.
    if (plainWav) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: fileSection,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...fileSection,
        const SizedBox(height: T.gapSection),
        const EyebrowLabel('IAMF profile'),
        const SizedBox(height: T.gapPair),
        // Plain ConsoleSelector, NOT ProfileSelector: that widget gates by
        // the *current* session's fit, but the import creates a new session.
        // Nothing to gate per profile either: the 7.1.4 bed fits them all.
        ConsoleSelector<IamfProfile>(
          value: _profile,
          items: [for (final p in IamfProfile.values) (p, p.label)],
          itemBadge: (p) =>
              p.supportedByYouTube ? const YouTubeSupportBadge() : null,
          onChanged: (v) => setState(() => _profile = v),
        ),
        const SizedBox(height: T.gapPair),
        Text(
          _profileHint(_profile),
          style: TextStyle(color: T.textSecondary, fontSize: T.fontCaption),
        ),
        const SizedBox(height: T.gapSection),
        const EyebrowLabel('Bed'),
        const SizedBox(height: T.gapPair),
        // The bed format is fixed (kAdmRenderTarget, kAdmBedBitDepth,
        // kAdmBedSampleRate): shown, not chosen. Extend here if a choice is
        // ever needed again, as with the retired layout menu.
        Text(
          '${target.label} · ${target.expectedChannels} channels · '
          '$kAdmBedBitDepth-bit · ${kAdmBedSampleRate ~/ 1000} kHz',
          style: T.styleBody,
        ),
        const SizedBox(height: T.gapSection),
        const EyebrowLabel('Session folder'),
        const SizedBox(height: T.gapPair),
        Row(
          children: [
            Expanded(
              child: _destDir == null
                  ? Text(
                      'Choose a folder to enable import.',
                      // Amber, like the report's warning rows: this is the
                      // one thing standing between the dialog and a run,
                      // and in secondary grey it read as description.
                      style: TextStyle(
                        color: T.meterYellow,
                        fontSize: T.fontSmall,
                      ),
                      overflow: TextOverflow.ellipsis,
                    )
                  // End-eliding a long path cuts the folder that was just
                  // chosen, which is the part being checked. Drop the middle
                  // instead, and keep the whole path one hover away.
                  : Tooltip(
                      message: _destDir!,
                      child: Text(
                        elideFolderPath(_destDir!),
                        style: TextStyle(
                          color: T.textPrimary,
                          fontSize: T.fontSmall,
                        ),
                        // Three lines, not two: the flow pane is 354 px
                        // wide in the split arrangements, so a session
                        // folder nested a few levels deep needs the room
                        // before elideFolderPath drops segments.
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
            ),
            const SizedBox(width: T.gapSm),
            AppButton(
              label: _destDir == null ? 'Choose…' : 'Change…',
              size: AppButtonSize.compact,
              onPressed: _chooseFolder,
            ),
          ],
        ),
        const SizedBox(height: T.gapSection),
        const EyebrowLabel('Session name'),
        const SizedBox(height: T.gapPair),
        TextField(
          controller: _nameCtl,
          style: T.styleBody,
          decoration: _fieldDecoration(),
          onChanged: (_) => setState(() {}),
        ),
        // The report: what the import will write, then the amber warnings
        // and the routine notices under it (ES-553). Titled for what it is —
        // the box carries both severities, so naming it for either one
        // would over- or under-sell the other. What gets written leads,
        // being the line checked before pressing Import; until a folder is
        // chosen the folder row carries that hint instead, so nothing here
        // repeats it. Nothing to report at all shows no box.
        if (canImport || warnings.isNotEmpty) ...[
          const SizedBox(height: T.gapSection),
          const EyebrowLabel('Import report'),
          const SizedBox(height: T.gapPair),
          Expanded(
            child: AdmImportReportPanel(
              warnings: warnings,
              creates: creates,
              expand: true,
            ),
          ),
        ],
      ],
    );
  }

  InputDecoration _fieldDecoration() {
    // In the `raised` style the field is `bgElevated`. On Light's
    // dialog ground that fill is 1.07:1 against `bgSurface`, so the
    // field takes the `border` rim, as `raisedField` draws for the
    // read-only boxes.
    final raised = T.chromeStyle == ChromeStyle.raised;
    final side = BorderSide(color: T.border);
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: raised ? T.bgElevated : T.bgBase,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(T.radiusMd),
        borderSide: side,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(T.radiusMd),
        borderSide: side,
      ),
    );
  }
}

/// The preview pane while the probe runs, and if it fails.
///
/// The dialog opens before the file has been read, so this stands in for the
/// preview, the channel table and their labels — the whole left column,
/// rather than a stack of separate skeletons, because none of them has
/// anything to show until one probe lands and then all of them do.
///
/// Failure lands here too rather than in an alert over the dialog: the
/// dialog is already open by then, and popping it to raise a modal would
/// flash. The Import button stays disabled, so this message is what the
/// column has to say.
///
/// A WAV without ADM metadata lands here as well (ES-1008), with the action
/// that opens it as a plain WAV.
class _ProbePanePlaceholder extends ConsumerWidget {
  const _ProbePanePlaceholder({this.error, this.onOpenAsPlainWav});

  /// Why the file could not be read. Null while the probe is still running
  /// and for a WAV without ADM metadata.
  final String? error;

  /// Set when the file is a WAV without ADM metadata: the pane says so and
  /// offers this action.
  final VoidCallback? onOpenAsPlainWav;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final plainWav = onOpenAsPlainWav != null;
    final failed = error != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const EyebrowLabel('Preview'),
        const SizedBox(height: T.gapPair),
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: T.bgBase,
              borderRadius: BorderRadius.circular(T.radiusMd),
            ),
            padding: const EdgeInsets.all(T.gapXl),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (plainWav)
                    Icon(Icons.info_outline, color: T.textSecondary, size: 28)
                  else if (failed)
                    Icon(Icons.error_outline, color: T.errorRed, size: 28)
                  else
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const SizedBox(height: T.gapMd),
                  // The file's name is already in the flow column, so this
                  // says only what is happening to it.
                  Text(
                    plainWav
                        ? 'This WAV file has no ADM metadata.'
                        : error ?? 'Reading ADM metadata…',
                    style: T.styleBody,
                    textAlign: TextAlign.center,
                  ),
                  if (plainWav) ...[
                    const SizedBox(height: T.gapPair),
                    Text(
                      'Open as Plain WAV starts a new session with the file '
                      'as its first element.',
                      style: T.styleBodySecondary,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: T.gapSection),
                    AppButton(
                      label: 'Open as Plain WAV',
                      onPressed: onOpenAsPlainWav,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Render progress dialog ───────────────────────────────────────────────────

class _RenderOutcome {
  const _RenderOutcome(this.ok, this.error, {this.channels, this.sampleRate});
  final bool ok;
  final String? error;
  final int? channels; // engine-reported output channel count (done only)
  final int? sampleRate; // engine-reported bed sample rate (done only)
}

/// The render runs on a native worker thread with its own OAR instance, so
/// the live renderer is held for the dialog's whole life. The dialog pops
/// only once the job is terminal (or never started), and the worker
/// publishes the terminal state after it has destroyed its instance
/// (`RunRenderImpl`, `adm2iamf_ffi.cc`), so releasing after the pop is
/// safe on the cancel path too.
Future<_RenderOutcome> _renderBedWithDialog(
  BuildContext context,
  ProviderContainer container,
  AdmRenderRequest request,
  String label,
) async {
  final outcome = await holdRendererForImport(
    container,
    () => showAppDialog<_RenderOutcome>(
      context: context,
      escape: DialogEscape.none,
      builder: (_) => _RenderProgressDialog(request: request, label: label),
    ),
  );
  return outcome ?? const _RenderOutcome(false, null);
}

class _RenderProgressDialog extends ConsumerStatefulWidget {
  const _RenderProgressDialog({required this.request, required this.label});
  final AdmRenderRequest request;
  final String label;

  @override
  ConsumerState<_RenderProgressDialog> createState() =>
      _RenderProgressDialogState();
}

class _RenderProgressDialogState extends ConsumerState<_RenderProgressDialog> {
  double _progress = 0;
  bool _cancelling = false;
  int _job = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final bridge = AdmImportBridge.instance;
    _job = bridge.renderStart(widget.request);
    if (_job <= 0) {
      // renderStart is synchronous, so this runs inside initState (before the
      // first await). Popping the route now would fire before it is fully
      // constructed — defer to after the first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.pop(
            context,
            const _RenderOutcome(false, 'Could not start the render.'),
          );
        }
      });
      return;
    }
    final resultJson = await bridge.awaitRender(
      _job,
      onProgress: (pr) {
        if (mounted) setState(() => _progress = pr);
      },
    );
    if (!mounted) return;
    _RenderOutcome outcome;
    try {
      final r = jsonDecode(resultJson) as Map<String, dynamic>;
      if (r['ok'] == true) {
        outcome = _RenderOutcome(
          true,
          null,
          channels: r['channels'] as int?,
          sampleRate: r['sample_rate'] as int?,
        );
      } else {
        final err = r['error'] as String? ?? 'Render failed.';
        // A user-cancelled render is not an error to surface.
        outcome = _cancelling
            ? const _RenderOutcome(false, null)
            : _RenderOutcome(false, err);
      }
    } on FormatException {
      outcome = const _RenderOutcome(false, 'Render returned no result.');
    }
    Navigator.pop(context, outcome);
  }

  void _cancel() {
    if (_cancelling || _job <= 0) return;
    setState(() => _cancelling = true);
    AdmImportBridge.instance.renderCancel(_job);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    return DialogShell(
      title: 'Rendering Bed',
      width: 408,
      actions: [
        AppButton(
          label: 'Cancel',
          role: AppButtonRole.quiet,
          onPressed: _cancelling ? null : _cancel,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _cancelling ? 'Cancelling…' : 'Rendering ${widget.label}…',
            style: T.styleBodySecondary,
          ),
          const SizedBox(height: T.gapSection),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              minHeight: 6,
              backgroundColor: T.bgBase,
            ),
          ),
          const SizedBox(height: T.gapPair),
          Text(
            '${(_progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
            style: TextStyle(color: T.textSecondary, fontSize: T.fontSmall),
          ),
        ],
      ),
    );
  }
}
