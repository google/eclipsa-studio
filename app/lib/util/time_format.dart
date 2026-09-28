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

/// Canonical audio duration / position formatting.
///
/// All audio time readouts (timeline block labels, inspector,
/// transport readout, export dialog) use [formatDuration] so clip
/// lengths and playhead positions are directly comparable anywhere
/// they appear. Intentional exceptions: timeline ruler ticks use
/// adaptive short labels (`42s`, `4:32`), and video displays use
/// frame-based `MM:SS.FF` timecode.
library;

/// Formats [seconds] as `MM:SS.mmm`, or `H:MM:SS.mmm` from one hour
/// up (hours unpadded). Zero-padded, millisecond precision, computed
/// in integer milliseconds so values like 59.9996 roll over to
/// `01:00.000` instead of printing `60.000`. Negative input clamps
/// to zero.
String formatDuration(double seconds) {
  var totalMs = (seconds * 1000).round();
  if (totalMs < 0) totalMs = 0;
  final hours = totalMs ~/ 3600000;
  final minutes = (totalMs ~/ 60000) % 60;
  final secs = (totalMs ~/ 1000) % 60;
  final millis = totalMs % 1000;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = secs.toString().padLeft(2, '0');
  final mmm = millis.toString().padLeft(3, '0');
  if (hours > 0) return '$hours:$mm:$ss.$mmm';
  return '$mm:$ss.$mmm';
}
