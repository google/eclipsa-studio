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

import 'package:eclipsa_studio/export/iamf_profile_rules.dart';
import 'package:eclipsa_studio/import/adm_render_target.dart';
import 'package:eclipsa_studio/models/audio_element_enums.dart';
import 'package:eclipsa_studio/state.dart' show IamfProfile;
import 'package:flutter_test/flutter_test.dart';

// The whole point of AdmRenderTarget is explicit coupling: the element type is
// fixed by the target, never inferred from the rendered channel count.
void main() {
  test('the fixed target is a 7.1.4 Channel element', () {
    const t = kAdmRenderTarget;
    expect(t.element.type, 'Channel');
    expect(t.element.layout, '7.1.4');
    expect(t.expectedChannels, 12);
    expect(t.label, '7.1.4');
  });

  test('request() maps paths for the engine', () {
    final r = kAdmRenderTarget.request(inPath: 'in.wav', outPath: 'out.wav');
    expect(r.inPath, 'in.wav');
    expect(r.outPath, 'out.wav');
  });

  // The dialog offers no per-profile gating for the bed (the old layout menu
  // greyed 9.1.6 out below Base-Enhanced). That only holds while the fixed
  // target is legal under every profile: a v1.0 layout, within every channel
  // budget.
  test('7.1.4 is legal under every IAMF profile', () {
    final layout = LoudspeakerLayout.fromDisplayName(
      kAdmRenderTarget.element.layout!,
    );
    expect(layout, isNotNull);
    for (final p in IamfProfile.values) {
      expect(profileAllowsLayout(p, layout!), isTrue, reason: p.label);
      expect(
        kAdmRenderTarget.expectedChannels,
        lessThanOrEqualTo(p.maxChannels),
        reason: p.label,
      );
    }
  });

  group('admBedWavBaseName', () {
    test('always carries the target label', () {
      expect(admBedWavBaseName('master', '7.1.4'), 'master_7.1.4');
    });

    test('does not double an existing label suffix', () {
      expect(admBedWavBaseName('master_7.1.4', '7.1.4'), 'master_7.1.4');
    });
  });
}
