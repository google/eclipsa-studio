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

#ifndef ECLIPSA_STUDIO_ENGINE_H_
#define ECLIPSA_STUDIO_ENGINE_H_

#include <stdint.h>

// Pull in the meter state definition so callers can interpret the pointer.
#include "meters/meter_state.h"

// Pull in the peak data struct so callers can interpret the returned pointer.
#include "waveform/peak_compute.h"

// Pull in log types + engine_log() so all engine TUs can log.
#include "engine_log.h"

// SH decode for visualization — stateless, not tied to Engine lifecycle.
#include "dsp/sh_decode.h"

// ── API / ABI stability ──────────────────────────────────────────────────────
//
// Everything declared in this header (and the headers it includes) is a
// versioned C API consumed across the FFI boundary — by the Flutter app
// via dart:ffi and by external validation harnesses via dlopen/ctypes.
//
// The version is a YYYYMMDD date stamp compared for EXACT equality by
// consumers — a build-freshness token, not a compatibility range. One
// rule: whenever anything about the FFI contract changes, set this to
// today's date and update kExpectedEngineApiVersion in
// app/lib/ffi_bridge.dart to match. If the stamp already equals
// today's date (a second contract change landing the same day, e.g.
// from a parallel branch), use the NEXT day's date instead — two
// different export sets must never share a stamp, or a stale dylib
// passes the freshness gate and throws on the missing symbol at
// lookup. Contract changes are:
//  - an exported function's signature, or the set of exported symbols;
//  - the layout of a struct that crosses the boundary
//    (EclipsaStudioMeterState, EclipsaStudioPeakData, ...) — silent ABI
//    breaks the linker cannot catch, and same-size field reordering slips
//    past sizeof static_asserts too;
//  - the MEANING of an existing field or parameter — units, valid
//    range, or the integer encoding of an enum-valued field (e.g.
//    EclipsaStudioPlaybackAe.kind, oar_layout_t parameters) — the most
//    dangerous breaks: nothing fails at compile, link, or load.
// Behavior-only changes (same signatures, layouts, meanings) don't
// touch the stamp.
//
// eclipsa_studio_api_version() returns the value the loaded library was
// compiled with, so a client can compare it against the header its
// bindings were generated from before calling anything else.
#define ECLIPSA_STUDIO_ENGINE_API_VERSION 20261019

#ifdef __cplusplus
extern "C" {
#endif

// ── Smoke ────────────────────────────────────────────────────────────────────

/// Trivial FFI smoke symbol (returns a + b) — the app's load-time
/// sanity check that the dylib resolved and calls marshal.
int32_t eclipsa_studio_add(int32_t a, int32_t b);

// ── Lifecycle ────────────────────────────────────────────────────────────────

/// Initialise the audio engine.
/// @param sample_rate   Output sample rate in Hz (e.g. 48000).
/// @param buffer_size   Audio callback buffer size in frames (e.g. 512).
/// @returns 0 on success, negative error code on failure.
int32_t eclipsa_studio_engine_init(uint32_t sample_rate, uint32_t buffer_size);

/// Shut down the engine and release all resources.
void eclipsa_studio_engine_shutdown(void);

// ── Transport
// ─────────────────────────────────────────────────────────────────

void eclipsa_studio_transport_play(void);
void eclipsa_studio_transport_pause(void);

/// Seek to an absolute time position (in seconds).
void eclipsa_studio_transport_seek(double seconds);

/// Enable looped playback between start_sec and end_sec.
void eclipsa_studio_transport_set_loop(double start_sec, double end_sec);

/// Disable looped playback.
void eclipsa_studio_transport_clear_loop(void);

/// Current playhead position in sample frames.
/// Advanced by the audio-thread callback during playback; frozen while
/// paused; jumped by eclipsa_studio_transport_seek(). Returns 0 if the engine
/// is not initialised. Lock-free atomic read — safe to call from any
/// thread.
uint64_t eclipsa_studio_transport_get_position_frames(void);

/// Returns 1 if the engine is initialised and the audio thread is wired
/// to a running output device; 0 otherwise (not initialised, or device
/// failed to open). When this is 0, the position counter will not
/// advance and callers should not treat it as ground truth.
uint8_t eclipsa_studio_transport_is_audio_thread_running(void);

// ── Elements
// ──────────────────────────────────────────────────────────────────

/// Add an audio element backed by a WAV file.
/// @param wav_path    Path to the WAV file.
/// @param element_id  Caller-supplied unique identifier.
/// @returns 0 on success, negative on error.
int32_t eclipsa_studio_element_add(const char* wav_path, uint32_t element_id);

void eclipsa_studio_element_remove(uint32_t element_id);

/// Copies the element id occupying each engine slot, in slot order,
/// into out_ids (up to capacity entries) and returns the element count.
/// Slot i of eclipsa_studio_get_meter_state()'s elements[] belongs to the
/// element whose id lands at out_ids[i] — hosts that key UI state by
/// slot (the Dart engineOrder map, ES-531) can verify their mapping
/// against this. Call from the control thread only, like add/remove.
uint32_t eclipsa_studio_element_ids(uint32_t* out_ids, uint32_t capacity);

void eclipsa_studio_element_set_gain(uint32_t element_id, float gain_db);
void eclipsa_studio_element_set_mute(uint32_t element_id, uint8_t muted);
void eclipsa_studio_element_set_solo(uint32_t element_id, uint8_t solo);

/// Exclude an element from the active mix presentation. Excluded elements
/// are silenced via the mute-gain node (click-free ramp to -120 dB) but
/// remain registered with OAR. Independent of user mute/solo state.
void eclipsa_studio_element_set_mix_excluded(uint32_t element_id,
                                             uint8_t excluded);

/// Set per-element IAMF mix gain (passed to OAR as element_mix_gain
/// metadata via oar_update_audio_element_metadata()).
/// Semantically distinct from eclipsa_studio_element_set_gain() which controls
/// the element's DSP-chain user gain — the mix gain is an IAMF concept
/// that weights elements inside a mix presentation.
///
/// The engine slew-limits fast changes and emits a sample-accurate
/// linear ramp to OAR each callback, so fader drags and text-edit
/// commits are click-free. For session load, where the target should
/// become the steady state without any ramp from zero, use
/// eclipsa_studio_element_seed_mix_gain() instead.
void eclipsa_studio_element_set_mix_gain(uint32_t element_id, float gain_db);

/// Set an object-based element's polar position(s).
///
/// Positions are REQUIRED for object elements to be audible on
/// loudspeaker layouts: OAR's object-to-loudspeaker renderer creates
/// its per-object processing only when position metadata arrives, so
/// an object element that never receives a position renders silence
/// on every speaker layout (binaural is unaffected — OBR uses a
/// default position). The audio thread re-pushes the latest values to
/// OAR every callback, so positions survive renderer rebuilds (layout
/// switches, element adds) automatically.
///
/// @param element_id     Element id (must be object-based; ignored
///                       otherwise until re-typed).
/// @param num_objects    1 = mono object, 2 = dual (second triplet used).
/// @param azimuth_deg    Horizontal angle in degrees (-180..180).
/// @param elevation_deg  Vertical angle in degrees (-90..90).
/// @param distance       Normalized distance (0..1).
void eclipsa_studio_element_set_object_position(
    uint32_t element_id, uint32_t num_objects, float azimuth_deg,
    float elevation_deg, float distance, float azimuth2_deg,
    float elevation2_deg, float distance2);

/// Set the per-element input channel routing map.
/// `routing[dest] = src`, where `src` is an index into the element's
/// WAV source channels and `-1` silences that dest. `len` is the number
/// of destination channels (the element's output channel count).
/// Passing `routing == nullptr` or `len == 0` clears to identity (no
/// remap — fast path on the audio thread).
///
/// Safe to call during playback: the engine publishes the map to the
/// audio thread through a lock-free triple buffer, and the next block
/// applies the latest map. The engine copies the map synchronously into
/// its own storage, so the caller's buffer does not need to outlive the
/// call.
void eclipsa_studio_element_set_input_routing(uint32_t element_id,
                                              const int8_t* routing,
                                              uint32_t len);

/// The order of an element's channels after routing, for
/// eclipsa_studio_element_set_channel_order() and
/// eclipsa_studio_mix_renderer_set_element_channel_order().
/// ECLIPSA_STUDIO_CHANNEL_ORDER_OAR (the default) feeds the element to
/// OAR as it is. ECLIPSA_STUDIO_CHANNEL_ORDER_916_ALT declares a 9.1.6
/// channel element in OBR's "IAMF 9.1.6 Alt" order (FLc FRc FC LFE FL
/// FR SiL SiR BL BR TpFL TpFR TpSiL TpSiR TpBL TpBR); the engine permutes
/// it into OAR's 9.1.6 order (FL FR FC LFE BL BR FLc FRc SiL SiR TpFL
/// TpFR TpBL TpBR TpSiL TpSiR) as it feeds OAR, after the element's
/// routing, gains and meters. It applies only while the element has 16
/// channels; any other count is fed as it is. An unknown value is
/// treated as ECLIPSA_STUDIO_CHANNEL_ORDER_OAR.
enum {
  ECLIPSA_STUDIO_CHANNEL_ORDER_OAR = 0,
  ECLIPSA_STUDIO_CHANNEL_ORDER_916_ALT = 1,
};

/// Declare the order of an element's channels after routing (see the
/// ECLIPSA_STUDIO_CHANNEL_ORDER_* values). Safe to call during playback:
/// one atomic store, read by the audio thread from the next callback.
void eclipsa_studio_element_set_channel_order(uint32_t element_id,
                                              uint32_t order);

/// Set the output mix gain of the active mix presentation, passed to OAR
/// as group metadata via oar_update_metadata() on gid=0.
/// Same slew-and-ramp semantics as eclipsa_studio_element_set_mix_gain.
void eclipsa_studio_set_output_mix_gain(float gain_db);

/// Seed per-element mix gain to its steady-state value without ramping.
/// Safe to call only while the audio thread is paused or outputting
/// silence — used by session load so a freshly opened project starts
/// at its persisted gains instead of ramping up from zero.
void eclipsa_studio_element_seed_mix_gain(uint32_t element_id, float gain_db);

/// Seed the output mix gain to its steady-state value without ramping.
/// Same constraints as eclipsa_studio_element_seed_mix_gain.
void eclipsa_studio_seed_output_mix_gain(float gain_db);

/// Monitor DIM (ES-629): engage (non-zero) or release a fixed -20 dB cut
/// on the device output, applied after the render, the limiter and
/// every meter tap. Monitor-only: it never reaches the mix, an export
/// or a measurement, and the output meters keep reading the undimmed
/// render. Ramped over 15 ms each way on the audio thread. Not
/// persisted anywhere; the engine starts undimmed.
void eclipsa_studio_set_monitor_dim(int32_t engaged);

/// Output-channel solo and mute of the monitoring target (ES-999). Bit c
/// of `soloed` and `muted` is the target's output channel c in the order
/// of eclipsa_studio_get_output_peaks(). A muted channel and, while any
/// channel is soloed, every channel that is not are silenced. Applied
/// with the device routing, after the render and the limiter; the output
/// and loudness meters keep reading the full render, and it never
/// reaches the mix, an export or a measurement. Calibration noise is not
/// cut. Ramped over 15 ms each way on the audio thread while program
/// plays, and set at once while it does not. Not persisted; the engine
/// starts with nothing soloed or muted.
void eclipsa_studio_set_output_solo_mute(uint64_t soloed, uint64_t muted);

/// Register an element's IAMF type with the OAR renderer.
/// Must be called after eclipsa_studio_element_add().
/// @param element_id  Same id used in eclipsa_studio_element_add().
/// @param type        0=channel-based, 1=scene-based, 2=object-based.
/// @param sub_type    Type-specific: oar_layout_t for channel, oar_hoa_t for
///                    scene, num_objects (1 or 2) for object.
/// @param channels    Number of channels for this element.
/// @returns 0 on success.
int32_t eclipsa_studio_element_set_type(uint32_t element_id, int32_t type,
                                        int32_t sub_type, uint32_t channels);

/// Stage the per-element IAMF element_rendering_config — headphones
/// rendering mode and binaural filter profile. The change is not
/// visible to the OAR renderer until eclipsa_studio_commit_rendering_config()
/// is called, because OAR latches these fields at element-add time
/// and applying them requires destroying and recreating the OAR
/// instance. Staging then batch-committing avoids N rebuilds on
/// session load / mix switch.
///
/// @param element_id  Must already exist in the OAR element list
///                    (call eclipsa_studio_element_set_type() first).
/// @param mode        headphones_rendering_mode (0=stereo fallback for
///                    channel-based / binaural world-locked for
///                    scene/object, 1=binaural world-locked,
///                    2=binaural head-locked).
/// @param profile     binaural_filter_profile (0=AMBIENT, 1=DIRECT,
///                    2=REVERBERANT). See OAR spec for meaning.
/// @returns 0 on success, negative if the element is not tracked.
int32_t eclipsa_studio_element_set_rendering_config(uint32_t element_id,
                                                    uint32_t mode,
                                                    uint32_t profile);

/// Apply any pending rendering-config changes staged via
/// eclipsa_studio_element_set_rendering_config() by rebuilding the OAR
/// instance. No-op if nothing is dirty.
/// @returns 0 on success, negative on rebuild failure.
int32_t eclipsa_studio_commit_rendering_config(void);

// ── Audio device
// ──────────────────────────────────────────────────────────────

uint32_t eclipsa_studio_device_count(void);

/// Name of the output device at `index`, or NULL when out of range.
///
/// Ownership: the caller owns the returned buffer and must release it
/// with `eclipsa_studio_string_free()`. Each call allocates a fresh copy.
const char* eclipsa_studio_device_name(uint32_t index);

void eclipsa_studio_device_select(uint32_t index);
uint32_t eclipsa_studio_device_channel_count(void);

/// Hardware-reported name of output channel `channel` (0-based) on the
/// currently OPEN device — e.g. "Phones 2" on a MOTU MicroBook II. NULL
/// when no device is open or the backend reports no label for the
/// channel (the WASAPI backend never does), in which case the UI
/// must render exactly as if the feature didn't exist.
///
/// Ownership: the caller owns the returned buffer and must release it
/// with `eclipsa_studio_string_free()`. Each call allocates a fresh copy.
const char* eclipsa_studio_device_channel_name(uint32_t channel);

/// Release a string returned by `eclipsa_studio_device_name()`,
/// `eclipsa_studio_device_channel_name()`,
/// `eclipsa_studio_last_device_error()`, or the log-callback category/message
/// pair (see `engine_log.h`). Frees with the engine's own allocator: the host
/// runtime's deallocator need not match — Dart's `package:ffi` `malloc.free()`
/// maps to CoTaskMemFree on Windows, which corrupts the heap when handed
/// CRT-malloc'd memory. NULL is a no-op.
void eclipsa_studio_string_free(const char* s);

/// Re-enumerate output devices (hot-plug / OS default changes). Safe
/// while a stream is open; the open device is never touched. The
/// selection is remapped by name across the index shift; if the
/// selected device disappeared it falls back to the system default.
/// @returns the new device count.
uint32_t eclipsa_studio_devices_refresh(void);

// Per-device capability queries (populated after engine init).
uint32_t eclipsa_studio_device_supported_sample_rate_count(
    uint32_t device_index);
uint32_t eclipsa_studio_device_supported_sample_rate(uint32_t device_index,
                                                     uint32_t rate_index);
uint32_t eclipsa_studio_device_supported_channel_count_count(
    uint32_t device_index);
uint32_t eclipsa_studio_device_supported_channel_count(uint32_t device_index,
                                                       uint32_t ch_index);
uint32_t eclipsa_studio_device_max_channels(uint32_t device_index);
uint8_t eclipsa_studio_device_is_default(uint32_t device_index);

// Current engine audio settings.
uint32_t eclipsa_studio_current_sample_rate(void);
uint32_t eclipsa_studio_current_buffer_size(void);
uint32_t eclipsa_studio_current_device_index(void);

// Block size the OAR renderer is currently configured for. Tracks
// eclipsa_studio_current_buffer_size() whenever reconfiguration works as
// intended; a divergence means the renderer is feeding/rendering
// blocks of the wrong size (diagnostic; also pinned by tests).
// 0 when no renderer exists.
uint32_t eclipsa_studio_oar_buffer_size(void);

// Live hardware sample rate of the open output device (Core Audio
// nominal rate) — the user can change it in Audio MIDI Setup at any
// time, so this can diverge from eclipsa_studio_current_sample_rate() until
// a reconfigure re-adopts it. 0 when no device is open or the
// platform query is unavailable. Control thread only.
uint32_t eclipsa_studio_device_hardware_sample_rate(void);

/// Stop, reconfigure, and restart the audio engine output device.
/// @param device_index  Index into the enumerated device list.
/// @param sample_rate   New sample rate in Hz (0 = keep current).
/// @param buffer_size   New buffer size in frames (0 = keep current).
/// @returns 0 on success, negative error code on failure.
int32_t eclipsa_studio_engine_reconfigure(uint32_t device_index,
                                          uint32_t sample_rate,
                                          uint32_t buffer_size);

/// Last failure message from the audio output device, or NULL if the
/// device is currently running or has never failed to start. Captures
/// failures from `eclipsa_studio_engine_init` and
/// `eclipsa_studio_engine_reconfigure`.
///
/// Ownership: the caller owns the returned buffer and must release it
/// with `eclipsa_studio_string_free()` (see there for why not the host
/// runtime's own free). Each call allocates a fresh copy.
const char* eclipsa_studio_last_device_error(void);

// ── Meters
// ────────────────────────────────────────────────────────────────────

/// Returns a pointer to the shared meter state.
/// The pointer is valid for the lifetime of the engine.
/// The audio thread writes; the Dart UI reads.
const EclipsaStudioMeterState* eclipsa_studio_get_meter_state(void);

/// Zero all meter state — peaks, RMS, holds, loudness, counters, and
/// the sticky clip latches. For context changes (mode switch, session
/// load); use eclipsa_studio_meter_reset_levels on the pause path.
void eclipsa_studio_meter_reset(void);

/// Like eclipsa_studio_meter_reset, but the sticky clip flags (per-element
/// and output-bus) survive: overload markers must remain visible after
/// a transport stop (ES-528). Use on the pause path; the full reset is
/// for context changes (mode switch, session load), and the clip
/// latches are otherwise cleared only via eclipsa_studio_meter_reset_clips.
void eclipsa_studio_meter_reset_levels(void);

/// Clear all sticky clip flags (per-element and output-bus). Safe at
/// any time: while playing the audio thread applies the clear at the
/// top of its next block (≤ ~10 ms); while paused it happens
/// immediately.
void eclipsa_studio_meter_reset_clips(void);

/// Direct read of the frame counter (workaround for Dart FFI uint64 alignment).
uint64_t eclipsa_studio_get_frame_counter(void);

/// Read output peak levels. Writes up to max_channels floats into out_peaks.
/// Returns the number of channels written.
uint32_t eclipsa_studio_get_output_peaks(float* out_peaks,
                                         uint32_t max_channels);

/// Read output RMS levels (short EMA integration — see
/// AudioGraph::kMeterRmsWindowMs — linear amplitude). Same tap and
/// channel order as eclipsa_studio_get_output_peaks(). Returns the number of
/// channels written.
uint32_t eclipsa_studio_get_output_rms(float* out_rms, uint32_t max_channels);

/// Read the sticky per-output-channel clip flags (1 = the channel hit
/// >= 0 dBFS since the last clip reset; latched by the audio thread so
/// overs between reads are never missed). Same channel order as
/// eclipsa_studio_get_output_peaks(). Returns the number of channels written.
uint32_t eclipsa_studio_get_output_clips(uint8_t* out_clips,
                                         uint32_t max_channels);

/// Enable or disable the visualizer channel-stats block (energy,
/// correlation, coherence, onsets). Written by the UI when any
/// channel-viz module is enabled or the stats HUD is visible; the
/// audio thread checks this flag and skips the entire stats pass
/// when disabled. Default: disabled.
void eclipsa_studio_set_channel_stats_enabled(uint8_t enabled);

// ── Monitoring / OAR ─────────────────────────────────────────────────────────

/// Set the OAR target layout. Values from oar_layout_t enum.
/// Switching layout destroys and recreates the OAR renderer; setting the
/// layout it already renders keeps it. The mix-bus loudness meter is
/// reconfigured, and its readings cleared, in both cases.
/// Use ck_oar_layout_binaural for binaural rendering.
/// @returns 0 on success, negative on error.
int32_t eclipsa_studio_monitoring_set_layout(uint32_t layout);

/// Number of output channels for the current layout.
uint32_t eclipsa_studio_monitoring_get_channels(void);

/// Set the per-OAR-channel device routing. masks[oar_ch] is a device-channel
/// bitmask (bit d set = OAR channel oar_ch feeds device channel d; 0 = mute).
/// len MUST equal eclipsa_studio_monitoring_get_channels(); a mismatch is
/// rejected so a stale-length push never partially applies.
/// @returns 0 on success, -1 on size mismatch or null.
int32_t eclipsa_studio_monitoring_set_routing(const uint64_t* masks,
                                              uint32_t len);

/// Atomic layout + routing switch: apply `layout` and its cached `masks`
/// (len device-channel bitmasks) as one control-thread op before the audio
/// thread runs the new layout, so there is no window of new-layout +
/// old-routing audio mid-switch.
/// @returns 0 on success, -1 on error.
int32_t eclipsa_studio_monitoring_set_layout_and_routing(uint32_t layout,
                                                         const uint64_t* masks,
                                                         uint32_t len);

/// Set the single pink-noise calibration injection point.
/// @param mode     0=off, 1=row (pre-routing, channel indexes the active OAR
///                 output channel), 2=col (post-routing, channel indexes the
///                 device output channel).
/// @param channel  OAR channel (row) or device channel (col).
/// @param dbfs     calibration reference level in dBFS; while a cell is lit
///                 the program is muted and noise plays at this fixed level,
///                 bypassing the output mix gain. Must be finite when
///                 mode != 0.
/// @returns 0 on success, -1 if mode > 2, channel exceeds 24 bits, or dbfs is
///          non-finite (rejected so a bad value can't silently mute output).
int32_t eclipsa_studio_monitoring_set_noise(uint32_t mode, uint32_t channel,
                                            float dbfs);

/// Bypass OAR and route element channels 0-1 directly to device output
/// (summed to stereo).  For debugging audio routing issues.
/// @returns 0 on success.
int32_t eclipsa_studio_set_bypass_oar(uint8_t enabled);

/// Pause / resume the live audio output for the duration of an offline
/// operation (e.g. IAMF export). While paused, the audio thread skips
/// OAR entirely and emits silence — this prevents the live OarRenderer
/// from running concurrently with the offline mix renderer's own
/// transient OAR instances during loudness measurement, which has been
/// observed to corrupt the heap (ES-44).
///
/// On paused=1, blocks until the audio thread has acknowledged the
/// pause (any in-flight oar_render() call has completed), so the caller
/// can safely create / use alternative OAR instances on return. No-op
/// when not initialised.
///
/// Delegates to OarRenderer::begin/end_offline_exclusive(), which
/// takes control_mutex_ — so the pause is serialized against layout
/// switches and rebuilds by construction, rebuilds requested while
/// paused are deferred and replayed on resume, and a device
/// reconfigure during the pause cannot resume the live OAR. The resume
/// goes through AudioGraph::end_offline_exclusive(), which resyncs the
/// mix-bus loudness meter when a deferred layout switch is replayed.
///
/// Idempotent in effect, but single-owner: a second paused=1 while
/// already paused logs a warning and changes nothing; resume when not
/// paused is a no-op. Callers must bracket strictly (try/finally).
void eclipsa_studio_engine_set_export_paused(uint8_t paused);

// ── IAMF export ──────────────────────────────────────────────────────────────

// Encode an IAMF bitstream (ES-480): each element streams straight from its
// source WAV through the offline bounce pipeline (gain, routing, resample,
// pad) into the push-PCM encoder — no temp WAVs.
//
// Call sequence — one builder sequence at a time (the app drives it
// from the export isolate). The three builder calls are serialized by
// an internal mutex (ES-504), so an errant second thread interleaving
// its own begin/add can garble which elements land in the pending
// request, but cannot cause a data race; run() drops the lock before
// the encode itself.
//   1. eclipsa_studio_iamf_push_export_begin(config_textproto,
//   output_iamf_path)
//      — `config_textproto` is an iamf_tools_cli_proto::UserMetadata
//      message serialized as textproto; `output_iamf_path` is the .iamf
//      file to write (parent directory must exist).
//   2. eclipsa_studio_iamf_push_export_add_element(...) once per element
//   3. eclipsa_studio_iamf_push_export_run()  — blocking; encodes and clears
//   the
//      pending request (also on failure)
//
// `wav_basename` must match an audio_frame_metadata[].wav_filename entry
// in the UserMetadata — that entry supplies the audio_element_id and the
// per-channel IAMF labels. `routing`/`routing_len` follow the
// ElementStream routing semantics (may be null/0 for identity), as do
// `pad_to_frames` (common padded length, in output-rate frames) and
// `output_sample_rate` (0 = keep source rate).
//
// Progress ([0,1], per coded frame) and cancel (honored once per coded
// frame; removes the partial output) are read/steered via
// eclipsa_studio_iamf_export_progress / eclipsa_studio_iamf_export_cancel —
// safe from any thread/isolate while run() blocks.
//
// Cancel reset boundary: begin() arms the request and drops any cancel
// raised BEFORE it as stale; a cancel raised AFTER begin() aborts the
// run with -99 even if it lands before run() is called. A cancel racing
// begin() itself may land on either side — callers that track their own
// cancel intent must re-check it when run() returns 0 (the export
// dialog does).
//
// Returns 0 on success. -4 means another export is already running
// (from begin() — which must not clear the in-flight run's cancel —
// and from run()); -5 means a C++ exception was caught at the FFI
// boundary; other negative codes come from IamfExporter::EncodePush
// (see iamf/iamf_exporter.h). begin/add return -1 on null/invalid
// arguments.
int32_t eclipsa_studio_iamf_push_export_begin(const char* config_textproto,
                                              const char* output_iamf_path);
int32_t eclipsa_studio_iamf_push_export_add_element(
    const char* wav_basename, const char* source_wav_path, float gain_db,
    const int32_t* routing, int32_t routing_len, uint64_t pad_to_frames,
    uint32_t output_sample_rate);
int32_t eclipsa_studio_iamf_push_export_run(void);

// Signal-overload stats for one element of the most recent push-export
// run, counted on the PCM actually fed to the encoder (element gain,
// routing, and resampling applied). `index` is the add-order ordinal of
// the begin/add/run sequence. A sample counts as clipped when |x| is
// strictly > 1.0 — past what the encoder's ±1.0 clamp preserves
// losslessly (exactly ±1.0 is legitimate full-scale integer content).
// `out_peak_linear` is max |x|; dBFS = 20*log10(peak). Counts are
// partial when the run failed or was cancelled mid-stream.
//
// Returns 0 and fills the out pointers (either may be NULL), -1 for an
// out-of-range index or before any run reached its element streams.
// Valid after run() returns until the next begin(); a mid-run call
// observes the previous (or cleared) snapshot — poll progress instead.
// Safe from any thread/isolate.
int32_t eclipsa_studio_iamf_push_export_element_clip_stats(
    uint32_t index, uint64_t* out_clipped_samples, float* out_peak_linear);

// Progress of the running export in [0, 1], stepped per coded frame
// (0 when no export is running). Safe from any thread/isolate.
float eclipsa_studio_iamf_export_progress(void);

// Request cancellation of the running export; honored once per coded
// frame, the partial output is removed and run() returns -99. Safe
// from any thread/isolate.
void eclipsa_studio_iamf_export_cancel(void);

// Mux an exported IAMF bitstream together with a video file into a single
// MP4 (IAMF-in-ISOBMFF), in-process via libgpac. The IAMF bytes are
// carried through unchanged (profile, substreams, loudness); the video
// track is stream-copied (no re-encode).
//
// `input_video` must be an ISOBMFF container (.mp4/.mov) — GPAC's
// ISO-media copy does not demux Matroska/WebM/MXF; callers gate on the
// source format upstream. `output_mp4` is overwritten if it exists.
//
// Returns 0 on success, negative on error. -4 means another mux is already
// running; -5 means a C++ exception was caught at the FFI boundary
// (details in the engine log); other negative codes come from
// eclipsa_studio::IamfMuxer::Mux. Runs synchronously on the calling (control)
// thread.
int32_t eclipsa_studio_iamf_mux(const char* input_iamf, const char* input_video,
                                const char* output_mp4);

// Check that `input_video` opens with the GPAC reader eclipsa_studio_iamf_mux
// uses and has a visual track, before an export runs (ES-742). Reads only
// the file's metadata; the mux's track copy can still fail on a file
// that passes. Returns 0 when the container opens and has a visual
// track; -1 for a null argument; -5 for a C++ exception at the FFI
// boundary; otherwise the codes of eclipsa_studio::IamfMuxer::ProbeVideo (-3
// missing, -10 GPAC init failed, -12 unreadable container, -13 no visual
// track). Read-only, so it may run while a mux is in progress. Runs
// synchronously on the calling thread.
int32_t eclipsa_studio_video_container_probe(const char* input_video);

// Free space and identity of the volume holding `path` (a file or a
// directory that exists), for the export dialog's disk-space check
// (ES-742). `out_free_bytes` is the space this process can use;
// `out_volume_id` is the same value for every path on one volume (st_dev
// on POSIX, the volume serial on Windows), so a caller can tell whether
// the scratch dir and the destination share a disk. Returns 0 on
// success, -1 for a null argument, -2 when the path does not exist or the
// OS query fails (outputs untouched).
int32_t eclipsa_studio_fs_volume_info(const char* path,
                                      uint64_t* out_free_bytes,
                                      uint64_t* out_volume_id);

// Encode a single RGBA frame into an H.264 video-only MP4 of the given
// duration — the video half of a still-image MP4 export (ES-192). The
// result is a valid `input_video` for eclipsa_studio_iamf_mux, so a loaded
// still image can ship as "static video + IAMF audio". Uses the OS
// encoder (VideoToolbox on macOS, Media Foundation on Windows); the
// vendored FFmpeg build has no encoders.
//
// `rgba` is tightly packed RGBA8888 (stride = width*4, top-down) with
// `rgba_size` >= width*height*4; `width`/`height` must be even and
// within the encoder-safe ceiling — callers downscale beforehand. The
// frame repeats at `fps` for `duration_seconds`, rounded up to whole
// frames.
//
// Returns 0 on success, negative on error, -5 for a C++ exception at
// the FFI boundary; the full argument contract and error-code table
// live with the implementation in video/still_video_encoder.h. Runs
// synchronously on the calling thread — call from a worker isolate,
// not the UI isolate.
int32_t eclipsa_studio_still_video_encode(const uint8_t* rgba,
                                          uint64_t rgba_size, uint32_t width,
                                          uint32_t height, uint32_t fps,
                                          double duration_seconds,
                                          const char* output_mp4);

// ── Playback mode (IAMF streaming) ───────────────────────────────────────────

// Descriptor for one Audio Element returned by
// eclipsa_studio_playback_open(). Mirrors
// iamf_tools::api::AudioElementDescriptor with plain ints so Dart FFI can read
// fields without pulling in the upstream C++ enum types.
typedef struct {
  uint32_t audio_element_id;
  // 0 = channel-based, 1 = scene-based (ambisonics), 2 = object-based.
  int32_t kind;
  uint32_t num_channels;
  // Channel AE: upstream OutputLayout enum value (kItu2051_SoundSystem*).
  // Scene AE:   ambisonics order N (1, 2, 3).
  // Object AE:  number of objects.
  int32_t layout_info;
} EclipsaStudioPlaybackAe;

// Result of eclipsa_studio_playback_open. All non-primitive fields are heap-
// allocated and owned by the result; free with
// eclipsa_studio_playback_open_result_free. On success, status == 0 and the
// audio_elements array carries the AE descriptors in stream order.
typedef struct {
  // 0 on success (session opened and slots claimed). Negative on error;
  // error_message then carries an upstream-prefixed reason
  // ("malformed:" / "io:" / "unsupported:" / "invalid_argument:").
  int32_t status;
  const char* error_message;  // heap-owned; NULL on success

  uint32_t sample_rate;
  uint64_t total_frames;

  uint32_t num_audio_elements;
  const EclipsaStudioPlaybackAe* audio_elements;  // heap-owned array
} EclipsaStudioPlaybackOpenResult;

// Open an IAMF file as a Playback-mode session. Opens the streaming
// decoder, claims one element-chain slot per Audio Element in the
// file, and registers each slot with the OAR renderer at its AE
// layout — playback is ready to start as soon as transport is
// resumed. Any previously-open IAMF session is closed first.
//
// In Playback mode the engine must not also have WAV Creator elements
// attached; callers enforce this via the workspace-mode guards in the
// Dart layer. A mixed state is not rejected here but is unsupported.
//
// Caller must free the returned pointer with
// eclipsa_studio_playback_open_result_free. Returns NULL only if the top-
// level allocation failed.
EclipsaStudioPlaybackOpenResult* eclipsa_studio_playback_open(const char* path);

// Release a result returned by eclipsa_studio_playback_open, including its
// nested string + array allocations. Safe to pass NULL.
void eclipsa_studio_playback_open_result_free(
    EclipsaStudioPlaybackOpenResult* result);

// Close the current IAMF session (if any) and release the slots it
// claimed. Also unregisters those elements from OAR. Idempotent.
void eclipsa_studio_playback_close(void);

// Control whether the stream's per-TU mix gains drive each IAMF
// element's mix gain (enabled != 0, the default after every
// eclipsa_studio_playback_open). The stream reports gains for the decoder's
// *default* mix presentation only — the streaming API has no mix
// selection (iamf-tools#23) — so when the app selects a non-default
// presentation it disables this and drives
// eclipsa_studio_element_set_mix_gain itself; re-enable when returning to the
// default presentation. Lock-free; safe during playback.
void eclipsa_studio_playback_use_stream_gains(uint8_t enabled);

// Scan-state snapshot for the currently-open IAMF session.
//
// The upstream `IamfStreamFactory::OpenFromBytes` is configured with
// `lazy_temporal_unit_scan = true` so open returns after descriptor
// parse + codec init only and runs the temporal-unit scan on a worker
// thread. While the worker is in flight `total_frames` is 0; callers
// poll this struct to update timeline duration once `scan_complete` /
// `total_samples_ready` flip.
typedef struct {
  // 0 when no IAMF session is open. 1 when a session exists. The other
  // fields are only meaningful with `session_open == 1`.
  int32_t session_open;
  // 1 once the upstream TU scan has finished (success or failure).
  // `Seek` no longer blocks on the scan past this point.
  int32_t scan_complete;
  // 1 once `total_frames` reflects a completed scan (i.e. the duration
  // is known). Distinct from `scan_complete` so that "not yet known"
  // is distinguishable from "0 samples".
  int32_t total_samples_ready;
  // Latest cached total frames per channel from the upstream stream.
  // 0 while the scan is in flight; the authoritative value once
  // `total_samples_ready == 1`.
  uint64_t total_frames;
} EclipsaStudioPlaybackStatus;

// Snapshot the current playback session's scan state. Returns
// session_open == 0 when no session is open. Safe to call from any
// thread; intended to be polled from the Dart 60 Hz tick loop until
// the duration is known.
EclipsaStudioPlaybackStatus eclipsa_studio_playback_status(void);

// ── Offline mix renderer (loudness measurement) ──────────────────────────────

// Opaque handle for an offline mix renderer instance.
typedef struct eclipsa_studio_mix_renderer eclipsa_studio_mix_renderer_t;

// Create a renderer for a target layout. Returns NULL on failure.
// layout values match oar_layout_t (2=stereo, 8=7.1.4, 0xFF=binaural, etc.)
eclipsa_studio_mix_renderer_t* eclipsa_studio_mix_renderer_create(
    uint32_t sample_rate, uint32_t buffer_size, uint32_t layout);

// Add an element. Call after create, before measure. The measure pass streams
// straight from the element's source WAV — `source_wav_path`, `gain_db`,
// `routing`/`routing_len`, `pad_to_frames`, and `output_sample_rate` have the
// same semantics as eclipsa_studio_iamf_push_export_add_element (gain →
// routing → resample → pad; NULL routing = identity; pad counted at the OUTPUT
// rate, 0 = source length; rate 0 = keep the source rate).
//
// `channels` is the declared post-routing channel count used to
// register the element with OAR; measure fails if the stream delivers
// a different count. `mix_gain_db` is the mix-level (OAR) gain, NOT
// the element pre-gain.
int32_t eclipsa_studio_mix_renderer_add_element(
    eclipsa_studio_mix_renderer_t* r, const char* source_wav_path,
    uint32_t element_id, int32_t element_type, int32_t element_sub_type,
    uint32_t channels, float mix_gain_db, uint32_t headphones_mode,
    uint32_t binaural_profile, float gain_db, const int32_t* routing,
    int32_t routing_len, uint64_t pad_to_frames, uint32_t output_sample_rate);

// Set an object element's polar position(s) for the offline render.
// Call after eclipsa_studio_mix_renderer_add_element for object-based
// elements: OAR's object-to-loudspeaker renderer produces silence
// until positions arrive, so an unpositioned object measures as
// silence on every speaker layout. Same parameter semantics as
// eclipsa_studio_element_set_object_position.
void eclipsa_studio_mix_renderer_set_object_position(
    eclipsa_studio_mix_renderer_t* r, uint32_t element_id, uint32_t num_objects,
    float azimuth_deg, float elevation_deg, float distance, float azimuth2_deg,
    float elevation2_deg, float distance2);

// Declare the order of an element's channels after routing for the
// offline render, after eclipsa_studio_mix_renderer_add_element. Same
// values and semantics as eclipsa_studio_element_set_channel_order.
void eclipsa_studio_mix_renderer_set_element_channel_order(
    eclipsa_studio_mix_renderer_t* r, uint32_t element_id, uint32_t order);

// Set the output mix gain in dB.
void eclipsa_studio_mix_renderer_set_output_gain(
    eclipsa_studio_mix_renderer_t* r, float gain_db);

// Run render + loudness measurement. Writes results to out pointers.
// Returns 0 on success, -1 on null handle, -2 when the render/measure
// failed (no elements, unreadable source WAV, channel-count mismatch,
// renderer error — details in the engine log; the out values are not
// written), -5 if a C++ exception was caught at the FFI boundary
// (details in the engine log). Callers must treat any non-zero return
// as "no measurement", never as silence.
int32_t eclipsa_studio_mix_renderer_measure(eclipsa_studio_mix_renderer_t* r,
                                            float* out_integrated_lufs,
                                            float* out_true_peak_dbtp,
                                            float* out_digital_peak_dbfs);

// ── Post-measurement time series ─────────────────────────────────────────
// Valid only after a successful eclipsa_studio_mix_renderer_measure() and until
// the next measure/destroy. Series ids (eclipsa_studio::MixTraceSeries):
//   0 = momentary loudness (400 ms window, LUFS)
//   1 = short-term loudness (3 s sliding window, LUFS)
//   2 = short-term peak (max sample peak per 3 s window, dBFS)
//   3 = short-term PSR (peak minus short-term loudness, dB)
//   4 = limiter gain reduction (envelope sampled once per render
//       block, max-reduced per 100 ms step, dB >= 0; sustained
//       limiting is accurate, isolated transients are understated —
//       resolution is bounded by the render block size, ES-541; no
//       warmup — entries from t=0)
// All series step at 100 ms; series 0-3 are shorter than program/step
// because their first entry lands only once the window has filled.

// Number of entries recorded for a series (0 before measure or for an
// unknown series id).
uint32_t eclipsa_studio_mix_renderer_trace_len(eclipsa_studio_mix_renderer_t* r,
                                               uint32_t series);

// Copy up to `cap` entries of a series into caller-allocated `out`.
// Returns the number of entries copied.
uint32_t eclipsa_studio_mix_renderer_copy_trace(
    eclipsa_studio_mix_renderer_t* r, uint32_t series, float* out,
    uint32_t cap);

// EBU TECH 3342 loudness range of the measured program. Returns 0 and
// fills the out pointers on success, -1 when unavailable (not measured
// yet, or program shorter than one short-term block). `out_is_stable`
// (0/1) reflects EBU TECH 3341's "stable after 60 s" criterion. Either
// out pointer may be NULL.
int32_t eclipsa_studio_mix_renderer_loudness_range(
    eclipsa_studio_mix_renderer_t* r, float* out_lra_lu,
    int32_t* out_is_stable);

// Signal-overload stats for one element of the measured render, keyed
// by the element_id passed to eclipsa_studio_mix_renderer_add_element. Counted
// on the element's own stream output (gain/routing/resample applied) —
// the same PCM the IAMF export would encode — not on the limited mix,
// so element overs are visible here while the measured peaks clamp.
// Same |x| strictly > 1.0 semantics as
// eclipsa_studio_iamf_push_export_element_clip_stats. Returns 0 and fills the
// out pointers (either may be NULL), -1 on a null handle, unknown id,
// or before a successful measure.
int32_t eclipsa_studio_mix_renderer_element_clip_stats(
    eclipsa_studio_mix_renderer_t* r, uint32_t element_id,
    uint64_t* out_clipped_samples, float* out_peak_linear);

// Destroy a renderer.
void eclipsa_studio_mix_renderer_destroy(eclipsa_studio_mix_renderer_t* r);

// ── Offline IAMF measurer (QC loudness measurement) ──────────────────────────
// Decodes an IAMF file (.iamf or IAMF-in-MP4) offline, renders a
// selection of its audio elements at one layout and measures the render
// with the same analyzer, weights, limiter and traces as the offline mix
// renderer above. One instance measures one row of the QC Loudness
// Report (one mix presentation sub-mix at one layout), with one
// _measure call; a second _measure on the same handle fails. Control
// thread or worker isolate only; the caller holds the graph's offline-exclusive
// access (eclipsa_studio_engine_set_export_paused) for the whole pass.

// Opaque handle for an offline IAMF measurer instance.
typedef struct eclipsa_studio_iamf_measurer eclipsa_studio_iamf_measurer_t;

// Open `path` and initialise the renderer for `layout` (oar_layout_t
// values as for eclipsa_studio_mix_renderer_create) at the file's sample
// rate, with `buffer_size` frames per render block. Scans the whole
// file. Returns NULL on failure (details in the engine log).
eclipsa_studio_iamf_measurer_t* eclipsa_studio_iamf_measurer_create(
    const char* path, uint32_t buffer_size, uint32_t layout);

// Include the audio element `audio_element_id` in the render with a
// static mix gain (the mix presentation's default element gain plus the
// sub-mix output gain folded in by the caller, or the element gain alone
// with the output gain passed to _set_output_gain) and its IAMF
// rendering config (headphones_mode 0=stereo, 1=binaural world-locked,
// 2=binaural head-locked; binaural_profile 0=ambient, 1=direct,
// 2=reverberant). Elements not included render nothing. Returns 0 on
// success, -1 on a null handle, -2 for an unknown id or an element OAR
// cannot render (details in the engine log).
int32_t eclipsa_studio_iamf_measurer_include_element(
    eclipsa_studio_iamf_measurer_t* m, uint32_t audio_element_id,
    float mix_gain_db, uint32_t headphones_mode, uint32_t binaural_profile);

// Set the sub-mix output gain in dB.
void eclipsa_studio_iamf_measurer_set_output_gain(
    eclipsa_studio_iamf_measurer_t* m, float gain_db);

// Decode, render and measure the whole program. Same return codes and
// out-pointer contract as eclipsa_studio_mix_renderer_measure: 0 on
// success, -1 on a null handle, -2 when the pass failed (nothing
// included, decode error, renderer error — details in the engine log
// and eclipsa_studio_iamf_measurer_last_error; the out values are not
// written), -5 for a C++ exception at the FFI boundary.
int32_t eclipsa_studio_iamf_measurer_measure(eclipsa_studio_iamf_measurer_t* m,
                                             float* out_integrated_lufs,
                                             float* out_true_peak_dbtp,
                                             float* out_digital_peak_dbfs);

// Post-measurement time series and loudness range, with the same series
// ids, step and contract as the eclipsa_studio_mix_renderer_* queries.
uint32_t eclipsa_studio_iamf_measurer_trace_len(
    eclipsa_studio_iamf_measurer_t* m, uint32_t series);
uint32_t eclipsa_studio_iamf_measurer_copy_trace(
    eclipsa_studio_iamf_measurer_t* m, uint32_t series, float* out,
    uint32_t cap);
int32_t eclipsa_studio_iamf_measurer_loudness_range(
    eclipsa_studio_iamf_measurer_t* m, float* out_lra_lu,
    int32_t* out_is_stable);

// The last failure message of this instance (prefixed `invalid_argument:`,
// `io:`, `malformed:`, `unsupported:` or `internal:`), or "" after a
// success. Owned by the measurer; valid until the next call on it.
const char* eclipsa_studio_iamf_measurer_last_error(
    eclipsa_studio_iamf_measurer_t* m);

// Destroy a measurer.
void eclipsa_studio_iamf_measurer_destroy(eclipsa_studio_iamf_measurer_t* m);

// ── Info
// ────────────────────────────────────────────────────────────────────── Note:
// eclipsa_studio_peaks_compute / eclipsa_studio_peaks_free /
// eclipsa_studio_peaks_level_data are declared in waveform/peak_compute.h
// (included above).

const char* eclipsa_studio_version(void);

/// The ECLIPSA_STUDIO_ENGINE_API_VERSION the loaded library was compiled with.
/// See the stability policy at the top of this header.
int32_t eclipsa_studio_api_version(void);

#ifdef __cplusplus
}
#endif

#endif  // ECLIPSA_STUDIO_ENGINE_H_
