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

/// Batch / replace WAV-import planning (ES-432).
///
/// The decision flow that used to live inline in `elements_view.dart`'s
/// drop handlers — which files need a format prompt, the sticky
/// "apply to remaining N-channel files" map, cancel-aborts-the-batch,
/// and the mid-batch profile bump — extracted here so it is
/// unit-testable without widgets. The view supplies [FormatPrompt],
/// normally a closure over `showElementFormatDialog`.
library;

import '../models/audio_element_enums.dart';
import '../state.dart';
import '../waveform/wav_decoder.dart';
import '../widgets/element_format_dialog.dart';

/// Presents one format choice for [path] and returns the user's
/// pick, or null when cancelled (or the presenting widget unmounted).
typedef FormatPrompt =
    Future<ElementFormatChoice?> Function({
      required String path,
      required WavInfo info,
      required IamfProfile profile,
      required int remainingSameCount,
    });

/// Outcome of [planWavBatch]: per-file config overrides for the
/// ambiguous files, plus the (possibly user-bumped) profile the
/// import should run under.
class WavBatchPlan {
  const WavBatchPlan({required this.overrides, required this.profile});

  final Map<String, ElementConfig> overrides;
  final IamfProfile profile;
}

/// Resolve every ambiguous channel count in a batch before anything
/// imports (ES-152): one prompt per ambiguous file, in [paths] order,
/// where a choice marked apply-to-remaining becomes sticky for that
/// channel count. Returns null when any prompt is cancelled — the
/// whole batch aborts, and callers must not have imported anything
/// yet.
///
/// [headers] holds the decodable files' WAV info; files without an
/// entry are never prompted (the import loop re-decodes them and
/// surfaces the standard per-file error). Ambiguity is judged against
/// the *starting* [profile] for the whole batch, matching the
/// import's one-profile-per-batch snapshot; a confirmed bump
/// ([ElementFormatChoice.bumpTo], offered only when [allowProfileBump])
/// re-parameterizes later prompts and is returned on the plan, but
/// persisting it is the caller's job — after the last prompt, so a
/// cancel leaves the session untouched.
Future<WavBatchPlan?> planWavBatch({
  required List<String> paths,
  required Map<String, WavInfo> headers,
  required IamfProfile profile,
  required bool allowProfileBump,
  required FormatPrompt prompt,
}) async {
  final ambiguous = [
    for (final path in paths)
      if (headers[path] != null &&
          elementFormatDialogWouldShow(
            profile,
            headers[path]!.channels,
            allowProfileBump: allowProfileBump,
          ))
        path,
  ];
  final overrides = <String, ElementConfig>{};
  final sticky = <int, ElementConfig>{};
  var effective = profile;
  for (var i = 0; i < ambiguous.length; i++) {
    final path = ambiguous[i];
    final info = headers[path]!;
    final stuck = sticky[info.channels];
    if (stuck != null) {
      overrides[path] = stuck;
      continue;
    }
    final remaining = ambiguous
        .skip(i + 1)
        .where((q) => headers[q]!.channels == info.channels)
        .length;
    final choice = await prompt(
      path: path,
      info: info,
      profile: effective,
      remainingSameCount: remaining,
    );
    if (choice == null) return null; // Cancelled — abort the whole batch.
    if (choice.bumpTo != null) effective = choice.bumpTo!;
    overrides[path] = choice.config;
    if (choice.applyToRemaining) sticky[info.channels] = choice.config;
  }
  return WavBatchPlan(overrides: overrides, profile: effective);
}

/// Outcome of [planWavReplace].
class WavReplacePlan {
  const WavReplacePlan.proceed([this.override]) : aborted = false;
  const WavReplacePlan.abort() : aborted = true, override = null;

  /// True when the user cancelled the prompt — keep the element as-is.
  final bool aborted;

  /// Config override for the replacement, when a choice was made.
  final ElementConfig? override;
}

/// Decide whether dropping [newInfo] onto an element with
/// [currentChannels] source channels needs a format choice (ES-152).
/// Only a different channel count re-types the element from the WAV;
/// same-count swaps, empty slots, and undecodable files
/// ([newInfo] == null — the assignment re-decodes and reports)
/// proceed unprompted with the existing config.
Future<WavReplacePlan> planWavReplace({
  required String path,
  required WavInfo? newInfo,
  required int? currentChannels,
  required IamfProfile profile,
  required FormatPrompt prompt,
}) async {
  if (newInfo == null ||
      currentChannels == null ||
      currentChannels == newInfo.channels) {
    return const WavReplacePlan.proceed();
  }
  final choice = await prompt(
    path: path,
    info: newInfo,
    profile: profile,
    remainingSameCount: 0,
  );
  if (choice == null) return const WavReplacePlan.abort();
  return WavReplacePlan.proceed(choice.config);
}
