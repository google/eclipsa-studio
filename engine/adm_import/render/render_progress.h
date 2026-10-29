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

// Cooperative progress reporting + cancellation for the chunked renderers.
//
// `RenderChannelBed` works through the audio in chunks and reports progress and
// polls for cancellation through this hook. The worker thread that
// `adm2iamf_render_start` (adm_import/ffi/adm2iamf_ffi.cc) runs passes one: it
// stores progress in an atomic the UI polls through `adm2iamf_render_progress`,
// and cancels when `adm2iamf_render_cancel` sets the job's flag. A caller that
// passes a null `RenderProgress*` (the default) gets no reports and no
// cancellation. Most tests do that; the progress and cancellation tests and
// `adm_import_bench` pass their own.
//
// `frames_done` / `frames_total` count output frames: RenderChannelBed reads,
// renders and mixes every source a chunk at a time and reports once per
// chunk. The callbacks run on the render thread; an implementation that
// shares state with another thread (e.g. the UI isolate reading progress)
// must back it with atomics.

#ifndef ADM2IAMF_RENDER_RENDER_PROGRESS_H_
#define ADM2IAMF_RENDER_RENDER_PROGRESS_H_

#include <cstdint>
#include <functional>

namespace adm2iamf {

struct RenderProgress {
  // Called once per processed chunk with cumulative frames done and the total
  // the render expects to do. `frames_total` is fixed for a given render.
  std::function<void(uint64_t frames_done, uint64_t frames_total)> report;

  // Polled once per chunk; returning true aborts the render, which then fails
  // with `absl::CancelledError`. Keep it cheap (a relaxed atomic load).
  std::function<bool()> should_cancel;

  void Report(uint64_t frames_done, uint64_t frames_total) const {
    if (report) report(frames_done, frames_total);
  }
  bool ShouldCancel() const { return should_cancel && should_cancel(); }
};

}  // namespace adm2iamf

#endif  // ADM2IAMF_RENDER_RENDER_PROGRESS_H_
