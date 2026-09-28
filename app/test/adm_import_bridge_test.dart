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

import 'dart:ffi';

import 'package:eclipsa_studio/import/adm_import_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

// Hermetic ABI guard for the ADM import bridge. Does NOT load the dylib — it
// only validates that the Dart struct mirror matches the C
// `Adm2iamfRenderConfig` layout (engine/adm_import/ffi/adm2iamf_ffi.h), which is
// the part most likely to silently drift and corrupt a render config.
void main() {
  test('Adm2iamfRenderConfig matches the C ABI size (24 bytes, 64-bit)', () {
    expect(sizeOf<Adm2iamfRenderConfig>(), 24);
  });

  test('state enum values match the C header', () {
    expect(AdmRenderState.running.value, 0);
    expect(AdmRenderState.done.value, 1);
    expect(AdmRenderState.error.value, 2);
    expect(AdmRenderState.cancelled.value, 3);
    expect(AdmRenderState.unknownJob.value, -1);
  });

  test('AdmRenderState.fromValue maps raw codes and unknowns', () {
    expect(AdmRenderState.fromValue(0), AdmRenderState.running);
    expect(AdmRenderState.fromValue(3), AdmRenderState.cancelled);
    expect(AdmRenderState.fromValue(-1), AdmRenderState.unknownJob);
    expect(AdmRenderState.fromValue(99), AdmRenderState.unknownJob);
  });
}
