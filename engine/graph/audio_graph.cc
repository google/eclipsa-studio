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

#include "graph/audio_graph.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>

// Maximum change in mix gain per audio callback, applied on the audio
// thread before constructing the linear ramp to OAR. At ~94 callbacks/s
// (48 kHz / 512 frames) and 12 dB/callback, a huge step (e.g. a mute
// from 0 dB to -60 dB via text edit) fades over ~5 callbacks ≈ 53 ms.
// That's still a perceptible fade rather than an instant hard cut, but
// not a "no click" guarantee for every step — the clamp is primarily
// there to bound the first-callback discontinuity so OAR's internal
// interpolator stays within its linear operating region. Small fader
// drags within a few dB pass through in a single callback unchanged.
static constexpr float kMaxMixGainDbPerCallback = 12.0f;

// Monitor DIM (ES-629): depth as a linear gain (-20 dB) and the ramp
// time in each direction. The ramp is linear in gain over the full
// distance, so engage and release take the same time.
static constexpr float kMonitorDimGain = 0.1f;
static constexpr float kMonitorDimRampMs = 15.0f;

#include "dsp/gain.h"
#include "dsp/resampler.h"
#include "engine_log.h"
#include "graph/routing_scatter.h"
#include "iamf/iamf_playback_session.h"
#include "iamf/iamf_ring_source.h"
#include "io/wav_reader.h"
#include "meters/channel_stats.h"
#include "meters/loudness_meter.h"
#include "meters/peak_meter.h"
#include "meters/rms_meter.h"
#include "renderer/oar_renderer.h"

// LoudnessMeter::process() feeds blocks longer than its scratch capacity
// in chunks; keeping every graph block within that capacity keeps the
// audio thread on the single-chunk path.
static_assert(kGraphMaxFrames <= LoudnessMeter::kMaxBlockFrames,
              "graph blocks must fit the loudness meter's scratch");

namespace {

// Pink-noise injection is published from the control thread to the audio
// thread as a single packed 64-bit atomic — lock-free on every 64-bit target,
// so the audio thread always reads a consistent (mode, channel, amp) triple.
//   bits [0, 8)   mode    (0=off, 1=row pre-routing, 2=col post-routing)
//   bits [8, 32)  channel (row=OAR output channel, col=device channel)
//   bits [32, 64) amp     (linear gain, IEEE-754 float bit-pattern)
static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "noise injection relies on a lock-free 64-bit atomic");

struct NoiseState {
  uint8_t mode;
  uint32_t channel;
  float amp;
};

inline uint64_t pack_noise(uint8_t mode, uint32_t channel, float amp) {
  uint32_t amp_bits;
  std::memcpy(&amp_bits, &amp, sizeof(amp_bits));
  return static_cast<uint64_t>(mode) |
         (static_cast<uint64_t>(channel & 0xFFFFFFu) << 8) |
         (static_cast<uint64_t>(amp_bits) << 32);
}

inline NoiseState unpack_noise(uint64_t packed) {
  NoiseState s;
  s.mode = static_cast<uint8_t>(packed & 0xFFu);
  s.channel = static_cast<uint32_t>((packed >> 8) & 0xFFFFFFu);
  const uint32_t amp_bits = static_cast<uint32_t>(packed >> 32);
  std::memcpy(&s.amp, &amp_bits, sizeof(s.amp));
  return s;
}

// EclipsaStudioMeterState::elements[] is keyed by physical slot, so chain
// compaction must carry the meter slot along and zero the slot it
// vacates (ES-531). The sticky clip[] latch survives transport pauses by
// design, so a latch left behind pins a false overload marker on
// whichever element inherits the slot next. Member-wise assignment
// routes every atomic cell through RelaxedAtomic's copy operators (a
// relaxed load/store pair) — but the same assignment also copies the
// PLAIN arrays (sh_snapshot, stats_*), which the audio thread writes
// unsynchronized every process(). That is why callers MUST hold the
// audio-thread pause + callback-quiescence barrier: with it, no
// process() runs at all during the copy; without it, the plain-field
// copy would be a data race.
void clear_meter_slot(EclipsaStudioMeterState& state, uint32_t slot) {
  state.elements[slot] = EclipsaStudioMeterData{};
}

void move_meter_slot(EclipsaStudioMeterState& state, uint32_t dst,
                     uint32_t src) {
  state.elements[dst] = state.elements[src];
  clear_meter_slot(state, src);
}

}  // namespace

// --- ElementChain methods (defined here because unique_ptr needs complete
// types) ---

void ElementChain::reset() {
  id = 0;
  ctrl.reset();
  wav_reader.reset();
  resampler.reset();
  iamf_ring_source.reset();
  gain.reset();
  mute_gain.reset();
  peak_meter.reset();
  rms_meter.reset();
  channel_stats.reset();
  buf = AudioBuffer{};
  routing_map.store(nullptr, std::memory_order_relaxed);
  routing_active_slot = 0;
  routing_len = 0;
}

void ElementChain::move_from(ElementChain& src) {
  id = src.id;
  ctrl.copy_from(src.ctrl);
  wav_reader = std::move(src.wav_reader);
  resampler = std::move(src.resampler);
  iamf_ring_source = std::move(src.iamf_ring_source);
  gain = std::move(src.gain);
  mute_gain = std::move(src.mute_gain);
  peak_meter = std::move(src.peak_meter);
  rms_meter = std::move(src.rms_meter);
  channel_stats = std::move(src.channel_stats);
  buf = src.buf;
  // Move routing state. Note: routing_map pointer is recomputed below
  // to reference THIS chain's storage (pointers into src's storage are
  // about to become invalid when src.reset() clears them).
  std::memcpy(routing_storage_a, src.routing_storage_a,
              sizeof(routing_storage_a));
  std::memcpy(routing_storage_b, src.routing_storage_b,
              sizeof(routing_storage_b));
  routing_active_slot = src.routing_active_slot;
  routing_len = src.routing_len;
  const bool had_routing =
      src.routing_map.load(std::memory_order_relaxed) != nullptr;
  if (had_routing) {
    const int8_t* new_ptr =
        routing_active_slot == 0 ? routing_storage_a : routing_storage_b;
    routing_map.store(new_ptr, std::memory_order_release);
  } else {
    routing_map.store(nullptr, std::memory_order_relaxed);
  }
  src.reset();
}

AudioGraph::AudioGraph() = default;
AudioGraph::~AudioGraph() { shutdown(); }

bool AudioGraph::init(uint32_t sample_rate, uint32_t max_frames,
                      uint32_t channels) {
  sample_rate_ = sample_rate;
  max_frames_ = std::min(max_frames, kGraphMaxFrames);
  channels_ = std::min(channels, kGraphMaxChannels);

  // Identity routing default: OAR channel i feeds device channel i. With no
  // Dart push the scatter then reproduces the old flat 1:1 copy byte-for-byte
  // (never let an all-zero map reach the scatter as "mute everything").
  for (uint32_t i = 0; i < kMaxRoutingChannels; ++i) {
    routing_[i].store(1ull << i, std::memory_order_relaxed);
  }
  noise_.store(0, std::memory_order_relaxed);  // calibration off.
  update_output_rms_alpha();

  // OAR renderer — default to stereo layout.
  oar_renderer_ = std::make_unique<OarRenderer>();
  oar_renderer_->init(sample_rate_, max_frames_,
                      /*layout=*/2 /*ck_oar_layout_stereo*/);

  // Mix-bus loudness meter. Measures the post-OAR rendered output so the
  // number matches what iamf-tools would report for the same signal. Sized
  // to OAR's current layout; layout switches go through
  // set_monitoring_layout().
  mix_loudness_meter_ = std::make_unique<LoudnessMeter>(
      sample_rate_, oar_renderer_->channel_count(), oar_renderer_->layout());

  initialized_ = true;
  return true;
}

bool AudioGraph::set_sample_rate(uint32_t new_rate) {
  if (!initialized_ || new_rate == 0) return false;
  if (new_rate == sample_rate_) return true;
  const uint32_t old_rate = sample_rate_;
  sample_rate_ = new_rate;

  bool ok = true;
  update_output_rms_alpha();
  const uint32_t count = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < count; ++i) {
    ElementChain& chain = elements_[i];
    if (chain.peak_meter) chain.peak_meter->set_sample_rate(new_rate);
    if (chain.rms_meter) chain.rms_meter->set_sample_rate(new_rate);
    if (chain.channel_stats) chain.channel_stats->set_sample_rate(new_rate);

    uint32_t src_sr = 0;
    if (chain.wav_reader) {
      src_sr = chain.wav_reader->sample_rate();
    } else if (chain.iamf_ring_source) {
      src_sr = chain.iamf_ring_source->sample_rate();
    } else {
      continue;
    }

    if (src_sr == 0 || src_sr == new_rate) {
      // Matched-rate fast path — the source read writes straight into
      // chain.buf again.
      chain.resampler.reset();
      continue;
    }
    if (!chain.resampler) {
      chain.resampler = std::make_unique<dsp::Resampler>();
    }
    if (!chain.resampler->init(src_sr, new_rate, chain.ctrl.wav_channels,
                               kGraphMaxFrames)) {
      char buf[160];
      snprintf(buf, sizeof(buf),
               "set_sample_rate: resampler init FAILED: id=%u src_sr=%u "
               "engine_sr=%u ch=%u — chain deactivated",
               chain.id, src_sr, new_rate, chain.ctrl.wav_channels);
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "graph", buf);
      chain.resampler.reset();
      chain.ctrl.active.store(false, std::memory_order_relaxed);
      ok = false;
    }
  }

  // set_sample_rate() also rebuilds the analyzer, but unlike reset_meters()
  // / set_monitoring_layout() it is only ever called with the audio thread
  // stopped (engine.cc stops the device, retargets, then restarts), so it
  // cannot race process() and needs no loudness fence. See issue ES-145.
  if (mix_loudness_meter_) mix_loudness_meter_->set_sample_rate(new_rate);

  {
    char buf[128];
    snprintf(buf, sizeof(buf), "set_sample_rate: %u -> %u Hz (%u chains)",
             old_rate, new_rate, count);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "graph", buf);
  }
  return ok;
}

void AudioGraph::shutdown() {
  // Keep the paused-seek-hook invariant total: the session is about
  // to go away. Callers stop the audio thread before shutdown(), so
  // this is bookkeeping, not a fence.
  paused_seek_hook_armed_.store(false, std::memory_order_release);
  // Drop the IAMF session first so ring sources destructed below
  // don't outlive their backing decoder.
  iamf_session_.reset();
  const uint32_t count = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < count; ++i) {
    elements_[i].reset();  // Reset to defaults, frees unique_ptrs.
    clear_meter_slot(global_meter_state_, i);
  }
  element_count_.store(0, std::memory_order_release);
  global_meter_state_.element_count = 0;
  initialized_ = false;
}

int32_t AudioGraph::add_element(uint32_t id, const char* wav_path) {
  const uint32_t count = element_count_.load(std::memory_order_acquire);
  if (count >= kGraphMaxElements) return -1;
  if (find_element(id) != nullptr) return -2;  // Duplicate ID.

  ElementChain& chain = elements_[count];
  chain.id = id;
  chain.ctrl.active.store(false, std::memory_order_relaxed);
  chain.ctrl.muted.store(false, std::memory_order_relaxed);
  chain.ctrl.solo.store(false, std::memory_order_relaxed);
  chain.ctrl.mix_excluded.store(false, std::memory_order_relaxed);

  // Allocate processing components (heap-allocated once, no audio-thread
  // alloc).
  chain.wav_reader = std::make_unique<WavReader>();
  chain.gain = std::make_unique<dsp::Gain>();
  chain.mute_gain = std::make_unique<dsp::Gain>();
  // Start unmuted — gain at unity. set_element_mute() and the solo pass
  // in process() update the target; the IIR smoother ramps.
  chain.mute_gain->set_gain_db(0.0f);
  chain.peak_meter = std::make_unique<PeakMeter>(2.0f, sample_rate_);
  chain.rms_meter = std::make_unique<RmsMeter>(kMeterRmsWindowMs, sample_rate_);
  chain.channel_stats = std::make_unique<ChannelStats>();
  chain.channel_stats->set_sample_rate(sample_rate_);

  // Lenient: a damaged-but-playable file (truncated recording, junk
  // tail) plays its intact prefix rather than refusing to load. Export
  // and ADM import stay strict — see wav::OpenMode.
  if (!chain.wav_reader->open(wav_path, wav::OpenMode::kLenient)) {
    char buf[512];
    snprintf(buf, sizeof(buf), "WAV open FAILED: id=%u, path=%s", id, wav_path);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "graph", buf);
    chain.reset();
    return -3;  // Failed to open WAV.
  }

  {
    char buf[256];
    snprintf(buf, sizeof(buf), "WAV opened: id=%u, ch=%u, sr=%u, frames=%llu",
             id, chain.wav_reader->channels(), chain.wav_reader->sample_rate(),
             static_cast<unsigned long long>(chain.wav_reader->total_frames()));
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "graph", buf);
  }

  // Set up element buffer view — use the WAV's actual channel count
  // so meters report the correct number of channels.
  const uint32_t wav_ch =
      std::min(chain.wav_reader->channels(), kGraphMaxChannels);
  chain.buf.data = chain.buf_storage;
  chain.buf.channels = wav_ch;
  chain.buf.frames = 0;
  chain.buf.capacity_frames = kGraphMaxFrames;
  chain.ctrl.wav_channels = wav_ch;

  // Sample-rate-convert the WAV stream to the engine output rate. The
  // graph and audio thread both clock at sample_rate_; without this,
  // a 44.1 kHz file would be consumed at the engine cadence, playing
  // back ~8.8 % pitched up and desyncing the timeline.
  const uint32_t wav_sr = chain.wav_reader->sample_rate();
  if (wav_sr != 0 && wav_sr != sample_rate_) {
    auto resampler = std::make_unique<dsp::Resampler>();
    // Size for the graph-wide max so the chain survives a later
    // engine reconfigure to a larger device buffer; process() clamps
    // frames to kGraphMaxFrames before reaching this stage.
    if (!resampler->init(wav_sr, sample_rate_, wav_ch, kGraphMaxFrames)) {
      char buf[160];
      snprintf(buf, sizeof(buf),
               "resampler init FAILED: id=%u wav_sr=%u engine_sr=%u ch=%u", id,
               wav_sr, sample_rate_, wav_ch);
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "graph", buf);
      chain.reset();
      return -4;
    }
    chain.resampler = std::move(resampler);
  }

  chain.ctrl.active.store(true, std::memory_order_relaxed);
  const uint32_t new_count = count + 1;
  element_count_.store(new_count, std::memory_order_release);

  // Keep element_count in the shared state in sync with the graph.
  global_meter_state_.element_count = new_count;

  {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "add_element: id=%u wav_ch=%u wav_rate=%u buf_ch=%u "
             "capacity=%u max_frames=%u engine_rate=%u slot=%u resample=%s",
             id, chain.wav_reader ? chain.wav_reader->channels() : 0,
             chain.wav_reader ? chain.wav_reader->sample_rate() : 0,
             chain.buf.channels, chain.buf.capacity_frames, max_frames_,
             sample_rate_, count, chain.resampler ? "yes" : "no");
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "graph", buf);
  }

  return 0;
}

void AudioGraph::remove_element(uint32_t id) {
  const uint32_t count = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < count; ++i) {
    if (elements_[i].id == id) {
      // Compact: move last element into this slot, then clear the tail.
      const uint32_t new_count = count - 1;
      if (i < new_count) {
        elements_[i].move_from(elements_[new_count]);
        // Re-seat buf.data — it must point to this slot's storage.
        elements_[i].buf.data = elements_[i].buf_storage;
        move_meter_slot(global_meter_state_, i, new_count);
      } else {
        elements_[i].reset();
        clear_meter_slot(global_meter_state_, i);
      }
      element_count_.store(new_count, std::memory_order_release);
      global_meter_state_.element_count = new_count;
      return;
    }
  }
}

uint32_t AudioGraph::element_ids(uint32_t* out, uint32_t capacity) const {
  const uint32_t count = element_count_.load(std::memory_order_acquire);
  const uint32_t n = out != nullptr ? std::min(count, capacity) : 0;
  for (uint32_t i = 0; i < n; ++i) {
    out[i] = elements_[i].id;
  }
  return count;
}

int32_t AudioGraph::open_iamf(const char* path) {
  close_iamf();

  auto session = std::make_unique<IamfPlaybackSession>();
  if (path == nullptr || !session->open(path)) {
    iamf_error_ = session->last_error().empty()
                      ? std::string("invalid_argument: empty path")
                      : session->last_error();
    return -2;
  }

  // Phase A refuses to pump if any AE is unsupported. Reject such
  // files here so Play never attaches to a stream that can't decode.
  const uint32_t num_ae = session->num_audio_elements();
  uint32_t num_supported = 0;
  for (uint32_t i = 0; i < num_ae; ++i) {
    if (session->ae_info(i).supported) ++num_supported;
  }
  if (num_supported == 0) {
    iamf_error_ = "unsupported: no decodable audio elements";
    return -3;
  }
  if (num_supported != num_ae) {
    iamf_error_ = "unsupported: one or more audio elements are not decodable";
    return -3;
  }

  const uint32_t count = element_count_.load(std::memory_order_acquire);
  if (count + num_supported > kGraphMaxElements) {
    iamf_error_ = "invalid_argument: too many audio elements";
    return -1;
  }

  for (uint32_t ae = 0; ae < num_ae; ++ae) {
    const auto info = session->ae_info(ae);
    if (!info.supported) continue;  // all supported per check above

    const uint32_t slot = count + ae;  // one slot per AE, stream-order
    ElementChain& chain = elements_[slot];

    // Fallback id for a zero audio_element_id. Keep in sync with
    // eclipsa_studio_playback_open (engine.cc), which reports the same
    // effective id to Dart and registers it with OAR.
    chain.id = info.audio_element_id != 0 ? info.audio_element_id : ae + 1;
    chain.ctrl.active.store(false, std::memory_order_relaxed);
    chain.ctrl.muted.store(false, std::memory_order_relaxed);
    chain.ctrl.solo.store(false, std::memory_order_relaxed);
    chain.ctrl.mix_excluded.store(false, std::memory_order_relaxed);
    chain.ctrl.is_scene.store(info.kind == 1, std::memory_order_relaxed);
    chain.ctrl.mix_gain_db.store(0.0f, std::memory_order_relaxed);
    chain.ctrl.mix_gain_slewed_db = 0.0f;
    chain.ctrl.mix_gain_last_sent_db = 0.0f;

    chain.iamf_ring_source = std::make_unique<IamfRingSource>();
    if (!chain.iamf_ring_source->attach(session.get(), ae)) {
      iamf_error_ = "unsupported: ring-source attach failed";
      // Roll back any slots already claimed in this call. No
      // clear_meter_slot needed: these slots were never published via
      // element_count_, so process() never wrote their meters.
      for (uint32_t j = count; j <= slot; ++j) elements_[j].reset();
      return -3;
    }

    chain.gain = std::make_unique<dsp::Gain>();
    chain.mute_gain = std::make_unique<dsp::Gain>();
    chain.mute_gain->set_gain_db(0.0f);
    chain.peak_meter = std::make_unique<PeakMeter>(2.0f, sample_rate_);
    chain.rms_meter =
        std::make_unique<RmsMeter>(kMeterRmsWindowMs, sample_rate_);
    chain.channel_stats = std::make_unique<ChannelStats>();
    chain.channel_stats->set_sample_rate(sample_rate_);

    const uint32_t src_ch =
        std::min<uint32_t>(info.num_channels, kGraphMaxChannels);
    chain.buf.data = chain.buf_storage;
    chain.buf.channels = src_ch;
    chain.buf.frames = 0;
    chain.buf.capacity_frames = kGraphMaxFrames;
    chain.ctrl.wav_channels = src_ch;  // field name predates IAMF; reused as
                                       // "source channel count".

    // Sample-rate-convert the decoded AE stream to the engine output
    // rate, mirroring the WAV path in add_element(). The session's
    // rings carry file-rate PCM; the resampler sits between the ring
    // read and chain.buf.
    const uint32_t file_sr = session->sample_rate();
    if (file_sr != 0 && file_sr != sample_rate_) {
      auto resampler = std::make_unique<dsp::Resampler>();
      if (!resampler->init(file_sr, sample_rate_, src_ch, kGraphMaxFrames)) {
        char buf[160];
        snprintf(buf, sizeof(buf),
                 "iamf resampler init FAILED: ae=%u file_sr=%u engine_sr=%u "
                 "ch=%u",
                 ae, file_sr, sample_rate_, src_ch);
        engine_log(ECLIPSA_STUDIO_LOG_ERROR, "graph", buf);
        iamf_error_ = "io: resampler allocation failed";
        // Unpublished slots — no clear_meter_slot needed (see above).
        for (uint32_t j = count; j <= slot; ++j) elements_[j].reset();
        return -3;
      }
      chain.resampler = std::move(resampler);
    }

    chain.ctrl.active.store(true, std::memory_order_relaxed);
  }

  const uint32_t new_count = count + num_supported;
  element_count_.store(new_count, std::memory_order_release);
  global_meter_state_.element_count = new_count;

  iamf_session_ = std::move(session);
  iamf_error_.clear();
  // A fresh file starts on the decoder's default mix presentation, so
  // the stream's per-TU gain fan-out is authoritative again.
  iamf_stream_gains_.store(true, std::memory_order_relaxed);
  // Session fully constructed and published — the paused seek hook
  // may dereference it from here on (release pairs with the hook's
  // acquire; the caller disarmed + quiesced before this call, see
  // disarm_paused_seek_hook()).
  paused_seek_hook_armed_.store(true, std::memory_order_release);

  {
    char buf[160];
    snprintf(buf, sizeof(buf),
             "iamf open: path=%s num_ae=%u sample_rate=%u total_frames=%llu",
             path, num_supported, iamf_session_->sample_rate(),
             static_cast<unsigned long long>(iamf_session_->total_frames()));
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "graph", buf);
  }

  return static_cast<int32_t>(num_supported);
}

void AudioGraph::close_iamf() {
  // Reset the seek de-click staging (ES-473/ES-536) BEFORE the no-session
  // early return: open_iamf() calls close_iamf() unconditionally, and
  // a WAV-staged seek (ENGINE-rate, unclamped) that no callback
  // consumed must never survive into the fresh session — the IAMF
  // branch of post_staged_seek_rt() would hand it to the decoder as a
  // file-rate position. Same no-concurrent-process() assumption as
  // the chain resets below (callers hold the barrier).
  pending_seek_count_.store(0, std::memory_order_relaxed);
  pending_seek_file_pos_.store(0, std::memory_order_relaxed);
  pending_seek_consumed_ = 0;
  seek_posted_request_count_ = 0;
  seek_mute_state_ = SeekMuteState::kIdle;
  seek_fade_gain_ = seek_fade_g0_ = seek_fade_g1_ = 1.0f;

  if (!iamf_session_) return;

  // Belt-and-braces: the caller must ALREADY have disarmed the paused
  // seek hook and waited for callback quiescence (see
  // disarm_paused_seek_hook()) — a hook past the gate right now would
  // race the resets below. This store only covers callers with no
  // audio thread at all (tests, teardown).
  paused_seek_hook_armed_.store(false, std::memory_order_release);

  // Reset iamf-sourced slots wherever they sit (remove_element's
  // swap-with-last can leave them interleaved with WAV chains, not
  // necessarily a prefix); compact surviving non-iamf chains toward
  // the front (move_from re-seats buf.data into its new slot's
  // storage), carrying each meter slot with its chain.
  const uint32_t old_count = element_count_.load(std::memory_order_acquire);
  uint32_t new_count = 0;
  for (uint32_t i = 0; i < old_count; ++i) {
    if (elements_[i].iamf_ring_source) {
      elements_[i].reset();
      continue;
    }
    if (i != new_count) {
      elements_[new_count].move_from(elements_[i]);
      elements_[new_count].buf.data = elements_[new_count].buf_storage;
      move_meter_slot(global_meter_state_, new_count, i);
    }
    ++new_count;
  }
  for (uint32_t i = new_count; i < old_count; ++i) {
    elements_[i].reset();
    clear_meter_slot(global_meter_state_, i);
  }
  element_count_.store(new_count, std::memory_order_release);
  global_meter_state_.element_count = new_count;

  iamf_session_.reset();
  iamf_error_.clear();
}

const std::string& AudioGraph::last_iamf_error() const { return iamf_error_; }

uint32_t AudioGraph::iamf_element_ids(uint32_t* out, uint32_t max_ids) const {
  if (out == nullptr || max_ids == 0) return 0;
  const uint32_t count = element_count_.load(std::memory_order_acquire);
  uint32_t written = 0;
  for (uint32_t i = 0; i < count && written < max_ids; ++i) {
    if (elements_[i].iamf_ring_source) {
      out[written++] = elements_[i].id;
    }
  }
  return written;
}

void AudioGraph::set_element_gain(uint32_t id, float gain_db) {
  ElementChain* chain = find_element(id);
  if (chain && chain->gain) {
    chain->gain->set_gain_db(gain_db);
  }
}

void AudioGraph::set_element_mute(uint32_t id, bool muted) {
  ElementChain* chain = find_element(id);
  if (chain) chain->ctrl.muted.store(muted, std::memory_order_relaxed);
  // The mute_gain target is re-evaluated every audio callback in
  // process(), so we don't need to set it here; the next callback will
  // pick up the new muted state (and account for solo interaction).
}

void AudioGraph::set_element_solo(uint32_t id, bool solo) {
  ElementChain* chain = find_element(id);
  if (chain) chain->ctrl.solo.store(solo, std::memory_order_relaxed);
}

void AudioGraph::set_channel_stats_enabled(bool enabled) {
  if (enabled && !channel_stats_enabled_.load(std::memory_order_relaxed)) {
    // Off->on: clear EMA/biquad state left over from before the pass
    // was disabled, so re-enabling doesn't briefly show stale
    // readings. Safe to touch from the control thread here — while
    // the flag is off the audio thread never runs the pass, and the
    // release store below publishes the resets before the flag
    // (paired with the acquire load in process()).
    for (auto& chain : elements_) {
      if (chain.channel_stats) chain.channel_stats->reset();
    }
  }
  channel_stats_enabled_.store(enabled, std::memory_order_release);
}

void AudioGraph::set_element_mix_excluded(uint32_t id, bool excluded) {
  ElementChain* chain = find_element(id);
  if (chain)
    chain->ctrl.mix_excluded.store(excluded, std::memory_order_relaxed);
}

void AudioGraph::set_element_scene(uint32_t id, bool scene) {
  ElementChain* chain = find_element(id);
  if (chain) chain->ctrl.is_scene.store(scene, std::memory_order_relaxed);
}

void AudioGraph::set_element_object(uint32_t id, bool object) {
  ElementChain* chain = find_element(id);
  if (chain) chain->ctrl.is_object.store(object, std::memory_order_relaxed);
}

void AudioGraph::set_element_object_position(uint32_t id, uint32_t count,
                                             float az_deg, float el_deg,
                                             float dist, float az2_deg,
                                             float el2_deg, float dist2) {
  ElementChain* chain = find_element(id);
  if (!chain) return;
  auto& c = chain->ctrl;
  c.object_count.store(count < 1 ? 1 : (count > 2 ? 2 : count),
                       std::memory_order_relaxed);
  c.object_az.store(az_deg, std::memory_order_relaxed);
  c.object_el.store(el_deg, std::memory_order_relaxed);
  c.object_dist.store(dist, std::memory_order_relaxed);
  c.object_az2.store(az2_deg, std::memory_order_relaxed);
  c.object_el2.store(el2_deg, std::memory_order_relaxed);
  c.object_dist2.store(dist2, std::memory_order_relaxed);
  // No dirty flag — the audio thread re-pushes positions every
  // callback for object chains (mirrors set_element_mix_gain).
}

void AudioGraph::set_element_mix_gain(uint32_t id, float gain_db) {
  ElementChain* chain = find_element(id);
  if (chain) {
    chain->ctrl.mix_gain_db.store(gain_db, std::memory_order_relaxed);
    // No dirty flag — the audio thread reads the atomic every callback,
    // and the slew limiter naturally no-ops once steady state is
    // reached (delta == 0, start == end in the emitted metadata).
  }
}

void AudioGraph::set_output_mix_gain(float gain_db) {
  output_mix_gain_db_.store(gain_db, std::memory_order_relaxed);
}

float AudioGraph::element_mix_gain_db(uint32_t id) {
  ElementChain* chain = find_element(id);
  return chain ? chain->ctrl.mix_gain_db.load(std::memory_order_relaxed) : 0.0f;
}

void AudioGraph::set_element_routing(uint32_t id, const int8_t* map,
                                     uint32_t len) {
  ElementChain* chain = find_element(id);
  if (!chain) {
    char buf[64];
    snprintf(buf, sizeof(buf), "set_routing: unknown element id=%u", id);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "graph", buf);
    return;
  }

  // Clearing to identity: publish nullptr. The audio thread's
  // acquire-load sees this next callback and takes the fast path.
  // Write metadata BEFORE the release-store so the invariant
  // "metadata precedes pointer publish" holds on both branches.
  if (map == nullptr || len == 0) {
    chain->routing_len = 0;
    chain->routing_map.store(nullptr, std::memory_order_release);
    return;
  }

  if (len > kGraphMaxChannels) {
    char buf[96];
    snprintf(buf, sizeof(buf),
             "set_routing: id=%u len=%u clamped to kGraphMaxChannels=%u", id,
             len, kGraphMaxChannels);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "graph", buf);
  }

  // Double-buffered publish: write to the inactive slot, then flip the
  // published pointer via release-store. The audio thread either sees
  // the old pointer (still valid) or the new one, never a torn write.
  const uint8_t inactive = chain->routing_active_slot == 0 ? 1 : 0;
  int8_t* inactive_storage =
      inactive == 0 ? chain->routing_storage_a : chain->routing_storage_b;
  const uint32_t clamped_len = std::min(len, kGraphMaxChannels);
  const uint32_t src_ch = chain->ctrl.wav_channels;
  bool any_oob = false;
  for (uint32_t i = 0; i < clamped_len; ++i) {
    const int8_t s = map[i];
    if (s >= 0 && static_cast<uint32_t>(s) >= src_ch) any_oob = true;
    inactive_storage[i] = s;
  }
  // Zero out any tail so audio thread doesn't read stale data if routing_len
  // later shrinks without being re-published.
  for (uint32_t i = clamped_len; i < kGraphMaxChannels; ++i) {
    inactive_storage[i] = -1;
  }
  if (any_oob) {
    char buf[96];
    snprintf(buf, sizeof(buf),
             "set_routing: id=%u has src index(es) >= wav_ch=%u; "
             "those dests will be silenced",
             id, src_ch);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "graph", buf);
  }
  chain->routing_len = static_cast<uint8_t>(clamped_len);
  chain->routing_active_slot = inactive;
  chain->routing_map.store(inactive_storage, std::memory_order_release);
}

void AudioGraph::seed_element_mix_gain(uint32_t id, float gain_db) {
  ElementChain* chain = find_element(id);
  if (!chain) return;
  // Control-thread write to the audio-thread-only fields. Safe only
  // because session load runs while the audio thread is either stopped
  // or outputting silence — see header doc.
  chain->ctrl.mix_gain_db.store(gain_db, std::memory_order_relaxed);
  chain->ctrl.mix_gain_slewed_db = gain_db;
  chain->ctrl.mix_gain_last_sent_db = gain_db;
}

void AudioGraph::seed_output_mix_gain(float gain_db) {
  output_mix_gain_db_.store(gain_db, std::memory_order_relaxed);
  output_mix_gain_slewed_db_ = gain_db;
  output_mix_gain_last_sent_db_ = gain_db;
}

void AudioGraph::set_monitor_dim(bool engaged) {
  monitor_dim_.store(engaged, std::memory_order_relaxed);
}

void AudioGraph::apply_monitor_dim(float* out, uint32_t frames,
                                   uint32_t channels) {
  const float target =
      monitor_dim_.load(std::memory_order_relaxed) ? kMonitorDimGain : 1.0f;
  float g = monitor_dim_gain_;
  if (g == 1.0f && target == 1.0f) return;  // steady undimmed: no work
  const float rate = static_cast<float>(std::max(sample_rate_, 1u));
  const float step =
      (1.0f - kMonitorDimGain) / (kMonitorDimRampMs * 0.001f * rate);
  for (uint32_t f = 0; f < frames; ++f) {
    if (g < target) {
      g = std::min(g + step, target);
    } else if (g > target) {
      g = std::max(g - step, target);
    }
    float* frame = out + static_cast<size_t>(f) * channels;
    for (uint32_t c = 0; c < channels; ++c) frame[c] *= g;
  }
  monitor_dim_gain_ = g;
}

void AudioGraph::process(float* out, uint32_t frames, uint32_t channels) {
  if (!initialized_ || !out) return;
  ++process_call_count_;

  // Re-arm the paused-branch OAR tail drain (ES-530): the next pause
  // starts draining again from scratch. Audio-thread only, like the
  // drain itself.
  oar_tail_drained_ = false;
  oar_drain_blocks_done_ = 0;

  // Perform any clip clear the UI requested. The audio thread is the
  // sole writer of the sticky clip flags, so doing the zeroing here
  // (instead of on the control thread) makes the clear race-free.
  consume_pending_clip_clear();

  const uint32_t fr = std::min(frames, kGraphMaxFrames);

  // Advance the IAMF seek de-click state machine (ES-473) and compute
  // this block's fade bracket [seek_fade_g0_, seek_fade_g1_]. Must
  // run before the element loop: the loop consults the state to skip
  // ring reads while priming and to apply the fade.
  update_seek_mute_state(fr);

  // Defensive: the device callback should never request more than the
  // pre-allocated kGraphMaxFrames, but every render path below only fills
  // [0, fr). If a device ever asks for more, zero the tail so it stays silent
  // instead of leaking uninitialised samples, and warn once.
  if (frames > fr) {
    std::memset(out + static_cast<size_t>(fr) * channels, 0,
                static_cast<size_t>(frames - fr) * channels * sizeof(float));
    if (!frames_clamped_warned_) {
      frames_clamped_warned_ = true;
      char buf[96];
      snprintf(buf, sizeof(buf), "frames=%u exceeds cap=%u; tail silenced",
               frames, kGraphMaxFrames);
      engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio", buf);
    }
  }

  // Snapshot element count (acquire pairs with release in add/remove).
  const uint32_t n = element_count_.load(std::memory_order_acquire);

  // Sync element count into the shared meter state.
  global_meter_state_.element_count = n;

  // Determine if any element is soloed.
  bool any_solo = false;
  for (uint32_t i = 0; i < n; ++i) {
    if (elements_[i].ctrl.active.load(std::memory_order_relaxed) &&
        elements_[i].ctrl.solo.load(std::memory_order_relaxed)) {
      any_solo = true;
      break;
    }
  }

  if (process_call_count_ == 1) {
    const uint32_t oar_buf = oar_renderer_ ? oar_renderer_->buffer_size() : 0;
    char buf[128];
    snprintf(buf, sizeof(buf),
             "first process: frames=%u ch=%u oar_buf=%u elements=%u", frames,
             channels, oar_buf, n);
    engine_log_rt(ECLIPSA_STUDIO_LOG_INFO, "audio", buf);
  }

  // Process each active element.
  //
  // Invariant: every active element ALWAYS reads WAV data, runs its full
  // DSP chain, and feeds PCM to OAR. Mute/solo are implemented by ramping
  // the dedicated mute_gain node to -120 dB (effectively silent) rather
  // than skipping reads/feeds. This keeps OAR's internal state consistent
  // regardless of mute/solo state and gives click-free transitions.
  for (uint32_t i = 0; i < n; ++i) {
    ElementChain& chain = elements_[i];
    if (!chain.ctrl.active.load(std::memory_order_relaxed)) continue;

    // Compute the effective mute state (explicit mute OR excluded by solo).
    const bool effectively_muted =
        chain.ctrl.muted.load(std::memory_order_relaxed) ||
        chain.ctrl.mix_excluded.load(std::memory_order_relaxed) ||
        (any_solo && !chain.ctrl.solo.load(std::memory_order_relaxed));

    // Update the mute gain target every callback so solo changes on
    // other elements propagate here. The Gain node's IIR smoother
    // (kSmoothCoeff = 0.001) has a one-tau time constant of ~21 ms at
    // 48 kHz; the perceived fade to -60 dB takes ~7 tau ≈ 145 ms.
    if (chain.mute_gain) {
      chain.mute_gain->set_gain_db(effectively_muted ? -120.0f : 0.0f);
    }

    // Reset the buffer view to the WAV (source) layout. If routing is
    // active the remap below will rebind buf to the scratch storage
    // with the element's output channel count.
    chain.buf.data = chain.buf_storage;
    chain.buf.channels = chain.ctrl.wav_channels;
    chain.buf.frames = fr;
    chain.buf.zero_frames();

    // IAMF per-TU mix gain fan-out: feed the latest session-reported
    // gain for this AE into the slew target before the read. The slew
    // ramp picks it up below so sudden TU-boundary changes fade over
    // a few callbacks instead of clicking. Skipped when the app has
    // selected a non-default mix presentation — the stream only
    // reports default-presentation gains, so the app's
    // set_element_mix_gain values must win (see set_iamf_stream_gains).
    if (chain.iamf_ring_source && iamf_session_ &&
        iamf_stream_gains_.load(std::memory_order_relaxed)) {
      const uint32_t ae_idx = chain.iamf_ring_source->ae_index();
      chain.ctrl.mix_gain_db.store(iamf_session_->latest_mix_gain_db(ae_idx),
                                   std::memory_order_relaxed);
    }

    // Always read from the active source — the mute_gain node will
    // ramp the buffer to silence when appropriate, and OAR expects
    // continuous data. Exactly one of {wav_reader, iamf_ring_source}
    // is non-null per active chain. When the source's native sample
    // rate differs from the engine rate, a dsp::Resampler stage
    // converts it; consume() updates chain.buf.frames to the
    // actually-produced count so downstream DSP / metering processes
    // a valid range.
    // While the seek state machine holds IAMF chains in the priming
    // mute (ES-473), skip their ring reads entirely: the output is
    // silent anyway, and consuming the freshly-refilled frames while
    // inaudible would burn the first ~40 ms of post-seek program. The
    // pre-zeroed buffer plays as silence; reads resume on fade-in.
    // Short reads during the hold are expected, so the underrun
    // accounting is skipped along with the read.
    const bool skip_iamf_read = seek_mute_state_ == SeekMuteState::kPriming &&
                                chain.iamf_ring_source != nullptr;

    if (chain.resampler) {
      AudioBuffer& rin = chain.resampler->input_buffer();
      // required_input() is steady-state at init plus filter warm-up
      // headroom, but a transient query could theoretically exceed
      // the input buffer's capacity. Clamp to the buffer's actual
      // capacity so the source read can't write past the scratch.
      // consume() also re-clamps internally as belt-and-suspenders.
      const uint64_t in_needed_raw = chain.resampler->required_input(fr);
      const uint32_t in_needed = static_cast<uint32_t>(
          std::min<uint64_t>(in_needed_raw, rin.capacity_frames));
      if (chain.wav_reader) {
        chain.wav_reader->read(rin, in_needed);
      } else if (chain.iamf_ring_source && !skip_iamf_read) {
        const uint32_t got = chain.iamf_ring_source->read(rin, in_needed);
        if (got < in_needed && !chain.iamf_ring_source->eof()) {
          note_ring_underrun(i, in_needed - got);
        }
      }
      if (!skip_iamf_read) {
        chain.resampler->consume(chain.buf, rin.frames, fr);
      }
    } else if (chain.wav_reader) {
      chain.wav_reader->read(chain.buf, fr);
    } else if (chain.iamf_ring_source && !skip_iamf_read) {
      const uint32_t got = chain.iamf_ring_source->read(chain.buf, fr);
      if (got < fr && !chain.iamf_ring_source->eof()) {
        note_ring_underrun(i, fr - got);
      }
    }

    // Apply the seek de-click fade: a linear ramp across the block
    // from seek_fade_g0_ to seek_fade_g1_ (unity in steady state —
    // skipped, as is the IAMF priming hold, whose buffer is already
    // zeroed; WAV chains read normally during the one-block hold and
    // the zero gain mutes them). Applied straight after the source
    // read, before DSP and metering, so meters show the audible
    // (faded) level. The per-sample step divides by nf (not nf-1) so
    // consecutive blocks' ramps join continuously — the same
    // application form as the OAR output fade further down.
    // skip_iamf_read implies an IAMF chain, and a chain with neither
    // source has a zeroed buffer — so the gain bracket plus the skip
    // flag is the whole predicate. Bracket first: the steady-state
    // early-out costs two scalar compares.
    if ((seek_fade_g0_ != 1.0f || seek_fade_g1_ != 1.0f) && !skip_iamf_read) {
      const uint32_t nf = chain.buf.frames;
      if (nf > 0) {
        const float step =
            (seek_fade_g1_ - seek_fade_g0_) / static_cast<float>(nf);
        for (uint32_t c = 0; c < chain.buf.channels; ++c) {
          float* d = chain.buf.channel(c);
          float g = seek_fade_g0_;
          for (uint32_t f = 0; f < nf; ++f) {
            d[f] *= g;
            g += step;
          }
        }
      }
    }

    // Input-channel remap (lock-free fast path if routing_map==nullptr).
    // Convention: rmap[dest] = src; -1 silences the dest. The WAV-shaped
    // source is in chain.buf_storage; the remapped dest-shaped buffer
    // goes into chain.buf_remap_storage. We then swap the view.
    {
      const int8_t* rmap = chain.routing_map.load(std::memory_order_acquire);
      if (rmap != nullptr) {
        const uint32_t src_ch = chain.ctrl.wav_channels;
        const uint32_t dest_ch =
            std::min<uint32_t>(chain.routing_len, kGraphMaxChannels);
        for (uint32_t d = 0; d < dest_ch; ++d) {
          float* dst = chain.buf_remap_storage +
                       static_cast<size_t>(d) * kGraphMaxFrames;
          const int8_t s = rmap[d];
          if (s < 0 || static_cast<uint32_t>(s) >= src_ch) {
            std::memset(dst, 0, fr * sizeof(float));
          } else {
            const float* src =
                chain.buf_storage + static_cast<size_t>(s) * kGraphMaxFrames;
            std::memcpy(dst, src, fr * sizeof(float));
          }
        }
        chain.buf.data = chain.buf_remap_storage;
        chain.buf.channels = dest_ch;
      }
    }

    // DSP chain (in-place). Order: user gain -> mute.
    // mute_gain is placed after user DSP but before metering so that
    // meters reflect post-mute (audible) levels.
    if (chain.gain) {
      chain.gain->process(chain.buf, chain.buf.frames);
    }
    if (chain.mute_gain) {
      chain.mute_gain->process(chain.buf, chain.buf.frames);
    }

    // SH active intensity snapshot for visualization (scene elements only).
    // For each channel c, compute mean(W[f] * ch_c[f]) where W is
    // channel 0 (omnidirectional). This yields the active intensity
    // in the SH domain: positive energy for W*W, signed correlation
    // for directional channels — preserving spatial direction while
    // being proportional to signal energy.
    {
      auto& md = global_meter_state_.elements[i];
      // Clamp like the peak/rms meters do: sh_snapshot has exactly
      // kEclipsaStudioMaxChannelsPerElement slots, and writing chain.buf's
      // raw channel count would overrun into the stats fields if
      // kGraphMaxChannels ever grows past it.
      const uint32_t n_sh = std::min<uint32_t>(
          chain.buf.channels, kEclipsaStudioMaxChannelsPerElement);
      if (chain.ctrl.is_scene.load(std::memory_order_relaxed) && n_sh > 0 &&
          chain.buf.frames > 0) {
        const float inv = 1.0f / static_cast<float>(chain.buf.frames);
        const float* w = chain.buf.channel(0);
        for (uint32_t c = 0; c < n_sh; ++c) {
          const float* src = chain.buf.channel(c);
          float sum = 0.0f;
          for (uint32_t f = 0; f < chain.buf.frames; ++f) {
            sum += w[f] * src[f];
          }
          md.sh_snapshot[c] = sum * inv;
        }
      } else {
        for (uint32_t c = 0; c < n_sh; ++c) {
          md.sh_snapshot[c] = 0.0f;
        }
      }
      for (uint32_t c = n_sh; c < kEclipsaStudioMaxChannelsPerElement; ++c) {
        md.sh_snapshot[c] = 0.0f;
      }
    }

    // Per-element metering — write linear values into global state slot i.
    if (chain.peak_meter) {
      chain.peak_meter->process(chain.buf, chain.buf.frames,
                                global_meter_state_, i);
    }
    if (chain.rms_meter) {
      chain.rms_meter->process(chain.buf, chain.buf.frames, global_meter_state_,
                               i);
    }
    // Visualizer stats — energy / correlation / coherence / onsets.
    // Only meaningful for channel-based elements; scene-based elements
    // reuse the sh_snapshot block above and object-based elements have
    // position semantics rather than channel geometry. Gated on the
    // UI's channel_stats_enabled flag so the real-time cost of this
    // pass only exists when a visualizer is actually consuming it.
    // Acquire pairs with the release store in set_channel_stats_enabled
    // so the off->on state reset is visible before the pass runs.
    if (channel_stats_enabled_.load(std::memory_order_acquire) &&
        chain.channel_stats &&
        !chain.ctrl.is_scene.load(std::memory_order_relaxed)) {
      chain.channel_stats->process(chain.buf, chain.buf.frames,
                                   global_meter_state_, i);
    }
  }

  // Increment frame counter once per process() call. Mix-bus loudness is
  // measured on the post-OAR rendered output below, after the renderer
  // runs, so the number reflects what the device hears (and what
  // iamf-tools would compute on the same signal).
  ++global_meter_state_.frame_counter;

  // Planar OAR render captured for the output level meters. The renderer
  // view's per-channel meters track the renderer's OWN output (pre-routing),
  // not the post-routing device buffer, so they keep showing every logical
  // channel (L/R/C/LFE/…) regardless of how the routing matrix patches them
  // onto physical outputs. Null = no render this block (bypass / silence),
  // in which case the device buffer is metered instead.
  const float* output_render = nullptr;
  uint32_t output_render_ch = 0;

  const bool bypass = bypass_oar_.load(std::memory_order_relaxed);

  // Set when this callback reached the loudness-meter site below (and
  // either fed the meter or acknowledged the fence there). Any other path
  // (bypass, OAR reconfiguring or offline-exclusive, no render)
  // acknowledges a raised fence after the render block instead, so the
  // control thread's fence wait finishes within one callback.
  bool loudness_site_reached = false;

  if (bypass) {
    // --- OAR bypass: sum channels 0-1 of each element straight to output ---
    // Muted/soloed elements are silenced by the mute_gain node already,
    // so we just sum every active element's post-DSP buffer.
    std::memset(out, 0, static_cast<size_t>(fr) * channels * sizeof(float));
    const uint32_t out_ch = std::min(channels, 2u);
    for (uint32_t i = 0; i < n; ++i) {
      auto& chain = elements_[i];
      if (!chain.ctrl.active.load(std::memory_order_relaxed)) continue;
      const uint32_t elem_ch = std::min(chain.buf.channels, out_ch);
      for (uint32_t c = 0; c < elem_ch; ++c) {
        const float* src = chain.buf.channel(c);
        for (uint32_t f = 0; f < fr; ++f) {
          out[f * channels + c] += src[f];
        }
      }
    }
    if (process_call_count_ == 1) {
      engine_log_rt(ECLIPSA_STUDIO_LOG_INFO, "audio",
                    "OAR bypass: routing ch0-1 direct");
    }
  } else {
    // Feed per-element PCM to OAR, then render to device output.
    // Skip OAR entirely while the control thread is reconfiguring it.
    const bool oar_ok = oar_renderer_ && !oar_renderer_->is_reconfiguring();
    bool rendered_ok = false;
    if (oar_ok) {
      // Always feed every active element — muted elements produce silent
      // buffers (via mute_gain) but must still feed OAR to keep its
      // internal state consistent. Push IAMF element_mix_gain as a
      // linear ramp from the last sent value to the current slew-
      // limited target; OAR interpolates sample-accurately within the
      // block. Between blocks, continuity is guaranteed by using the
      // previous callback's end as this callback's start.
      for (uint32_t i = 0; i < n; ++i) {
        auto& chain = elements_[i];
        if (!chain.ctrl.active.load(std::memory_order_relaxed)) continue;

        // Slew-limit the target before emitting the ramp. Big jumps
        // (text-edit commits) fade over multiple callbacks instead of
        // a single 10 ms block; small fader drags pass through in one.
        const float target_db =
            chain.ctrl.mix_gain_db.load(std::memory_order_relaxed);
        const float delta = target_db - chain.ctrl.mix_gain_slewed_db;
        const float clamped_delta = std::clamp(delta, -kMaxMixGainDbPerCallback,
                                               kMaxMixGainDbPerCallback);
        chain.ctrl.mix_gain_slewed_db += clamped_delta;

        const float ramp_start = chain.ctrl.mix_gain_last_sent_db;
        const float ramp_end = chain.ctrl.mix_gain_slewed_db;
        oar_renderer_->set_element_mix_gain(chain.id, ramp_start, ramp_end, fr);
        chain.ctrl.mix_gain_last_sent_db = ramp_end;

        // Object chains: push the current polar position(s) as constant
        // metadata covering this block. OAR's object-to-loudspeaker
        // renderer creates its per-object processing only when position
        // metadata arrives, so without this push object elements are
        // silent on every speaker layout. Pushing every callback (like
        // the mix-gain ramp above) also survives OAR rebuilds — the
        // fresh instance re-learns positions on the next block.
        if (chain.ctrl.is_object.load(std::memory_order_relaxed)) {
          const uint32_t cnt =
              chain.ctrl.object_count.load(std::memory_order_relaxed);
          const float az[2] = {
              chain.ctrl.object_az.load(std::memory_order_relaxed),
              chain.ctrl.object_az2.load(std::memory_order_relaxed)};
          const float el[2] = {
              chain.ctrl.object_el.load(std::memory_order_relaxed),
              chain.ctrl.object_el2.load(std::memory_order_relaxed)};
          const float dist[2] = {
              chain.ctrl.object_dist.load(std::memory_order_relaxed),
              chain.ctrl.object_dist2.load(std::memory_order_relaxed)};
          oar_renderer_->set_element_object_positions(chain.id, cnt, az, el,
                                                      dist, fr);
        }

        oar_renderer_->update_element_data(chain.id, chain.buf.data,
                                           chain.buf.channels, fr,
                                           chain.buf.capacity_frames);
      }

      // Push the group-level output mix gain (master fader) using the
      // same slew-and-ramp pattern so text-edit commits on the master
      // fader don't click either.
      {
        const float target_db =
            output_mix_gain_db_.load(std::memory_order_relaxed);
        const float delta = target_db - output_mix_gain_slewed_db_;
        const float clamped_delta = std::clamp(delta, -kMaxMixGainDbPerCallback,
                                               kMaxMixGainDbPerCallback);
        output_mix_gain_slewed_db_ += clamped_delta;

        const float ramp_start = output_mix_gain_last_sent_db_;
        const float ramp_end = output_mix_gain_slewed_db_;
        oar_renderer_->set_output_mix_gain(ramp_start, ramp_end, fr,
                                           /*gid=*/0);
        output_mix_gain_last_sent_db_ = ramp_end;
      }

      // Re-check: renderer may have been reconfigured between the feed
      // loop and here if a layout switch raced with this callback.
      if (!oar_renderer_->is_reconfiguring()) {
        const float* rendered = oar_renderer_->render(fr);
        const uint32_t rch = oar_renderer_->channel_count();
        if (rendered && rch > 0) {
          // OAR output is planar (rendered[c * fr + f]); the device buffer is
          // interleaved (out[f * channels + c]). Scatter each OAR channel to
          // its routed device channel(s) per the routing matrix. Snapshot the
          // masks once into a stack array so the scatter sees a consistent
          // view and stays a pure function; a 1-buffer-stale mask during a
          // switch is acceptable, so relaxed loads suffice.
          uint64_t local[kMaxRoutingChannels];
          const uint32_t n = std::min(rch, kMaxRoutingChannels);
          for (uint32_t c = 0; c < n; ++c) {
            local[c] = routing_[c].load(std::memory_order_relaxed);
          }
          const NoiseState nd =
              unpack_noise(noise_.load(std::memory_order_relaxed));

          // Pre-zeroing subsumes the old tail-zero loop and gives the scatter
          // a clean accumulation target.
          std::memset(out, 0,
                      static_cast<size_t>(fr) * channels * sizeof(float));
          if (nd.mode == 0) {
            scatter_routed(out, rendered, local, n, fr, channels);
          } else {
            // A calibration cell is lit: mute the program and inject pink
            // noise at the fixed reference level (bypasses the master fader).
            // Row noise fans out through the patch; column noise goes straight
            // to the device channel.
            for (uint32_t f = 0; f < fr; ++f) {
              noise_storage_[f] = noise_gen_.next() * nd.amp;
            }
            scatter_noise(out, noise_storage_, nd.mode, nd.channel, local, n,
                          fr, channels);
          }

          // Output fade for click-free rebuilds and device stops
          // (issue ES-73): a short linear ramp toward the fade target,
          // applied to the device buffer so both program and
          // calibration noise are covered. Unity in steady state.
          float fade_g0 = 1.0f;
          float fade_g1 = 1.0f;
          oar_renderer_->fade_block(fr, sample_rate_, &fade_g0, &fade_g1);
          if (fade_g0 != 1.0f || fade_g1 != 1.0f) {
            const float step = (fade_g1 - fade_g0) / static_cast<float>(fr);
            float g = fade_g0;
            for (uint32_t f = 0; f < fr; ++f, g += step) {
              float* frame = out + static_cast<size_t>(f) * channels;
              for (uint32_t c = 0; c < channels; ++c) frame[c] *= g;
            }
          }
          rendered_ok = true;
          output_render = rendered;  // meter the render, not the patch.
          output_render_ch = rch;
          oar_renderer_->snapshot_limiter_env();
          global_meter_state_.limiter_gr =
              static_cast<float>(oar_renderer_->limiter_env());

          // Post-OAR loudness meter — the rendered buffer is planar at
          // OAR's output channel count, with stride == fr (render packs
          // the block tightly). Wrap it as an AudioBuffer view; the
          // meter only reads, the const_cast is safe.
          if (mix_loudness_meter_ && rch) {
            loudness_site_reached = true;
            // Skip + acknowledge while the control thread is rebuilding the
            // analyzer (reset/reconfigure), so it never frees the
            // EbuR128Analyzer out from under this call. See issue ES-145.
            // seq_cst: see loudness_reconfiguring_ in the header.
            if (loudness_reconfiguring_.load(std::memory_order_seq_cst)) {
              loudness_ack_.fetch_add(1, std::memory_order_seq_cst);
            } else {
              AudioBuffer rv;
              rv.data = const_cast<float*>(rendered);
              rv.channels = rch;
              rv.frames = fr;
              rv.capacity_frames = fr;
              mix_loudness_meter_->process(rv, fr, global_meter_state_);
            }
          }
        }
      } else {
        // Reconfiguring detected mid-process — signal rebuild().
        oar_renderer_->acknowledge_reconfiguring();
      }
    }
    if (!oar_ok && oar_renderer_) {
      // Audio thread observed is_reconfiguring at entry — signal rebuild().
      oar_renderer_->acknowledge_reconfiguring();
    }
    if (!rendered_ok) {
      std::memset(out, 0, static_cast<size_t>(fr) * channels * sizeof(float));
    }
  }
  // The meter was not entered this callback, so a raised fence can be
  // acknowledged here (issue ES-833: a layout switch holds the fence across
  // the OAR rebuild, during which the audio thread skips OAR).
  if (!loudness_site_reached) ack_loudness_reconfigure_if_pending();

  // Compute output peak + RMS levels (exposed via
  // eclipsa_studio_get_output_peaks() / eclipsa_studio_get_output_rms()). When
  // OAR rendered, meter its planar per-channel output (pre-routing) so the
  // renderer view tracks the render itself — same source as the post-OAR
  // loudness meter. On bypass / silence there is no render, so fall back to
  // metering the interleaved device buffer.
  if (output_render != nullptr) {
    output_channel_count_ = std::min(output_render_ch, kMaxOutputChannels);
    for (uint32_t c = 0; c < output_channel_count_; ++c) {
      const float* src = output_render + static_cast<size_t>(c) * fr;
      meter_output_channel(src, fr, /*stride=*/1, c);
    }
  } else {
    output_channel_count_ = std::min(channels, kMaxOutputChannels);
    for (uint32_t c = 0; c < output_channel_count_; ++c) {
      meter_output_channel(out + c, fr, /*stride=*/channels, c);
    }
  }

  // Monitor DIM last (ES-629): after the render, the limiter, the
  // loudness tap and the output meters above, so none of them see it.
  apply_monitor_dim(out, frames, channels);
}

void AudioGraph::update_output_rms_alpha() {
  // Same integration math as RmsMeter::update_alpha().
  float window_samples =
      (kMeterRmsWindowMs / 1000.0f) * static_cast<float>(sample_rate_);
  if (window_samples < 1.0f) window_samples = 1.0f;
  output_rms_alpha_ = 1.0f - std::exp(-1.0f / window_samples);
}

void AudioGraph::meter_output_channel(const float* samples, uint32_t frames,
                                      uint32_t stride, uint32_t channel) {
  float peak = 0.0f;
  float avg = output_rms_sq_[channel];
  const float alpha = output_rms_alpha_;
  for (uint32_t f = 0; f < frames; ++f) {
    const float s = samples[static_cast<size_t>(f) * stride];
    const float v = std::abs(s);
    if (v > peak) peak = v;
    avg += alpha * (s * s - avg);
  }
  // A NaN/Inf sample would poison the EMA permanently (NaN never
  // leaves an average) — drop the state back to silence instead.
  if (!std::isfinite(avg)) avg = 0.0f;
  output_peaks_[channel] = peak;
  output_rms_sq_[channel] = avg;
  output_rms_[channel] = std::sqrt(avg);
  // Sticky clip latch at 0 dBFS — same semantics as the per-element
  // PeakMeter flags, so the UI never misses an over between reads.
  if (peak >= 1.0f) output_clip_[channel] = 1;
}

uint32_t AudioGraph::get_output_peaks(float* dst, uint32_t max_ch) const {
  const uint32_t n = std::min(output_channel_count_, max_ch);
  for (uint32_t i = 0; i < n; ++i) dst[i] = output_peaks_[i];
  return n;
}

uint32_t AudioGraph::get_output_rms(float* dst, uint32_t max_ch) const {
  const uint32_t n = std::min(output_channel_count_, max_ch);
  for (uint32_t i = 0; i < n; ++i) dst[i] = output_rms_[i];
  return n;
}

uint32_t AudioGraph::get_output_clips(uint8_t* dst, uint32_t max_ch) const {
  const uint32_t n = std::min(output_channel_count_, max_ch);
  for (uint32_t i = 0; i < n; ++i) dst[i] = output_clip_[i];
  return n;
}

void AudioGraph::request_clip_clear() {
  clip_clear_requested_.store(true, std::memory_order_release);
}

void AudioGraph::consume_pending_clip_clear() {
  if (clip_clear_requested_.exchange(false, std::memory_order_acquire)) {
    clear_clips_now();
  }
}

void AudioGraph::clear_clips_now() {
  const uint32_t n = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < n; ++i) {
    for (auto& c : global_meter_state_.elements[i].clip) {
      c = 0;
    }
  }
  for (auto& c : output_clip_) {
    c = 0;
  }
}

void AudioGraph::seek(uint64_t frame_pos) {
  if (iamf_session_) {
    // Single stream drives every AE — one session seek repositions
    // all iamf_ring_source chains. The request is STAGED for the
    // audio thread (ES-473) rather than posted to the session here: the
    // audio thread fades the IAMF program out first, posts RT-safely,
    // and holds the chains muted until the post-seek refill is primed
    // — see update_seek_mute_state(). The paused transport branch
    // consumes via consume_pending_seek_paused().
    //
    // frame_pos is in engine-rate frames; the session's timeline is
    // in file-rate frames. Convert by ratio (same rounding as the WAV
    // path below) so the stream restarts at the requested playhead.
    // Clamp here too: seek_to_frame()'s clamp reads total_frames(),
    // which is control-thread-only — the audio thread posts the
    // staged value verbatim.
    uint64_t file_pos = frame_pos;
    const uint32_t file_sr = iamf_session_->sample_rate();
    if (file_sr != 0 && sample_rate_ != 0 && file_sr != sample_rate_) {
      file_pos = (frame_pos * file_sr + (sample_rate_ / 2)) / sample_rate_;
    }
    const uint64_t total = iamf_session_->total_frames();
    if (total > 0) {
      file_pos = std::min(file_pos, total);
    }
    // Position first, count second — the audio thread reads count
    // then position, so a torn pair can only deliver a fresher
    // position (see the staging-protocol comment in the header).
    pending_seek_file_pos_.store(file_pos, std::memory_order_release);
    pending_seek_count_.fetch_add(1, std::memory_order_release);
    return;
  }
  // WAV sessions stage too (ES-536): repositioning the readers here, on
  // the control thread, hard-spliced old program to new mid-callback —
  // the last unfaded transport edge. The audio thread now runs the
  // same fade-out → apply → fade-in machinery as IAMF; the priming
  // hold degenerates (iamf_rings_primed() is trivially true with no
  // IAMF session), so a WAV seek costs fade-out + one held block +
  // fade-in. Staged in ENGINE-rate frames; apply_wav_seek_rt converts
  // per chain. Paused seeks are consumed by the paused hook, which
  // skips the fade — nothing is audible while paused.
  pending_seek_file_pos_.store(frame_pos, std::memory_order_release);
  pending_seek_count_.fetch_add(1, std::memory_order_release);
}

void AudioGraph::apply_wav_seek_rt(uint64_t engine_frame_pos) {
  const uint32_t n = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < n; ++i) {
    ElementChain& chain = elements_[i];
    if (!chain.wav_reader) continue;
    uint64_t wav_pos = engine_frame_pos;
    if (chain.resampler) {
      // engine-rate frames → the WAV's file-rate cursor. Convert by
      // ratio so the chain restarts at the same playhead position the
      // user requested, regardless of which side of the resampler
      // we're indexing.
      const uint32_t in_sr = chain.resampler->in_rate();
      const uint32_t out_sr = chain.resampler->out_rate();
      if (out_sr > 0) {
        wav_pos = (engine_frame_pos * in_sr + (out_sr / 2)) / out_sr;
      }
    }
    // No clamp needed (unlike the IAMF branch's control-side clamp):
    // WavReader::seek is a bounds-clamped cursor assignment — no I/O
    // at all — so an out-of-range target lands at EOF and reads
    // return silence. Resampler history is dropped by the shared loop
    // in post_staged_seek_rt().
    chain.wav_reader->seek(wav_pos);
  }
}

void AudioGraph::post_staged_seek_rt() {
  // Count first, position second: the control thread stores position
  // before bumping the count, so this order can only pair the count
  // with an equal-or-fresher position (header comment).
  const uint32_t count = pending_seek_count_.load(std::memory_order_acquire);
  const uint64_t pos = pending_seek_file_pos_.load(std::memory_order_acquire);
  if (iamf_session_) {
    iamf_session_->post_seek_rt(pos);
    seek_posted_request_count_ = iamf_session_->seeks_requested();
  } else {
    apply_wav_seek_rt(pos);
    seek_posted_request_count_ = 0;
  }
  pending_seek_consumed_ = count;
  seek_prime_hold_frames_ = 0;  // re-arm the priming watchdog
  // Drop resampler LPF history on every chain so pre-seek samples
  // don't leak into the first post-seek output block. Safe here: the
  // resampler is audio-thread-owned.
  const uint32_t n = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < n; ++i) {
    if (elements_[i].resampler) elements_[i].resampler->reset();
  }
}

bool AudioGraph::iamf_rings_primed() const {
  // WAV sessions have nothing to refill — the reader reposition in
  // post_staged_seek_rt() is the whole apply, so the priming hold
  // completes on the next block (ES-536).
  if (!iamf_session_) return true;
  // Until the I/O thread has applied the posted seek (upstream Seek
  // done, discard floors published), buffered_frames() still counts
  // the stale pre-seek backlog — never trust it before then.
  if (iamf_session_->seeks_applied() < seek_posted_request_count_) {
    return false;
  }
  const uint32_t n = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < n; ++i) {
    const ElementChain& chain = elements_[i];
    if (!chain.iamf_ring_source) continue;
    const uint32_t ae = chain.iamf_ring_source->ae_index();
    if (iamf_session_->buffered_frames(ae) >= kSeekPrimeFrames) continue;
    // A ring that will never reach the threshold (seek near EOF, or a
    // failed seek that EOF-marked every ring) counts as primed — the
    // fade-in then reveals the drain-to-EOF tail or silence.
    if (chain.iamf_ring_source->eof()) continue;
    return false;
  }
  return true;
}

void AudioGraph::update_seek_mute_state(uint32_t frames) {
  // WAV sessions run the same machine (ES-536): their seeks are staged
  // like IAMF's, and iamf_rings_primed() is trivially true with no
  // IAMF session, so the priming hold lasts exactly one block.
  const uint32_t pending = pending_seek_count_.load(std::memory_order_acquire);
  switch (seek_mute_state_) {
    case SeekMuteState::kIdle:
      if (pending != pending_seek_consumed_) {
        seek_mute_state_ = SeekMuteState::kFadeOut;
      }
      break;
    case SeekMuteState::kFadeOut:
      // The previous block's ramp reached silence — post now, then
      // hold. (Posting one block after silence keeps this block's
      // ramp tail reading the old program, not racing the discard.)
      if (seek_fade_gain_ <= 0.0f) {
        post_staged_seek_rt();
        seek_mute_state_ = SeekMuteState::kPriming;
      }
      break;
    case SeekMuteState::kPriming:
      if (pending != pending_seek_consumed_) {
        // A newer seek arrived mid-prime (scrub drag): re-post and
        // keep holding. Naturally coalesces a seek storm.
        post_staged_seek_rt();
      } else if (iamf_rings_primed()) {
        seek_mute_state_ = SeekMuteState::kIdle;  // fade back in below
      } else {
        // Watchdog: a ring can starve without EOF (see
        // kSeekPrimeTimeoutSeconds) — give up rather than hold the
        // whole mix muted forever.
        seek_prime_hold_frames_ += frames;
        if (static_cast<float>(seek_prime_hold_frames_) >=
            kSeekPrimeTimeoutSeconds * static_cast<float>(sample_rate_)) {
          engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio",
                        "seek prime timeout: a ring never refilled — "
                        "resuming unprimed (expect underruns on the "
                        "starved element; see ES-238)");
          seek_mute_state_ = SeekMuteState::kIdle;
        }
      }
      break;
  }

  // Advance the linear fade toward the state's target and bracket
  // this block with [g0, g1] — same ramp shape as OAR's output fade.
  const float target = (seek_mute_state_ == SeekMuteState::kIdle) ? 1.0f : 0.0f;
  const float start = seek_fade_gain_;
  float end = start;
  if (start != target) {
    const float step =
        (sample_rate_ > 0)
            ? static_cast<float>(frames) /
                  (kSeekFadeSeconds * static_cast<float>(sample_rate_))
            : 1.0f;
    end = (target > start) ? start + step : start - step;
    if ((target > start) ? (end > target) : (end < target)) end = target;
  }
  seek_fade_g0_ = start;
  seek_fade_g1_ = end;
  seek_fade_gain_ = end;
}

// Shared zero block fed to every chain while draining the OAR tail
// (ES-530). Never written; .bss, so it costs address space, not resident
// pages proportional to use.
static const float kOarDrainZeros[kGraphMaxChannels * kGraphMaxFrames] = {};

void AudioGraph::drain_oar_tail_paused() {
  // Gate first, like consume_pending_seek_paused(): this runs on the
  // paused callback, which keeps firing while control-thread barriers
  // mutate the chains (element remove, session open/close) — their
  // quiescence wait only drains the in-flight callback. A disarmed
  // gate makes the drain skip those windows; the caller re-arms after
  // the mutation and the drain resumes on the next paused callback.
  if (paused_drain_disarm_count_.load(std::memory_order_acquire) != 0) return;
  if (oar_tail_drained_) return;
  if (!oar_renderer_ || oar_renderer_->is_reconfiguring()) {
    // Not drained — retry on the next paused callback. A rebuild-driven
    // reconfigure resets OAR anyway, but begin_offline_exclusive()
    // raises the flag WITHOUT rebuilding (export while paused), and the
    // tail must still be drained once that window closes.
    return;
  }
  // limiter_delay() is 0 only before the first init; any built
  // instance carries the limiter's 5 ms delay line.
  if (bypass_oar_.load(std::memory_order_relaxed) ||
      oar_renderer_->limiter_delay() == 0) {
    oar_tail_drained_ = true;  // Nothing OAR-side to drain.
    return;
  }

  // Zero-feed every chain and render-discard ONE native-size block per
  // paused callback, until the output decays below audibility. The
  // zero feed is required: an element that is not re-fed REPEATS its
  // previous block at full level, so a bare render would refill OAR's
  // internals with program audio instead of draining them. One block
  // per callback keeps the paused branch's cost at a single render —
  // matrix layouts drain on the first block (the limiter delay line is
  // all they hold), while binaural rendering is a convolution whose
  // zero-input tail decays over many blocks and must never be chased
  // inside one callback (ES-530 review: ~1.5 ms per binaural render).
  const uint32_t n = element_count_.load(std::memory_order_acquire);
  const uint32_t fr = max_frames_;  // OAR's configured block size.
  for (uint32_t i = 0; i < n; ++i) {
    ElementChain& chain = elements_[i];
    // buf.channels holds the shape of the chain's last feed (clamped —
    // it also bounds the kOarDrainZeros read); a chain that never fed
    // (0) has nothing staged in OAR to overwrite.
    const uint32_t ch = std::min(chain.buf.channels, kGraphMaxChannels);
    if (ch == 0) continue;
    oar_renderer_->update_element_data(chain.id, kOarDrainZeros, ch, fr, fr);
  }
  const float* out = oar_renderer_->render(fr);
  if (out == nullptr) return;  // Dropped render — retry next callback.
  ++oar_drain_blocks_done_;

  float peak = 0.0f;
  const uint32_t out_ch = oar_renderer_->channel_count();
  for (uint32_t k = 0; k < fr * out_ch; ++k) {
    peak = std::max(peak, std::fabs(out[k]));
  }
  if (peak < kOarDrainSilenceEps) {
    oar_tail_drained_ = true;
  } else if (oar_drain_blocks_done_ >= kOarDrainMaxBlocks) {
    // Backstop only — decay is exponential and FTZ is on, so a real
    // renderer reaches the epsilon. Log rather than fail silently: a
    // cap exhaustion means resumes may open with an audible residue.
    oar_tail_drained_ = true;
    char buf[128];
    snprintf(buf, sizeof(buf),
             "oar tail drain capped at %u blocks (peak %.2e) — resume may "
             "carry residue",
             oar_drain_blocks_done_, static_cast<double>(peak));
    engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio", buf);
  }
}

void AudioGraph::consume_pending_seek_paused() {
  // The gate must be checked BEFORE any other member access: this
  // runs on the paused audio callback, which keeps firing while
  // control-thread barriers swap the session (open_iamf()/close_iamf()
  // — which also RESET the pending/consumed fields read below) or
  // mutate the chain array (element remove). Every such barrier holds
  // the paused-drain disarm scope, so this one gate covers them all;
  // while it is down the seek stays pending and is retried on the
  // next paused callback.
  if (paused_drain_disarm_count_.load(std::memory_order_acquire) != 0) return;
  const uint32_t pending = pending_seek_count_.load(std::memory_order_acquire);
  if (pending == pending_seek_consumed_) return;
  if (paused_seek_hook_armed_.load(std::memory_order_acquire)) {
    // Armed implies a valid session (armed only at the end of a
    // successful open, disarmed before every teardown). Paused output
    // is silent — no fade-out needed. Post and enter the priming hold
    // with the gain already at zero, so a resume stays muted until the
    // refill is primed, then fades in.
    post_staged_seek_rt();
    seek_mute_state_ = SeekMuteState::kPriming;
    seek_fade_gain_ = seek_fade_g0_ = seek_fade_g1_ = 0.0f;
    return;
  }
  if (iamf_session_ != nullptr) {
    // Should be unreachable: every disarmed-while-attached window sits
    // inside a PausedDrainDisarmScope (caught by the gate above) or
    // runs with no audio thread. If an engine change breaks that
    // invariant, retrying silently would livelock the seek — say so.
    engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio",
                  "paused seek: session attached but hook disarmed — "
                  "barrier invariant broken; retrying");
    return;
  }
  // WAV session (ES-536): reposition the readers now, while nothing is
  // audible, and stay transparent — no fade states to run, and the
  // transport fade-in covers the resume edge.
  post_staged_seek_rt();
  seek_mute_state_ = SeekMuteState::kIdle;
  seek_fade_gain_ = seek_fade_g0_ = seek_fade_g1_ = 1.0f;
}

void AudioGraph::note_ring_underrun(uint32_t element_index, uint32_t missing) {
  EclipsaStudioMeterState& ms = global_meter_state_;
  ms.ring_underrun_frames += missing;
  // Publish details first, then bump the counter last — same ordering
  // contract as the dropout/overrun blocks in audio_thread.cc, so the
  // Dart reader never pairs a bumped count with stale details.
  ms.last_underrun_element = element_index;
  ms.last_underrun_missing = missing;
  std::atomic_thread_fence(std::memory_order_release);
  const uint64_t n = ms.ring_underrun_count + 1;
  ms.ring_underrun_count = n;
  // Throttle the rt log to power-of-two event counts (1, 2, 4, …):
  // the first drops surface immediately; a sustained storm decays to
  // one line per doubling instead of one per callback.
  if ((n & (n - 1)) == 0) {
    char buf[256];
    int len =
        snprintf(buf, sizeof(buf),
                 "ring underrun: element=%u missing=%u frames "
                 "(events=%llu, frames_total=%llu)",
                 element_index, missing, static_cast<unsigned long long>(n),
                 static_cast<unsigned long long>(ms.ring_underrun_frames));
    // Append a per-ring fill snapshot for the IAMF path so a sustained
    // storm shows whether a sibling ring is full — which would wedge
    // the all-rings pump gate and starve this one — or also empty,
    // pointing upstream of the rings (ES-238). Atomic loads only; RT-safe.
    if (iamf_session_ && len > 0 && len < static_cast<int>(sizeof(buf))) {
      const uint32_t na = std::min<uint32_t>(
          iamf_session_->num_audio_elements(), kGraphMaxChannels);
      len += snprintf(buf + len, sizeof(buf) - len, " rings=[");
      for (uint32_t a = 0;
           a < na && len > 0 && len < static_cast<int>(sizeof(buf)); ++a) {
        const PcmRing* r = iamf_session_->ring(a);
        if (!r) continue;
        len += snprintf(buf + len, sizeof(buf) - len, "%s%u:%u/%u%s",
                        a == 0 ? "" : " ", a, r->buffered_frames(),
                        r->free_frames(), r->eof() ? "(eof)" : "");
      }
      if (len > 0 && len < static_cast<int>(sizeof(buf))) {
        snprintf(buf + len, sizeof(buf) - len, "] (buffered/free)");
      }
    }
    engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio", buf);
  }
}

void AudioGraph::reset_meters(bool preserve_clips) {
  // Contract: the peak/RMS resets below write meter internals and the
  // shared per-element meter slots without any fence of their own —
  // the caller must keep the audio callback quiescent (see
  // eclipsa_studio_meter_reset's pause + wait_for_callback_quiescent
  // barrier). Only the loudness analyzer rebuild is self-fenced.
  const uint32_t n = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < n; ++i) {
    if (elements_[i].peak_meter) {
      elements_[i].peak_meter->reset(global_meter_state_, i);
    }
    if (elements_[i].rms_meter) {
      elements_[i].rms_meter->reset(global_meter_state_, i);
    }
  }
  // The loudness meter rebuilds its analyzer here; fence the audio thread
  // out first so it isn't freed mid-process() (issue ES-145). The loudness
  // state clear rides inside the fence so the audio thread never observes
  // a partially-reset meter.
  if (mix_loudness_meter_) {
    with_loudness_fenced([this] {
      mix_loudness_meter_->reset();
      global_meter_state_.loudness = {};
    });
  } else {
    global_meter_state_.loudness = {};
  }
  global_meter_state_.frame_counter = 0;
  global_meter_state_.ring_underrun_count = 0;
  global_meter_state_.ring_underrun_frames = 0;
  // Output RMS carries integration state across blocks — clear it with
  // the rest of the meters (same quiescence contract as above).
  for (uint32_t c = 0; c < kMaxOutputChannels; ++c) {
    output_rms_sq_[c] = 0.0f;
    output_rms_[c] = 0.0f;
    output_peaks_[c] = 0.0f;
  }
  // Clip latches last, through the one definition of "clear every
  // latch" (element clip[] and output_clip_ alike). PeakMeter::reset
  // deliberately leaves them alone.
  if (!preserve_clips) clear_clips_now();
}

bool AudioGraph::set_monitoring_layout(uint32_t layout) {
  if (!oar_renderer_) return false;
  // Always reconfigure on an applied switch, even to the same channel
  // count: the old integrated measurement belongs to the old layout and
  // channel weighting.
  return change_oar_loudness_fenced(
      [this, layout] { return oar_renderer_->set_layout(layout); },
      /*force_meter_reconfigure=*/true);
}

bool AudioGraph::end_offline_exclusive() {
  if (!oar_renderer_) return false;
  // The fence costs at most one callback: while the mode is held the
  // audio thread skips OAR and acknowledges the fence at the end of
  // process() (or on the paused branch).
  return change_oar_loudness_fenced(
      [this] { return oar_renderer_->end_offline_exclusive(); },
      /*force_meter_reconfigure=*/false);
}

void AudioGraph::resync_loudness_meter_if_stale() {
  if (!oar_renderer_ || !mix_loudness_meter_) return;
  if (oar_renderer_->is_offline_exclusive()) return;
  if (oar_renderer_->channel_count() == 0) return;
  if (loudness_meter_matches_oar()) return;
  with_loudness_fenced(
      [this] { resync_loudness_meter_locked(/*force=*/false); });
}

bool AudioGraph::loudness_meter_matches_oar() const {
  return oar_renderer_->channel_count() ==
             mix_loudness_meter_->num_channels() &&
         oar_renderer_->layout() == mix_loudness_meter_->layout();
}

void AudioGraph::resync_loudness_meter_locked(bool force) {
  if (oar_renderer_->is_offline_exclusive()) return;
  const uint32_t channels = oar_renderer_->channel_count();
  const uint32_t layout = oar_renderer_->layout();
  if (channels == 0) return;
  if (!force && loudness_meter_matches_oar()) return;
  // reconfigure() frees and rebuilds the analyzer (issue ES-145); the caller's
  // fence keeps the audio thread out of it. Clear the loudness-accumulated
  // state too: the old integrated measurement belongs to the old layout.
  mix_loudness_meter_->reconfigure(channels, layout);
  global_meter_state_.loudness = {};
}

void AudioGraph::wait_for_loudness_ack() {
  // No callbacks firing → the audio thread cannot be inside the meter, and
  // nothing would ever post the ack; skip the wait entirely.
  if (!audio_running_.load(std::memory_order_acquire)) return;
  // The audio thread posts the ack within one callback (~10 ms at
  // 48 kHz / 512). The timeout is an escape hatch for the device stopping
  // between the running-check above and here; 500 ms matches OarRenderer's
  // wait_for_audio_thread_ack() default.
  // seq_cst: see loudness_reconfiguring_ in the header.
  const uint64_t prev = loudness_ack_.load(std::memory_order_seq_cst);
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
  while (loudness_ack_.load(std::memory_order_seq_cst) == prev) {
    if (std::chrono::steady_clock::now() >= deadline) return;
    std::this_thread::yield();
  }
}

int32_t AudioGraph::set_routing(const uint64_t* masks, uint32_t len) {
  // Reject a stale-length push rather than partially apply it: len must match
  // the active OAR channel count so each OAR channel maps to exactly one mask.
  const uint32_t rch = oar_renderer_ ? oar_renderer_->channel_count() : 0;
  if (masks == nullptr || len != rch || len > kMaxRoutingChannels) {
    char buf[96];
    snprintf(buf, sizeof(buf), "set_routing rejected: len=%u, oar_ch=%u", len,
             rch);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "engine", buf);
    return -1;
  }
  std::lock_guard<std::mutex> lock(routing_mutex_);
  for (uint32_t i = 0; i < len; ++i) {
    routing_[i].store(masks[i], std::memory_order_relaxed);
  }
  return 0;
}

int32_t AudioGraph::set_layout_and_routing(uint32_t layout,
                                           const uint64_t* masks,
                                           uint32_t len) {
  if (!oar_renderer_) return -1;
  if (masks == nullptr || len == 0 || len > kMaxRoutingChannels) return -1;
  std::lock_guard<std::mutex> lock(routing_mutex_);
  // Store the new layout's routing FIRST so the masks are live before the OAR
  // rebuild. During the rebuild the audio thread skips rendering
  // (is_reconfiguring), so it never observes the new layout paired with the
  // old routing — the switch is glitch-free.
  for (uint32_t i = 0; i < len; ++i) {
    routing_[i].store(masks[i], std::memory_order_relaxed);
  }
  // Reset every slot above the pushed range back to identity. Without this a
  // shrink (wide layout -> narrow) would leave the old wide-layout masks live
  // in routing_[len..63]; if the new layout reuses an OAR channel in that range
  // the audio thread would scatter it through a stale patch. Identity (1<<i)
  // matches the un-pushed default, so the worst case is a benign 1:1 fallback.
  for (uint32_t i = len; i < kMaxRoutingChannels; ++i) {
    routing_[i].store(1ull << i, std::memory_order_relaxed);
  }
  if (!set_monitoring_layout(layout)) return -1;
  // The caller is expected to size `masks` to the post-switch channel count.
  // If it didn't, the routing is still safe (identity fallback above), but the
  // mismatch is a wiring bug worth surfacing.
  const uint32_t rch = oar_renderer_->channel_count();
  if (len != rch) {
    char buf[96];
    snprintf(buf, sizeof(buf),
             "set_layout_and_routing: len=%u != new oar_ch=%u", len, rch);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "engine", buf);
  }
  return 0;
}

void AudioGraph::set_noise(uint8_t mode, uint32_t channel, float amp) {
  noise_.store(pack_noise(mode, channel, amp), std::memory_order_relaxed);
}

void AudioGraph::render_noise(float* out, uint32_t frames, uint32_t channels) {
  if (!out) return;
  const uint32_t fr = std::min(frames, kGraphMaxFrames);
  // Zero the full requested buffer (not just the clamped fr) so an oversized
  // request leaves the tail silent rather than uninitialised; the generator
  // and scatter below only touch [0, fr).
  std::memset(out, 0, static_cast<size_t>(frames) * channels * sizeof(float));

  const NoiseState nd = unpack_noise(noise_.load(std::memory_order_relaxed));
  if (nd.mode != 0) {
    // Snapshot the routing masks so row noise follows the patch exactly like
    // program audio would; col noise indexes the device channel directly.
    uint64_t local[kMaxRoutingChannels];
    const uint32_t rch = oar_renderer_ ? oar_renderer_->channel_count() : 0;
    const uint32_t n = std::min(rch, kMaxRoutingChannels);
    for (uint32_t c = 0; c < n; ++c) {
      local[c] = routing_[c].load(std::memory_order_relaxed);
    }
    for (uint32_t f = 0; f < fr; ++f) {
      noise_storage_[f] = noise_gen_.next() * nd.amp;
    }
    scatter_noise(out, noise_storage_, nd.mode, nd.channel, local, n, fr,
                  channels);
  }

  // Keep the master output meter alive while paused so the calibration level
  // is visible on the UI.
  output_channel_count_ = std::min(channels, kMaxOutputChannels);
  for (uint32_t c = 0; c < output_channel_count_; ++c) {
    meter_output_channel(out + c, fr, /*stride=*/channels, c);
  }

  // Calibration noise is dimmed like program (ES-629): DIM emulates the
  // listening chain, after the meter tap above.
  apply_monitor_dim(out, frames, channels);
}

ElementChain* AudioGraph::find_element(uint32_t id) {
  const uint32_t n = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < n; ++i) {
    if (elements_[i].id == id) return &elements_[i];
  }
  return nullptr;
}
