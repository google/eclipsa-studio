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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ffi_bridge.dart' show PlaybackAe;
import '../logging/log.dart';
import '../meters/db_utils.dart';
import '../meters/meter_provider.dart' show eclipsaStudioEngineProvider;
import '../state.dart' show monitoringConfigProvider;
import 'iamf_probe.dart';

/// What applying a mix presentation to the engine means, computed
/// purely so it is unit-testable without an engine.
class MixApplication {
  const MixApplication({
    required this.gainsByElementId,
    required this.excludedElementIds,
    required this.approximatedElementIds,
  });

  /// Applied per-element gain in dB: the element's `default_mix_gain`
  /// plus its sub-mix's `output_mix_gain`, folded so multi-sub-mix
  /// presentations work through the single per-element gain channel.
  final Map<int, double> gainsByElementId;

  /// Session AEs the presentation does not include — gated via
  /// mix-exclude (the engine's mute-gain path, click-free).
  final Set<int> excludedElementIds;

  /// Elements whose applied constant gain may be an approximation:
  /// their gain (or their sub-mix's output gain) has
  /// `param_definition_mode` 0, implying stream-carried time-varying
  /// values the app cannot read (iamf-tools#23 and iamf-tools#24).
  final Set<int> approximatedElementIds;
}

/// Compute the engine application of [mix] for a session whose decoded
/// audio elements are [sessionElementIds]. Falls back to the
/// first-sub-mix convenience list when [mix] has no enriched sub-mixes
/// (defensive — enrichment always synthesizes at least one).
MixApplication computeMixApplication(
  IamfMixPresentation mix,
  Iterable<int> sessionElementIds,
) {
  final gains = <int, double>{};
  final approx = <int>{};
  if (mix.subMixes.isEmpty) {
    for (final el in mix.elements) {
      gains[el.audioElementId] = el.defaultGainDb;
      if (el.paramDefinitionMode == 0) approx.add(el.audioElementId);
    }
  } else {
    for (final sm in mix.subMixes) {
      for (final el in sm.elements) {
        gains[el.audioElementId] = el.defaultGainDb + sm.outputMixGainDb;
        if (el.paramDefinitionMode == 0 ||
            sm.outputGainParamDefinitionMode == 0) {
          approx.add(el.audioElementId);
        }
      }
    }
  }
  return MixApplication(
    gainsByElementId: gains,
    excludedElementIds: {
      for (final id in sessionElementIds)
        if (!gains.containsKey(id)) id,
    },
    approximatedElementIds: approx,
  );
}

/// IAMF spec value for a probe `headphones_rendering_mode` string
/// (0 = stereo, 1 = binaural world-locked, 2 = binaural head-locked),
/// or null for reserved/unknown strings.
int? headphonesModeSpecValue(String? s) => switch (s) {
  'stereo' => 0,
  'binaural_world_locked' => 1,
  'binaural_head_locked' => 2,
  _ => null,
};

/// IAMF spec value for a probe `binaural_filter_profile` string
/// (0 = ambient, 1 = direct, 2 = reverberant), or null for
/// reserved/unknown strings.
int? binauralProfileSpecValue(String? s) => switch (s) {
  'ambient' => 0,
  'direct' => 1,
  'reverberant' => 2,
  _ => null,
};

/// Per-element IAMF element_rendering_config carried by [mix], as the
/// spec integers the engine FFI takes. Pure, so it is unit-testable.
///
/// Only elements whose reference carries a rendering config in the full
/// probe are returned — with no entry the engine keeps OAR's default
/// (binaural world-locked), matching pre-ES-327 behaviour for files probed
/// without enrichment. A present-but-reserved mode string falls back to
/// world-locked (1) and a reserved profile to ambient (0): staging the
/// spec-safe default beats leaving a stale value from the previous
/// presentation. Multi-sub-mix folding matches [computeMixApplication]:
/// later sub-mixes win when a file references one AE twice.
Map<int, ({int mode, int profile})> computeRenderingConfigs(
  IamfMixPresentation mix,
) {
  final configs = <int, ({int mode, int profile})>{};
  for (final sm in mix.subMixes) {
    for (final el in sm.elements) {
      if (el.headphonesRenderingMode == null) continue;
      configs[el.audioElementId] = (
        mode: headphonesModeSpecValue(el.headphonesRenderingMode) ?? 1,
        profile: binauralProfileSpecValue(el.binauralFilterProfile) ?? 0,
      );
    }
  }
  return configs;
}

/// Per-element linear rescale factors for the Dart-side scene/meter
/// levels, aligned with [sessionElementIds] order. The engine applies
/// [mix]'s gains (per-element gain + folded sub-mix output gain, the
/// same folding as [computeMixApplication]) at the mix-bus sum — after
/// the per-element meter tap — so the UI folds them into the levels it
/// shows to reflect the presentation's balance. Elements the
/// presentation excludes get 1.0; the engine gates them to silence
/// anyway. A null [mix] (no presentations in the file) means no
/// rescale at all.
List<double> computeMixMeterScales(
  IamfMixPresentation? mix,
  List<int> sessionElementIds,
) {
  if (mix == null) return List.filled(sessionElementIds.length, 1.0);
  final gains = computeMixApplication(mix, sessionElementIds).gainsByElementId;
  return [
    for (final id in sessionElementIds) DbUtils.dbToLinear(gains[id] ?? 0.0),
  ];
}

/// Value for the renderer view's read-only OUTPUT MIX GAIN readout in
/// Playback (ES-293), extracted from the widget so the branches are
/// unit-testable. `show` is false when there is no session, no active
/// presentation, or the presentation carries no sub-mixes. `gainDb` is
/// null — rendered as an em dash — when the presentation's sub-mixes
/// disagree on their output gain, since no single number is honest
/// then (single-sub-mix files, the common case, always agree).
({bool show, double? gainDb}) playbackOutputMixGainReadout(
  PlaybackSession? session,
) {
  final mps = session?.report.mixPresentations ?? const [];
  final idx = session?.activeMixIndex ?? -1;
  if (idx < 0 || idx >= mps.length) return (show: false, gainDb: null);
  final subs = mps[idx].subMixes;
  if (subs.isEmpty) return (show: false, gainDb: null);
  final first = subs.first.outputMixGainDb;
  final agree = subs.every((s) => s.outputMixGainDb == first);
  return (show: true, gainDb: agree ? first : null);
}

/// State held for the currently-open Playback (QC) file.
///
/// Lives for the duration of a single Playback workspace. Cleared when
/// the user returns to landing via `workspaceModeProvider.returnToLanding`.
class PlaybackSession {
  const PlaybackSession({
    required this.path,
    required this.report,
    required this.activeMixIndex,
    required this.sampleRate,
    required this.totalFrames,
    required this.audioElements,
    this.soloedAeIds = const {},
    this.mutedAeIds = const {},
  });

  final String path;
  final IamfProbeReport report;

  /// Index into `report.mixPresentations`. Selecting a presentation
  /// gates the audio elements it does not include (mix-exclude) and
  /// applies its per-element + sub-mix output gains; index 0 is
  /// treated as the decoder's default presentation, where the stream's
  /// per-TU `mix_gain_db` stays authoritative. `-1` when the file
  /// carries no mix presentations. Note this does *not* drive OAR's
  /// output layout — OAR renders to the selected monitoring target, not
  /// the file's native layout (see [PlaybackSessionNotifier.open]).
  final int activeMixIndex;

  /// Stream info from the engine's IAMF session. `sampleRate` and
  /// `totalFrames` come from
  /// `IamfStreamInterface::GetSampleRate / GetTotalSamples`; the
  /// descriptor list carries per-AE fields sized and labelled by the
  /// streaming decoder (not the probe), which is what the audio path
  /// actually consumes.
  final int sampleRate;
  final int totalFrames;
  final List<PlaybackAe> audioElements;

  /// Monitoring-only solo/mute, keyed by audio element id. Applied by
  /// the engine as a per-chain mute-gain on the monitoring path — it
  /// never touches IAMF metadata or export. Ephemeral by design:
  /// Playback has no session file, so this state lives in memory only
  /// and resets when the file is closed.
  final Set<int> soloedAeIds;
  final Set<int> mutedAeIds;

  PlaybackSession copyWith({
    int? activeMixIndex,
    int? totalFrames,
    Set<int>? soloedAeIds,
    Set<int>? mutedAeIds,
  }) => PlaybackSession(
    path: path,
    report: report,
    activeMixIndex: activeMixIndex ?? this.activeMixIndex,
    sampleRate: sampleRate,
    totalFrames: totalFrames ?? this.totalFrames,
    audioElements: audioElements,
    soloedAeIds: soloedAeIds ?? this.soloedAeIds,
    mutedAeIds: mutedAeIds ?? this.mutedAeIds,
  );
}

class PlaybackSessionNotifier extends Notifier<PlaybackSession?> {
  @override
  PlaybackSession? build() => null;

  /// Register an opened session. Called after the engine's
  /// `eclipsa_studio_playback_open` succeeds and the probe + gate have
  /// validated the file; see `_openQcPath` in `landing_screen.dart`.
  /// Also re-asserts the selected monitoring target on the engine
  /// (playback_open re-inits OAR to a default) and seeds mix[0]'s gains.
  void open({
    required String path,
    required IamfProbeReport report,
    required int sampleRate,
    required int totalFrames,
    required List<PlaybackAe> audioElements,
  }) {
    final activeIndex = report.mixPresentations.isEmpty ? -1 : 0;
    state = PlaybackSession(
      path: path,
      report: report,
      activeMixIndex: activeIndex,
      sampleRate: sampleRate,
      totalFrames: totalFrames,
      audioElements: audioElements,
    );
    if (activeIndex >= 0) {
      _applyMixToEngine(
        report.mixPresentations[activeIndex],
        isDefault: activeIndex == 0,
      );
    }
  }

  void setActiveMix(int index) {
    final s = state;
    if (s == null) return;
    if (index < 0 || index >= s.report.mixPresentations.length) return;
    if (index == s.activeMixIndex) return;
    state = s.copyWith(activeMixIndex: index);
    _applyMixToEngine(s.report.mixPresentations[index], isDefault: index == 0);
  }

  void clear() => state = null;

  /// Set monitoring-only solo for one audio element, mirrored to the
  /// engine through the same setter Creator mode uses. The engine
  /// keeps its chains across pause/seek and `setActiveMix`, so the
  /// state survives those; a fresh `open` (new session, chains rebuilt
  /// unmuted) starts clean again. Never persisted, never exported.
  void setAeSolo(int aeId, bool solo) {
    final s = state;
    if (s == null) return;
    final ids = {...s.soloedAeIds};
    final changed = solo ? ids.add(aeId) : ids.remove(aeId);
    if (!changed) return;
    state = s.copyWith(soloedAeIds: ids);
    ref.read(eclipsaStudioEngineProvider)?.setElementSolo(aeId, solo);
  }

  /// Monitoring-only mute counterpart of [setAeSolo].
  void setAeMute(int aeId, bool mute) {
    final s = state;
    if (s == null) return;
    final ids = {...s.mutedAeIds};
    final changed = mute ? ids.add(aeId) : ids.remove(aeId);
    if (!changed) return;
    state = s.copyWith(mutedAeIds: ids);
    ref.read(eclipsaStudioEngineProvider)?.setElementMute(aeId, mute);
  }

  /// Update `totalFrames` once the upstream lazy temporal-unit scan
  /// publishes the real duration. Returns true if the value changed.
  bool updateTotalFrames(int totalFrames) {
    final s = state;
    if (s == null) return false;
    if (s.totalFrames == totalFrames) return false;
    state = s.copyWith(totalFrames: totalFrames);
    return true;
  }

  void _applyMixToEngine(IamfMixPresentation mix, {required bool isDefault}) {
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) return;
    // playback_open re-inits OAR to a default layout, so re-assert the
    // user's selected monitoring target. In Playback, OAR renders the
    // decoded elements to whichever output target is selected (driven by
    // monitoringConfig, exactly like Creator) — it must NOT switch to the
    // file's native layout, or the renderer-view output-target selector
    // would disagree with what OAR is actually rendering (ES-105).
    final target = ref.read(monitoringConfigProvider).layout;
    if (!engine.setLayout(target.oarValue)) {
      Log.w(
        LogCat.engine,
        'setLayout(${target.label}) failed for mix "${mix.name ?? mix.id}"',
      );
    }

    final sessionAeIds = [
      for (final ae in state?.audioElements ?? const <PlaybackAe>[])
        ae.audioElementId,
    ];
    final app = computeMixApplication(mix, sessionAeIds);

    // Flip the stream-gain gate BEFORE writing gains: for a
    // non-default selection, an audio callback landing between the
    // gain writes and a later gate flip would overwrite them with the
    // stream's default-presentation values — and the disabled gate
    // would then freeze the clobbered gains. For the default
    // presentation the order is irrelevant (the stream fan-out
    // re-asserts its values every callback). ES-287, iamf-tools#23.
    engine.playbackUseStreamGains(isDefault);
    // Gains before exclusions, so a re-included element ramps in at
    // its correct level rather than the previous presentation's value.
    app.gainsByElementId.forEach(engine.setElementMixGain);
    for (final id in sessionAeIds) {
      engine.setElementMixExcluded(id, app.excludedElementIds.contains(id));
    }
    // Sub-mix output gains are folded into the per-element values (so
    // multi-sub-mix presentations work through the single per-element
    // gain channel); keep the graph-level output gain at unity.
    engine.setOutputMixGain(0);

    // Per-reference IAMF element_rendering_config from the file's
    // descriptors (ES-327). Without this push OAR keeps its world-locked
    // default, so a mode-0 (already-stereo/binaural) bed monitored on
    // the Binaural target is re-binauralized as two virtual speakers
    // instead of taking OAR's stereo passthrough. Stage all, commit
    // once (a commit is one OAR rebuild). AEs the engine skipped at
    // registration (e.g. object-based) just log an unknown-id warning
    // in OarRenderer and are ignored.
    final rendering = computeRenderingConfigs(mix);
    rendering.forEach(
      (id, rc) => engine.stageElementRenderingConfig(id, rc.mode, rc.profile),
    );
    if (rendering.isNotEmpty) engine.commitRenderingConfig();

    Log.i(
      LogCat.engine,
      'active mix → ${mix.name ?? "#${mix.id}"} '
      '(target=${target.label}, ${app.gainsByElementId.length} gains, '
      '${app.excludedElementIds.length} gated, '
      '${rendering.length} rendering configs, '
      'streamGains=$isDefault)',
    );
    if (!isDefault && app.approximatedElementIds.isNotEmpty) {
      Log.w(
        LogCat.engine,
        'mix "${mix.name ?? mix.id}" carries time-varying gain '
        '(param mode 0) for AEs ${app.approximatedElementIds.toList()..sort()}'
        ' — applied as constant defaults (iamf-tools#23 and iamf-tools#24)',
      );
    }
  }
}

final playbackSessionProvider =
    NotifierProvider<PlaybackSessionNotifier, PlaybackSession?>(
      PlaybackSessionNotifier.new,
    );
