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

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../renderer/viz_state.dart';
import '../state.dart';
import '../video/video_provider.dart';
import 'session_provider.dart';

/// Invisible widget that marks the session dirty when state changes.
///
/// Suppressed while [SessionState.loading] is true (during new/open).
/// Place once in the widget tree (e.g., in [AppShell]).
class DirtyTracker extends ConsumerStatefulWidget {
  const DirtyTracker({super.key});

  @override
  ConsumerState<DirtyTracker> createState() => _DirtyTrackerState();
}

class _DirtyTrackerState extends ConsumerState<DirtyTracker> {
  void _onStateChanged() {
    final session = ref.read(sessionProvider);
    if (!session.loading) {
      ref.read(sessionProvider.notifier).markDirty();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(elementsProvider, (p, n) => _onStateChanged());
    ref.listen(mixesNotifierProvider, (p, n) => _onStateChanged());
    ref.listen(iamfProfileProvider, (p, n) => _onStateChanged());
    ref.listen(vizStateProvider, (p, n) => _onStateChanged());
    // Only the loaded file path is persisted to the session; the rest of
    // VideoState (visibility, mode, duration, resolution) is transient UI
    // that changes during playback and must not dirty the session. Select
    // filePath so add/replace/remove video marks dirty, nothing else does.
    ref.listen(
      videoProvider.select((v) => v.filePath),
      (p, n) => _onStateChanged(),
    );

    return const SizedBox.shrink();
  }
}
