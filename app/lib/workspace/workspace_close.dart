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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/log.dart';
import '../session/session_provider.dart';
import '../state.dart'
    show loopRegionProvider, playingProvider, transportProvider;
import '../theme.dart';
import '../video/video_provider.dart';
import '../widgets/app_button.dart';
import '../widgets/app_dialog.dart';
import 'workspace_mode.dart';

/// Identity of the unsaved-changes prompt for the [showAppDialog]
/// single-instance guard. The prompt is built inline, so there is no
/// widget `Type` to pass.
const _unsavedChangesDialog = #unsavedChanges;

/// Close the current workspace and return to the landing screen.
///
/// In Creator mode, prompts to save unsaved changes before closing.
/// Playback is read-only so it never prompts.
///
/// Returns `true` if the workspace was closed, `false` if the user
/// cancelled at the unsaved-changes prompt.
Future<bool> closeWorkspace(BuildContext context, WidgetRef ref) async {
  if (!await confirmDiscardIfDirty(context, ref)) return false;
  ref.read(workspaceModeProvider.notifier).returnToLanding();
  return true;
}

/// Prepare the engine + provider state to switch into a different
/// workspace. Returns `false` if the user cancels at the unsaved-
/// changes prompt; callers must abort the open-flow in that case.
///
/// Behaviour matrix (current → target):
/// - `creator → creator`:  dirty-prompt; load path overwrites in-place.
/// - `creator → playback`: dirty-prompt; tear down creator engine state.
/// - `playback → creator`: tear down playback engine state.
/// - `playback → playback`: tear down playback engine state (must
///   close the open session before opening another).
/// - `none → *`:           nothing to do.
///
/// Does **not** change the workspace mode itself — the caller's open
/// path is still expected to call [WorkspaceModeNotifier.enterCreator]
/// or [enterPlayback] after the new workspace is ready.
Future<bool> prepareForWorkspaceSwitch(
  BuildContext context,
  WidgetRef ref, {
  required WorkspaceMode target,
}) async {
  final current = ref.read(workspaceModeProvider);

  if (current == WorkspaceMode.creator) {
    if (!await confirmDiscardIfDirty(context, ref)) return false;
  }

  // Same-mode Creator reopen: the load path's _applySession +
  // _syncElementsToEngine handles its own engine cleanup. Skip
  // teardown here to avoid an unnecessary remove-then-readd pass.
  if (current == WorkspaceMode.creator && target == WorkspaceMode.creator) {
    return true;
  }

  // A Creator session load still running would keep writing Creator
  // state into the next workspace.
  ref.read(sessionProvider.notifier).cancelLoad();

  // All other transitions need engine teardown for the source mode,
  // including playback → playback (must close before reopen).
  ref.read(workspaceModeProvider.notifier).teardownEngineForCurrentMode();

  // Reset the transport, mirroring `returnToLanding`. Without this the
  // next workspace inherits the source mode's playhead and "playing"
  // flag: the tick loop's stuck-detector then logs a false "device may
  // be hung" ERROR during the gap, and the stale position trips an
  // out-of-range clamp on the next open (issue ES-229). The engine-side
  // counter is zeroed in `teardownEngineForCurrentMode`.
  //
  // Crucially this runs BEFORE the awaited `unload()` below: with the
  // video player now reused (not recreated), clearing `playing` first
  // makes the 60 Hz tick take its paused branch, so its `syncToAudio`
  // can't drive seek/play on the player while `unload()` is tearing it
  // down across an await gap.
  ref.invalidate(transportProvider);
  ref.invalidate(playingProvider);
  // The loop region is set in sample positions of the source mode's
  // timeline; the tick loop and the scrub bar would act on it against
  // the next workspace's duration (ES-783). clear() also disarms the loop
  // toggle, as the session paths do.
  ref.read(loopRegionProvider.notifier).clear();

  // Clear the shared video's content — but do NOT invalidate the
  // provider. `videoProvider` owns a process-lifetime VideoBackend.
  // Recreating that Notifier mid-switch (the earlier ES-226/ES-227 approach)
  // strands consumers on the disposed instance: VideoTransportSync kept
  // calling play() on the old, shut-down notifier, so the next file
  // decoded but never started (ES-226 follow-up — the reported "video 2
  // didn't start"). Reuse one stable player and swap its media instead;
  // unload() stops playback and clears the picture, and the next
  // loadFile opens the new file on the same player/texture. The
  // creator → creator reopen path returns above, so its session-restore
  // video handling is untouched.
  //
  // Guarded: the engine is already torn down by this point, so a throw
  // here (the fullscreen exit, the player's stop) must not abort the
  // switch and leave the workspace with no engine and no new file. The
  // next loadFile opens its media on the same player either way (ES-235).
  try {
    await ref.read(videoProvider.notifier).unload();
  } catch (e) {
    Log.w(LogCat.video, 'unload during workspace switch failed', e);
  }
  return true;
}

/// Show a save-changes dialog if the current Creator session is dirty.
/// Returns `true` if it's safe to proceed (saved, discarded, or
/// nothing to do), `false` if the user cancelled.
///
/// No-ops in Playback or on the landing screen, since neither has a
/// Dart-side session model that can be dirty.
///
/// The prompt is the direct target of Cmd+N, Cmd+O and Cmd+W, which
/// the macOS menu bar keeps live under a modal route, and the session
/// is still dirty while it is up. It is guarded by id (ES-682), so a
/// repeat press leaves the open prompt alone and returns `false`,
/// abandoning its own switch rather than stacking a second prompt.
Future<bool> confirmDiscardIfDirty(BuildContext context, WidgetRef ref) async {
  final mode = ref.read(workspaceModeProvider);
  if (mode != WorkspaceMode.creator) return true;
  final session = ref.read(sessionProvider);
  if (!session.dirty) return true;

  final action = await showAppDialog<String>(
    context: context,
    id: _unsavedChangesDialog,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.bgElevated,
      title: Text('Unsaved Changes', style: T.styleTitle),
      content: Text(
        'Save changes to "${session.name}" before continuing?',
        style: TextStyle(color: T.textSecondary, fontSize: T.fontHeading),
      ),
      actions: [
        AppButton(
          label: 'Discard',
          role: AppButtonRole.destructive,
          onPressed: () => Navigator.pop(ctx, 'discard'),
        ),
        AppButton(
          label: 'Cancel',
          role: AppButtonRole.quiet,
          onPressed: () => Navigator.pop(ctx, 'cancel'),
        ),
        AppButton(
          label: 'Save',
          role: AppButtonRole.affirmative,
          onPressed: () => Navigator.pop(ctx, 'save'),
        ),
      ],
    ),
  );
  if (action == 'cancel' || action == null) return false;
  if (action == 'save') {
    final saved = await ref.read(sessionProvider.notifier).save();
    if (!saved) return false;
  }
  return true;
}

/// Set once an exit is certain after the unsaved-changes question was
/// answered. Closing the main window on macOS asks, then sends the app's
/// terminate request, which runs [confirmExit] again; this keeps the
/// second call from asking twice. Set only at the point of no return
/// ([markExitConfirmed]), so an exit that stops after the question
/// cannot leave it set for a later exit with new edits.
class ExitConfirmedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void confirm() => state = true;
}

final exitConfirmedProvider = NotifierProvider<ExitConfirmedNotifier, bool>(
  ExitConfirmedNotifier.new,
);

/// Whether [confirmExit] would show the unsaved-changes prompt now: a
/// dirty Creator session whose exit is not yet confirmed.
bool exitWouldPrompt(WidgetRef ref) =>
    !ref.read(exitConfirmedProvider) &&
    ref.read(workspaceModeProvider) == WorkspaceMode.creator &&
    ref.read(sessionProvider).dirty;

/// Asks about unsaved changes before the app closes or quits: the window
/// close button and the macOS Quit command (the app menu, Cmd+Q, the
/// Dock) both call it. Returns true without asking once
/// [markExitConfirmed] has run. Returns false when the user cancels, or
/// when a Save they chose did not complete; the exit must then stop.
Future<bool> confirmExit(BuildContext context, WidgetRef ref) async {
  if (ref.read(exitConfirmedProvider)) return true;
  return confirmDiscardIfDirty(context, ref);
}

/// Records that the exit is going ahead, so the terminate request a
/// window close sends on macOS does not ask again. Call it immediately
/// before the window closes, after anything that could still stop it.
void markExitConfirmed(WidgetRef ref) =>
    ref.read(exitConfirmedProvider.notifier).confirm();
