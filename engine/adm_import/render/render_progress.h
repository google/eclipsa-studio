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

// Cooperative progress reporting + cancellation for the block-wise renderers.
//
// `RenderChannelBed` (and the parked adm-lab bakes, ES-569) loops
// block-by-block; this hook lets a caller
// observe how far along a render is and ask it to stop early. It exists for the
// FFI/UI worker thread (Phase 7): the UI polls progress and can cancel a long
// render, while the CLI and tests simply pass nothing (the default no-op).
//
// `frames_done` / `frames_total` are in *work frames* -- a renderer that makes
// several passes over the audio counts each pass, so the ratio is a smooth
// 0..1 estimate of wall-clock work, not the output duration. The callbacks run
// on the render thread; an implementation that shares state with another thread
// (e.g. the UI isolate reading progress) must back it with atomics.

#ifndef ADM2IAMF_RENDER_RENDER_PROGRESS_H_
#define ADM2IAMF_RENDER_RENDER_PROGRESS_H_

#include <cstdint>
#include <functional>

namespace adm2iamf {

struct RenderProgress {
  // Called once per processed block with cumulative work frames done and the
  // total the render expects to do. `frames_total` is fixed for a given render.
  std::function<void(uint64_t frames_done, uint64_t frames_total)> report;

  // Polled once per block; returning true aborts the render, which then fails
  // with `absl::CancelledError`. Keep it cheap (a relaxed atomic load).
  std::function<bool()> should_cancel;

  void Report(uint64_t frames_done, uint64_t frames_total) const {
    if (report) report(frames_done, frames_total);
  }
  bool ShouldCancel() const { return should_cancel && should_cancel(); }
};

}  // namespace adm2iamf

#endif  // ADM2IAMF_RENDER_RENDER_PROGRESS_H_
