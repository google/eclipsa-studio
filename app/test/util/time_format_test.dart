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

import 'package:eclipsa_studio/util/time_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatDuration', () {
    test('sub-minute durations keep the zero-padded minutes field', () {
      expect(formatDuration(0), '00:00.000');
      expect(formatDuration(1), '00:01.000');
      expect(formatDuration(42.5), '00:42.500');
    });

    test('minutes and hours tiers', () {
      expect(formatDuration(272.5), '04:32.500');
      expect(formatDuration(3723.456), '1:02:03.456');
      expect(formatDuration(36661.0), '10:11:01.000');
    });

    test('rolls over instead of printing 60 seconds', () {
      expect(formatDuration(59.9996), '01:00.000');
      expect(formatDuration(3599.9996), '1:00:00.000');
    });

    test('clamps negative input to zero', () {
      expect(formatDuration(-3.2), '00:00.000');
    });
  });
}
