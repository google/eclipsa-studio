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

/// Shared tooltip copy for the per-element Solo/Mute buttons.
///
/// Solo and Mute are monitoring conveniences applied on the engine's
/// monitoring path only — in both Creator and Playback modes they never
/// reach IAMF metadata or exported audio, unlike the adjacent Mix
/// settings (`included`, mix gain), which do. Every S/M site (elements
/// view, mix view channel strip, renderer input panel) shares this copy
/// so the export-neutral promise reads identically everywhere.
library;

const String kSoloTooltip =
    'Solo — monitor this element only.\n'
    'Monitoring only: does not affect IAMF export.';

const String kMuteTooltip =
    'Mute — silence this element.\n'
    'Monitoring only: does not affect IAMF export.';

/// Shown instead of [kSoloTooltip]/[kMuteTooltip] when the button is
/// disabled because the element is excluded from the active mix
/// (ES-297): the element is already silent, and soloing it would only
/// mute everything else. An already-engaged button stays tappable so
/// the state can be cleared; this copy applies to the disengaged one.
const String kSoloMuteExcludedTooltip =
    'Not in the active mix. This element is already silent, '
    'so solo and mute have no effect on it.';

/// Monitor DIM (ES-629), shared by the Renderer view toggle and the
/// status bar item.
const String kMonitorDimTooltip =
    'Monitor DIM: cuts the monitoring output by 20 dB. Monitoring only: '
    'the meters, the export and the Loudness Report are unaffected. '
    'Press D to toggle.';

/// Output-channel solo (ES-999) for the Monitoring panel's S button of the
/// output channel labelled [label].
String outputSoloTooltip(String label) =>
    'Solo output channel $label: play this channel only.\n'
    'Monitoring only: the meters, the export and the Loudness Report '
    'are unaffected.';

/// The status bar item for engaged output-channel solo and mute (ES-999),
/// with the [soloed] and [muted] channels' labels.
String outputSoloMuteStatusTooltip(List<String> soloed, List<String> muted) => [
  if (soloed.isNotEmpty) 'Soloed output channels: ${soloed.join(', ')}.',
  if (muted.isNotEmpty) 'Muted output channels: ${muted.join(', ')}.',
  'Monitoring only: the meters, the export and the Loudness Report '
      'are unaffected. Click to clear.',
].join('\n');

/// Output-channel mute (ES-999) for the Monitoring panel's M button of the
/// output channel labelled [label].
String outputMuteTooltip(String label) =>
    'Mute output channel $label: silence this channel.\n'
    'Monitoring only: the meters, the export and the Loudness Report '
    'are unaffected.';
