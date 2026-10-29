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
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../export/iamf_export_validator.dart' show channelCountForLayout;
import '../export/iamf_profile_rules.dart';
import '../ffi_bridge.dart';
import '../logging/log.dart';
import '../loudness/loudness_measure_runner.dart';
import '../meters/meter_provider.dart';
import '../renderer/viz_state.dart';
import '../state.dart';
import '../video/video_provider.dart';
import '../waveform/waveform.dart';
import '../workspace/workspace_mode.dart';
import 'atomic_write.dart';
import 'folder_bookmarks.dart';
import 'recent_qc_files.dart';
import 'recent_sessions.dart';
import 'session_model.dart';

/// File extension for Eclipsa Studio session files.
const kSessionExtension = 'esp';

/// Default mix added to new/empty sessions.
const kDefaultMix = Mix(
  id: 1,
  name: 'Main Mix',
  language: 'en',
  subMixes: [SubMix()],
);

/// Tracks the current session file and dirty state.
class SessionState {
  /// Path to the current `.esp` file, or null if unsaved.
  final String? filePath;

  /// The session name (shown in title bar).
  final String name;

  /// Whether the session has unsaved changes.
  final bool dirty;

  /// Whether a session is currently being loaded (suppresses dirty tracking).
  final bool loading;

  /// Last error message from a failed operation, or null.
  final String? lastError;

  /// The loaded session's media path when that media failed to load, or
  /// null. A save writes it while no other media is loaded, so the
  /// session keeps its media reference (ES-843). Cleared when the video's
  /// file changes outside a load, and by
  /// [SessionNotifier.clearMissingMedia].
  final String? missingMediaPath;

  const SessionState({
    this.filePath,
    this.name = 'Untitled',
    this.dirty = false,
    this.loading = false,
    this.lastError,
    this.missingMediaPath,
  });

  SessionState copyWith({
    String? filePath,
    String? name,
    bool? dirty,
    bool? loading,
    String? lastError,
    bool clearPath = false,
    bool clearError = false,
    bool clearMissingMedia = false,
  }) {
    return SessionState(
      filePath: clearPath ? null : (filePath ?? this.filePath),
      name: name ?? this.name,
      dirty: dirty ?? this.dirty,
      loading: loading ?? this.loading,
      lastError: clearError ? null : (lastError ?? this.lastError),
      missingMediaPath: clearMissingMedia ? null : missingMediaPath,
    );
  }

  /// The session's folder — the directory its `.esp` lives in, or null when
  /// the session has never been saved. This is the canonical "session
  /// folder": derived from [filePath] (not stored), and the default home for
  /// the session's media (e.g. ADM-rendered beds) and exports (IAMF, and any
  /// future muxed MP4 / bounces).
  String? get folder => filePath == null ? null : p.dirname(filePath!);
}

/// Manages session lifecycle: new, open, save, save-as.
class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() {
    // A load still running when this notifier is disposed (the workspace
    // returning to the landing screen) must stop at its next await.
    ref.onDispose(() {
      _loadGeneration++;
      _halfApplied = false;
    });
    // A change of the video's file outside a load (a video loaded or
    // removed) clears the missing media path. A load's own video writes
    // happen while `loading` is set.
    ref.listen(videoProvider.select((v) => v.filePath), (_, _) {
      if (!state.loading && state.missingMediaPath != null) {
        state = state.copyWith(clearMissingMedia: true);
      }
    });
    return const SessionState();
  }

  /// Test hooks standing in for the two panels the ES-628 remedies open —
  /// both are platform channels, so a headless test cannot run them.
  /// Null in production; mirrors [WavDecoder.probeForTesting].
  @visibleForTesting
  static Future<String?> Function(String? initialDirectory)?
  folderPickerForTesting;

  @visibleForTesting
  static Future<String?> Function(String? initialDirectory)?
  wavPickerForTesting;

  /// Whether this process holds access to the session's folder: a bookmark
  /// restored at load, or the folder panel confirmed since. While it is
  /// false, a file beside the session that fails to load is a grant
  /// problem; once it is true the stat can be trusted again, so a file that
  /// is gone is reported as missing rather than sent back to the folder
  /// panel (ES-628). Only [classifyMissingWav] reads it.
  bool _folderGranted = false;

  /// Bumped by [loadFile] and [newSession]. A load that finds it changed
  /// after an await stops without writing providers or [state], so a
  /// session opened or created during it is not overwritten (ES-841).
  int _loadGeneration = 0;

  /// Returns a test that is true while the providers hold the session
  /// they hold now. It turns false when a load or New Session starts
  /// and when the workspace leaves Creator. An edit that waits for a
  /// dialog or a file read takes one first and drops its result once
  /// the test fails: another session can be opened from the native menu
  /// while a Flutter dialog is up, and the result must not land in that
  /// session (ES-868).
  bool Function() sessionGuard() {
    final generation = _loadGeneration;
    return () => ref.mounted && generation == _loadGeneration;
  }

  /// Bumped by every [markDirty]. A save clears `dirty` only when no
  /// edit arrived while it was writing (ES-842).
  int _editRevision = 0;

  /// True from the first provider write of a load until that load, or
  /// a New Session, completes. A load that fails while it is set resets
  /// to a new session, so the providers never hold part of one session
  /// under another session's path.
  bool _halfApplied = false;

  /// Create a new empty session, discarding current state.
  void newSession() {
    _loadGeneration++;
    _halfApplied = false;
    // Remove all elements from C++ engine.
    final engine = ref.read(eclipsaStudioEngineProvider);
    final elements = ref.read(elementsProvider);
    if (engine != null) {
      for (final el in elements) {
        engine.removeElement(el.id);
      }
    }
    ref.read(engineOrderProvider.notifier).set([]);

    // Reset all providers to defaults. The loudness report and any
    // pass measuring it belong to the session being replaced.
    ref.read(loudnessMeasureProvider.notifier).discard();
    ref.read(elementsProvider.notifier).set([]);
    ref.read(mixesNotifierProvider.notifier).set([kDefaultMix]);
    ref.read(activeMixProvider.notifier).set(0);
    ref.read(playingProvider.notifier).set(false);
    ref.read(transportProvider.notifier).resetPosition();
    // A leftover region would hijack return-on-stop in the fresh
    // session (returnToPlayStart prefers the region start, ES-277).
    // clear() also disarms the loop toggle when a region existed.
    ref.read(loopRegionProvider.notifier).clear();
    ref.read(videoProvider.notifier).unload();
    ref.read(vizStateProvider.notifier).resetToDefaults();
    // Land a fresh session on the Elements tab. newSession() is only
    // reached in Creator (New Session or an ADM import), whose default
    // tab is Elements. Reset it explicitly: the active tab survives a
    // session reset otherwise, and `renderer` is shared with Playback,
    // so a prior renderer/mix selection would stick instead.
    ref.read(activeTabProvider.notifier).set(WorkspaceTabs.elements);

    state = const SessionState();
  }

  /// Open a session file via file picker.
  ///
  /// Starts in the most recent session's folder. That list already exists
  /// (recent_sessions.json), so this needs no preference of its own — and
  /// deliberately not [lastImportDirProvider], which tracks where *source
  /// media* was last read from, not where projects live.
  Future<bool> open() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [kSessionExtension],
      initialDirectory: await RecentSessions.lastDirectory(),
    );
    if (result == null || result.files.single.path == null) return false;
    return loadFile(result.files.single.path!);
  }

  /// Load a session from a specific file path.
  ///
  /// Returns false when the load fails, and also when a newer load or
  /// New Session overtakes it; only a failure sets `lastError`.
  Future<bool> loadFile(String path) async {
    final generation = ++_loadGeneration;
    try {
      final file = File(path);
      final content = await file.readAsString();
      if (_superseded(generation, path)) return false;
      final sessionDir = p.dirname(path);
      // Restore write access to the session folder (if bookmarked) so exports
      // and re-renders into it don't re-prompt this session.
      final granted = await FolderBookmarks.ensureAccess(sessionDir);
      if (_superseded(generation, path)) return false;
      _folderGranted = granted;
      final session = SessionModel.decode(content, resolveFrom: sessionDir);
      // Loading a session implies the user is entering Creator. Flip
      // the workspace mode before _applySession so its writes pass the
      // creator-only guards on element/mix providers. Idempotent when
      // already in Creator (e.g. File → Open replacing current session).
      ref.read(workspaceModeProvider.notifier).enterCreator();
      if (!await _applySession(session, path, generation)) return false;
      await RecentSessions.add(path, mediaPaths: _mediaPaths(session));
      ref.read(recentSessionsProvider.notifier).refresh();
      // STABLE LOG CONTRACT (issue ES-39): external smoke tests watch
      // for this exact "Loaded session: <path>" line. Keep the format.
      Log.i(LogCat.session, 'Loaded session: $path');
      return true;
    } on FormatException catch (e) {
      Log.e(LogCat.session, 'Invalid session file: $path', e);
      _failLoad(generation, 'Invalid session file: $e');
      return false;
    } on TypeError catch (e) {
      Log.e(LogCat.session, 'Invalid session file structure: $path', e);
      _failLoad(generation, 'Invalid session file structure: $e');
      return false;
    } on FileSystemException catch (e) {
      Log.e(LogCat.session, 'Could not read session: $path', e);
      _failLoad(generation, 'Could not read "$path": ${e.message}');
      return false;
    } catch (e) {
      // Anything else a partial _applySession can throw (platform
      // exceptions, provider guards, ...). Without this the exception
      // reaches PlatformDispatcher.onError with `loading` still true.
      Log.e(LogCat.session, 'Failed to load session: $path', e);
      _failLoad(generation, 'Could not load "$path": $e');
      return false;
    } finally {
      // Never leave the dirty-suppression flag latched: DirtyTracker
      // skips markDirty while `loading` is set, so a stuck flag would
      // silently disable unsaved-changes prompts for the rest of the
      // app's life. On the success path _applySession already replaced
      // state with loading=false, making this a no-op.
      // A newer load or New Session owns the flag once this one is
      // superseded.
      if (generation == _loadGeneration && ref.mounted && state.loading) {
        state = state.copyWith(loading: false);
      }
    }
  }

  /// Stops a load in progress at its next await, without resetting the
  /// providers. Called when the workspace leaves Creator, where the
  /// load's writes no longer belong.
  void cancelLoad() {
    _loadGeneration++;
    _halfApplied = false;
    // The cancelled load no longer owns the flag, so nothing else would
    // clear it.
    if (state.loading) state = state.copyWith(loading: false);
  }

  /// Reports a failed load. When a load (this one, or one it overtook)
  /// had already written part of its session into the providers, reset
  /// to a new session first: otherwise the next Save would write that
  /// part over the previously open session's file. A load that has
  /// itself been overtaken reports nothing.
  void _failLoad(int generation, String message) {
    if (!ref.mounted || generation != _loadGeneration) return;
    // Only in Creator: New Session's writes are Creator-only, and a load
    // is cancelled when the workspace leaves Creator.
    if (_halfApplied &&
        ref.read(workspaceModeProvider) == WorkspaceMode.creator) {
      Log.w(LogCat.session, 'Load failed after a partial apply: resetting');
      newSession();
    }
    state = state.copyWith(lastError: message, loading: false);
  }

  /// Whether a newer [loadFile] or [newSession] has started since the
  /// load of [path] took [generation].
  bool _superseded(int generation, String path) {
    if (ref.mounted && generation == _loadGeneration) return false;
    Log.i(LogCat.session, 'Load superseded, stopping: $path');
    return true;
  }

  /// Save to the current file path, or prompt save-as if none.
  Future<bool> save() async {
    if (state.filePath != null) {
      return _writeFile(state.filePath!);
    }
    return saveAs();
  }

  /// Prompt for a file path and save.
  ///
  /// Starts beside the session being saved when it already has a home
  /// ("Save a copy next to the original" is the common case), else in the
  /// most recent session's folder.
  Future<bool> saveAs() async {
    // Refuse before the panel, not after the user has picked a place.
    if (_refuseSaveWhileLoading('Save As')) return false;
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save Session',
      fileName: state.name,
      allowedExtensions: [kSessionExtension],
      type: FileType.custom,
      initialDirectory: state.folder ?? await RecentSessions.lastDirectory(),
    );
    if (path == null) return false;
    final savePath = path.endsWith('.$kSessionExtension')
        ? path
        : '$path.$kSessionExtension';
    return _writeFile(savePath);
  }

  /// Save to a known [path] without prompting. Used by ADM import, which picks
  /// the location up front; mirrors [saveAs] but skips the file dialog.
  Future<bool> saveToPath(String path) {
    final savePath = path.endsWith('.$kSessionExtension')
        ? path
        : '$path.$kSessionExtension';
    return _writeFile(savePath);
  }

  /// Whether a save must be refused because a session is loading; sets
  /// `lastError` so the user sees why.
  bool _refuseSaveWhileLoading(String target) {
    if (!state.loading) return false;
    Log.w(LogCat.session, 'Save refused while a session is loading: $target');
    state = state.copyWith(
      lastError:
          'The session is still loading. Save again once it has '
          'opened.',
    );
    return true;
  }

  /// Clear the last error.
  void clearError() {
    if (state.lastError != null) {
      state = state.copyWith(clearError: true);
    }
  }

  /// Mark the session as dirty (unsaved changes).
  void markDirty() {
    _editRevision++;
    if (!state.dirty) {
      state = state.copyWith(dirty: true);
    }
  }

  /// Drops the reference to the session's media that failed to load, so
  /// the next save writes no media path, and marks the session dirty.
  /// No effect when no media is missing.
  void clearMissingMedia() {
    if (state.missingMediaPath == null) return;
    state = state.copyWith(clearMissingMedia: true);
    markDirty();
  }

  /// Build a [SessionModel] snapshot from current provider state.
  SessionModel _snapshot() {
    return SessionModel(
      sampleRate: ref.read(transportProvider).sampleRate,
      iamfProfile: ref.read(iamfProfileProvider),
      elements: ref.read(elementsProvider),
      mixes: ref.read(mixesNotifierProvider),
      mediaPath: ref.read(videoProvider).filePath ?? state.missingMediaPath,
      vizState: ref.read(vizStateProvider.notifier).snapshot(),
    );
  }

  /// Write the session to a file.
  Future<bool> _writeFile(String path) async {
    // A snapshot taken mid-load would mix two sessions.
    if (_refuseSaveWhileLoading(path)) return false;
    final generation = _loadGeneration;
    try {
      final revision = _editRevision;
      final session = _snapshot();
      final sessionDir = p.dirname(path);
      // Atomic replace: a failed or interrupted save leaves the previous
      // file intact instead of truncating it (ES-840).
      final mode = await writeStringAtomically(
        path,
        session.encode(relativeTo: sessionDir),
      );
      Log.d(LogCat.session, 'Saved $path (${mode.name})');
      await RecentSessions.add(path, mediaPaths: _mediaPaths(session));
      // Best-effort: bookmark the session folder for grant-free writes into it
      // (exports, beds). Succeeds only when we hold a folder grant — e.g. an
      // ADM import's folder pick; a plain Save-As granted just the .esp file.
      await FolderBookmarks.capture(sessionDir);
      // Close Workspace during the write disposes this notifier; the file
      // is saved, and a disposed ref must not be read.
      if (!ref.mounted) return true;
      ref.read(recentSessionsProvider.notifier).refresh();
      // A load or New Session during the save now owns the state; the
      // file on disk is still the session that was saved.
      if (generation != _loadGeneration) return true;
      // An edit made while the write was pending is not in the file, so
      // the session stays dirty for it (ES-842).
      state = state.copyWith(
        filePath: path,
        name: _nameFromPath(path),
        dirty: _editRevision != revision,
        clearError: true,
      );
      return true;
    } on FileSystemException catch (e) {
      Log.e(LogCat.session, 'Could not save session: $path', e);
      state = state.copyWith(lastError: 'Could not save file: ${e.message}');
      return false;
    }
  }

  /// Apply a loaded session to all providers. Returns false, having
  /// stopped at an await, when a newer load or New Session took over.
  Future<bool> _applySession(
    SessionModel session,
    String path,
    int generation,
  ) async {
    state = state.copyWith(loading: true);
    _halfApplied = true;

    // The loudness report and any pass measuring it belong to the
    // session being replaced; every session's default mix is id 1, so
    // a kept report would put the old figures on the new chips.
    ref.read(loudnessMeasureProvider.notifier).discard();
    ref.read(elementsProvider.notifier).set(session.elements);
    ref
        .read(mixesNotifierProvider.notifier)
        .set(session.mixes.isEmpty ? [kDefaultMix] : session.mixes);
    // Backfill mix settings for any element the session's mixes do not
    // reference (a hand-edited file), so export never emits an empty
    // `sub_mixes.audio_elements` list, which iamf-tools rejects.
    for (final e in session.elements) {
      ref.read(mixesNotifierProvider.notifier).ensureElementSettings(e.id);
    }
    ref.read(iamfProfileProvider.notifier).set(session.iamfProfile);
    ref.read(activeMixProvider.notifier).set(0);
    ref.read(playingProvider.notifier).set(false);
    ref.read(transportProvider.notifier).resetPosition();
    // Loop regions are not persisted; drop the previous session's so
    // it can't hijack return-on-stop in the loaded one (ES-277).
    ref.read(loopRegionProvider.notifier).clear();
    ref.read(vizStateProvider.notifier).apply(session.vizState);

    // Restore the video / still image if saved
    String? missingMediaPath;
    if (session.mediaPath != null) {
      final err = await ref
          .read(videoProvider.notifier)
          .loadFile(session.mediaPath!);
      // Checked before the unload below, which would otherwise cancel
      // the video load of a newer session.
      if (_superseded(generation, path)) return false;
      if (err != null) {
        // A failed load leaves the previous session's media loaded, and
        // a save would write its path into this session (ES-843).
        await ref.read(videoProvider.notifier).unload();
        missingMediaPath = session.mediaPath;
        ref
            .read(importNoticeProvider.notifier)
            .showWarning(err, title: "Couldn't Load Video");
      }
    } else {
      await ref.read(videoProvider.notifier).unload();
    }
    if (_superseded(generation, path)) return false;

    // Re-read WAV info and recalculate timeline duration.
    await _reloadWavInfo(sessionDir: p.dirname(path));
    if (_superseded(generation, path)) return false;
    _recalcDuration();

    // Feed audio elements to the C++ engine for metering.
    _syncElementsToEngine();

    warnOnProfileConflicts(session);

    _halfApplied = false;
    state = SessionState(
      filePath: path,
      name: _nameFromPath(path),
      missingMediaPath: missingMediaPath,
    );
    return true;
  }

  /// ES-490: a hand-edited or tool-generated session (or an older one
  /// after profile-rule changes) can declare a profile its own content
  /// violates — e.g. `"iamfProfile": "base"` with an Object element.
  /// The loader is deliberately lenient and until now the mismatch
  /// surfaced only in the export dialog's validator. Check on load and
  /// surface a non-modal notice naming the conflicts — never blocking
  /// the load — with a one-tap switch to the lowest fitting profile
  /// (the same auto-bump the export dialog computes). Public only for
  /// tests; production callers go through [loadFile].
  @visibleForTesting
  void warnOnProfileConflicts(SessionModel session) {
    final elements = session.elements;
    final mixes = session.mixes.isEmpty ? [kDefaultMix] : session.mixes;
    final conflicts = profileConflicts(
      elements: elements,
      mixes: mixes,
      profile: session.iamfProfile,
    );
    if (conflicts.isEmpty) return;

    final bumpTo = minProfileForSession(elements: elements, mixes: mixes);
    Log.w(
      LogCat.session,
      'Loaded session conflicts with its ${session.iamfProfile.label} '
      'profile: ${conflicts.map((c) => c.shortLabel).join(' · ')}'
      '${bumpTo == null ? '' : ' (fits ${bumpTo.label})'}',
    );
    ref
        .read(importNoticeProvider.notifier)
        .showWarning(
          profileLoadWarning(session.iamfProfile, conflicts),
          title: 'Profile Conflict',
          actionLabel: bumpTo == null ? null : 'Switch to ${bumpTo.label}',
          onAction: bumpTo == null
              ? null
              : () => ref.read(iamfProfileProvider.notifier).set(bumpTo),
        );
  }

  /// Push audio elements to the C++ engine so it can read WAVs
  /// and drive real meter data.
  ///
  /// Mirrors the single-element logic in [_syncElementToEngine] in
  /// `elements_view.dart` — if the protocol changes, update both.
  void _syncElementsToEngine() {
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) {
      Log.d(LogCat.engine, 'Engine is null, skipping element sync');
      return;
    }

    final elements = ref.read(elementsProvider);
    Log.d(LogCat.engine, 'Syncing ${elements.length} elements to engine');

    // Remove old elements from C++ engine before adding new ones.
    final oldOrder = ref.read(engineOrderProvider);
    for (final id in oldOrder) {
      engine.removeElement(id);
    }
    engine.meterReset();
    final engineOrder = <int>[];
    final failed = <String>[];
    for (final e in elements) {
      if (e.wavPath == null) continue;
      // Every caller runs after the WAV headers were (re)read, so a null
      // wavInfo means the file could not be opened and _reloadWavInfo has
      // already raised the notice with the remedy. The engine open would
      // fail the same way; skip it rather than stack a second "Couldn't
      // Load Audio" dialog on top (ES-628).
      if (e.wavInfo == null) {
        Log.d(LogCat.engine, 'Skipping element ${e.id}: WAV not readable');
        continue;
      }
      final rc = engine.addElement(e.id, e.wavPath!);
      Log.d(
        LogCat.engine,
        'addElement(id=${e.id}, '
        'name="${e.name}", '
        'path="${e.wavPath}") -> rc=$rc',
      );
      if (rc != 0) {
        Log.w(
          LogCat.engine,
          'Failed to add element ${e.id} "${e.name}" (rc=$rc)',
        );
        failed.add(p.basename(e.wavPath!));
        continue;
      }
      engineOrder.add(e.id);
      final (oarType, oarSubType, oarCh) = elementToOarType(e);
      engine.setElementType(e.id, oarType, oarSubType, oarCh);
      engine.setElementChannelOrder(e.id, elementChannelOrder(e));
      engine.setElementGain(e.id, e.gain);
      engine.setElementMute(e.id, e.mute);
      engine.setElementSolo(e.id, e.solo);
      engine.setElementInputRouting(e.id, e.inputRouting);
      pushElementObjectPosition(engine, e);
    }
    ref.read(engineOrderProvider.notifier).set(engineOrder);

    if (failed.isNotEmpty) {
      final msg = failed.length == 1
          ? 'Engine failed to load "${failed.first}"'
          : 'Engine failed to load ${failed.length} files: '
                '${failed.join(", ")}';
      ref
          .read(importNoticeProvider.notifier)
          .showWarning(msg, title: "Couldn't Load Audio");
    }

    // Push IAMF mix gains from the active mix presentation into OAR.
    // This ensures that reloading a session preserves the fader state
    // the user had set, and that OAR's metadata matches the Dart model.
    _syncActiveMixGainsToEngine(engine);
    Log.d(LogCat.engine, 'engineOrder set to $engineOrder');
    Log.d(LogCat.engine, 'Synced ${elements.length} elements to engine');
  }

  /// Seed per-element and output mix gains from the active mix
  /// presentation's active sub-mix into OAR at their steady-state
  /// values, bypassing the slew-ramp path. Also stages and commits
  /// the per-element IAMF element_rendering_config for every element
  /// so the OAR instance matches the restored session from frame 0.
  /// Safe to call multiple times. No-op when there is no mix or the
  /// indices are out of range.
  ///
  /// Uses the seed path instead of setElementMixGain/setOutputMixGain so
  /// that opening a session with non-zero persisted mix gains does not
  /// cause an audible dip-and-rise ramp from 0 dB at the first audio
  /// callback after load. Rendering-config pushes are staged and
  /// committed in one rebuild so N elements cost one rebuild.
  void _syncActiveMixGainsToEngine(EclipsaStudioEngine engine) {
    final mixes = ref.read(mixesNotifierProvider);
    final activeMixIdx = ref.read(activeMixProvider);
    if (activeMixIdx < 0 || activeMixIdx >= mixes.length) return;
    final mix = mixes[activeMixIdx];
    final activeSubIdx = ref.read(activeSubMixProvider);
    if (activeSubIdx < 0 || activeSubIdx >= mix.subMixes.length) return;
    final sub = mix.subMixes[activeSubIdx];
    final elements = ref.read(elementsProvider);
    for (final el in elements) {
      final s = sub.settingsFor(el.id);
      engine.setElementMixExcluded(el.id, !s.included);
      engine.seedElementMixGain(el.id, s.mixGain);
      engine.stageElementRenderingConfig(
        el.id,
        s.effectiveHeadphonesMode(el).index,
        s.binauralProfile.index,
      );
    }
    engine.commitRenderingConfig();
    engine.seedOutputMixGain(sub.outputMixGain);
  }

  /// Re-read WAV headers for all elements that have wavPath set.
  ///
  /// Collects the failures, tells no-access apart from not-found, and
  /// pushes one aggregated notice via [importNoticeProvider] with the
  /// matching remedy as its action (ES-628): "Grant Access…" runs the folder
  /// panel so the sandboxed app can read media beside the session;
  /// "Locate…" relinks files one by one. Without this a session whose WAVs
  /// are present but ungranted looked like one whose WAVs were gone.
  ///
  /// Stops without writing when a load or New Session started while the
  /// headers were being read, and returns false then. [sessionDir] is the
  /// folder of the session being loaded; it defaults to the open one.
  Future<bool> _reloadWavInfo({String? sessionDir}) async {
    final generation = _loadGeneration;
    final folder = sessionDir ?? state.folder;
    final elements = ref.read(elementsProvider);
    final noAccess = <String>[];
    final notFound = <String>[];
    final unreadable = <String>[];
    final futures = elements.map((e) async {
      if (e.wavPath == null) return e;
      final path = e.wavPath!;
      final exists = await File(path).exists();
      var rejected = false;
      if (exists) {
        try {
          final info = await WavDecoder.readInfo(path);
          return e.copyWith(wavInfo: info);
        } on FormatException catch (err) {
          // The file opened and the parser refused its content. No folder
          // grant fixes that, so this one must not be sent to the grant
          // panel (which would raise the same notice again, ES-628).
          rejected = true;
          Log.w(LogCat.session, 'WAV rejected by the parser: $path', err);
        } on Exception catch (err) {
          Log.w(LogCat.session, 'Failed to read WAV info for $path', err);
        }
      } else {
        Log.w(LogCat.session, 'Missing WAV file: $path');
      }
      final name = p.basename(path);
      switch (classifyMissingWav(
        path: path,
        sessionDir: folder,
        exists: exists,
        rejected: rejected,
        folderGranted: _folderGranted,
      )) {
        case MissingWavKind.noAccess:
          noAccess.add(name);
        case MissingWavKind.notFound:
          notFound.add(name);
        case MissingWavKind.unreadable:
          unreadable.add(name);
      }
      return e;
    });
    final updated = await Future.wait(futures);
    if (generation != _loadGeneration) return false;
    ref.read(elementsProvider.notifier).set(updated);

    // One notice per load. The access remedy comes first: once the folder
    // is granted (_folderGranted), the reload after it re-runs this, and a
    // file beside the session that is still missing is then classified by
    // its stat, so the Locate… notice follows instead of the grant again.
    if (noAccess.isNotEmpty) {
      ref
          .read(importNoticeProvider.notifier)
          .showWarning(
            '${_countFiles(noAccess.length)} beside this session could not '
            'be opened: ${noAccess.join(", ")}. Eclipsa Studio needs access '
            "to the session's folder to load them.",
            title: 'Audio Files Not Accessible',
            actionLabel: 'Grant Access…',
            onAction: grantSessionFolderAccess,
          );
    } else if (notFound.isNotEmpty) {
      ref
          .read(importNoticeProvider.notifier)
          .showWarning(
            '${_countFiles(notFound.length)} could not be found: '
            '${notFound.join(", ")}.',
            title: 'Missing Audio Files',
            actionLabel: 'Locate…',
            onAction: locateMissingWavs,
          );
    } else if (unreadable.isNotEmpty) {
      ref
          .read(importNoticeProvider.notifier)
          .showWarning(
            '${_countFiles(unreadable.length)} could not be read: '
            '${unreadable.join(", ")}. The file is there, but Eclipsa '
            'Studio could not open it as a WAV.',
            title: 'Audio Files Could Not Be Read',
            actionLabel: 'Locate…',
            onAction: locateMissingWavs,
          );
    }
    return true;
  }

  static String _countFiles(int n) =>
      n == 1 ? '1 audio file' : '$n audio files';

  /// Ask for the session's folder in a folder panel, keep the grant as a
  /// folder bookmark (per machine, across launches), and reload the media.
  /// The panel starts on the session's own folder; picking a parent folder
  /// works too, since a folder grant covers everything below it.
  Future<void> grantSessionFolderAccess() async {
    final dir = state.folder;
    if (dir == null) return;
    final picked = folderPickerForTesting != null
        ? await folderPickerForTesting!(dir)
        : await fs.getDirectoryPath(
            initialDirectory: dir,
            confirmButtonText: 'Grant Access',
          );
    if (picked == null) return;
    // The panel itself grants this process access, bookmark or not; the
    // reload below must not send a file that is simply gone back here.
    _folderGranted = true;
    await FolderBookmarks.capture(picked);
    Log.i(LogCat.session, 'Folder access granted: $picked');
    // Re-reading headers replaces the element list, which the dirty
    // tracker would otherwise take as an edit; nothing persisted changed.
    // A load or New Session during the reload owns the state: leave its
    // `loading` flag and its elements alone.
    final generation = _loadGeneration;
    state = state.copyWith(loading: true);
    try {
      if (!await _reloadWavInfo()) return;
      _recalcDuration();
      _syncElementsToEngine();
    } finally {
      if (generation == _loadGeneration) {
        state = state.copyWith(loading: false);
      }
    }
    if (state.filePath != null) {
      // File bookmarks for the now-readable media, as a save would make.
      await RecentSessions.add(
        state.filePath!,
        mediaPaths: _mediaPaths(_snapshot()),
      );
    }
  }

  /// Run [locateWav] for every element whose WAV failed to load, in element
  /// order, stopping at the first cancelled panel.
  Future<void> locateMissingWavs() async {
    for (final e in ref.read(elementsProvider)) {
      if (e.wavPath == null || e.wavInfo != null) continue;
      if (!await locateWav(e.id)) return;
    }
  }

  /// Ask the user to point at the WAV for element [id] and relink it.
  /// Returns false when the panel was cancelled or the id is unknown.
  Future<bool> locateWav(int id) async {
    final elem = ref.read(elementsProvider).where((e) => e.id == id);
    if (elem.isEmpty) return false;
    final current = elem.first.wavPath;
    final String? picked;
    if (wavPickerForTesting != null) {
      picked = await wavPickerForTesting!(state.folder);
    } else {
      final result = await FilePicker.pickFiles(
        dialogTitle: current == null
            ? 'Locate WAV for ${elem.first.name}'
            : 'Locate ${p.basename(current)}',
        type: FileType.custom,
        allowedExtensions: const ['wav'],
        initialDirectory: state.folder,
      );
      picked = result?.files.single.path;
    }
    if (picked == null) return false;
    return relinkWav(id, picked);
  }

  /// Point element [id] at [newPath], read its header, and mark the session
  /// dirty so the next save stores the new (relative) path. Returns false
  /// (with a notice) when the file cannot be read.
  Future<bool> relinkWav(int id, String newPath) async {
    final elements = ref.read(elementsProvider);
    final idx = elements.indexWhere((e) => e.id == id);
    if (idx < 0) return false;
    final WavInfo info;
    try {
      info = await WavDecoder.readInfo(newPath);
    } on Exception catch (err) {
      Log.w(LogCat.session, 'Relink: cannot read $newPath', err);
      ref
          .read(importNoticeProvider.notifier)
          .showWarning(
            '${p.basename(newPath)} could not be read as a WAV file.',
            title: 'Relink Failed',
          );
      return false;
    }
    // A relink points an element at the file it was made from. A file with
    // a different channel count would leave the element's declared layout
    // describing something the WAV is not — the export validator reports
    // that as ELEMENT_CHANNEL_MISMATCH, and the engine would register the
    // element under the old layout. Replacing an element's content is the
    // WAV swap on its card, which rebuilds the element for the new count.
    final declared = channelCountForLayout(elements[idx]);
    if (declared > 0 && info.channels != declared) {
      Log.w(
        LogCat.session,
        'Relink: ${info.channels} channels but element $id expects $declared',
      );
      ref
          .read(importNoticeProvider.notifier)
          .showWarning(
            '${p.basename(newPath)} has ${info.channels} channels, but '
            '"${elements[idx].name}" is ${elements[idx].layout} '
            '($declared channels). Pick the file this element was made '
            "from, or replace the element's WAV from its card.",
            title: 'Relink Failed',
          );
      return false;
    }
    ref.read(elementsProvider.notifier).set([
      for (final e in elements)
        e.id == id ? e.copyWith(wavPath: newPath, wavInfo: info) : e,
    ]);
    Log.i(LogCat.session, 'Relinked element $id to $newPath');
    markDirty();
    _recalcDuration();
    _syncElementsToEngine();
    if (state.filePath != null) {
      await RecentSessions.add(
        state.filePath!,
        mediaPaths: _mediaPaths(_snapshot()),
      );
    }
    return true;
  }

  /// Recalculate transport duration from loaded elements and video.
  ///
  /// Duration is stored in engine-rate frames (not the longest WAV's
  /// native rate) so the playhead's seek round-trip
  /// engine_frames ⇄ Dart.samplePosition stays exact for mixed-rate
  /// sessions. See _recalcDuration in elements_view.dart for the same
  /// reasoning.
  void _recalcDuration() {
    final audioSeconds = longestAudioSeconds(ref.read(elementsProvider));

    final videoDuration = ref.read(videoProvider).duration;
    final videoSeconds = videoDuration != null
        ? videoDuration.inMilliseconds / 1000.0
        : 0.0;

    final maxSeconds = max(audioSeconds, videoSeconds);
    if (maxSeconds <= 0) return;

    final engine = ref.read(eclipsaStudioEngineProvider);
    final transportRate = engine?.currentSampleRate ?? 48000;
    ref
        .read(transportProvider.notifier)
        .updateDuration((maxSeconds * transportRate).ceil(), transportRate);
  }

  /// Collect all media file paths from a session for bookmarking.
  static List<String> _mediaPaths(SessionModel session) => [
    for (final e in session.elements)
      if (e.wavPath != null) e.wavPath!,
    if (session.mediaPath != null) session.mediaPath!,
  ];

  static String _nameFromPath(String path) {
    return p.basenameWithoutExtension(path);
  }
}

/// Builds the load-time profile-conflict warning (ES-490): the loaded
/// session violates its own declared [profile] in the ways listed by
/// [conflicts]. Top-level and pure so it is unit-testable without a
/// provider container; the conflict messages already name the profile
/// and what would have to change.
String profileLoadWarning(
  IamfProfile profile,
  List<ProfileConflict> conflicts,
) =>
    'This session does not fit its ${profile.label} profile. '
    '${conflicts.map((c) => c.message).join(' ')}';

/// Provider for session state.
final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(
  SessionNotifier.new,
);

/// Cached list of recent session paths for the File menu.
class RecentSessionsNotifier extends Notifier<List<String>> {
  int _generation = 0;

  @override
  List<String> build() {
    refresh();
    return [];
  }

  Future<void> refresh() async {
    final gen = ++_generation;
    final paths = await RecentSessions.load();
    if (gen == _generation) state = paths;
  }
}

final recentSessionsProvider =
    NotifierProvider<RecentSessionsNotifier, List<String>>(
      RecentSessionsNotifier.new,
    );

/// Cached list of recent QC file paths for the Playback landing card.
class RecentQcFilesNotifier extends Notifier<List<String>> {
  int _generation = 0;

  @override
  List<String> build() {
    refresh();
    return [];
  }

  Future<void> refresh() async {
    final gen = ++_generation;
    final paths = await RecentQcFiles.load();
    if (gen == _generation) state = paths;
  }
}

final recentQcFilesProvider =
    NotifierProvider<RecentQcFilesNotifier, List<String>>(
      RecentQcFilesNotifier.new,
    );

/// Why a session's WAV failed to load, which picks the remedy offered.
enum MissingWavKind {
  /// The file is (or is presumed) present but the sandbox refused it:
  /// remedy is a folder grant.
  noAccess,

  /// Nothing at the path: remedy is relinking.
  notFound,

  /// The file opened and the parser refused its content, or it is beside
  /// the session in a granted folder and still would not open: remedy is
  /// relinking, since no grant makes such a file readable.
  unreadable,
}

/// Classifies a WAV that failed to load. On macOS the app is sandboxed and
/// a read needs a security-scoped grant; the open panel grants the `.esp`
/// alone, and the sandbox refuses the stat of an ungranted file as well as
/// the open, so a file beside or below the session (whose folder
/// demonstrably exists) that fails is a grant problem, not a missing file,
/// whatever [exists] says. Once the folder is granted ([folderGranted]: a
/// restored bookmark, or the folder panel confirmed) the stat is reliable
/// again, so such a file is not found when absent and unreadable when
/// present, never a grant problem, or the grant would be offered in a loop
/// it cannot end. Elsewhere, a file that stats as present but fails to open
/// is also a grant problem; one that does not stat is treated as not found
/// (the sandbox can refuse the stat too, so Locate… stays available for
/// that case). Without a sandbox every failure is not-found. [rejected] —
/// the parser opened the file and refused its content — outranks all of
/// that: a grant cannot fix it. [isMacOS] is a parameter for tests.
@visibleForTesting
MissingWavKind classifyMissingWav({
  required String path,
  required String? sessionDir,
  required bool exists,
  bool rejected = false,
  bool folderGranted = false,
  bool? isMacOS,
}) {
  if (rejected) return MissingWavKind.unreadable;
  final mac = isMacOS ?? Platform.isMacOS;
  if (!mac) return MissingWavKind.notFound;
  if (sessionDir != null && p.isWithin(sessionDir, path)) {
    if (!folderGranted) return MissingWavKind.noAccess;
    return exists ? MissingWavKind.unreadable : MissingWavKind.notFound;
  }
  return exists ? MissingWavKind.noAccess : MissingWavKind.notFound;
}
