/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef ECLIPSA_STUDIO_ENGINE_DROPOUT_DETECTOR_H_
#define ECLIPSA_STUDIO_ENGINE_DROPOUT_DETECTOR_H_

#include <cstdint>

/// Throughput-aware audio dropout detector.
///
/// CoreAudio does not surface xruns directly, so dropouts must be
/// inferred from callback timing. Naive per-gap detection (flagging any
/// inter-callback gap much larger than the buffer period) cries wolf on
/// devices whose internal period exceeds the requested one: such devices
/// deliver callbacks in back-to-back bursts — a cluster of ~0 ms gaps
/// followed by one device-period gap — at perfect overall throughput.
///
/// This detector instead compares cumulative frames delivered against
/// frames the device must have consumed (elapsed wall-clock × sample
/// rate). Burst pacing nets out to zero deficit at the end of every
/// device period, while real starvation — skipped callbacks, stalls,
/// sustained clock slip — leaves the cumulative count behind schedule.
///
/// The deficit is evaluated as a windowed minimum: within one burst
/// cycle the instantaneous deficit oscillates by up to a device period,
/// but its lower envelope touches ~0 whenever throughput is healthy.
/// Each evaluation window (~0.5 s) compares that envelope against a
/// drift-adjusted baseline; growth of a full buffer or more is counted
/// as that many dropped buffers. Sub-threshold growth is bled into the
/// baseline at a rate generous for crystal-oscillator drift between the
/// monotonic clock and the device clock (≤ ~200 ppm) but far below any
/// audible starvation rate, so drift never accumulates into false
/// positives while genuine gradual starvation still trips the count.
///
/// Real-time safe: no allocation, no locking, no system calls. All
/// methods must be called from a single thread (the audio thread).
class DropoutDetector {
 public:
  struct Result {
    /// Buffers newly detected as lost (0 when on schedule).
    uint32_t new_dropouts = 0;
    /// How far delivery was behind schedule at detection, in ms.
    float behind_ms = 0.0f;
  };

  /// Feed one callback entry. `now_ns` is a monotonic timestamp taken
  /// at callback entry; `frames` is this callback's buffer size.
  /// Returns the dropouts detected by this call (usually zero; nonzero
  /// only on the callback that closes an evaluation window).
  Result on_callback(uint64_t now_ns, uint32_t frames, uint32_t sample_rate);

  /// Forget all history. Call when callbacks pause or the device is
  /// reconfigured, so the silent interval is not mistaken for a stall.
  void reset() { anchored_ = false; }

 private:
  /// Evaluation window length. Must exceed one device-side burst cycle
  /// (device period / requested period × period) so the deficit's lower
  /// envelope is sampled at least once per window; 0.5 s covers device
  /// periods up to tens of thousands of frames at any supported rate.
  static constexpr uint64_t kEvalWindowNs = 500'000'000;

  /// Tolerated clock skew between the monotonic clock and the device
  /// clock, bled into the baseline each window. Real oscillator drift
  /// is < 100 ppm; audible starvation (e.g. rate mismatch) is ≥ 1000s
  /// of ppm, so the gray zone is unoccupied in practice.
  static constexpr double kDriftCapPpm = 200.0;

  /// Counting threshold slack, in buffers. Entry-time jitter makes a
  /// true one-buffer deficit measure slightly under one buffer, so
  /// count when the deficit reaches (1 - slack) buffers.
  static constexpr double kCountSlack = 0.25;

  bool anchored_ = false;
  uint32_t sample_rate_ = 0;
  uint64_t anchor_ns_ = 0;
  /// Frames delivered since the anchor, including the anchor callback.
  double frames_delivered_ = 0.0;
  /// Drift-adjusted deficit baseline (frames). Deficit growth above
  /// this is loss; the baseline absorbs counted loss and slow drift.
  double baseline_frames_ = 0.0;
  uint64_t window_start_ns_ = 0;
  /// Lower envelope of the deficit within the current window (frames).
  double window_min_deficit_ = 0.0;
  bool window_has_sample_ = false;
};

#endif  // ECLIPSA_STUDIO_ENGINE_DROPOUT_DETECTOR_H_
