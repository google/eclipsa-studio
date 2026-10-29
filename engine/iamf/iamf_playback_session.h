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

#ifndef ECLIPSA_STUDIO_IAMF_IAMF_PLAYBACK_SESSION_H_
#define ECLIPSA_STUDIO_IAMF_IAMF_PLAYBACK_SESSION_H_

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "iamf/iamf_demuxer.h"
#include "iamf/include/iamf_tools/iamf_stream_interface.h"
#include "iamf/pcm_ring.h"
#include "iamf/read_only_file_map.h"

/// One-file playback coordinator for a .iamf stream.
///
/// Owns a single `iamf_tools::api::IamfStreamInterface` plus per-AE
/// SPSC PCM rings (`PcmRing`). A dedicated I/O thread, spawned on
/// `open()`, is the *only* thread that calls upstream
/// `NextTemporalUnit` / `Seek` (`WaitForScanComplete` and the scan
/// getters are upstream-documented thread-safe and are called from
/// the control thread); the audio thread reads from the rings and
/// never blocks on decode. This breaks the previous
/// architecture's contention between upstream's lazy-scan worker and
/// the audio callback's pump path — the scan and decode now happen on
/// the same thread (this one), and the audio thread is a pure consumer.
///
/// Threading contract:
///   - Producer (this session's I/O thread): `NextTemporalUnit`,
///     `Seek`, ring writes, mix-gain publishes, EOF/error publishes.
///   - Consumer (audio thread, via `IamfRingSource::read`): ring reads,
///     mix-gain reads. Never touches the upstream stream.
///   - Control thread (e.g. Dart FFI): `seek_to_frame()` posts a
///     request (and clears the rings' atomic EOF latches); `close()`
///     joins the I/O thread; `last_error()` reads a mutex-protected
///     snapshot. Ring/stream access is limited to atomics and
///     upstream calls documented thread-safe — the control thread
///     never reads or writes ring sample data, and never drives the
///     stream's decode path.
///
/// Lifecycle:
///   1. `open()` / `open_from_memory()` parses descriptors, sizes
///       the rings, spawns the I/O thread. Returns synchronously.
///   2. The I/O thread starts pumping immediately so the rings are
///       primed before `IamfRingSource::read` is first called.
///   3. `IamfRingSource::attach(session, ae_index)` binds a per-slot
///       view; multiple ring sources read from the same session.
///   4. `seek_to_frame(pos)` posts a request. The I/O thread serves it
///       from the rings when every ring still holds `pos` (discard
///       floors up to `pos`, pump left running), as end of stream when
///       `pos` is at or past a known end, and otherwise with upstream
///       `Seek` followed by a discard floor at every ring's head. In each
///       case the audio thread skips the discarded samples on its next
///       read.
///   5. `close()` (or destruction) signals the I/O thread to stop and
///       joins it before tearing down the stream.
class IamfPlaybackSession {
 public:
  /// Per-AE descriptor the graph consumes when claiming slots.
  ///
  /// Mirrors upstream's `iamf_tools::api::AudioElementDescriptor`
  /// 1:1. `layout_info`'s meaning is kind-dependent (matches the
  /// upstream contract):
  ///   - `kind == 0` (channel): `OutputLayout` enum value cast to
  ///     int32_t (e.g. `kItu2051_SoundSystemA_0_2_0 = 0` for
  ///     stereo). `-1` when the layout has no canonical
  ///     `OutputLayout` (e.g. an Expanded sub-layout other than
  ///     9.1.6). Cast to `OutputLayout` at the call site.
  ///   - `kind == 1` (scene): ambisonics order N (1, 2, 3, ...).
  ///   - `kind == 2` (object): number of objects in the AE.
  /// The raw coded layout pair (`loudspeaker_layout_raw` /
  /// `expanded_loudspeaker_layout_raw`, -1 sentinels for non-channel
  /// AEs) identifies every coded layout including Expanded
  /// sub-layouts; the OAR capability mapping
  /// (renderer/oar_capability.h) keys on it.
  /// `supported` reflects upstream's decode capability only — the
  /// renderer-capability narrowing (does OAR have a sub-renderer
  /// for this layout?) happens at the `eclipsa_studio_playback_open`
  /// registration site via `OarSubTypeForElement`.
  struct AeInfo {
    uint32_t audio_element_id = 0;
    int32_t kind = 0;
    uint32_t num_channels = 0;
    int32_t layout_info = 0;
    int32_t loudspeaker_layout_raw = -1;
    int32_t expanded_loudspeaker_layout_raw = -1;
    bool supported = false;
  };

  IamfPlaybackSession();
  ~IamfPlaybackSession();

  IamfPlaybackSession(const IamfPlaybackSession&) = delete;
  IamfPlaybackSession& operator=(const IamfPlaybackSession&) = delete;
  IamfPlaybackSession(IamfPlaybackSession&&) = delete;
  IamfPlaybackSession& operator=(IamfPlaybackSession&&) = delete;

  bool open(const char* path);
  bool open_from_memory(const uint8_t* bytes, size_t len);
  void close();

  bool is_open() const { return stream_ != nullptr; }

  uint32_t sample_rate() const { return sample_rate_; }
  uint64_t total_frames() const { return total_frames_; }
  uint32_t num_audio_elements() const {
    return static_cast<uint32_t>(ae_info_.size());
  }
  AeInfo ae_info(uint32_t ae_index) const;

  /// Lazy temporal-unit scan state (non-blocking, any thread).
  bool is_scan_complete() const;
  bool is_total_samples_ready() const;

  /// Refresh the cached `total_frames_` from the stream once the
  /// upstream scan publishes it. Returns the new total. Control
  /// thread ONLY: `total_frames_` is a plain (non-atomic) field, and
  /// every writer and reader lives on the control thread. Calling
  /// this from the I/O thread would race the control thread's reads.
  uint64_t refresh_total_frames();

  /// Block until the upstream temporal-unit scan finishes (success or
  /// failure), then refresh `total_frames_`. The scan runs on
  /// upstream's own worker thread; we just wait for it. Returns true
  /// on success, false on stream error or closed session.
  bool wait_for_scan_complete();

  /// Request a global seek. Posts to the I/O thread; the actual
  /// upstream `Seek` happens asynchronously. Returns true if the
  /// request was queued (session open), false if not.
  bool seek_to_frame(uint64_t frame_pos);

  /// RT-safe seek post for the audio thread (ES-473's mute-until-primed
  /// state machine). Same atomics as seek_to_frame() — target store,
  /// request-count bump, ring EOF clears — but no clamp (`frame_pos`
  /// must already be clamped against total_frames() by the control
  /// thread that staged it; total_frames_ is not audio-thread
  /// readable) and no io_cv_ notify, so no lock. The I/O thread's
  /// idle waits are bounded (2 ms pump-saturated / 50 ms at EOF), so
  /// the request is picked up on the next poll.
  void post_seek_rt(uint64_t frame_pos);

  /// Number of seek requests the I/O thread has fully APPLIED —
  /// upstream Seek done and every ring's discard floor published.
  /// Once this catches up to seeks_requested(), buffered_frames()
  /// counts post-seek frames only. The pair lets the audio thread's
  /// prime check avoid declaring "primed" on the stale pre-seek
  /// backlog in the window between posting a seek and the floors
  /// landing (ES-473).
  uint64_t seeks_applied() const {
    return seeks_applied_.load(std::memory_order_acquire);
  }

  /// Number of seek requests posted (seek_to_frame + post_seek_rt).
  uint64_t seeks_requested() const {
    return seek_request_count_.load(std::memory_order_acquire);
  }

  /// Number of applied seeks served from frames already in the rings,
  /// without repositioning the stream (informational).
  uint64_t seeks_served_from_rings() const {
    return seeks_served_from_rings_.load(std::memory_order_relaxed);
  }

  /// Last upstream-prefixed error message ("malformed:" / "io:" /
  /// "unsupported:" / "decode:" / "invalid_argument:") or empty.
  /// Thread-safe — guarded by an internal mutex.
  std::string last_error() const;

  /// Latest per-TU mix gain for this AE, in dB. Updated by the I/O
  /// thread on each `pump`; read by the audio thread via `IamfRingSource`.
  float latest_mix_gain_db(uint32_t ae_index) const;

  /// Frames currently buffered for AE `ae_index` in the ring.
  /// Best-effort observation; the I/O thread may add frames concurrently.
  uint32_t buffered_frames(uint32_t ae_index) const;

  /// Test/init helper: spin until the named AE has at least
  /// `target_frames` buffered, or `timeout_ms` elapses. Returns true
  /// on success (target reached or EOF). Tests rely on this because
  /// the I/O thread fills rings asynchronously after `open()`.
  bool wait_for_buffered(uint32_t ae_index, uint32_t target_frames,
                         uint32_t timeout_ms);

  // --- Ring access for `IamfRingSource`. ---
  PcmRing* ring(uint32_t ae_index) {
    return ae_index < rings_.size() ? rings_[ae_index].get() : nullptr;
  }

 private:
  // Opens the stream over `source`'s ranges and takes ownership of it on
  // success. `t0` is when open() started, for the timing log.
  bool open_mp4_source(std::unique_ptr<eclipsa_studio::IamfMp4Source> source,
                       std::chrono::steady_clock::time_point t0);
  bool configure_from_open_stream();
  // I/O thread. Serves a seek to file frame `target` from the rings when
  // every ring still holds it: publishes discard floors up to it and
  // leaves the pump where it is. Returns false (nothing changed) when the
  // stream has to seek instead.
  bool seek_within_rings(uint64_t target);
  // I/O thread. Serves a seek at or past the end of a stream whose
  // duration is known: empties the rings and marks them EOF. Returns false
  // (nothing changed) otherwise.
  bool seek_to_end(uint64_t target);
  bool map_file(const char* path);
  void unmap_file();

  void start_io_thread();
  void stop_io_thread();
  void io_loop();

  // Set the error message under `error_mu_` and publish a flag
  // so reads can short-circuit. Producer (I/O thread) only.
  void set_error(std::string msg);

  std::unique_ptr<iamf_tools::api::IamfStreamInterface> stream_;
  iamf_tools::api::TemporalUnitOutput tu_;  // owned by I/O thread

  uint32_t sample_rate_ = 0;
  uint64_t total_frames_ = 0;
  std::vector<AeInfo> ae_info_;

  // Per-AE SPSC rings (one per AE). Sized at `configure_from_open_stream`.
  std::vector<std::unique_ptr<PcmRing>> rings_;
  // Per-AE latest mix gain published by the I/O thread, read by the
  // audio thread. Atomic float so the audio thread can read without
  // a lock.
  std::vector<std::atomic<float>> ae_latest_mix_gain_;
  // File frame the next pumped frame is credited to: the target of the
  // last stream seek (0 at open) plus every frame pumped since. Written by
  // the I/O thread only, after the ring writes, so with rings_aligned_ each
  // written ring's head holds the frame before it. IamfStream::Seek lands on
  // the start of the temporal unit containing its target, so after a
  // non-zero stream seek this runs up to one temporal unit ahead of the
  // frames actually pumped; the offset carries unchanged through seeks
  // served from the rings.
  std::atomic<uint64_t> pump_cursor_{0};

  // I/O thread + control flags.
  std::thread io_thread_;
  std::atomic<bool> io_should_stop_{false};
  std::atomic<bool> io_eof_{false};

  // Seek request posting. The I/O thread serves the most recent
  // request; coalescing multiple seeks is fine because only the
  // final position matters.
  std::atomic<uint64_t> seek_target_{0};
  std::atomic<uint64_t> seek_request_count_{0};
  // Bumped by the I/O thread after a successful upstream Seek + ring
  // discard-floor publication (also on a failed Seek, which marks the
  // rings EOF — "applied" means "this request's outcome is visible").
  std::atomic<uint64_t> seeks_applied_{0};
  std::atomic<uint64_t> seeks_served_from_rings_{0};
  uint64_t seek_observed_count_ = 0;     // I/O thread only
  bool scan_completion_logged_ = false;  // I/O thread only
  // One-shot-per-seek latch for the "partial temporal unit" diagnostic
  // (ES-238): after a seek, did upstream hand back a TU with frames for
  // some AEs but zero for others? Such a TU makes the pump skip the
  // empty ring (it can't write zero frames), starving that AE until a
  // fresh seek. Logged once per seek so a sustained run doesn't spam.
  bool partial_tu_logged_ = false;  // I/O thread only
  // I/O thread only. True while every written ring has received every
  // pumped frame since the last stream seek, so ring positions map to
  // file frames through `pump_cursor_` (see seek_within_rings()).
  bool rings_aligned_ = true;
  // I/O thread only. True when the pump stopped because the stream ended
  // (not because of an error), so the rings hold every frame to the end.
  bool pump_at_end_ = false;
  // Scan-throttle override latch — true while a ring below low-water
  // has the pump running full-speed mid-scan. Logged on transitions
  // only. I/O thread only.
  bool scan_override_active_ = false;

  // Wakeup signal for the I/O thread when a seek is posted or the
  // ring frees up after being saturated. Not strictly required for
  // correctness — the thread also polls — but cuts seek latency.
  mutable std::mutex io_mu_;
  std::condition_variable io_cv_;

  mutable std::mutex error_mu_;
  std::string last_error_;

  // Backing bytes (mmap or owned copy from open_from_memory).
  // mapped_bytes_/mapped_len_ are the unified view consumed by upstream;
  // they point either into `file_map_.data()` or into `owned_bytes_`.
  const uint8_t* mapped_bytes_ = nullptr;
  size_t mapped_len_ = 0;
  eclipsa_studio::ReadOnlyFileMap file_map_;
  std::vector<uint8_t> owned_bytes_;
  // Set when an MP4's IAMF track is read in place; the stream reads its
  // ranges, so it must outlive `stream_`.
  std::unique_ptr<eclipsa_studio::IamfMp4Source> mp4_source_;
};

#endif  // ECLIPSA_STUDIO_IAMF_IAMF_PLAYBACK_SESSION_H_
