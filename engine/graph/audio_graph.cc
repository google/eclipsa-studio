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

// Output-channel solo and mute (ES-999): the ramp time between unity and
// silence, in each direction.
static constexpr float kOutputSoloMuteRampMs = 15.0f;

#include "dsp/gain.h"
#include "dsp/resampler.h"
#include "engine_log.h"
#include "graph/routing_scatter.h"
#include "iamf/iamf_playback_session.h"
#include "iamf/iamf_ring_source.h"
#include "io/wav_stream.h"
#include "meters/channel_stats.h"
#include "meters/live_loudness_meter.h"
#include "meters/peak_meter.h"
#include "meters/rms_meter.h"
#include "renderer/oar_renderer.h"

// The live loudness meter's ring holds at least one analyzer chunk, so a
// graph block always fits the ring when the meter thread has drained it.
static_assert(kGraphMaxFrames <= LiveLoudnessMeter::kChunkFrames,
              "graph blocks must fit the live loudness meter's ring");

namespace {

// Multiplies the first `frames` frames of every channel of `buf` by a
// linear ramp starting at g0. The step divides by `frames`, not
// frames - 1, so the ramp of the next block, starting at g1, joins this
// one continuously. Same form as the OAR output fade.
void ramp_buffer(AudioBuffer& buf, uint32_t frames, float g0, float g1) {
  if (frames == 0) return;
  const float step = (g1 - g0) / static_cast<float>(frames);
  for (uint32_t c = 0; c < buf.channels; ++c) {
    float* d = buf.channel(c);
    float g = g0;
    for (uint32_t f = 0; f < frames; ++f) {
      d[f] *= g;
      g += step;
    }
  }
}

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
  wav_stream.reset();
  resampler.reset();
  iamf_ring_source.reset();
  gain.reset();
  mute_gain.reset();
  peak_meter.reset();
  rms_meter.reset();
  channel_stats.reset();
  buf = AudioBuffer{};
  routing_slots = {};
  routing_shared.store(kRoutingInitialShared, std::memory_order_relaxed);
  routing_front = kRoutingInitialFront;
  routing_back = kRoutingInitialBack;
  join_pending = false;
  joining = false;
  join_frame = 0;
  join_attempts = 0;
}

void ElementChain::move_from(ElementChain& src) {
  id = src.id;
  ctrl.copy_from(src.ctrl);
  wav_stream = std::move(src.wav_stream);
  resampler = std::move(src.resampler);
  iamf_ring_source = std::move(src.iamf_ring_source);
  gain = std::move(src.gain);
  mute_gain = std::move(src.mute_gain);
  peak_meter = std::move(src.peak_meter);
  rms_meter = std::move(src.rms_meter);
  channel_stats = std::move(src.channel_stats);
  buf = src.buf;
  // Routing state is slot contents plus slot indices, so it copies as
  // it is, a published-but-untaken map included. Callers hold the audio
  // thread out of process() (remove_element and close_iamf run under
  // the pause and quiescence barrier), so neither side of the slot
  // protocol runs during the copy.
  routing_slots = src.routing_slots;
  routing_shared.store(src.routing_shared.load(std::memory_order_relaxed),
                       std::memory_order_relaxed);
  routing_front = src.routing_front;
  routing_back = src.routing_back;
  join_pending = src.join_pending;
  joining = src.joining;
  join_frame = src.join_frame;
  join_attempts = src.join_attempts;
  src.reset();
}

void ElementChain::publish_routing() {
  // Release: the writes to the slot happen before the audio thread's
  // exchange that takes it. Acquire: the parked slot taken here may be
  // one the audio thread read during an earlier block, and its exchange
  // (release) put it there after those reads.
  routing_back = routing_shared.exchange(routing_back | kRoutingFresh,
                                         std::memory_order_acq_rel) &
                 kRoutingSlotMask;
}

const ElementChain::RoutingSlot& ElementChain::routing_for_block() {
  // Only the audio thread clears kRoutingFresh, so a set bit seen here
  // is still set at the exchange (which may return a newer slot than
  // the one first seen, if the control thread published again).
  if (routing_shared.load(std::memory_order_relaxed) & kRoutingFresh) {
    routing_front =
        routing_shared.exchange(routing_front, std::memory_order_acq_rel) &
        kRoutingSlotMask;
  }
  return routing_slots[routing_front];
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
  // Output-channel solo and mute (ES-999) off: nothing silenced, unity gain.
  output_silenced_.store(0, std::memory_order_relaxed);
  for (uint32_t i = 0; i < kMaxRoutingChannels; ++i) {
    output_channel_gains_[i] = 1.0f;
  }
  update_output_rms_alpha();

  // OAR renderer — default to stereo layout.
  oar_renderer_ = std::make_unique<OarRenderer>();
  oar_renderer_->init(sample_rate_, max_frames_,
                      /*layout=*/2 /*ck_oar_layout_stereo*/);
  // A new OarRenderer counts its instances from 1 again, so the first
  // block rendered by this one is ramped in too. Written before the
  // audio thread starts.
  oar_generation_fed_ = 0;

  // Mix-bus loudness meter. Measures the post-OAR rendered output so the
  // number matches what iamf-tools would report for the same signal. Sized
  // to OAR's current layout; layout switches go through
  // set_monitoring_layout().
  mix_loudness_meter_ = std::make_unique<LiveLoudnessMeter>(
      sample_rate_, oar_renderer_->channel_count(), oar_renderer_->layout(),
      &global_meter_state_.loudness);

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
  // The program position is in engine-rate frames (ES-986). A join in
  // progress targets a frame at the old rate, so it starts again; the
  // caller seeks after a rate change anyway (engine.cc does), which
  // aligns every chain.
  program_frame_ = (program_frame_ * new_rate + old_rate / 2) / old_rate;
  const uint32_t count = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < count; ++i) {
    ElementChain& chain = elements_[i];
    if (chain.peak_meter) chain.peak_meter->set_sample_rate(new_rate);
    if (chain.rms_meter) chain.rms_meter->set_sample_rate(new_rate);
    if (chain.channel_stats) chain.channel_stats->set_sample_rate(new_rate);
    if (chain.joining) {
      chain.joining = false;
      chain.join_pending = true;
    }
    chain.join_attempts = 0;

    uint32_t src_sr = 0;
    if (chain.wav_stream) {
      src_sr = chain.wav_stream->sample_rate();
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

  // set_sample_rate() also resizes the meter's ring, but unlike
  // reset_meters() / set_monitoring_layout() it is only ever called with
  // the audio thread stopped (engine.cc stops the device, retargets, then
  // restarts), so it cannot race push() and needs no loudness fence. See
  // issue ES-145.
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
  program_frame_ = 0;
  // The chain resets above released every WavStream; stop the disk
  // thread too (add_element() starts a new one).
  wav_streamer_.reset();
  // Stop and join the loudness meter's thread here, in the engine's
  // shutdown call, rather than in a static destructor at process exit
  // (g_graph is a static). init() creates a new meter. Every user of the
  // meter checks for null.
  mix_loudness_meter_.reset();
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
  chain.gain = std::make_unique<dsp::Gain>();
  chain.mute_gain = std::make_unique<dsp::Gain>();
  // Start unmuted — gain at unity. set_element_mute() and the solo pass
  // in process() update the target; the IIR smoother ramps.
  chain.mute_gain->set_gain_db(0.0f);
  chain.peak_meter = std::make_unique<PeakMeter>(2.0f, sample_rate_);
  chain.rms_meter = std::make_unique<RmsMeter>(kMeterRmsWindowMs, sample_rate_);
  chain.channel_stats = std::make_unique<ChannelStats>();
  chain.channel_stats->set_sample_rate(sample_rate_);

  // WavStream opens lenient: a damaged-but-playable file (truncated
  // recording, junk tail) plays its intact prefix rather than refusing
  // to load. Export and ADM import stay strict — see wav::OpenMode. It
  // also reads the file's first 4096 frames here, on the control thread,
  // so the element has data before the disk thread first wakes.
  chain.wav_stream = std::make_shared<WavStream>();
  if (!chain.wav_stream->open(wav_path, kGraphMaxChannels)) {
    char buf[512];
    snprintf(buf, sizeof(buf), "WAV open FAILED: id=%u, path=%s", id, wav_path);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "graph", buf);
    chain.reset();
    return -3;  // Failed to open WAV.
  }

  {
    char buf[256];
    snprintf(buf, sizeof(buf), "WAV opened: id=%u, ch=%u, sr=%u, frames=%llu",
             id, chain.wav_stream->channels(), chain.wav_stream->sample_rate(),
             static_cast<unsigned long long>(chain.wav_stream->total_frames()));
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "graph", buf);
  }

  // Set up element buffer view — use the WAV's actual channel count
  // (capped at kGraphMaxChannels by WavStream::open) so meters report
  // the correct number of channels.
  const uint32_t wav_ch = chain.wav_stream->channels();
  chain.buf.data = chain.buf_storage;
  chain.buf.channels = wav_ch;
  chain.buf.frames = 0;
  chain.buf.capacity_frames = kGraphMaxFrames;
  chain.ctrl.wav_channels = wav_ch;

  // Sample-rate-convert the WAV stream to the engine output rate. The
  // graph and audio thread both clock at sample_rate_; without this,
  // a 44.1 kHz file would be consumed at the engine cadence, playing
  // back ~8.8 % pitched up and desyncing the timeline.
  const uint32_t wav_sr = chain.wav_stream->sample_rate();
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

  // The disk thread keeps the ring filled from here on.
  if (!wav_streamer_) wav_streamer_ = std::make_unique<WavStreamer>();
  wav_streamer_->add(chain.wav_stream);
  // Start at the program position, not at frame 0 (ES-986): the audio
  // thread seeks the chain there at its first playing block. A seek
  // before then (the one sent on play, for an element added while
  // paused) moves it instead.
  chain.join_pending = true;

  // Log before the publish below: from then on process() rewrites
  // chain.buf every block, and this thread must not read it.
  {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "add_element: id=%u wav_ch=%u wav_rate=%u buf_ch=%u "
             "capacity=%u max_frames=%u engine_rate=%u slot=%u resample=%s",
             id, chain.wav_stream->channels(), chain.wav_stream->sample_rate(),
             chain.buf.channels, chain.buf.capacity_frames, max_frames_,
             sample_rate_, count, chain.resampler ? "yes" : "no");
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "graph", buf);
  }

  chain.ctrl.active.store(true, std::memory_order_relaxed);
  const uint32_t new_count = count + 1;
  element_count_.store(new_count, std::memory_order_release);

  // Keep element_count in the shared state in sync with the graph.
  global_meter_state_.element_count = new_count;

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

void AudioGraph::set_element_channel_order(uint32_t id, uint32_t order) {
  ElementChain* chain = find_element(id);
  if (chain) chain->ctrl.channel_order.store(order, std::memory_order_relaxed);
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

  // Fill the control thread's own slot, then publish it (see
  // ElementChain). len 0 is identity: the audio thread skips the remap.
  ElementChain::RoutingSlot& slot = chain->routing_back_slot();
  if (map == nullptr || len == 0) {
    slot.len = 0;
    chain->publish_routing();
    return;
  }

  if (len > kGraphMaxChannels) {
    char buf[96];
    snprintf(buf, sizeof(buf),
             "set_routing: id=%u len=%u clamped to kGraphMaxChannels=%u", id,
             len, kGraphMaxChannels);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "graph", buf);
  }

  const uint32_t clamped_len = std::min(len, kGraphMaxChannels);
  const uint32_t src_ch = chain->ctrl.wav_channels;
  bool any_oob = false;
  for (uint32_t i = 0; i < clamped_len; ++i) {
    const int8_t s = map[i];
    if (s >= 0 && static_cast<uint32_t>(s) >= src_ch) any_oob = true;
    slot.map[i] = s;
  }
  if (any_oob) {
    char buf[96];
    snprintf(buf, sizeof(buf),
             "set_routing: id=%u has src index(es) >= wav_ch=%u; "
             "those dests will be silenced",
             id, src_ch);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "graph", buf);
  }
  slot.len = static_cast<uint8_t>(clamped_len);
  chain->publish_routing();
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

void AudioGraph::set_output_solo_mute(uint64_t soloed, uint64_t muted) {
  output_silenced_.store(muted | (soloed != 0 ? ~soloed : 0),
                         std::memory_order_relaxed);
}

void AudioGraph::settle_output_solo_mute(uint32_t from) {
  const uint64_t silenced = output_silenced_.load(std::memory_order_relaxed);
  for (uint32_t c = from; c < kMaxRoutingChannels; ++c) {
    output_channel_gains_[c] = ((silenced >> c) & 1u) != 0 ? 0.0f : 1.0f;
  }
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
  // The WAV chains' reads move the program position this block unless
  // the seek hold skips them (ES-986).
  const bool program_moves = seek_mute_state_ != SeekMuteState::kPriming;

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
  // The shared meter state's element_count is the control thread's to
  // write (meters/meter_state.h).
  const uint32_t n = element_count_.load(std::memory_order_acquire);

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
    // continuous data. Exactly one of {wav_stream, iamf_ring_source}
    // is non-null per active chain, and both read a ring: the
    // WavStreamer's disk thread fills a WAV chain's (ES-836), the IAMF
    // session's I/O thread an IAMF chain's. A short read without EOF
    // means that thread fell behind and is counted as an underrun.
    // When the source's native sample rate differs from the engine
    // rate, a dsp::Resampler stage converts it; consume() updates
    // chain.buf.frames to the actually-produced count so downstream
    // DSP / metering processes a valid range.
    // While the seek state machine holds the chains in the priming
    // mute (ES-473), skip their ring reads entirely: the output is
    // silent anyway, and consuming the freshly-refilled frames while
    // inaudible would burn the first post-seek program. The
    // pre-zeroed buffer plays as silence; reads resume on fade-in.
    // Short reads during the hold are expected, so the underrun
    // accounting is skipped along with the read. A WAV chain beside an
    // IAMF session also skips during the session's hold; it is not
    // seeked, and its output is muted then anyway. A WAV chain whose
    // stream has not applied the last posted seek when the hold ends
    // (the watchdog in update_seek_mute_state() gave up) joins the
    // program again (step_join_rt()), as its ring still holds frames
    // from before the seek.
    //
    // A WAV chain added while the program plays joins it in step (ES-986;
    // see ElementChain::join_pending and step_join_rt()), skipping its
    // reads until it starts. So does a WAV chain that underruns: the
    // program moves on by the whole block while the chain's ring stays
    // where the disk thread left it, so the chain is behind by the
    // frames it missed and joins again (read_source below).
    const bool join_hold =
        chain.wav_stream != nullptr &&
        step_join_rt(chain, fr, program_moves, effectively_muted);
    const bool has_source =
        chain.wav_stream != nullptr || chain.iamf_ring_source != nullptr;
    const bool skip_read =
        has_source &&
        (seek_mute_state_ == SeekMuteState::kPriming || join_hold ||
         (chain.wav_stream && !chain.wav_stream->seek_applied()));
    auto read_source = [&](AudioBuffer& dst, uint32_t want) {
      uint32_t got = 0;
      bool eof = false;
      if (chain.wav_stream) {
        got = chain.wav_stream->read(dst, want);
        eof = chain.wav_stream->eof();
      } else {
        got = chain.iamf_ring_source->read(dst, want);
        eof = chain.iamf_ring_source->eof();
      }
      if (got < want && !eof) {
        note_ring_underrun(i, want - got);
        if (chain.wav_stream) {
          // The frames read play; the rest of the block is silence, and
          // the chain is silent from the next block until it has joined
          // the program again. At the end of the file a short read is
          // not an underrun and the chain plays out.
          char buf[128];
          snprintf(buf, sizeof(buf),
                   "join: element %u fell %u frames behind the program at "
                   "frame %llu; joining again",
                   chain.id, want - got,
                   static_cast<unsigned long long>(program_frame_));
          engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio", buf);
          chain.join_pending = true;
        }
      }
    };

    if (has_source && !skip_read) {
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
        read_source(rin, in_needed);
        chain.resampler->consume(chain.buf, rin.frames, fr);
      } else {
        read_source(chain.buf, fr);
      }
    }

    // Apply the seek de-click fade: a linear ramp across the block
    // from seek_fade_g0_ to seek_fade_g1_ (unity in steady state —
    // skipped, as is the priming hold, whose buffer is already
    // zeroed). Applied straight after the source read, before DSP and
    // metering, so meters show the audible (faded) level. A chain with
    // no source has a zeroed buffer, so the gain bracket plus the skip
    // flag is the whole predicate. Bracket first: the steady-state
    // early-out costs two scalar compares.
    if ((seek_fade_g0_ != 1.0f || seek_fade_g1_ != 1.0f) && !skip_read) {
      ramp_buffer(chain.buf, chain.buf.frames, seek_fade_g0_, seek_fade_g1_);
    }

    // Input-channel remap (skipped for identity, route.len == 0).
    // Convention: route.map[dest] = src; -1 silences the dest. The
    // WAV-shaped source is in chain.buf_storage; the remapped dest-shaped
    // buffer goes into chain.buf_remap_storage. We then swap the view.
    {
      const ElementChain::RoutingSlot& route = chain.routing_for_block();
      if (route.len != 0) {
        const uint32_t src_ch = chain.ctrl.wav_channels;
        const uint32_t dest_ch =
            std::min<uint32_t>(route.len, kGraphMaxChannels);
        for (uint32_t d = 0; d < dest_ch; ++d) {
          float* dst = chain.buf_remap_storage +
                       static_cast<size_t>(d) * kGraphMaxFrames;
          const int8_t s = route.map[d];
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
  // Channels the program scatter ramped this block (ES-999); 0 when no
  // program reached the device buffer through it.
  uint32_t scattered_channels = 0;

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
      //
      // A new OAR instance takes its first blocks ramped up from
      // silence (see oar_input_fade_gain_). The ramp goes on the
      // element buffers after metering, so it is the instance's input
      // only. The ramp state advances only once the block is rendered
      // (below): an instance fed but not rendered starts its ramp again
      // on the next block, whose element data replaces this one's.
      const uint32_t generation = oar_renderer_->instance_generation();
      const float in_g0 =
          generation == oar_generation_fed_ ? oar_input_fade_gain_ : 0.0f;
      float in_g1 = in_g0;
      if (in_g0 < 1.0f) {
        const float step =
            (sample_rate_ > 0)
                ? static_cast<float>(fr) /
                      (kOarInputFadeSeconds * static_cast<float>(sample_rate_))
                : 1.0f;
        in_g1 = std::min(1.0f, in_g0 + step);
      }
      for (uint32_t i = 0; i < n; ++i) {
        auto& chain = elements_[i];
        if (!chain.ctrl.active.load(std::memory_order_relaxed)) continue;
        if (in_g0 < 1.0f) ramp_buffer(chain.buf, fr, in_g0, in_g1);

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

        // A 9.1.6 element in OBR's alt order is permuted into OLR's
        // order here, after its routing, gains and meters (ES-960):
        // ElementInputOrder() returns a table only for the matching
        // channel count, so a mismatch feeds the block as it is.
        const eclipsa_studio::ChannelOrder* input_order =
            eclipsa_studio::ElementInputOrder(
                chain.ctrl.channel_order.load(std::memory_order_relaxed),
                chain.buf.channels);
        oar_renderer_->update_element_data(
            chain.id, chain.buf.data, chain.buf.channels, fr,
            chain.buf.capacity_frames, input_order);
      }

      // Push the group-level output mix gain with the same slew-and-ramp
      // pattern, so a large jump committed from the Mix view's output
      // mix gain knob or dB field does not click either.
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
          oar_generation_fed_ = generation;
          oar_input_fade_gain_ = in_g1;
          // The block in monitoring channel order (ES-960): for 9.1.6 a
          // planar copy of OAR's output with the channels permuted into
          // OBR's alternative order, so the routing matrix rows, the
          // identity patch and the output meters follow that order.
          // Every other layout is monitored as OLR renders it. The
          // table is keyed on the layout the current OAR instance
          // renders, and its channel count must match the render's,
          // so a stale pair during a layout switch falls back to the
          // unpermuted block rather than reading past either buffer.
          const float* monitored = rendered;
          const eclipsa_studio::ChannelOrder* order =
              eclipsa_studio::MonitoringChannelOrder(
                  oar_renderer_->rendered_layout());
          if (order != nullptr && order->channels == rch) {
            for (uint32_t c = 0; c < rch; ++c) {
              std::memcpy(monitoring_storage_ + static_cast<size_t>(c) * fr,
                          rendered + static_cast<size_t>(order->source[c]) * fr,
                          static_cast<size_t>(fr) * sizeof(float));
            }
            monitored = monitoring_storage_;
          }

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
            // Output-channel solo and mute (ES-999) are applied here, on
            // the way into the device buffer, so `monitored` and
            // `rendered` stay whole for the meters below. The plain
            // scatter runs while none of the n channels is silenced or
            // ramping; the channels above n are settled after the block.
            const uint64_t silenced =
                output_silenced_.load(std::memory_order_relaxed) &
                (n >= 64 ? ~0ull : (1ull << n) - 1);
            bool unity = silenced == 0;
            for (uint32_t c = 0; unity && c < n; ++c) {
              unity = output_channel_gains_[c] == 1.0f;
            }
            if (unity) {
              scatter_routed(out, monitored, local, n, fr, channels);
            } else {
              const float step =
                  1.0f / (kOutputSoloMuteRampMs * 0.001f *
                          static_cast<float>(std::max(sample_rate_, 1u)));
              scatter_routed_ramped(out, monitored, local, silenced,
                                    output_channel_gains_, step, n, fr,
                                    channels);
            }
            scattered_channels = n;
          } else {
            // A calibration cell is lit: mute the program and inject pink
            // noise at the fixed reference level, bypassing the output mix
            // gain. Row noise fans out through the patch; column noise goes
            // straight to the device channel.
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
          // Meter the render, not the patch, in monitoring order.
          output_render = monitored;
          output_render_ch = rch;
          oar_renderer_->snapshot_limiter_env();
          global_meter_state_.limiter_gr =
              static_cast<float>(oar_renderer_->limiter_env());

          // Post-OAR loudness meter — the rendered buffer is planar at
          // OAR's output channel count, with stride == fr (render packs
          // the block tightly). Wrap it as an AudioBuffer view; the
          // meter only reads, the const_cast is safe. It reads OAR's
          // own order, not the monitoring order: the meter's BS.1770
          // channel weights (meters/bs1770_weights.cc) follow OLR's.
          // push() copies the block into the meter's ring; the meter's
          // own thread runs the analyzer (ES-905).
          if (mix_loudness_meter_ && rch) {
            loudness_site_reached = true;
            // Skip + acknowledge while the control thread is reconfiguring
            // the meter (reset/reconfigure), so it never reallocates the
            // ring out from under this call. See issue ES-145.
            // seq_cst: see loudness_reconfiguring_ in the header.
            if (loudness_reconfiguring_.load(std::memory_order_seq_cst)) {
              loudness_ack_.fetch_add(1, std::memory_order_seq_cst);
            } else {
              AudioBuffer rv;
              rv.data = const_cast<float*>(rendered);
              rv.channels = rch;
              rv.frames = fr;
              rv.capacity_frames = fr;
              mix_loudness_meter_->push(rv, fr);
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

  // Output-channel solo and mute (ES-999): the channels the scatter did
  // not ramp, all of them when no program reached it (bypass,
  // calibration noise, no render), go straight to their target, so a
  // change made meanwhile is complete when program reaches them.
  settle_output_solo_mute(scattered_channels);

  // Compute output peak + RMS levels (exposed via
  // eclipsa_studio_get_output_peaks() / eclipsa_studio_get_output_rms()). When
  // OAR rendered, meter its planar per-channel output (pre-routing) so the
  // renderer view tracks the render itself — same source as the post-OAR
  // loudness meter. On bypass / silence there is no render, so fall back to
  // metering the interleaved device buffer.
  if (output_render != nullptr) {
    const uint32_t metered = std::min(output_render_ch, kMaxOutputChannels);
    output_channel_count_ = metered;
    for (uint32_t c = 0; c < metered; ++c) {
      const float* src = output_render + static_cast<size_t>(c) * fr;
      meter_output_channel(src, fr, /*stride=*/1, c);
    }
  } else {
    const uint32_t metered = std::min(channels, kMaxOutputChannels);
    output_channel_count_ = metered;
    for (uint32_t c = 0; c < metered; ++c) {
      meter_output_channel(out + c, fr, /*stride=*/channels, c);
    }
  }

  // Monitor DIM last (ES-629): after the render, the limiter, the
  // loudness tap and the output meters above, so none of them see it.
  apply_monitor_dim(out, frames, channels);

  if (program_moves) program_frame_ += fr;
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
  const uint32_t n = std::min<uint32_t>(output_channel_count_, max_ch);
  for (uint32_t i = 0; i < n; ++i) dst[i] = output_peaks_[i];
  return n;
}

uint32_t AudioGraph::get_output_rms(float* dst, uint32_t max_ch) const {
  const uint32_t n = std::min<uint32_t>(output_channel_count_, max_ch);
  for (uint32_t i = 0; i < n; ++i) dst[i] = output_rms_[i];
  return n;
}

uint32_t AudioGraph::get_output_clips(uint8_t* dst, uint32_t max_ch) const {
  const uint32_t n = std::min<uint32_t>(output_channel_count_, max_ch);
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
  // the last unfaded transport edge. The audio thread runs the same
  // fade-out → post → hold → fade-in machinery as IAMF; the hold lasts
  // until every WAV chain's disk-thread ring has applied the seek and
  // refilled (ES-836). Staged in ENGINE-rate frames; apply_wav_seek_rt
  // converts per chain. Paused seeks are consumed by the paused hook,
  // which skips the fade — nothing is audible while paused.
  pending_seek_file_pos_.store(frame_pos, std::memory_order_release);
  pending_seek_count_.fetch_add(1, std::memory_order_release);
}

void AudioGraph::apply_wav_seek_rt(uint64_t engine_frame_pos) {
  const uint32_t n = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < n; ++i) {
    ElementChain& chain = elements_[i];
    if (!chain.wav_stream) continue;
    // No clamp needed (unlike the IAMF branch's control-side clamp):
    // the disk thread clamps to the file's length, so an out-of-range
    // target lands at EOF and reads return silence. post_seek_rt() only
    // stores the request (no I/O, no lock). Resampler history is
    // dropped by the shared loop in post_staged_seek_rt().
    chain.wav_stream->post_seek_rt(wav_file_frame(chain, engine_frame_pos));
    // The seek moves this chain with the others, so a join in progress
    // is no longer needed (ES-986), and the next join starts with the
    // plain lead again.
    chain.join_pending = false;
    chain.joining = false;
    chain.join_attempts = 0;
  }
}

uint64_t AudioGraph::wav_file_frame(const ElementChain& chain,
                                    uint64_t engine_frame) {
  if (!chain.resampler) return engine_frame;
  // engine-rate frames → the WAV's file-rate cursor. Convert by ratio
  // so the chain lands at the same playhead position regardless of
  // which side of the resampler we're indexing.
  const uint32_t in_sr = chain.resampler->in_rate();
  const uint32_t out_sr = chain.resampler->out_rate();
  if (out_sr == 0) return engine_frame;
  return (engine_frame * in_sr + (out_sr / 2)) / out_sr;
}

void AudioGraph::start_join_rt(ElementChain& chain, uint32_t frames) {
  if (frames == 0) return;
  const uint64_t lead =
      static_cast<uint64_t>(kJoinLeadSeconds * static_cast<float>(sample_rate_))
      << chain.join_attempts;
  const uint64_t blocks = (lead + frames - 1) / frames;
  chain.join_frame = program_frame_ + blocks * frames;
  chain.wav_stream->post_seek_rt(wav_file_frame(chain, chain.join_frame));
  chain.join_pending = false;
  chain.joining = true;
}

bool AudioGraph::step_join_rt(ElementChain& chain, uint32_t frames,
                              bool program_moves, bool muted) {
  // At program frame 0 a chain that has not been seeked is already in
  // step: its stream starts at frame 0 of the file.
  if (chain.join_pending && program_frame_ == 0) chain.join_pending = false;
  if (!chain.joining && program_moves && !iamf_session_ &&
      !chain.wav_stream->seek_applied()) {
    // The seek hold ended (its watchdog gave up) before the disk thread
    // applied this chain's seek: the ring still holds frames from
    // before it, and the program has moved on from the target. Join
    // the program ahead instead of playing from the target once the
    // seek lands.
    if (!chain.join_pending) {
      char buf[128];
      snprintf(buf, sizeof(buf),
               "join: element %u seek unapplied at frame %llu; joining again",
               chain.id, static_cast<unsigned long long>(program_frame_));
      engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio", buf);
    }
    chain.join_pending = true;
  }
  if (!chain.join_pending && !chain.joining) return false;
  if (iamf_session_) {
    // Beside an IAMF session the WAV chains are not seeked; the chain
    // plays from where its stream is.
    chain.join_pending = false;
    chain.joining = false;
    chain.join_attempts = 0;
    return false;
  }
  if (!program_moves) {
    // During a seek hold program_frame_ is the hold's target. A chain
    // added now joins the hold: rings_primed() waits for its refill as
    // for the others, and it fades in with them. The hold skips its
    // reads meanwhile. The hold's watchdog starts again, so the chain
    // gets the full kSeekPrimeTimeoutSeconds for its refill.
    if (chain.join_pending) {
      chain.wav_stream->post_seek_rt(wav_file_frame(chain, program_frame_));
      chain.join_pending = false;
      seek_prime_hold_frames_ = 0;
    }
    return false;
  }
  if (chain.join_pending) start_join_rt(chain, frames);
  const bool at_join_frame = program_frame_ == chain.join_frame;
  if (at_join_frame &&
      chain.wav_stream->primed(wav_prime_frames(chain, frames))) {
    chain.joining = false;
    chain.join_attempts = 0;
    // Start from silence: snap the mute gain down, then restore this
    // block's target so it ramps up instead of stepping in mid-signal.
    if (chain.mute_gain) {
      chain.mute_gain->set_gain_db(-120.0f);
      chain.mute_gain->reset();
      chain.mute_gain->set_gain_db(muted ? -120.0f : 0.0f);
    }
    return false;
  }
  if (program_frame_ >= chain.join_frame) {
    // The ring was not primed in time (a slow disk), or the program
    // passed join_frame (the block size changed): join again further
    // ahead, with a longer lead after an unprimed ring.
    if (at_join_frame && chain.join_attempts < kMaxJoinLeadDoublings) {
      ++chain.join_attempts;
    }
    char buf[128];
    snprintf(buf, sizeof(buf),
             "join: element %u not in step at frame %llu; joining again "
             "(lead x%u)",
             chain.id, static_cast<unsigned long long>(program_frame_),
             1u << chain.join_attempts);
    engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio", buf);
    start_join_rt(chain, frames);
  }
  return true;
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
    program_frame_ = pos;
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

uint32_t AudioGraph::wav_prime_frames(const ElementChain& chain,
                                      uint32_t frames) {
  uint64_t input = frames;
  if (chain.resampler && chain.resampler->out_rate() > 0) {
    input = static_cast<uint64_t>(frames) * chain.resampler->in_rate() /
                chain.resampler->out_rate() +
            1;
  }
  // The disk thread stops filling a ring once less than a chunk is
  // free, so a larger threshold could never be reached.
  return static_cast<uint32_t>(
      std::min<uint64_t>(std::max<uint64_t>(kWavPrimeFrames, 2 * input),
                         WavStream::kRingFrames - WavStream::kChunkFrames));
}

bool AudioGraph::wav_join_pending() const {
  const uint32_t n = element_count_.load(std::memory_order_acquire);
  for (uint32_t i = 0; i < n; ++i) {
    if (elements_[i].wav_stream && elements_[i].join_pending) return true;
  }
  return false;
}

bool AudioGraph::rings_primed(uint32_t frames) const {
  const uint32_t n = element_count_.load(std::memory_order_acquire);
  if (!iamf_session_) {
    // post_staged_seek_rt() posted to every WAV chain's stream; each
    // checks that its disk-thread ring has applied the seek (discard
    // floor published) and refilled, or reached the end (ES-836).
    for (uint32_t i = 0; i < n; ++i) {
      const ElementChain& chain = elements_[i];
      if (!chain.wav_stream) continue;
      if (!chain.wav_stream->primed(wav_prime_frames(chain, frames))) {
        return false;
      }
    }
    return true;
  }
  // Until the I/O thread has applied the posted seek (upstream Seek
  // done, discard floors published), buffered_frames() still counts
  // the stale pre-seek backlog — never trust it before then.
  if (iamf_session_->seeks_applied() < seek_posted_request_count_) {
    return false;
  }
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

bool AudioGraph::wait_for_wav_streams(uint32_t frames,
                                      uint32_t timeout_ms) const {
  if (iamf_session_) return true;
  // The WAV branch of rings_primed(), less the streams a test has
  // stalled.
  const auto ready = [&] {
    const uint32_t n = element_count_.load(std::memory_order_acquire);
    for (uint32_t i = 0; i < n; ++i) {
      const ElementChain& chain = elements_[i];
      if (!chain.wav_stream || chain.wav_stream->stalled_for_testing()) {
        continue;
      }
      if (!chain.wav_stream->primed(wav_prime_frames(chain, frames))) {
        return false;
      }
    }
    return true;
  };
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (!ready()) {
    if (std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return true;
}

void AudioGraph::update_seek_mute_state(uint32_t frames) {
  // WAV sessions run the same machine (ES-536): their seeks are staged
  // like IAMF's and posted to each chain's WavStream, and
  // rings_primed() waits for every WAV chain's disk-thread ring to
  // refill (ES-836).
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
      } else if (rings_primed(frames) && !wav_join_pending()) {
        seek_mute_state_ = SeekMuteState::kIdle;  // fade back in below
      } else {
        // Watchdog: a ring can starve without EOF (see
        // kSeekPrimeTimeoutSeconds), or a slow disk can refill a WAV
        // ring late — give up rather than hold the whole mix muted
        // forever. A WAV chain whose seek is still unapplied then joins
        // the program again (step_join_rt()).
        seek_prime_hold_frames_ += frames;
        if (static_cast<float>(seek_prime_hold_frames_) >=
            kSeekPrimeTimeoutSeconds * static_cast<float>(sample_rate_)) {
          engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio",
                        "seek prime timeout: a ring did not refill within "
                        "250 ms; resuming unprimed (an IAMF element "
                        "underruns, a WAV element joins again)");
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
  // limiter_delay() is 0 only before the first init: the live graph
  // never turns the limiter off, and set_limiter_enabled() refuses any
  // instance not marked set_no_audio_thread(), so any built live
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
  if (!paused_seek_hook_armed_.load(std::memory_order_acquire) &&
      iamf_session_ != nullptr) {
    // Should be unreachable: every disarmed-while-attached window sits
    // inside a PausedDrainDisarmScope (caught by the gate above) or
    // runs with no audio thread. If an engine change breaks that
    // invariant, retrying silently would livelock the seek — say so.
    engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio",
                  "paused seek: session attached but hook disarmed — "
                  "barrier invariant broken; retrying");
    return;
  }
  // Armed implies a valid IAMF session (armed only at the end of a
  // successful open, disarmed before every teardown); with no session,
  // the seek goes to the WAV chains' streams (ES-536, ES-836). Paused
  // output is silent — no fade-out needed. Post and enter the priming
  // hold with the gain already at zero, so a resume stays muted until
  // the refill is primed, then fades in. The hold matters for WAV too:
  // a resume before the disk thread applies the seek would otherwise
  // read frames from before it. If the refill landed while paused, the
  // first playing block is the fade-in block.
  post_staged_seek_rt();
  seek_mute_state_ = SeekMuteState::kPriming;
  seek_fade_gain_ = seek_fade_g0_ = seek_fade_g1_ = 0.0f;
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
  // The loudness meter rewinds its ring here; fence the audio thread out
  // of push() first (issue ES-145). reset() also clears
  // global_meter_state_.loudness, under the meter's mutex.
  if (mix_loudness_meter_) {
    with_loudness_fenced([this] { mix_loudness_meter_->reset(); });
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
  // Always reconfigure the meter, which clears its readings. After a
  // switch, even to the same channel count, the old integrated
  // measurement belongs to the old layout and channel weighting. A call
  // with the current layout keeps the OAR instance (ES-987) but still
  // clears them: Playback makes that call on every mix-presentation
  // switch, and the measurement belongs to the previous mix.
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
  // reconfigure() reallocates the meter's ring (issue ES-145); the caller's
  // fence keeps the audio thread out of it. It also rebuilds the analyzer
  // and clears the readings: the old integrated measurement belongs to
  // the old layout.
  mix_loudness_meter_->reconfigure(channels, layout);
}

void AudioGraph::drain_loudness_meter() {
  if (mix_loudness_meter_) mix_loudness_meter_->drain();
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
  const uint32_t metered = std::min(channels, kMaxOutputChannels);
  output_channel_count_ = metered;
  for (uint32_t c = 0; c < metered; ++c) {
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
