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

// Flat C ABI over the ADM->bed converter. The symbols are linked into the
// `eclipsa_studio_engine` library, and the Flutter app looks them up by name
// (app/lib/ffi/engine_bindings.dart). The ABI follows the conventions of the
// `eclipsa_studio_engine` C ABI:
//   * rich/variable data (the probed scene, per-render stats) crosses as a
//     heap-allocated JSON string the caller frees with `adm2iamf_string_free`;
//   * fixed scalars cross in the `Adm2iamfRenderConfig` struct, mirrored
//     field-for-field in Dart;
//   * long renders run on a native worker thread behind a job table, polled
//     for progress/state and cancellable -- the UI never blocks on a render.
//
// All functions are thread-safe with respect to the job table. Strings returned
// by `*_json` functions are heap-owned by this library; free them with
// `adm2iamf_string_free` (NULL is tolerated).

#ifndef ADM2IAMF_FFI_ADM2IAMF_FFI_H_
#define ADM2IAMF_FFI_ADM2IAMF_FFI_H_

#ifdef __cplusplus
extern "C" {
#endif

// ── Read path ────────────────────────────────────────────────────────────────

// Probe an ADM-BWF file and return its format, ADM structure, resolved scene
// (bed sources with az/el, objects with first position + importance, LFE) and
// any unresolved common-definition channels as a JSON string. On success:
//   {"ok":true,"format":{...},"adm":{...},
//    "scene":{"sources":[...],"objects":[...]},"unresolved":[...]}
// On failure: {"ok":false,"error":"..."}. Returns NULL only if allocation of
// the result string itself fails. Free with `adm2iamf_string_free`.
char* adm2iamf_probe_json(const char* path);

// Free a string returned by any `adm2iamf_*_json` function. Safe to pass NULL.
void adm2iamf_string_free(char* s);

// ── Render path ──────────────────────────────────────────────────────────────
//
// Renders are channel-bed only, to the fixed 7.1.4 layout (12 channels),
// written as 24-bit PCM at 48 kHz.

// Job state returned by `adm2iamf_render_state`.
enum {
  kAdm2iamfRenderRunning = 0,
  kAdm2iamfRenderDone = 1,
  kAdm2iamfRenderError = 2,
  kAdm2iamfRenderCancelled = 3,
  kAdm2iamfRenderUnknownJob = -1,  // No such job id.
};

// Fixed render parameters, mirrored field-for-field in Dart for ABI safety.
typedef struct {
  int min_importance;    // Objects below this ADM importance are skipped.
  const char* in_path;   // Input ADM-BWF path.
  const char* out_path;  // Output WAV path.
} Adm2iamfRenderConfig;

// Start a render on a native worker thread. Returns a positive job id, or a
// negative value if the config is rejected before the thread starts (e.g. NULL
// config/paths). The render reads `cfg` fully before returning, so the caller
// may free its strings immediately afterwards.
//
// Job ids count up from 1 for the life of the process and are never reused;
// the counter is an int, so it holds 2^31 - 1 renders, which a host cannot
// reach (one render per second for 68 years). A finished job stays in the
// table, with its result JSON, until the next adm2iamf_render_start or
// adm2iamf_shutdown reaps it, so the host can read the result of the last
// render at any time.
int adm2iamf_render_start(const Adm2iamfRenderConfig* cfg);

// Current render progress in [0,1], or -1 for an unknown job id.
float adm2iamf_render_progress(int job);

// Current job state (kAdm2iamfRender*), or kAdm2iamfRenderUnknownJob.
int adm2iamf_render_state(int job);

// Once the job is terminal (done/error/cancelled), a JSON string describing the
// outcome. On done:
// {"ok":true,"out_path":"...","sample_rate":N,
// "channels":N,"stats":{...}}. On error/cancelled: {"ok":false,"error":"..."}.
// Returns NULL while the job is still running or the id is unknown. Free with
// `adm2iamf_string_free`.
char* adm2iamf_render_result_json(int job);

// Request cancellation of a running job; returns at once. The channel render
// polls the request after each 65536-frame chunk and, once it sees it, stops
// when any in-flight read of the next chunk has finished. The resample pass
// (run when the master is not at 48 kHz) polls after each block of up to 4096
// output frames. The job then becomes kAdm2iamfRenderCancelled. A request after
// the last poll does not stop the WAV write, and the job finishes as done.
// No-op for unknown/terminal jobs.
void adm2iamf_render_cancel(int job);

// Cancel every job and block until all worker threads have finished, then clear
// the job table. The host MUST call this before unloading this library or
// exiting, otherwise an in-flight worker can outlive the library's
// code/statics. It must NOT race adm2iamf_render_start: stop issuing renders
// first, since a render_start concurrent with (or after) shutdown may register
// a worker that shutdown does not drain. Behaviour of any render_start after
// shutdown is undefined. Safe to call with no jobs running.
void adm2iamf_shutdown(void);

// ── Misc ─────────────────────────────────────────────────────────────────────

// Library version string (statically owned; do not free).
const char* adm2iamf_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ADM2IAMF_FFI_ADM2IAMF_FFI_H_
