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

import '../playback/iamf_probe.dart' show IamfMixPresentation;
import '../playback/playback_session.dart' show computeRenderingConfigs;
import '../state.dart';

// The sets of elements SceneBridge.build draws differently from the rest
// (its stereoOnHeadphones and silenced), named by what the engine does
// with them.
//
// On the binaural monitoring target, OAR renders a channel-based element
// whose headphones rendering mode is Stereo (IAMF value 0) to stereo and
// outputs that unchanged, instead of passing it to OBR; the scene draws
// those elements' sources inside the listener's head.

/// Whether OAR registers [el] as a channel-based element, the type its
/// Stereo-mode check applies to.
bool _isChannelBased(AudioElement el) => elementToOarType(el).$1 == 0;

/// Ids of the channel-based [elements] the binaural target plays as plain
/// stereo in Creator. The mode is the one the app pushes for [subMix],
/// [MixElementSettings.effectiveHeadphonesMode], which is Stereo for
/// every Binaural element. Without a sub-mix the app pushes nothing and
/// the engine keeps binaural world-locked.
Set<int> creatorStereoOnHeadphones(
  SubMix? subMix,
  List<AudioElement> elements,
) {
  if (subMix == null) return const {};
  return {
    for (final el in elements)
      if (_isChannelBased(el) &&
          subMix.settingsFor(el.id).effectiveHeadphonesMode(el) ==
              HeadphonesRenderingMode.stereo)
        el.id,
  };
}

/// [creatorStereoOnHeadphones] for Playback: the channel-based
/// [elements] whose rendering config in [mix], the selected mix
/// presentation, has headphones rendering mode 0 (Stereo), as the engine
/// pushes it. An element without a rendering config keeps the engine
/// default, binaural world-locked.
Set<int> playbackStereoOnHeadphones(
  IamfMixPresentation? mix,
  List<AudioElement> elements,
) {
  if (mix == null) return const {};
  final rendering = computeRenderingConfigs(mix);
  return {
    for (final el in elements)
      if (_isChannelBased(el) && rendering[el.id]?.mode == 0) el.id,
  };
}

/// Ids of the [elements] the engine silences for mute and solo: a muted
/// element and, while any element is soloed, every element that is not
/// (AudioGraph::process in the engine). Pass every element of the
/// session, the ones the active mix excludes included: the engine counts
/// their solo too. The engine does not count the solo of an element it
/// has no active chain for, such as one whose WAV is missing; this does.
Set<int> silencedByMuteSolo(List<AudioElement> elements) {
  final anySolo = elements.any((e) => e.solo);
  return {
    for (final e in elements)
      if (e.mute || (anySolo && !e.solo)) e.id,
  };
}
