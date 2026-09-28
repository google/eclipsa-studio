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

import '../models/audio_element_enums.dart';
import 'adm_import_bridge.dart';

/// ADM imports render to one fixed channel-bed target: 7.1.4.
///
/// 7.1.4 is the bed's authoring layout. Every other layout is derived from it
/// downstream: OAR's matrix table for monitoring and the Loudness Report, the
/// decoder's for consumers. The layout menu (nine targets, stereo to 9.1.6)
/// was retired because how the other targets should render is undecided
/// (ES-620, ES-622); the binaural/ambisonic bake targets are parked in adm-lab
/// (ES-569).
///
/// The point of this module is **explicit coupling**: the target carries the
/// exact [ElementConfig] its rendered WAV is seeded with, so the element type
/// is never inferred from the output channel count.

/// The render target: the explicit element config its output is seeded with,
/// and the channel count the engine is expected to produce (asserted by the
/// flow after the render). The engine renders its fixed 7.1.4 layout; the
/// target does not name one.
class AdmRenderTarget {
  const AdmRenderTarget({
    required this.label,
    required this.element,
    required this.expectedChannels,
  });

  /// Short suffix for the bed WAV / session name and progress text: "7.1.4".
  final String label;

  /// Explicit element typing, applied verbatim — not derived from the WAV.
  final ElementConfig element;
  final int expectedChannels;

  /// Bind this target to concrete paths for an engine render.
  AdmRenderRequest request({required String inPath, required String outPath}) =>
      AdmRenderRequest(inPath: inPath, outPath: outPath);
}

/// Every imported bed is written at this rate (the engine's kBedSampleRate);
/// a master at another rate is resampled after the render, through the
/// engine's libsamplerate wrapper at the export tier.
const int kAdmBedSampleRate = 48000;

/// Every imported bed is written as 24-bit PCM (fixed in adm2iamf_ffi.cc);
/// the dialog offers no encoding choice.
const int kAdmBedBitDepth = 24;

/// The import target: a 7.1.4 channel bed, 12 channels. 7.1.4 is a v1.0
/// layout and 12 channels fit the smallest profile budget (Simple, 16), so it
/// is legal under every IAMF profile (pinned in adm_render_target_test.dart).
const AdmRenderTarget kAdmRenderTarget = AdmRenderTarget(
  label: '7.1.4',
  expectedChannels: 12,
  element: (
    label: 'Channel · 7.1.4',
    type: 'Channel',
    layout: '7.1.4',
    ambisonicsOrder: null,
    isDual: null,
  ),
);

/// Base name (no extension) for a rendered bed WAV. The label is always present
/// in the name (it's a specific rendered bed), and de-duplicated so a stem that
/// already ends in `_<label>` (e.g. the default session name) isn't doubled.
String admBedWavBaseName(String stem, String label) {
  final suffix = '_$label';
  return stem.endsWith(suffix) ? stem : '$stem$suffix';
}
