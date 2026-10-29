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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/log.dart';
import '../loudness/loudness_measure_runner.dart';
import '../loudness/qc_loudness_report_provider.dart';
import '../meters/meter_provider.dart'
    show eclipsaStudioEngineProvider, engineLoadProvider;
import '../playback/playback_session.dart';
import '../session/session_provider.dart';
import '../state.dart';
import '../video/video_provider.dart';

/// Which kind of workspace is currently loaded.
///
/// * [none] — no workspace; the landing screen is shown.
/// * [creator] — WAV-based authoring (the historical ES workspace).
/// * [playback] — IAMF-based QC playback (source is read-only).
enum WorkspaceMode { none, creator, playback }

class WorkspaceModeNotifier extends Notifier<WorkspaceMode> {
  @override
  WorkspaceMode build() => WorkspaceMode.none;

  void enterCreator() => state = WorkspaceMode.creator;

  void enterPlayback() => state = WorkspaceMode.playback;

  /// Tear down the engine-side state of the current workspace.
  /// Used both by [returnToLanding] and by mid-session mode switches
  /// initiated from the File menu, so a follow-up open call sees the
  /// engine in a clean state. Safe to call when [state] is [none].
  void teardownEngineForCurrentMode() {
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) return;
    switch (state) {
      case WorkspaceMode.playback:
        // A QC Loudness Report pass measures this file; neither it nor
        // its report applies after the switch.
        ref.read(qcLoudnessMeasureProvider.notifier).discard();
        // Pause first so any in-flight process() call finishes before
        // close_iamf releases the session backing the ring sources.
        try {
          engine.transportPause();
          // Reset the engine playhead. The audio-thread frame counter
          // is not cleared by playback_close/open, so without this the
          // next QC open inherits this file's position — surfacing as a
          // spurious "device may be hung" ERROR during the close→reopen
          // gap and an out-of-range clamp once the new duration lands
          // (issue ES-229). A lock-free atomic store; safe pre-close.
          engine.transportSeek(0);
          engine.playbackClose();
        } on Object catch (e) {
          Log.w(LogCat.app, 'playbackClose teardown failed: $e');
        }
      case WorkspaceMode.creator:
        // Pause and zero the engine playhead, same as the playback
        // branch: the audio-thread frame counter is process-lifetime
        // and is not reset by mode switches, so without this a
        // creator → QC open inherits the creator session's position
        // (ES-229, creator source) and the new file can land past its
        // own end. Lock-free atomic stores; safe here.
        engine.transportPause();
        engine.transportSeek(0);
        // A Loudness Report pass measures this session's elements and
        // writes into its mixes; neither exists after the switch.
        ref.read(loudnessMeasureProvider.notifier).discard();
        // Remove every Creator element registered in OAR. Without
        // this, switching directly to Playback (or to a fresh
        // Creator session that fails to load) would leave stale
        // element registrations in the engine.
        final order = ref.read(engineOrderProvider);
        for (final id in order) {
          engine.removeElement(id);
        }
        engine.meterReset();
        ref.read(engineOrderProvider.notifier).set([]);
      case WorkspaceMode.none:
        break;
    }
  }

  /// Dispose workspace-scoped providers and return to the landing
  /// screen. The engine singleton (device, monitoring config) stays
  /// warm so the user's listening setup persists across mode switches.
  ///
  /// Callers that might have unsaved Creator edits are responsible
  /// for running a dirty-state / "Save changes?" confirmation *before*
  /// invoking this; see `closeWorkspace` in `workspace_close.dart`.
  void returnToLanding() {
    teardownEngineForCurrentMode();
    ref.invalidate(sessionProvider);
    ref.invalidate(elementsProvider);
    ref.invalidate(mixesNotifierProvider);
    // Clear the shared video's content — but do NOT invalidate the
    // provider. `videoProvider` wraps a process-lifetime video
    // backend; invalidating disposes the Notifier
    // (shutDown=true) and strands its consumers. Even though the landing
    // hub unmounts the workspace, the still-mounted shell rebuilds and
    // re-reads videoProvider during the invalidate, so VideoTransportSync
    // ends up calling play() on the shut-down instance — the next QC file
    // then decodes but never starts (the ES-226 stranded-notifier bug, via
    // the Close-Workspace path ES-232 left uncovered). Reuse the one stable
    // player and just unload() its media, exactly as
    // `prepareForWorkspaceSwitch` does. Fire-and-forget: this is a void
    // sync method and the next open's loadFile stop()s the player anyway.
    unawaited(ref.read(videoProvider.notifier).unload());
    ref.invalidate(peakCacheProvider);
    ref.invalidate(transportProvider);
    ref.invalidate(playingProvider);
    ref.read(loopRegionProvider.notifier).clear();
    ref.invalidate(playbackSessionProvider);
    state = WorkspaceMode.none;
  }
}

final workspaceModeProvider =
    NotifierProvider<WorkspaceModeNotifier, WorkspaceMode>(
      WorkspaceModeNotifier.new,
    );

/// Whether the landing screen shows: no workspace is open and the
/// engine loaded. Without the engine a diagnostic screen takes the
/// whole window instead. The root of the app picks the screen by it,
/// and the titlebar and menu bar take the landing ground by it, so the
/// three cannot disagree.
final landingVisibleProvider = Provider<bool>(
  (ref) =>
      ref.watch(engineLoadProvider).engine != null &&
      ref.watch(workspaceModeProvider) == WorkspaceMode.none,
);
