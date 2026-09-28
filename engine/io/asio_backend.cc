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

#include "io/asio_backend.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <thread>

// clang-format off: the SDK headers are order-sensitive. asiosys.h
// must precede asio.h — it defines the platform macros (WINDOWS,
// IEEE754_64FLOAT, NATIVE_INT64) that asio.h's typedefs key on;
// without them ASIOSampleRate degrades from double to a byte-array
// struct and nothing compiles.
#define NOMINMAX  // asiosys.h pulls windows.h, whose min/max macros
                  // would break the std::min/max calls below
#include "asiosys.h"
#include "asio.h"
#include "asiodrivers.h"
// clang-format on

#include "engine_log.h"

// Globals owned by the vendored SDK host glue (third_party/asio):
// asiodrivers.cpp defines both; there is no SDK header declaring them —
// hosts are expected to declare them locally.
extern AsioDrivers* asioDrivers;
bool loadAsioDriver(char* name);

namespace {

// Bounds mirroring the audio graph's pre-allocated capacity
// (kGraphMaxChannels / kGraphMaxFrames in graph/audio_graph.h). The
// graph clamps and silences anything beyond these, so driver buffers
// past the caps could never carry program audio — don't create them.
constexpr uint32_t kMaxOutputChannels = 28;
constexpr uint32_t kMaxBufferFrames = 4096;

// Rates offered in DeviceInfo::supported_sample_rates, probed via
// ASIOCanSampleRate.
constexpr uint32_t kCandidateRates[] = {44100, 48000,  88200,
                                        96000, 176400, 192000};

// AsioDrivers::loadDriver matches names it reads with a 32-byte cap, so
// enumeration must use the same cap for load-by-name to round-trip.
constexpr int kDriverNameLen = 32;

// Failed driver probes are retried no sooner than this. A newly
// connected interface re-registers under the same driver name, so the
// slow retry is what eventually picks it up — while keeping the app's
// 3 s hot-plug poll from hammering dead drivers with ASIOInit (ES-275
// field report: UI stalls and log spam).
constexpr std::chrono::seconds kFailedProbeRetry{60};

const char* AsioErrorText(ASIOError err) {
  switch (err) {
    case ASE_OK:
      return "ASE_OK";
    case ASE_SUCCESS:
      return "ASE_SUCCESS";
    case ASE_NotPresent:
      return "ASE_NotPresent";
    case ASE_HWMalfunction:
      return "ASE_HWMalfunction";
    case ASE_InvalidParameter:
      return "ASE_InvalidParameter";
    case ASE_InvalidMode:
      return "ASE_InvalidMode";
    case ASE_SPNotAdvancing:
      return "ASE_SPNotAdvancing";
    case ASE_NoClock:
      return "ASE_NoClock";
    case ASE_NoMemory:
      return "ASE_NoMemory";
    default:
      return "unknown ASIOError";
  }
}

uint32_t BytesPerSample(ASIOSampleType type) {
  switch (type) {
    case ASIOSTInt16LSB:
      return 2;
    case ASIOSTInt24LSB:
      return 3;
    case ASIOSTInt32LSB:
    case ASIOSTFloat32LSB:
      return 4;
    default:
      return 0;  // unsupported — rejected in start()
  }
}

// Convert one channel of interleaved f32 into the driver's native
// sample type. Real-time safe: no allocation, no locks.
void ConvertChannel(const float* src, uint32_t frames, uint32_t stride,
                    ASIOSampleType type, void* dst) {
  switch (type) {
    case ASIOSTFloat32LSB: {
      auto* out = static_cast<float*>(dst);
      for (uint32_t i = 0; i < frames; ++i) out[i] = src[i * stride];
      break;
    }
    case ASIOSTInt32LSB: {
      auto* out = static_cast<int32_t*>(dst);
      for (uint32_t i = 0; i < frames; ++i) {
        float v = src[i * stride];
        v = v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v);
        out[i] =
            static_cast<int32_t>(llrint(static_cast<double>(v) * 2147483647.0));
      }
      break;
    }
    case ASIOSTInt24LSB: {
      auto* out = static_cast<uint8_t*>(dst);
      for (uint32_t i = 0; i < frames; ++i) {
        float v = src[i * stride];
        v = v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v);
        const auto s =
            static_cast<int32_t>(lrint(static_cast<double>(v) * 8388607.0));
        out[0] = static_cast<uint8_t>(s & 0xFF);
        out[1] = static_cast<uint8_t>((s >> 8) & 0xFF);
        out[2] = static_cast<uint8_t>((s >> 16) & 0xFF);
        out += 3;
      }
      break;
    }
    case ASIOSTInt16LSB: {
      auto* out = static_cast<int16_t*>(dst);
      for (uint32_t i = 0; i < frames; ++i) {
        float v = src[i * stride];
        v = v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v);
        out[i] = static_cast<int16_t>(lrintf(v * 32767.0f));
      }
      break;
    }
    default:
      // Unreachable: start() rejects drivers with unsupported types.
      std::memset(dst, 0, static_cast<size_t>(frames) * BytesPerSample(type));
      break;
  }
}

// All backend state. File-scope because the ASIO callbacks carry no
// context pointer — the driver calls back into free functions that can
// only reach globals (the same reason AsioBackend is a singleton).
struct BackendState {
  // Control-thread state.
  std::vector<AsioBackend::DriverInfo> snapshot;
  // Probe results by driver name — successes AND failures. A failed
  // probe is negative-cached (retried no sooner than kFailedProbeRetry)
  // and its ASIOInit warning is logged once per session, so re-probing
  // can never stall the UI thread every poll cycle or drown the log
  // (ES-275 field report).
  struct ProbeEntry {
    AsioBackend::DriverCaps caps;
    bool valid = false;
    bool failure_logged = false;
    std::chrono::steady_clock::time_point retry_after{};
  };
  std::map<std::string, ProbeEntry> caps_cache;
  std::string last_error;

  // Stream state. Written on the control thread before ASIOStart()
  // (which acts as the publication barrier) and read by the driver's
  // real-time thread in OnBufferSwitch.
  std::vector<ASIOBufferInfo> buffer_infos;   // output channels only
  std::vector<ASIOSampleType> channel_types;  // parallel to buffer_infos
  std::vector<float> interleaved;             // f32 scratch for the graph
  AsioBackend::DataCallback cb = nullptr;
  void* cb_user = nullptr;
  uint32_t channels = 0;
  uint32_t frames = 0;
  bool output_ready = false;  // driver supports ASIOOutputReady()

  std::atomic<uint32_t> live_rate{0};
  std::atomic<bool> running{false};
  // True while OnBufferSwitch is executing. stop() waits on this
  // between ASIOStop() and ASIODisposeBuffers(): the spec promises no
  // *future* callbacks after ASIOStop returns, not that the current
  // one has drained.
  std::atomic<bool> in_callback{false};
};

BackendState g;

// RAII in-flight marker for OnBufferSwitch (see stop()'s drain).
struct CallbackScope {
  CallbackScope() { g.in_callback.store(true, std::memory_order_release); }
  ~CallbackScope() { g.in_callback.store(false, std::memory_order_release); }
};

// ── Driver callbacks (real-time thread unless noted) ────────────────────

void OnBufferSwitch(long double_buffer_index, ASIOBool /*direct_process*/) {
  const CallbackScope in_callback;

  // Acquire `running` before touching any plain stream field: the
  // acquire pairs with start()'s release store, which is what
  // publishes frames/channels/buffer_infos/channel_types to this
  // thread. Reading them before the acquire is a data race.
  const bool active = g.running.load(std::memory_order_acquire);
  const uint32_t frames = g.frames;
  const uint32_t channels = g.channels;
  const auto index = static_cast<size_t>(double_buffer_index & 1);

  if (!active || g.cb == nullptr) {
    for (uint32_t ch = 0; ch < channels; ++ch) {
      std::memset(
          g.buffer_infos[ch].buffers[index], 0,
          static_cast<size_t>(frames) * BytesPerSample(g.channel_types[ch]));
    }
    return;
  }

  // The graph clamps its fill to its own channel/frame capacity, so
  // pre-zero the scratch — slots the graph never writes stay silent.
  std::memset(g.interleaved.data(), 0,
              static_cast<size_t>(frames) * channels * sizeof(float));
  g.cb(g.interleaved.data(), frames, channels, g.cb_user);

  for (uint32_t ch = 0; ch < channels; ++ch) {
    ConvertChannel(g.interleaved.data() + ch, frames, channels,
                   g.channel_types[ch], g.buffer_infos[ch].buffers[index]);
  }

  // Tell the driver the buffer is ready now rather than at the next
  // switch — saves one block of output latency where supported.
  if (g.output_ready) ASIOOutputReady();
}

ASIOTime* OnBufferSwitchTimeInfo(ASIOTime* time, long double_buffer_index,
                                 ASIOBool direct_process) {
  OnBufferSwitch(double_buffer_index, direct_process);
  return time;
}

void OnSampleRateDidChange(ASIOSampleRate rate) {
  const auto new_rate = static_cast<uint32_t>(rate + 0.5);
  g.live_rate.store(new_rate, std::memory_order_relaxed);
  char buf[96];
  snprintf(buf, sizeof(buf), "ASIO driver changed sample rate to %u Hz",
           new_rate);
  engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "device", buf);
}

long OnAsioMessage(long selector, long value, void* /*message*/,
                   double* /*opt*/) {
  switch (selector) {
    case kAsioSelectorSupported:
      return (value == kAsioEngineVersion || value == kAsioResetRequest ||
              value == kAsioOverload)
                 ? 1
                 : 0;
    case kAsioEngineVersion:
      return 2;
    case kAsioResetRequest:
      // The driver wants to be closed and reopened (rate/buffer change
      // from its control panel). Accepting is mandatory-ish; the actual
      // reopen happens when the user reselects the device.
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "device",
                 "ASIO driver requested a reset — reselect the output "
                 "device to apply its new settings");
      return 1;
    case kAsioOverload:
      engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio",
                    "ASIO driver reported an overload");
      return 1;
    default:
      return 0;
  }
}

ASIOCallbacks g_callbacks = {
    &OnBufferSwitch,
    &OnSampleRateDidChange,
    &OnAsioMessage,
    &OnBufferSwitchTimeInfo,
};

// ── Control-thread helpers ───────────────────────────────────────────────

// (Re)build the SDK's registry-backed driver list. Only call while no
// stream is running: deleting AsioDrivers unloads any loaded driver.
void RebuildDriverList() {
  delete asioDrivers;
  asioDrivers = new AsioDrivers();
}

bool LoadDriverByName(const std::string& name) {
  char mutable_name[kDriverNameLen + 1];
  snprintf(mutable_name, sizeof(mutable_name), "%s", name.c_str());
  return loadAsioDriver(mutable_name);
}

// Load + init a driver, query its capabilities, and unload it again.
// The ASIOInit-failure warning is emitted only on the driver's first
// failed probe of the session (*failure_logged) — with several dead
// drivers registered, per-probe warnings used to drown the log (ES-275).
bool ProbeDriver(const std::string& name, AsioBackend::DriverCaps* caps,
                 bool* failure_logged) {
  if (!LoadDriverByName(name)) return false;

  ASIODriverInfo info{};
  info.asioVersion = 2;
  if (ASIOInit(&info) != ASE_OK) {
    if (!*failure_logged) {
      *failure_logged = true;
      char buf[224];
      snprintf(buf, sizeof(buf),
               "ASIO probe: ASIOInit failed for '%s': %s — driver hidden "
               "from the device list; retried quietly",
               name.c_str(), info.errorMessage);
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "device", buf);
    }
    asioDrivers->removeCurrentDriver();
    return false;
  }

  long inputs = 0;
  long outputs = 0;
  const bool ok = ASIOGetChannels(&inputs, &outputs) == ASE_OK && outputs > 0;
  if (ok) {
    caps->output_channels =
        std::min(static_cast<uint32_t>(outputs), kMaxOutputChannels);
    long min_size = 0, max_size = 0, preferred = 0, granularity = 0;
    if (ASIOGetBufferSize(&min_size, &max_size, &preferred, &granularity) ==
            ASE_OK &&
        preferred > 0) {
      caps->preferred_buffer_frames = static_cast<uint32_t>(preferred);
    }
    caps->supported_sample_rates.clear();
    for (const uint32_t rate : kCandidateRates) {
      if (ASIOCanSampleRate(static_cast<ASIOSampleRate>(rate)) == ASE_OK) {
        caps->supported_sample_rates.push_back(rate);
      }
    }
  }
  ASIOExit();  // implies removeCurrentDriver()
  return ok;
}

// Pick the buffer size for ASIOCreateBuffers: the driver's preferred
// size, walked down to the graph's frame cap if it exceeds it (using
// the driver's advertised granularity; -1 means power-of-two steps).
long NegotiateBufferFrames(long min_size, long max_size, long preferred,
                           long granularity) {
  long frames = preferred > 0 ? preferred : 512;
  if (min_size > 0 && frames < min_size) frames = min_size;
  if (max_size > 0 && frames > max_size) frames = max_size;
  const long cap = static_cast<long>(kMaxBufferFrames);
  if (frames > cap) {
    if (granularity == -1) {
      while (frames > cap && frames / 2 >= min_size) frames /= 2;
    } else if (granularity > 0 && min_size > 0) {
      frames = min_size + ((cap - min_size) / granularity) * granularity;
    } else {
      frames = min_size > 0 ? min_size : cap;
    }
  }
  return frames;
}

void SetStartError(const char* phase, ASIOError rc, const std::string& name,
                   const char* driver_message) {
  char buf[320];
  if (driver_message != nullptr && driver_message[0] != '\0') {
    snprintf(buf, sizeof(buf), "%s FAILED: rc=%ld (%s) on \"%s\": %s", phase,
             rc, AsioErrorText(rc), name.c_str(), driver_message);
  } else {
    snprintf(buf, sizeof(buf), "%s FAILED: rc=%ld (%s) on \"%s\"", phase, rc,
             AsioErrorText(rc), name.c_str());
  }
  g.last_error = buf;
  engine_log(ECLIPSA_STUDIO_LOG_ERROR, "device", buf);
}

}  // namespace

// ── AsioBackend ──────────────────────────────────────────────────────────

AsioBackend& AsioBackend::instance() {
  static AsioBackend backend;
  return backend;
}

const std::vector<AsioBackend::DriverInfo>& AsioBackend::enumerate() {
  if (g.running.load(std::memory_order_relaxed)) {
    // Probing loads drivers, and the SDK unloads the current driver
    // before loading another — that would kill the active stream.
    return g.snapshot;
  }

  RebuildDriverList();
  g.snapshot.clear();

  const auto now = std::chrono::steady_clock::now();
  const long count = asioDrivers->asioGetNumDev();
  for (long i = 0; i < count; ++i) {
    char name[kDriverNameLen + 1] = {0};
    if (asioDrivers->asioGetDriverName(static_cast<int>(i), name,
                                       kDriverNameLen) != 0) {
      continue;
    }

    auto [it, inserted] = g.caps_cache.try_emplace(name);
    BackendState::ProbeEntry& entry = it->second;
    if (inserted || (!entry.valid && now >= entry.retry_after)) {
      entry.valid = ProbeDriver(it->first, &entry.caps, &entry.failure_logged);
      if (!entry.valid) entry.retry_after = now + kFailedProbeRetry;
    }
    // A driver whose probe failed (refused to load — usually its
    // hardware is disconnected) is not offered: the engine already
    // knows start() cannot open it (ES-275 field report).
    if (!entry.valid) continue;

    DriverInfo info;
    info.name = it->first;
    info.driver_index = static_cast<uint32_t>(i);
    info.caps = entry.caps;
    g.snapshot.push_back(std::move(info));
  }
  return g.snapshot;
}

bool AsioBackend::start(uint32_t driver_index, uint32_t sample_rate,
                        DataCallback cb, void* user_data) {
  stop();
  g.last_error.clear();

  const DriverInfo* driver = nullptr;
  for (const auto& d : g.snapshot) {
    if (d.driver_index == driver_index) {
      driver = &d;
      break;
    }
  }
  if (driver == nullptr) {
    g.last_error = "ASIO driver index not in the current enumeration";
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "device", g.last_error.c_str());
    return false;
  }
  const std::string& name = driver->name;

  if (!LoadDriverByName(name)) {
    g.last_error = "ASIO loadDriver FAILED on \"" + name + "\"";
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "device", g.last_error.c_str());
    return false;
  }

  ASIODriverInfo info{};
  info.asioVersion = 2;
  if (const ASIOError rc = ASIOInit(&info); rc != ASE_OK) {
    SetStartError("ASIOInit", rc, name, info.errorMessage);
    asioDrivers->removeCurrentDriver();
    return false;
  }

  long inputs = 0;
  long outputs = 0;
  if (const ASIOError rc = ASIOGetChannels(&inputs, &outputs);
      rc != ASE_OK || outputs <= 0) {
    SetStartError("ASIOGetChannels", rc, name, nullptr);
    ASIOExit();
    return false;
  }
  const uint32_t channels =
      std::min(static_cast<uint32_t>(outputs), kMaxOutputChannels);

  // Request the engine's rate; adopt the driver's own rate if refused
  // (DeviceManager reports it as the hardware rate and the engine
  // reopens at that rate, same as the WASAPI path).
  if (ASIOCanSampleRate(static_cast<ASIOSampleRate>(sample_rate)) == ASE_OK) {
    ASIOSetSampleRate(static_cast<ASIOSampleRate>(sample_rate));
  }
  ASIOSampleRate actual_rate = 0;
  if (ASIOGetSampleRate(&actual_rate) != ASE_OK || actual_rate <= 0) {
    actual_rate = static_cast<ASIOSampleRate>(sample_rate);
  }

  long min_size = 0, max_size = 0, preferred = 0, granularity = 0;
  if (const ASIOError rc =
          ASIOGetBufferSize(&min_size, &max_size, &preferred, &granularity);
      rc != ASE_OK) {
    SetStartError("ASIOGetBufferSize", rc, name, nullptr);
    ASIOExit();
    return false;
  }
  const long frames =
      NegotiateBufferFrames(min_size, max_size, preferred, granularity);
  if (frames <= 0 || frames > static_cast<long>(kMaxBufferFrames)) {
    char buf[192];
    snprintf(buf, sizeof(buf),
             "ASIO buffer size unusable on \"%s\": min=%ld max=%ld "
             "preferred=%ld granularity=%ld (engine cap %u)",
             name.c_str(), min_size, max_size, preferred, granularity,
             kMaxBufferFrames);
    g.last_error = buf;
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "device", buf);
    ASIOExit();
    return false;
  }

  g.buffer_infos.assign(channels, ASIOBufferInfo{});
  for (uint32_t ch = 0; ch < channels; ++ch) {
    g.buffer_infos[ch].isInput = ASIOFalse;
    g.buffer_infos[ch].channelNum = static_cast<long>(ch);
    g.buffer_infos[ch].buffers[0] = nullptr;
    g.buffer_infos[ch].buffers[1] = nullptr;
  }
  if (const ASIOError rc =
          ASIOCreateBuffers(g.buffer_infos.data(), static_cast<long>(channels),
                            frames, &g_callbacks);
      rc != ASE_OK) {
    SetStartError("ASIOCreateBuffers", rc, name, nullptr);
    ASIOExit();
    return false;
  }

  // Query per-channel sample types and reject anything we can't
  // convert to (rare in practice: LSB int16/24/32 and float32 cover
  // the field on x86 Windows).
  g.channel_types.assign(channels, ASIOSTInt32LSB);
  for (uint32_t ch = 0; ch < channels; ++ch) {
    ASIOChannelInfo ch_info{};
    ch_info.channel = static_cast<long>(ch);
    ch_info.isInput = ASIOFalse;
    if (const ASIOError rc = ASIOGetChannelInfo(&ch_info); rc != ASE_OK) {
      SetStartError("ASIOGetChannelInfo", rc, name, nullptr);
      ASIODisposeBuffers();
      ASIOExit();
      return false;
    }
    if (BytesPerSample(ch_info.type) == 0) {
      char buf[192];
      snprintf(buf, sizeof(buf),
               "ASIO sample type %ld on \"%s\" channel %u is not supported",
               static_cast<long>(ch_info.type), name.c_str(), ch);
      g.last_error = buf;
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "device", buf);
      ASIODisposeBuffers();
      ASIOExit();
      return false;
    }
    g.channel_types[ch] = ch_info.type;
  }

  // Silence both halves of the driver's double buffer so nothing
  // undefined sounds between ASIOStart() and the first bufferSwitch.
  // All-zero bytes are digital silence in every accepted sample type.
  for (uint32_t ch = 0; ch < channels; ++ch) {
    const size_t bytes =
        static_cast<size_t>(frames) * BytesPerSample(g.channel_types[ch]);
    std::memset(g.buffer_infos[ch].buffers[0], 0, bytes);
    std::memset(g.buffer_infos[ch].buffers[1], 0, bytes);
  }

  g.output_ready = (ASIOOutputReady() == ASE_OK);
  g.interleaved.assign(static_cast<size_t>(frames) * channels, 0.0f);
  g.cb = cb;
  g.cb_user = user_data;
  g.channels = channels;
  g.frames = static_cast<uint32_t>(frames);
  g.live_rate.store(static_cast<uint32_t>(actual_rate + 0.5),
                    std::memory_order_relaxed);
  // Publish before ASIOStart: the first bufferSwitch can fire
  // immediately on the driver thread.
  g.running.store(true, std::memory_order_release);

  if (const ASIOError rc = ASIOStart(); rc != ASE_OK) {
    g.running.store(false, std::memory_order_release);
    SetStartError("ASIOStart", rc, name, nullptr);
    ASIODisposeBuffers();
    ASIOExit();
    return false;
  }

  long input_latency = 0;
  long output_latency = 0;
  ASIOGetLatencies(&input_latency, &output_latency);
  {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "ASIO started: \"%s\" channels=%u frames=%u rate=%u "
             "outputLatency=%ld outputReady=%d",
             name.c_str(), channels, g.frames,
             g.live_rate.load(std::memory_order_relaxed), output_latency,
             g.output_ready ? 1 : 0);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "device", buf);
  }
  return true;
}

void AsioBackend::stop() {
  if (!g.running.load(std::memory_order_relaxed)) return;
  g.running.store(false, std::memory_order_release);
  ASIOStop();
  // Drain an in-flight bufferSwitch before freeing the buffers it may
  // still be writing (ASIOStop only fences off *future* callbacks).
  // Control thread, and the callback body is sub-millisecond, so a
  // yielding spin is fine.
  while (g.in_callback.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  ASIODisposeBuffers();
  ASIOExit();  // unloads the driver via removeCurrentDriver()
  g.cb = nullptr;
  g.cb_user = nullptr;
  g.channels = 0;
  g.frames = 0;
  g.live_rate.store(0, std::memory_order_relaxed);
  engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "device", "ASIO stopped");
}

bool AsioBackend::is_running() const {
  return g.running.load(std::memory_order_relaxed);
}

uint32_t AsioBackend::channel_count() const { return g.channels; }

uint32_t AsioBackend::current_sample_rate() const {
  return g.live_rate.load(std::memory_order_relaxed);
}

uint32_t AsioBackend::buffer_frames() const { return g.frames; }

const std::string& AsioBackend::last_error() const { return g.last_error; }
