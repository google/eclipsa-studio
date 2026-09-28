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

/// Staleness fingerprint for offline loudness measurements.
///
/// A measurement (report or export) is valid only for the exact inputs
/// it was computed from. This fingerprint canonicalizes every session
/// property the offline render depends on; results stored alongside a
/// fingerprint are stale the moment the live session's fingerprint
/// differs.
///
/// Covered inputs — keep in sync with the orchestrator
/// (`loudness_measurement.dart`) and the bounce path:
/// - per element: source WAV (path + replacement generation), source
///   gain, input routing, and the OAR registration type (element type /
///   layout / ambisonics order / mono-vs-dual)
/// - per mix / sub-mix: output mix gain, layout list, and each included
///   element's mix gain + rendering config
/// - the render sample rate
///
/// Deliberately NOT covered: mute/solo (never reaches bounced output,
/// ES-284), element names/colors, excluded elements' settings.
library;

import '../state.dart';

/// Canonical fingerprint of everything an offline loudness measurement
/// depends on. Equal strings ⇔ a stored measurement is still valid.
/// The string is human-readable on purpose — it doubles as a debugging
/// aid when a report is unexpectedly (not) stale.
String loudnessFingerprint({
  required List<AudioElement> elements,
  required List<Mix> mixes,
  required int sampleRate,
}) {
  final buf = StringBuffer('sr=$sampleRate');

  final sortedElements = [...elements]..sort((a, b) => a.id.compareTo(b.id));
  for (final e in sortedElements) {
    if (e.wavPath == null) continue; // never bounced, never measured
    buf
      ..write('|el:${e.id}')
      ..write(';wav=${e.wavPath}')
      ..write(';gen=${e.wavGeneration}')
      ..write(';gain=${e.gain}')
      ..write(';route=${e.inputRouting?.join(',') ?? '-'}')
      ..write(';type=${e.type}')
      ..write(';layout=${e.layout}')
      ..write(';hoa=${e.ambisonicsOrder}')
      ..write(';dual=${e.isDual}');
  }

  for (final mix in mixes) {
    buf.write('|mix:${mix.id}');
    for (var subIdx = 0; subIdx < mix.subMixes.length; subIdx++) {
      final sub = mix.subMixes[subIdx];
      buf
        ..write('|sub:$subIdx')
        ..write(';out=${sub.outputMixGain}')
        ..write(
          ';layouts=${sub.layouts.map((l) => l.soundSystem.name).join(',')}',
        );
      final included = sub.elementSettings.where((s) => s.included).toList()
        ..sort((a, b) => a.elementId.compareTo(b.elementId));
      for (final s in included) {
        buf
          ..write(';set:${s.elementId}')
          ..write('=${s.mixGain}')
          ..write('/${s.headphonesMode.index}')
          ..write('/${s.binauralProfile.index}');
      }
    }
  }
  return buf.toString();
}
