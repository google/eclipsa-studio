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

#include "iamf/iamf_playback_session.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <string>

#include "absl/time/time.h"
#include "engine_log.h"
#include "iamf/iamf_demuxer.h"
#include "iamf/include/iamf_tools/iamf_stream_factory.h"
#include "iamf/include/iamf_tools/iamf_stream_settings.h"
#include "iamf/include/iamf_tools/iamf_tools_api_types.h"

using iamf_tools::api::AudioElementDescriptor;
using iamf_tools::api::AudioElementKind;
using iamf_tools::api::IamfStatus;
using iamf_tools::api::IamfStreamFactory;
using iamf_tools::api::IamfStreamSettings;

namespace {

// Per-AE ring capacity in frames. Sized for ~700 ms of headroom at
// 48 kHz (32768 / 48000 ≈ 0.68 s) so the audio thread can ride
// through transient I/O thread stalls (page faults, GC pauses,
// upstream `WaitForScanComplete` blocking on a busy mutex). Power
// of two so PcmRing's wrap is a mask. Memory cost is bounded:
// 32768 frames × 16 channels × 4 B ≈ 2 MB per AE.
constexpr uint32_t kRingCapacityFrames = 32768;

// Per-pump headroom required across *every* ring before we issue a
// `NextTemporalUnit` call. Sized larger than any plausible TU frame
// count (Opus tops out around 1920 frames at 48 kHz / 40 ms; AAC
// 1024; FLAC up to 4608) so a single pump can never over-fill any
// ring. Gating on the *minimum* per-ring free-space prevents the
// previous "any hungry → pump" design from silently truncating a
// TU's write into a near-full ring and desynchronising AEs by the
// dropped sample count.
constexpr uint32_t kPumpHeadroomFrames = 8192;

// Low-water mark for the scan-throttle override. While the lazy scan
// is still running the pump normally yields 1 ms per TU so the scan
// worker can interleave — but when any consumed ring drops below this
// level, playback is about to starve and wins over the scan: the
// yield is skipped until every ring recovers (ES-90). Half the ring
// (~340 ms at 48 kHz) leaves a wide hysteresis band below the pump
// gate (capacity - kPumpHeadroomFrames ≈ 24576), so the override
// engages well before the audio thread reaches an empty ring.
constexpr uint32_t kScanLowWaterFrames = kRingCapacityFrames / 2;

// Idle-sleep when no AE ring needs more data and we're not at EOF.
constexpr auto kIdleSleep = std::chrono::milliseconds(2);

// EOF sleep — once upstream returns 0 frames, there's no more data
// coming until a seek. Wake more sparingly.
constexpr auto kEofSleep = std::chrono::milliseconds(50);

int32_t KindToInt(AudioElementKind k) {
  switch (k) {
    case AudioElementKind::kChannel:
      return 0;
    case AudioElementKind::kScene:
      return 1;
    case AudioElementKind::kObject:
      return 2;
  }
  return 0;
}

}  // namespace

IamfPlaybackSession::IamfPlaybackSession() = default;

IamfPlaybackSession::~IamfPlaybackSession() { close(); }

bool IamfPlaybackSession::open(const char* path) {
  close();
  if (path == nullptr || *path == '\0') {
    set_error("invalid_argument: empty path");
    return false;
  }
  using clock = std::chrono::steady_clock;
  const auto t0 = clock::now();
  if (!map_file(path)) return false;
  const auto t_map = clock::now();

  // IAMF-in-ISOBMFF (.mp4/.mov) deliverables: demux the `iamf` track into a
  // standalone bitstream and play it from memory. The mmap was only needed
  // to sniff the container — libgpac reopens the path itself, so release it
  // before handing off to the in-memory path (which owns its own copy).
  if (eclipsa_studio::IamfDemuxer::IsIsoBmff(mapped_bytes_, mapped_len_)) {
    unmap_file();
    std::vector<uint8_t> iamf_bytes;
    // The QC-open probe demuxed this same file moments ago and stashed the
    // result; reuse it instead of re-parsing the container (ES-215). Falls
    // through to a fresh demux when there's no matching stash (a direct open
    // with no preceding probe — tests, CLI).
    if (!eclipsa_studio::TakeIamfDemux(path, &iamf_bytes)) {
      eclipsa_studio::IamfDemuxer demuxer;
      if (!demuxer.DemuxToBytes(path, &iamf_bytes)) {
        set_error(demuxer.last_error());
        return false;
      }
    }
    return open_from_memory(iamf_bytes.data(), iamf_bytes.size());
  }

  // Lazy temporal-unit scan: `OpenFromBytes` returns after descriptor
  // parse + codec init only; the upstream library walks the temporal
  // units on a worker thread. Scan progress surfaces via
  // `is_scan_complete()` for the timeline duration.
  IamfStreamSettings settings;
  settings.lazy_temporal_unit_scan = true;
  IamfStatus status = IamfStreamFactory::OpenFromBytes(
      mapped_bytes_, mapped_len_, settings, stream_);
  if (!status.ok()) {
    set_error(status.error_message);
    stream_.reset();
    unmap_file();
    return false;
  }
  const auto t_open = clock::now();
  if (!configure_from_open_stream()) {
    stream_.reset();
    unmap_file();
    return false;
  }
  start_io_thread();

  using ms = std::chrono::duration<double, std::milli>;
  char buf[192];
  std::snprintf(buf, sizeof(buf),
                "session open: %.1f MB in %.1f ms (mmap=%.1f, factory=%.1f, "
                "configure=%.1f)",
                static_cast<double>(mapped_len_) / (1024.0 * 1024.0),
                ms(clock::now() - t0).count(), ms(t_map - t0).count(),
                ms(t_open - t_map).count(), ms(clock::now() - t_open).count());
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "iamf", buf);
  return true;
}

bool IamfPlaybackSession::open_from_memory(const uint8_t* bytes, size_t len) {
  close();
  if (bytes == nullptr || len == 0) {
    set_error("invalid_argument: empty buffer");
    return false;
  }
  owned_bytes_.assign(bytes, bytes + len);
  mapped_bytes_ = owned_bytes_.data();
  mapped_len_ = owned_bytes_.size();

  IamfStreamSettings settings;
  settings.lazy_temporal_unit_scan = true;
  IamfStatus status = IamfStreamFactory::OpenFromBytes(
      mapped_bytes_, mapped_len_, settings, stream_);
  if (!status.ok()) {
    set_error(status.error_message);
    stream_.reset();
    owned_bytes_.clear();
    mapped_bytes_ = nullptr;
    mapped_len_ = 0;
    return false;
  }
  if (!configure_from_open_stream()) {
    stream_.reset();
    owned_bytes_.clear();
    mapped_bytes_ = nullptr;
    mapped_len_ = 0;
    return false;
  }
  start_io_thread();
  return true;
}

bool IamfPlaybackSession::configure_from_open_stream() {
  sample_rate_ = stream_->GetSampleRate();
  total_frames_ = stream_->GetTotalSamples();
  pump_cursor_.store(0, std::memory_order_relaxed);
  io_eof_.store(false, std::memory_order_relaxed);
  seek_target_.store(0, std::memory_order_relaxed);
  seek_request_count_.store(0, std::memory_order_relaxed);
  seeks_applied_.store(0, std::memory_order_relaxed);
  seek_observed_count_ = 0;
  scan_completion_logged_ = false;
  scan_override_active_ = false;
  partial_tu_logged_ = false;
  {
    std::lock_guard<std::mutex> lk(error_mu_);
    last_error_.clear();
  }

  const uint32_t num_ae = stream_->GetNumAudioElements();
  ae_info_.resize(num_ae);
  rings_.clear();
  rings_.reserve(num_ae);
  // std::atomic<float> is non-movable / non-copyable; rebuild the
  // vector with `num_ae` default-constructed (zero-initialised) slots
  // rather than mutating an existing vector.
  ae_latest_mix_gain_ = std::vector<std::atomic<float>>(num_ae);

  // Mirror upstream's `AudioElementDescriptor` straight into our
  // `AeInfo`. Channel-based AEs carry the `OutputLayout` enum value
  // in `layout_info` (cast to int32_t); scene AEs carry the
  // ambisonics order; object AEs carry num_substreams. The
  // OAR-renderer-capability narrowing happens at the
  // `eclipsa_studio_playback_open` call site, where the OAR sub_type is
  // also derived from the same field.
  for (uint32_t i = 0; i < num_ae; ++i) {
    const AudioElementDescriptor d = stream_->GetAudioElement(i);
    AeInfo& info = ae_info_[i];
    info.audio_element_id = d.audio_element_id;
    info.kind = KindToInt(d.kind);
    info.num_channels = d.num_channels;
    info.layout_info = d.layout_info;
    info.loudspeaker_layout_raw = d.loudspeaker_layout_raw;
    info.expanded_loudspeaker_layout_raw = d.expanded_loudspeaker_layout_raw;
    info.supported = d.supported;

    auto ring = std::make_unique<PcmRing>();
    // Zero-channel AEs (e.g. an unsupported AE we still claim a slot
    // for) get a 1-channel placeholder so the ring is well-formed;
    // the I/O thread skips them and the consumer never reads.
    const uint32_t ch = d.num_channels == 0 ? 1 : d.num_channels;
    ring->configure(ch, kRingCapacityFrames);
    rings_.push_back(std::move(ring));
    ae_latest_mix_gain_[i].store(0.0f, std::memory_order_relaxed);
  }
  return true;
}

void IamfPlaybackSession::close() {
  stop_io_thread();
  stream_.reset();
  unmap_file();
  owned_bytes_.clear();
  mapped_bytes_ = nullptr;
  mapped_len_ = 0;

  sample_rate_ = 0;
  total_frames_ = 0;
  pump_cursor_.store(0, std::memory_order_relaxed);
  io_eof_.store(false, std::memory_order_relaxed);
  ae_info_.clear();
  rings_.clear();
  ae_latest_mix_gain_.clear();
  tu_.samples_per_ae.clear();
  tu_.mix_gain_db_per_ae.clear();
  tu_.frames_produced = 0;
}

IamfPlaybackSession::AeInfo IamfPlaybackSession::ae_info(
    uint32_t ae_index) const {
  if (ae_index >= ae_info_.size()) return {};
  return ae_info_[ae_index];
}

bool IamfPlaybackSession::seek_to_frame(uint64_t frame_pos) {
  if (!stream_) return false;
  // Only clamp once the upstream lazy scan has published a real
  // duration. Before that, `total_frames_ == 0` and clamping would
  // silently snap every seek to frame 0 — a particularly nasty UX
  // bug where the timeline appears to refuse to scrub during the
  // first ~minute after open. The I/O thread will surface an upstream
  // error if the requested frame is past EOF.
  if (total_frames_ > 0) {
    frame_pos = std::min(frame_pos, total_frames_);
  }
  // Clear EOF on all rings up front so observers (audio thread,
  // tests waiting on `wait_for_buffered`) don't mistake stale post-
  // drain EOF for "no more data ever". The I/O thread will replay
  // the clear after `Seek` succeeds; doing it on both sides is
  // idempotent and races nothing — `clear_eof` is an atomic store.
  for (auto& r : rings_) {
    if (r) r->clear_eof();
  }
  seek_target_.store(frame_pos, std::memory_order_release);
  seek_request_count_.fetch_add(1, std::memory_order_acq_rel);
  // Wake the I/O thread if it's idle on the EOF sleep or saturated.
  std::lock_guard<std::mutex> lk(io_mu_);
  io_cv_.notify_one();
  return true;
}

void IamfPlaybackSession::post_seek_rt(uint64_t frame_pos) {
  if (!stream_) return;
  // Same as seek_to_frame() minus the total_frames_ clamp (not
  // audio-thread readable — the control thread clamps at staging
  // time) and minus the io_cv_ notify (taking io_mu_ on the audio
  // thread risks priority inversion). The I/O thread's idle waits are
  // bounded, so the request lands within one poll interval.
  for (auto& r : rings_) {
    if (r) r->clear_eof();
  }
  seek_target_.store(frame_pos, std::memory_order_release);
  seek_request_count_.fetch_add(1, std::memory_order_acq_rel);
}

float IamfPlaybackSession::latest_mix_gain_db(uint32_t ae_index) const {
  if (ae_index >= ae_latest_mix_gain_.size()) return 0.0f;
  return ae_latest_mix_gain_[ae_index].load(std::memory_order_acquire);
}

bool IamfPlaybackSession::is_scan_complete() const {
  return stream_ ? stream_->IsScanComplete() : false;
}

bool IamfPlaybackSession::is_total_samples_ready() const {
  return stream_ ? stream_->IsTotalSamplesReady() : false;
}

uint64_t IamfPlaybackSession::refresh_total_frames() {
  if (!stream_) return total_frames_;
  if (stream_->IsTotalSamplesReady()) {
    total_frames_ = stream_->GetTotalSamples();
  }
  return total_frames_;
}

bool IamfPlaybackSession::wait_for_scan_complete() {
  if (!stream_) return false;
  const IamfStatus status =
      stream_->WaitForScanComplete(absl::InfiniteDuration());
  if (!status.ok()) {
    set_error(status.error_message);
    return false;
  }
  refresh_total_frames();
  return true;
}

uint32_t IamfPlaybackSession::buffered_frames(uint32_t ae_index) const {
  if (ae_index >= rings_.size()) return 0;
  return rings_[ae_index]->buffered_frames();
}

bool IamfPlaybackSession::wait_for_buffered(uint32_t ae_index,
                                            uint32_t target_frames,
                                            uint32_t timeout_ms) {
  if (ae_index >= rings_.size()) return false;
  PcmRing* r = rings_[ae_index].get();
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (std::chrono::steady_clock::now() < deadline) {
    if (r->eof() || r->buffered_frames() >= target_frames) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return r->eof() || r->buffered_frames() >= target_frames;
}

std::string IamfPlaybackSession::last_error() const {
  std::lock_guard<std::mutex> lk(error_mu_);
  return last_error_;
}

void IamfPlaybackSession::set_error(std::string msg) {
  std::lock_guard<std::mutex> lk(error_mu_);
  last_error_ = std::move(msg);
}

void IamfPlaybackSession::start_io_thread() {
  io_should_stop_.store(false, std::memory_order_relaxed);
  io_thread_ = std::thread(&IamfPlaybackSession::io_loop, this);
}

void IamfPlaybackSession::stop_io_thread() {
  if (!io_thread_.joinable()) return;
  io_should_stop_.store(true, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lk(io_mu_);
    io_cv_.notify_one();
  }
  io_thread_.join();
}

void IamfPlaybackSession::io_loop() {
  while (!io_should_stop_.load(std::memory_order_acquire)) {
    // Service any pending seek first. Coalesce: only the latest
    // target matters, so skipping intermediate states is correct.
    const uint64_t cur_seek_count =
        seek_request_count_.load(std::memory_order_acquire);
    if (cur_seek_count != seek_observed_count_) {
      const uint64_t target = seek_target_.load(std::memory_order_acquire);
      const IamfStatus seek_status = stream_->Seek(target);
      if (!seek_status.ok()) {
        // Seek failed — the upstream stream may be in an unknown
        // state. Halt the pump path: log, record the error, mark
        // EOF on every ring + on `io_eof_` so the audio thread
        // reads silence, and consider this seek "observed" so we
        // don't retry the same broken target every loop iteration.
        // The consumer can recover by issuing a *new* seek, which
        // bumps the request count and triggers a fresh attempt.
        char msg[256];
        std::snprintf(msg, sizeof(msg), "io_loop: Seek(%llu) failed: %s",
                      static_cast<unsigned long long>(target),
                      seek_status.error_message.c_str());
        engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf", msg);
        set_error(seek_status.error_message);
        io_eof_.store(true, std::memory_order_release);
        for (auto& r : rings_) r->mark_eof();
        seek_observed_count_ = cur_seek_count;
        // The outcome (EOF-marked rings) is visible — count the
        // request as applied so a prime check waiting on
        // seeks_applied() unblocks and observes the EOF instead of
        // stalling muted forever.
        seeks_applied_.store(cur_seek_count, std::memory_order_release);
        continue;
      }
      pump_cursor_.store(target, std::memory_order_release);
      io_eof_.store(false, std::memory_order_release);
      // Publish the discard floor so the audio thread skips any
      // still-buffered pre-seek frames on its next read. Each ring
      // gets its current head as the discard target — the consumer
      // jumps to that point, then reads the post-seek data we
      // pump below.
      for (auto& r : rings_) {
        r->clear_eof();
        r->publish_discard_to(r->head_pos());
      }
      seek_observed_count_ = cur_seek_count;
      // Floors are published: buffered_frames() now counts post-seek
      // frames only. Release AFTER the publish loop so an observer of
      // seeks_applied() also sees the floors (ES-473 prime check).
      seeks_applied_.store(cur_seek_count, std::memory_order_release);
      partial_tu_logged_ = false;  // re-arm the partial-TU diagnostic
      continue;                    // re-check stop / new seeks before pumping
    }

    // EOF: nothing more to pump until a seek arrives.
    if (io_eof_.load(std::memory_order_acquire)) {
      std::unique_lock<std::mutex> lk(io_mu_);
      io_cv_.wait_for(lk, kEofSleep, [&] {
        return io_should_stop_.load(std::memory_order_acquire) ||
               seek_request_count_.load(std::memory_order_acquire) !=
                   seek_observed_count_;
      });
      continue;
    }

    // Pump only if *every* ring has at least one TU's worth of
    // headroom. The previous "any hungry → pump" gate could let a
    // pump fire when one ring was hungry and another was nearly
    // full; the second ring's `write_interleaved` would then
    // truncate, dropping samples for that AE only and desynchronising
    // the AEs by the dropped count. Gating on the minimum free
    // space keeps every per-AE write whole.
    bool all_have_room = true;
    for (auto& r : rings_) {
      if (r->free_frames() < kPumpHeadroomFrames) {
        all_have_room = false;
        break;
      }
    }
    if (!all_have_room) {
      std::unique_lock<std::mutex> lk(io_mu_);
      io_cv_.wait_for(lk, kIdleSleep, [&] {
        return io_should_stop_.load(std::memory_order_acquire) ||
               seek_request_count_.load(std::memory_order_acquire) !=
                   seek_observed_count_;
      });
      continue;
    }

    // While the upstream lazy-scan worker is still walking the
    // file, sleep briefly so it can grab the stream's internal
    // state between our pump calls. Without this, our tight pump
    // loop holds upstream busy and the scan never completes —
    // leaving the timeline duration forever at zero. 1 ms ≈ one
    // Opus TU's worth of decode wall-time, enough to interleave.
    //
    // Exception: playback wins over the scan. When any consumed
    // ring is below the low-water mark — initial fill after open,
    // post-seek refill, or the audio thread out-draining a
    // throttled pump — skip the yield and pump at full speed until
    // every ring recovers; a starved ring plays as silence (ES-90).
    // The scan still progresses: once the rings are comfortable the
    // throttle re-engages, and a saturated pump idles in the
    // headroom wait above.
    //
    // Once `IsScanComplete()` flips true we revert to no-throttle
    // pumping for max throughput.
    if (stream_ != nullptr && !stream_->IsScanComplete()) {
      bool below_low_water = false;
      for (uint32_t i = 0; i < rings_.size(); ++i) {
        // Skip placeholder rings for zero-channel AEs — they are
        // never written, so they would pin the override on forever
        // and starve the scan.
        if (ae_info_[i].num_channels == 0) continue;
        if (rings_[i]->buffered_frames() < kScanLowWaterFrames) {
          below_low_water = true;
          break;
        }
      }
      if (below_low_water != scan_override_active_) {
        scan_override_active_ = below_low_water;
        engine_log(ECLIPSA_STUDIO_LOG_INFO, "iamf",
                   below_low_water
                       ? "io_loop: ring below low-water during scan — "
                         "pumping full-speed"
                       : "io_loop: rings recovered — scan throttle "
                         "re-engaged");
      }
      if (!below_low_water) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    } else if (!scan_completion_logged_) {
      scan_completion_logged_ = true;
      engine_log(ECLIPSA_STUDIO_LOG_INFO, "iamf",
                 "io_loop: scan complete, switching to full-throttle "
                 "pumping");
    }

    // Pump one TU.
    const IamfStatus status = stream_->NextTemporalUnit(tu_);
    if (!status.ok()) {
      char msg[256];
      std::snprintf(msg, sizeof(msg),
                    "io_loop: NextTemporalUnit failed at cursor %llu: %s",
                    static_cast<unsigned long long>(
                        pump_cursor_.load(std::memory_order_relaxed)),
                    status.error_message.c_str());
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf", msg);
      set_error(status.error_message);
      io_eof_.store(true, std::memory_order_release);
      for (auto& r : rings_) r->mark_eof();
      continue;
    }
    if (tu_.frames_produced == 0) {
      io_eof_.store(true, std::memory_order_release);
      for (auto& r : rings_) r->mark_eof();
      continue;
    }

    const uint32_t num_ae = static_cast<uint32_t>(ae_info_.size());
    bool halt_pump = false;
    // Diagnostic accounting for the "partial temporal unit" case
    // (ES-238): how many real (non-placeholder) AEs exist this TU, how
    // many actually carried frames, and the first one that came back
    // empty. An empty AE skips its ring write below and starves.
    uint32_t real_ae = 0;
    uint32_t produced_ae = 0;
    uint32_t first_empty_ae = UINT32_MAX;
    for (uint32_t i = 0; i < num_ae; ++i) {
      const uint32_t ch = ae_info_[i].num_channels;
      if (ch == 0 || i >= tu_.samples_per_ae.size()) continue;
      ++real_ae;
      const std::vector<float>& src = tu_.samples_per_ae[i];
      // Channel-width contract (ES-265): a non-empty TU buffer must hold
      // exactly frames_produced frames of `ch` channels (the same check
      // iamf_extract_main makes). When the stream API and the descriptor
      // disagree — as with the pre-fix mixed-order ambisonics packing,
      // where 7-channel TUs arrived against a 16-channel descriptor —
      // dividing by `ch` silently reinterprets the buffer and plays fast
      // and garbled with desynced rings. Halt loudly instead. (An empty
      // buffer is the ES-238 partial-TU case, diagnosed below, not here.)
      const uint64_t expected = static_cast<uint64_t>(tu_.frames_produced) * ch;
      if (!src.empty() && src.size() != expected) {
        char msg[224];
        std::snprintf(msg, sizeof(msg),
                      "io_loop: AE %u delivered %zu samples for %u frames * "
                      "%u channels (expected %llu); halting instead of "
                      "reinterpreting the buffer",
                      i, src.size(), tu_.frames_produced, ch,
                      static_cast<unsigned long long>(expected));
        engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", msg);
        set_error("internal: temporal unit channel-width mismatch");
        halt_pump = true;
        break;
      }
      const uint32_t frames = static_cast<uint32_t>(src.size() / ch);
      if (frames == 0) {
        if (first_empty_ae == UINT32_MAX) first_empty_ae = i;
        continue;
      }
      ++produced_ae;
      // The headroom check above sized this write, but a shortfall
      // here is NOT proof of inconsistency: a read entering
      // read_planar() between the gate and this write can briefly
      // hide the discard floor from free_frames() (the guard raises
      // before the entry loads settle the tail — see read_planar()),
      // and a descheduled audio thread can hold that window open for
      // milliseconds. The space reappears as soon as the read's
      // entry completes, so retry the remainder with a deadline and
      // reserve the halt for a shortfall that never resolves —
      // halting mid-TU would desync AEs (different rings advanced by
      // different counts) and kill playback until the next seek.
      uint32_t written = rings_[i]->write_interleaved(src.data(), frames);
      if (written != frames) {
        const auto retry_deadline =
            std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
        while (written < frames &&
               !io_should_stop_.load(std::memory_order_acquire) &&
               std::chrono::steady_clock::now() < retry_deadline) {
          std::this_thread::yield();
          written += rings_[i]->write_interleaved(
              src.data() + static_cast<size_t>(written) * ch, frames - written);
        }
      }
      if (written != frames) {
        char msg[192];
        std::snprintf(msg, sizeof(msg),
                      "io_loop: ring %u truncated write: %u of %u frames "
                      "(headroom check failed); halting to avoid AE desync",
                      i, written, frames);
        engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", msg);
        set_error("internal: ring truncation");
        halt_pump = true;
        break;
      }
      if (i < tu_.mix_gain_db_per_ae.size()) {
        ae_latest_mix_gain_[i].store(tu_.mix_gain_db_per_ae[i],
                                     std::memory_order_release);
      }
    }
    // A TU that fed some AEs but not all (and not a whole-stream EOF,
    // which `frames_produced == 0` already handled above) leaves the
    // empty AEs' rings unwritten while the others advance — the most
    // likely shape of ES-238's "one ring goes quiet after a seek". Log
    // it once per seek so a field repro confirms or rules out this
    // path without flooding the log.
    if (!halt_pump && produced_ae > 0 && produced_ae < real_ae &&
        !partial_tu_logged_) {
      partial_tu_logged_ = true;
      char msg[192];
      std::snprintf(
          msg, sizeof(msg),
          "io_loop: partial temporal unit at cursor %llu — %u/%u AEs carried "
          "frames (first empty AE=%u); its ring will starve until a reseek",
          static_cast<unsigned long long>(
              pump_cursor_.load(std::memory_order_relaxed)),
          produced_ae, real_ae, first_empty_ae);
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf", msg);
    }
    if (halt_pump) {
      io_eof_.store(true, std::memory_order_release);
      for (auto& r : rings_) r->mark_eof();
      continue;
    }
    pump_cursor_.fetch_add(tu_.frames_produced, std::memory_order_release);
  }
}

bool IamfPlaybackSession::map_file(const char* path) {
  std::string err;
  if (!file_map_.open(path, &err)) {
    set_error(err.c_str());
    return false;
  }
  // Hint sequential access so the kernel pre-reads aggressively as
  // the upstream factory walks the descriptor OBUs and as the I/O
  // thread later pumps temporal units in order.
  file_map_.hint_sequential();
  mapped_bytes_ = file_map_.data();
  mapped_len_ = file_map_.size();
  return true;
}

void IamfPlaybackSession::unmap_file() {
  file_map_.close();
  // Drop the borrowed view so it can't dangle past the unmap — the MP4
  // path sniffs the mmap, unmaps it, then demuxes from the path and hands
  // owned bytes to open_from_memory.
  mapped_bytes_ = nullptr;
  mapped_len_ = 0;
}
