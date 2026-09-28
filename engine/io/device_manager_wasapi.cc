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

// Native WASAPI backend for DeviceManager (Windows). Implements
// enumerate(), start(), stop() and query_hardware_sample_rate();
// backend-independent logic lives in device_manager_common.cc.
//
// On Windows the device list is multiplexed over two backends: WASAPI
// endpoints (opened here) plus installed ASIO drivers (opened through
// io/asio_backend.h — ES-101), appended to the list with an " (ASIO)"
// name suffix. Which backend owns a row is a private per-device tag in
// DeviceManagerImpl; nothing backend-specific leaks past this TU.
//
// Why not miniaudio here (ES-355): owning IAudioClient directly gives us
// the exclusive-mode format negotiation (bit-exact, mixer-bypassed
// multichannel output), the period/alignment dance, and MMCSS thread
// priority without a wrapper's abstractions in the way — the same
// motivation that put the native HAL backend on macOS (ES-334). The
// engine keeps receiving fixed-size interleaved f32 callbacks; this
// backend rebuffers to whatever period the device granted and converts
// to the negotiated device sample format on the render thread.

// clang-format off
#define NOMINMAX  // windows.h min/max macros would break std::min/max
#include <windows.h>

#include <initguid.h>  // keep first in this block: defines INITGUID so
                       // the PKEY_* / KSDATAFORMAT_* GUIDs below are
                       // instantiated in this TU

#include <mmdeviceapi.h>  // pulls propkeydef.h — DEFINE_PROPERTYKEY must
                          // exist before functiondiscoverykeys_devpkey.h,
                          // which uses the macro without defining it

#include <audioclient.h>
#include <avrt.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmreg.h>
// clang-format on

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "engine_log.h"
#include "io/asio_backend.h"
#include "io/device_manager.h"
#include "io/device_manager_internal.h"

#pragma comment(lib, "avrt.lib")
#pragma comment(lib, "ole32.lib")

// Converts one span of interleaved f32 samples into the device's
// negotiated sample format. `samples` counts individual samples
// (frames * channels). Chosen at open, called on the render thread.
using SampleWriter = void (*)(uint8_t* dst, const float* src, size_t samples);

// One entry per device_list() row: WASAPI endpoints carry the IMMDevice
// ID string, ASIO drivers the registry driver index. Kept in lockstep
// with device_list(); start()/stop() dispatch on `asio`.
struct BackendRef {
  bool asio = false;
  std::wstring endpoint_id;   // WASAPI only
  uint32_t driver_index = 0;  // ASIO only
};

// Cached ASIO section of device_list(); rebuilt only when no WASAPI
// stream is open (see enumerate()).
struct AsioRow {
  DeviceManager::DeviceInfo info;
  uint32_t driver_index = 0;
};

namespace {

// Rates probed for exclusive-mode support during enumeration (the
// endpoint's shared-mode mix rate is always included as well).
constexpr uint32_t kProbeRates[] = {44100, 48000, 88200, 96000, 176400, 192000};

// Keeps COM initialized for the lifetime of the enclosing scope.
// RPC_E_CHANGED_MODE (thread already in an STA) leaves COM usable; it
// just must not be balanced with CoUninitialize.
class ComInit {
 public:
  ComInit() : hr_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
  ~ComInit() {
    if (SUCCEEDED(hr_)) CoUninitialize();
  }
  ComInit(const ComInit&) = delete;
  ComInit& operator=(const ComInit&) = delete;

 private:
  HRESULT hr_;
};

// Minimal COM smart pointer (release-on-scope-exit). Kept local so the
// backend does not pull in wrl/client.h.
template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  ~ComPtr() { reset(); }
  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;

  T** out() {
    reset();
    return &p_;
  }
  T* get() const { return p_; }
  T* operator->() const { return p_; }
  explicit operator bool() const { return p_ != nullptr; }
  void reset() {
    if (p_ != nullptr) {
      p_->Release();
      p_ = nullptr;
    }
  }
  T* release() {
    T* p = p_;
    p_ = nullptr;
    return p;
  }

 private:
  T* p_ = nullptr;
};

std::string WideToUtf8(const wchar_t* w) {
  if (w == nullptr || *w == L'\0') return {};
  const int len =
      WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (len <= 1) return {};
  std::string s(static_cast<size_t>(len) - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), len, nullptr, nullptr);
  return s;
}

// Human-readable name for the AUDCLNT_E_* codes this backend actually
// hits; anything else renders as the raw HRESULT in hex.
std::string HrDesc(HRESULT hr) {
  switch (hr) {
    case AUDCLNT_E_DEVICE_INVALIDATED:
      return "AUDCLNT_E_DEVICE_INVALIDATED";
    case AUDCLNT_E_DEVICE_IN_USE:
      return "AUDCLNT_E_DEVICE_IN_USE";
    case AUDCLNT_E_UNSUPPORTED_FORMAT:
      return "AUDCLNT_E_UNSUPPORTED_FORMAT";
    case AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED:
      return "AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED";
    case AUDCLNT_E_ENDPOINT_CREATE_FAILED:
      return "AUDCLNT_E_ENDPOINT_CREATE_FAILED";
    case AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED:
      return "AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED";
    case AUDCLNT_E_INVALID_DEVICE_PERIOD:
      return "AUDCLNT_E_INVALID_DEVICE_PERIOD";
    case E_ACCESSDENIED:
      return "E_ACCESSDENIED";
    default: {
      char buf[16];
      snprintf(buf, sizeof(buf), "0x%08lX", static_cast<unsigned long>(hr));
      return buf;
    }
  }
}

std::string FormatWasapiError(const char* phase, HRESULT hr,
                              const std::string& dev_name) {
  return device_backend::FormatDeviceError(phase, static_cast<long>(hr),
                                           HrDesc(hr).c_str(), dev_name);
}

// ── f32 → device-format sample writers ───────────────────────────────

void WriteF32(uint8_t* dst, const float* src, size_t samples) {
  std::memcpy(dst, src, samples * sizeof(float));
}

// Also covers 24-valid-bits-in-32 formats: samples are left-justified
// in the 32-bit container, so full-scale int32 is correct and the
// hardware ignores the low bits.
void WriteI32(uint8_t* dst, const float* src, size_t samples) {
  auto* out = reinterpret_cast<int32_t*>(dst);
  for (size_t i = 0; i < samples; ++i) {
    const double c = std::clamp(static_cast<double>(src[i]), -1.0, 1.0);
    out[i] = static_cast<int32_t>(std::lrint(c * 2147483647.0));
  }
}

void WriteI16(uint8_t* dst, const float* src, size_t samples) {
  auto* out = reinterpret_cast<int16_t*>(dst);
  for (size_t i = 0; i < samples; ++i) {
    const float c = std::clamp(src[i], -1.0f, 1.0f);
    out[i] = static_cast<int16_t>(std::lrintf(c * 32767.0f));
  }
}

}  // namespace

// Backend-private state. The render thread reads only this struct —
// all fields it touches are written in start() before CreateThread()
// and IAudioClient::Start(), which act as the happens-before barrier
// (same contract as cb_ / cb_user_ in device_manager.h). `run` is the
// one field written afterwards; it is atomic.
struct DeviceManagerImpl {
  // All control-side methods run on the construction thread (see the
  // threading contract in device_manager.h), so one COM init covers
  // enumerate()/start()/stop(). The render thread does its own.
  ComInit com;

  // Open-stream state.
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioRenderClient* render = nullptr;
  HANDLE event = nullptr;
  HANDLE thread = nullptr;
  std::atomic<bool> run{false};
  bool exclusive = false;
  uint32_t device_buffer_frames = 0;  // frames per WASAPI buffer pass
  SampleWriter write = nullptr;
  uint32_t bytes_per_sample = 4;

  // Engine-callback snapshot (see happens-before note above).
  DeviceManager::DataCallback cb = nullptr;
  void* cb_user = nullptr;
  uint32_t channels = 0;
  uint32_t callback_frames = 0;  // fixed engine-callback block size

  // FIFO of rendered-but-undelivered frames (interleaved f32) bridging
  // the fixed engine block size and the device period. Allocated at
  // open — nothing allocates on the render thread.
  std::vector<float> stage;
  uint32_t stage_pos = 0;  // next unread frame
  uint32_t stage_len = 0;  // valid frames in stage

  // True while the open stream belongs to the ASIO backend; the WASAPI
  // stream state above is then untouched/closed.
  bool asio_active = false;

  // Per-device backend refs, indexed in lockstep with device_list().
  std::vector<BackendRef> refs;

  // ASIO rows from the last enumeration that was allowed to probe.
  std::vector<AsioRow> asio_rows;
};

namespace {

// The negotiated stream format plus the conversion it implies.
struct StreamPick {
  WAVEFORMATEXTENSIBLE fmt = {};
  SampleWriter writer = nullptr;
  uint32_t bytes_per_sample = 0;
  const char* desc = "";
};

// Candidate exclusive-mode sample layouts, best first.
struct SampleLayout {
  uint16_t bits;
  uint16_t valid_bits;
  bool is_float;
  SampleWriter writer;
  const char* desc;
};
constexpr SampleLayout kExclusiveLayouts[] = {
    {32, 32, true, WriteF32, "f32"},
    {32, 32, false, WriteI32, "i32"},
    {32, 24, false, WriteI32, "i24-in-32"},
    {16, 16, false, WriteI16, "i16"},
};

DWORD DefaultMask(uint32_t channels) {
  switch (channels) {
    case 1:
      return KSAUDIO_SPEAKER_MONO;
    case 2:
      return KSAUDIO_SPEAKER_STEREO;
    case 4:
      return KSAUDIO_SPEAKER_QUAD;
    case 6:
      return KSAUDIO_SPEAKER_5POINT1;
    case 8:
      return KSAUDIO_SPEAKER_7POINT1_SURROUND;
    default:
      // First N speaker positions — accepted by drivers as "N discrete
      // channels" for layouts with no canonical mask.
      return channels >= 32 ? 0xFFFFFFFFu : ((1u << channels) - 1u);
  }
}

WAVEFORMATEXTENSIBLE MakeExtensible(uint32_t channels, uint32_t rate,
                                    const SampleLayout& layout, DWORD mask) {
  WAVEFORMATEXTENSIBLE f = {};
  f.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  f.Format.nChannels = static_cast<WORD>(channels);
  f.Format.nSamplesPerSec = rate;
  f.Format.wBitsPerSample = layout.bits;
  f.Format.nBlockAlign = static_cast<WORD>(channels * layout.bits / 8);
  f.Format.nAvgBytesPerSec = rate * f.Format.nBlockAlign;
  f.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
  f.Samples.wValidBitsPerSample = layout.valid_bits;
  f.dwChannelMask = mask;
  f.SubFormat = layout.is_float ? KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
                                : KSDATAFORMAT_SUBTYPE_PCM;
  return f;
}

// Widen any WAVEFORMATEX into WAVEFORMATEXTENSIBLE form. Returns false
// for compressed/unknown tags.
bool NormalizeFormat(const WAVEFORMATEX* wf, WAVEFORMATEXTENSIBLE* out) {
  if (wf == nullptr) return false;
  if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      wf->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    std::memcpy(out, wf, sizeof(WAVEFORMATEXTENSIBLE));
    return true;
  }
  if (wf->wFormatTag != WAVE_FORMAT_PCM &&
      wf->wFormatTag != WAVE_FORMAT_IEEE_FLOAT) {
    return false;
  }
  *out = {};
  out->Format = *wf;
  out->Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  out->Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
  out->Samples.wValidBitsPerSample = wf->wBitsPerSample;
  out->dwChannelMask = DefaultMask(wf->nChannels);
  out->SubFormat = (wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT)
                       ? KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
                       : KSDATAFORMAT_SUBTYPE_PCM;
  return true;
}

// The endpoint's exclusive-mode default format from the property
// store — the closest WASAPI gets to "the device's native layout".
bool ReadDeviceFormat(IPropertyStore* store, WAVEFORMATEXTENSIBLE* out) {
  PROPVARIANT v;
  PropVariantInit(&v);
  bool ok = false;
  if (SUCCEEDED(store->GetValue(PKEY_AudioEngine_DeviceFormat, &v)) &&
      v.vt == VT_BLOB && v.blob.pBlobData != nullptr &&
      v.blob.cbSize >= sizeof(WAVEFORMATEX)) {
    ok = NormalizeFormat(
        reinterpret_cast<const WAVEFORMATEX*>(v.blob.pBlobData), out);
  }
  PropVariantClear(&v);
  return ok;
}

// Writer for a shared-mode (mix) format the OS handed us.
bool PickWriter(const WAVEFORMATEXTENSIBLE& fmt, StreamPick* pick) {
  const bool is_float = fmt.SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
  const bool is_pcm = fmt.SubFormat == KSDATAFORMAT_SUBTYPE_PCM;
  const uint16_t bits = fmt.Format.wBitsPerSample;
  if (is_float && bits == 32) {
    pick->writer = WriteF32;
    pick->bytes_per_sample = 4;
    pick->desc = "f32";
  } else if (is_pcm && bits == 32) {
    pick->writer = WriteI32;
    pick->bytes_per_sample = 4;
    pick->desc = "i32";
  } else if (is_pcm && bits == 16) {
    pick->writer = WriteI16;
    pick->bytes_per_sample = 2;
    pick->desc = "i16";
  } else {
    return false;
  }
  pick->fmt = fmt;
  return true;
}

HRESULT ActivateClient(IMMDevice* device, IAudioClient** client) {
  if (*client != nullptr) {
    (*client)->Release();
    *client = nullptr;
  }
  return device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(client));
}

REFERENCE_TIME FramesToRefTime(uint32_t frames, uint32_t rate) {
  return static_cast<REFERENCE_TIME>(10000000.0 * frames / rate + 0.5);
}

// Negotiate an exclusive-mode format and event-driven period. On entry
// *client is an activated, uninitialized IAudioClient; a failed
// Initialize leaves the client unusable, so the retry paths (and the
// caller's shared-mode fallback) re-activate. On success the client is
// initialized and *granted holds the frames per buffer pass.
HRESULT InitExclusive(IMMDevice* device, IAudioClient** client,
                      uint32_t want_rate, uint32_t buffer_frames,
                      StreamPick* pick, uint32_t* granted) {
  // Baseline channels/mask from the endpoint's exclusive-mode device
  // format, falling back to the shared-mode mix format.
  WAVEFORMATEXTENSIBLE base = {};
  bool have_base = false;
  {
    ComPtr<IPropertyStore> store;
    if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, store.out()))) {
      have_base = ReadDeviceFormat(store.get(), &base);
    }
  }
  if (!have_base) {
    WAVEFORMATEX* mix = nullptr;
    if (FAILED((*client)->GetMixFormat(&mix)) || mix == nullptr) {
      return AUDCLNT_E_UNSUPPORTED_FORMAT;
    }
    have_base = NormalizeFormat(mix, &base);
    CoTaskMemFree(mix);
    if (!have_base) return AUDCLNT_E_UNSUPPORTED_FORMAT;
  }
  const uint32_t channels = base.Format.nChannels;
  const DWORD mask =
      base.dwChannelMask != 0 ? base.dwChannelMask : DefaultMask(channels);

  // Requested rate first, then the device format's own rate.
  uint32_t rates[2] = {want_rate, base.Format.nSamplesPerSec};
  if (rates[0] == 0) rates[0] = rates[1];

  bool found = false;
  HRESULT last = AUDCLNT_E_UNSUPPORTED_FORMAT;
  for (size_t r = 0; r < 2 && !found; ++r) {
    const uint32_t rate = rates[r];
    if (rate == 0 || (r == 1 && rate == rates[0])) continue;
    for (const SampleLayout& layout : kExclusiveLayouts) {
      const WAVEFORMATEXTENSIBLE fmt =
          MakeExtensible(channels, rate, layout, mask);
      const HRESULT hr = (*client)->IsFormatSupported(
          AUDCLNT_SHAREMODE_EXCLUSIVE, &fmt.Format, nullptr);
      if (hr == S_OK) {
        pick->fmt = fmt;
        pick->writer = layout.writer;
        pick->bytes_per_sample = layout.bits / 8u;
        pick->desc = layout.desc;
        found = true;
        break;
      }
      if (FAILED(hr)) last = hr;
    }
  }
  if (!found) return last;

  const uint32_t rate = pick->fmt.Format.nSamplesPerSec;
  REFERENCE_TIME default_period = 0;
  REFERENCE_TIME min_period = 0;
  if (FAILED((*client)->GetDevicePeriod(&default_period, &min_period)) ||
      default_period <= 0 || min_period <= 0) {
    return AUDCLNT_E_INVALID_DEVICE_PERIOD;
  }
  REFERENCE_TIME period = FramesToRefTime(buffer_frames, rate);
  if (period < min_period) period = min_period;

  // Exclusive event-driven requires buffer duration == periodicity.
  // Drivers can reject a period two different ways, and a fix for one
  // can re-trigger the other (the aligned frame count rounds to a new
  // period some drivers then call invalid), so retry as a bounded loop
  // rather than one shot per error: NOT_ALIGNED → re-init at the
  // driver's aligned buffer size; INVALID_DEVICE_PERIOD → re-init at
  // the driver's default period. A failed Initialize leaves the client
  // unusable, so every retry re-activates a fresh one.
  HRESULT hr = E_FAIL;
  for (int attempt = 0; attempt < 3; ++attempt) {
    hr = (*client)->Initialize(AUDCLNT_SHAREMODE_EXCLUSIVE,
                               AUDCLNT_STREAMFLAGS_EVENTCALLBACK, period,
                               period, &pick->fmt.Format, nullptr);
    if (SUCCEEDED(hr)) break;

    REFERENCE_TIME next_period = 0;
    if (hr == AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED) {
      UINT32 aligned = 0;
      if (FAILED((*client)->GetBufferSize(&aligned)) || aligned == 0) {
        return hr;
      }
      next_period = FramesToRefTime(aligned, rate);
    } else if (hr == AUDCLNT_E_INVALID_DEVICE_PERIOD) {
      next_period = default_period;
    } else {
      return hr;
    }
    if (next_period <= 0 || next_period == period) return hr;

    {
      char buf[128];
      snprintf(buf, sizeof(buf),
               "exclusive Initialize retry: %s, period %lld -> %lld",
               HrDesc(hr).c_str(), static_cast<long long>(period),
               static_cast<long long>(next_period));
      engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "device", buf);
    }
    period = next_period;
    HRESULT ahr = ActivateClient(device, client);
    if (FAILED(ahr)) return ahr;
  }
  if (FAILED(hr)) return hr;

  UINT32 size = 0;
  if (FAILED((*client)->GetBufferSize(&size)) || size == 0) return E_FAIL;
  *granted = size;
  return S_OK;
}

// Shared-mode fallback: the mix format as-is (float32 in practice),
// event-driven with the engine's default buffering.
HRESULT InitShared(IAudioClient* client, StreamPick* pick, uint32_t* granted) {
  WAVEFORMATEX* mix = nullptr;
  HRESULT hr = client->GetMixFormat(&mix);
  if (FAILED(hr)) return hr;
  if (mix == nullptr) return E_FAIL;
  WAVEFORMATEXTENSIBLE fmt = {};
  const bool usable = NormalizeFormat(mix, &fmt) && PickWriter(fmt, pick);
  if (!usable) {
    CoTaskMemFree(mix);
    return AUDCLNT_E_UNSUPPORTED_FORMAT;
  }
  hr =
      client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                         AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, mix, nullptr);
  CoTaskMemFree(mix);
  if (FAILED(hr)) return hr;
  UINT32 size = 0;
  if (FAILED(client->GetBufferSize(&size)) || size == 0) return E_FAIL;
  *granted = size;
  return S_OK;
}

// Pull engine audio through the fixed-size-callback FIFO and convert
// into the device buffer. Render thread only; no allocation, no locks.
void FillFromEngine(DeviceManagerImpl* impl, uint8_t* dst, uint32_t frames) {
  const uint32_t ch = impl->channels;
  if (impl->cb == nullptr) {
    std::memset(dst, 0,
                static_cast<size_t>(frames) * ch * impl->bytes_per_sample);
    return;
  }
  while (frames > 0) {
    if (impl->stage_pos == impl->stage_len) {
      impl->cb(impl->stage.data(), impl->callback_frames, ch, impl->cb_user);
      impl->stage_pos = 0;
      impl->stage_len = impl->callback_frames;
    }
    const uint32_t n = std::min(frames, impl->stage_len - impl->stage_pos);
    impl->write(dst,
                impl->stage.data() + static_cast<size_t>(impl->stage_pos) * ch,
                static_cast<size_t>(n) * ch);
    dst += static_cast<size_t>(n) * ch * impl->bytes_per_sample;
    impl->stage_pos += n;
    frames -= n;
  }
}

// Event-driven render loop. Exclusive mode fills the whole buffer each
// event; shared mode fills whatever the padding leaves free.
DWORD WINAPI RenderThread(LPVOID param) {
  auto* impl = static_cast<DeviceManagerImpl*>(param);
  ComInit com;
  DWORD task_index = 0;
  HANDLE task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task_index);
  if (task == nullptr) {
    engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "device",
                  "AvSetMmThreadCharacteristics failed; render thread runs "
                  "at normal priority");
  }

  while (impl->run.load(std::memory_order_acquire)) {
    const DWORD wait = WaitForSingleObject(impl->event, 2000);
    if (!impl->run.load(std::memory_order_acquire)) break;
    if (wait != WAIT_OBJECT_0) continue;

    uint32_t frames = impl->device_buffer_frames;
    if (!impl->exclusive) {
      UINT32 padding = 0;
      if (FAILED(impl->client->GetCurrentPadding(&padding))) {
        engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "device",
                      "WASAPI device invalidated (removed or format "
                      "changed); output stopped");
        break;
      }
      if (padding >= frames) continue;
      frames -= padding;
    }

    BYTE* out = nullptr;
    const HRESULT hr = impl->render->GetBuffer(frames, &out);
    if (hr == AUDCLNT_E_DEVICE_INVALIDATED) {
      engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "device",
                    "WASAPI device invalidated (removed or format changed); "
                    "output stopped");
      break;
    }
    if (FAILED(hr) || out == nullptr) continue;
    FillFromEngine(impl, out, frames);
    impl->render->ReleaseBuffer(frames, 0);
  }

  if (task != nullptr) AvRevertMmThreadCharacteristics(task);
  return 0;
}

// Tear down the render thread and every open-stream COM object /
// handle. Safe on partially-opened state (start() failure paths) and
// no-op on already-closed state.
void CloseStream(DeviceManagerImpl* impl) {
  impl->run.store(false, std::memory_order_release);
  if (impl->thread != nullptr) {
    if (impl->event != nullptr) SetEvent(impl->event);
    WaitForSingleObject(impl->thread, INFINITE);
    CloseHandle(impl->thread);
    impl->thread = nullptr;
  }
  if (impl->client != nullptr) impl->client->Stop();
  if (impl->render != nullptr) {
    impl->render->Release();
    impl->render = nullptr;
  }
  if (impl->client != nullptr) {
    impl->client->Release();
    impl->client = nullptr;
  }
  if (impl->event != nullptr) {
    CloseHandle(impl->event);
    impl->event = nullptr;
  }
  if (impl->device != nullptr) {
    impl->device->Release();
    impl->device = nullptr;
  }
}

// Probe which of the standard rates the endpoint accepts in exclusive
// mode, using the device format's own layout as the template. The mix
// rate is always reported so shared-mode fallback stays selectable.
std::vector<uint32_t> ProbeSampleRates(IAudioClient* client,
                                       const WAVEFORMATEXTENSIBLE& base,
                                       uint32_t mix_rate) {
  std::vector<uint32_t> rates;
  auto add = [&rates](uint32_t r) {
    if (r > 0 && std::find(rates.begin(), rates.end(), r) == rates.end()) {
      rates.push_back(r);
    }
  };
  if (client != nullptr) {
    for (uint32_t rate : kProbeRates) {
      WAVEFORMATEXTENSIBLE fmt = base;
      fmt.Format.nSamplesPerSec = rate;
      fmt.Format.nAvgBytesPerSec = rate * fmt.Format.nBlockAlign;
      if (client->IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, &fmt.Format,
                                    nullptr) == S_OK) {
        add(rate);
      }
    }
  }
  add(mix_rate);
  std::sort(rates.begin(), rates.end());
  return rates;
}

}  // namespace

DeviceManager::DeviceManager() : impl_(std::make_unique<DeviceManagerImpl>()) {}

DeviceManager::~DeviceManager() { stop(); }

bool DeviceManager::enumerate() {
  devices_.clear();
  impl_->refs.clear();

  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                              __uuidof(IMMDeviceEnumerator),
                              reinterpret_cast<void**>(enumerator.out())))) {
    return false;
  }

  std::wstring default_id;
  {
    ComPtr<IMMDevice> def;
    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                      def.out()))) {
      LPWSTR id = nullptr;
      if (SUCCEEDED(def->GetId(&id)) && id != nullptr) {
        default_id = id;
        CoTaskMemFree(id);
      }
    }
  }

  ComPtr<IMMDeviceCollection> collection;
  if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE,
                                            collection.out()))) {
    return false;
  }
  UINT count = 0;
  collection->GetCount(&count);

  for (UINT i = 0; i < count; ++i) {
    ComPtr<IMMDevice> dev;
    if (FAILED(collection->Item(i, dev.out()))) continue;
    LPWSTR raw_id = nullptr;
    if (FAILED(dev->GetId(&raw_id)) || raw_id == nullptr) continue;
    std::wstring id = raw_id;
    CoTaskMemFree(raw_id);

    DeviceInfo info;
    WAVEFORMATEXTENSIBLE device_fmt = {};
    bool have_device_fmt = false;
    {
      ComPtr<IPropertyStore> store;
      if (SUCCEEDED(dev->OpenPropertyStore(STGM_READ, store.out()))) {
        PROPVARIANT v;
        PropVariantInit(&v);
        if (SUCCEEDED(store->GetValue(PKEY_Device_FriendlyName, &v)) &&
            v.vt == VT_LPWSTR) {
          info.name = WideToUtf8(v.pwszVal);
        }
        PropVariantClear(&v);
        have_device_fmt = ReadDeviceFormat(store.get(), &device_fmt);
      }
    }
    if (info.name.empty()) continue;
    info.is_default = (id == default_id);

    ComPtr<IAudioClient> client;
    WAVEFORMATEX* mix = nullptr;
    if (SUCCEEDED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void**>(client.out())))) {
      client->GetMixFormat(&mix);
    }
    const uint32_t mix_rate = mix != nullptr ? mix->nSamplesPerSec : 0;
    if (!have_device_fmt) {
      have_device_fmt = NormalizeFormat(mix, &device_fmt);
    }
    info.channel_count = have_device_fmt && device_fmt.Format.nChannels > 0
                             ? device_fmt.Format.nChannels
                             : 2;
    info.supported_channel_counts = {info.channel_count};
    if (have_device_fmt) {
      info.supported_sample_rates =
          ProbeSampleRates(client.get(), device_fmt, mix_rate);
    }
    if (mix != nullptr) CoTaskMemFree(mix);
    if (info.supported_sample_rates.empty()) {
      info.supported_sample_rates = {44100, 48000, 96000, 192000};
    }

    // Prefer 48000 as default; fall back to first available.
    info.default_sample_rate = 48000;
    const auto& rates = info.supported_sample_rates;
    if (std::find(rates.begin(), rates.end(), 48000u) == rates.end()) {
      info.default_sample_rate = rates[0];
    }

    devices_.push_back(std::move(info));
    BackendRef ref;
    ref.endpoint_id = std::move(id);
    impl_->refs.push_back(std::move(ref));
  }

  // Append ASIO drivers after the WASAPI endpoints (ES-101 step 3). The
  // " (ASIO)" suffix keeps names distinct from the same interface's
  // WASAPI endpoint, so refresh()'s name-based selection remap can't
  // cross backends.
  //
  // While a WASAPI stream is open, reuse the previous ASIO rows instead
  // of re-enumerating: probing an unseen driver loads and inits it,
  // which can contend with the very endpoint WASAPI holds exclusively.
  // (An open ASIO stream is fine — AsioBackend::enumerate() then
  // returns its cached snapshot without touching the driver.)
  if (!running_ || impl_->asio_active) {
    impl_->asio_rows.clear();
    for (const auto& drv : AsioBackend::instance().enumerate()) {
      DeviceInfo info;
      info.name = drv.name + " (ASIO)";
      info.channel_count = drv.caps.output_channels;
      info.supported_channel_counts = {drv.caps.output_channels};
      info.supported_sample_rates = drv.caps.supported_sample_rates;
      info.default_sample_rate = 48000;
      if (!info.supported_sample_rates.empty() &&
          std::find(info.supported_sample_rates.begin(),
                    info.supported_sample_rates.end(),
                    48000u) == info.supported_sample_rates.end()) {
        info.default_sample_rate = info.supported_sample_rates[0];
      }
      impl_->asio_rows.push_back({std::move(info), drv.driver_index});
    }
  }
  for (const auto& row : impl_->asio_rows) {
    devices_.push_back(row.info);
    BackendRef ref;
    ref.asio = true;
    ref.driver_index = row.driver_index;
    impl_->refs.push_back(std::move(ref));
  }
  return true;
}

bool DeviceManager::start(uint32_t sample_rate, uint32_t buffer_frames,
                          DataCallback callback, void* user_data) {
  if (running_) return true;

  if (devices_.empty()) {
    {
      std::lock_guard<std::mutex> lock(last_error_mu_);
      last_error_ = "no output devices available";
    }
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "device",
               "no output devices available");
    return false;
  }

  // Pre-resolve "system default" to a concrete enumerated index so the
  // open path always addresses an explicit endpoint.
  selected_index_ = ResolveSelectedIndex(devices_, selected_index_);

  {
    char buf[192];
    const char* name = (selected_index_ < devices_.size())
                           ? devices_[selected_index_].name.c_str()
                           : "<none>";
    snprintf(buf, sizeof(buf),
             "Opening device: index=%u (%s), rate=%u, bufFrames=%u",
             selected_index_, name, sample_rate, buffer_frames);
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "device", buf);
  }

  const std::string dev_name = (selected_index_ < devices_.size())
                                   ? devices_[selected_index_].name
                                   : std::string("system default");
  auto fail = [this, &dev_name](const char* phase, HRESULT hr) {
    CloseStream(impl_.get());
    const std::string msg = FormatWasapiError(phase, hr, dev_name);
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "device", msg.c_str());
    std::lock_guard<std::mutex> lock(last_error_mu_);
    last_error_ = msg;
    return false;
  };

  // ASIO devices take a different open path entirely: driver-owned
  // buffer size, per-channel buffers, no WASAPI involvement (ES-101).
  if (selected_index_ < impl_->refs.size() &&
      impl_->refs[selected_index_].asio) {
    auto& asio = AsioBackend::instance();
    cb_ = callback;
    cb_user_ = user_data;
    if (!asio.start(impl_->refs[selected_index_].driver_index, sample_rate, cb_,
                    cb_user_)) {
      std::string msg = asio.last_error();
      if (msg.empty()) msg = "ASIO start FAILED on \"" + dev_name + "\"";
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "device", msg.c_str());
      std::lock_guard<std::mutex> lock(last_error_mu_);
      last_error_ = std::move(msg);
      return false;
    }
    // The ASIO buffer size is driver-owned and the driver may hold a
    // different rate than requested; report both so the engine adopts
    // them (AdoptHardwareSampleRate + OAR reinit), same as the WASAPI
    // clamp path.
    open_channels_ = asio.channel_count();
    current_sample_rate_ = asio.current_sample_rate();
    hardware_sample_rate_ = current_sample_rate_;
    current_buffer_size_ = asio.buffer_frames();
    impl_->asio_active = true;
    {
      char buf[192];
      snprintf(buf, sizeof(buf),
               "Device buffer (ASIO): callback=%u rate=%u channels=%u",
               current_buffer_size_, current_sample_rate_, open_channels_);
      engine_log(ECLIPSA_STUDIO_LOG_INFO, "device", buf);
    }
    {
      std::lock_guard<std::mutex> lock(last_error_mu_);
      last_error_.clear();
    }
    running_ = true;
    return true;
  }

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(enumerator.out()));
  if (FAILED(hr)) return fail("create device enumerator", hr);

  IMMDevice* device = nullptr;
  hr = (selected_index_ < impl_->refs.size())
           ? enumerator->GetDevice(
                 impl_->refs[selected_index_].endpoint_id.c_str(), &device)
           : enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (FAILED(hr) || device == nullptr) return fail("open endpoint", hr);
  impl_->device = device;

  IAudioClient* client = nullptr;
  hr = ActivateClient(device, &client);
  if (FAILED(hr)) return fail("activate IAudioClient", hr);

  // WASAPI exclusive mode: bypass the Windows mixer so we get a
  // bit-exact, un-resampled multichannel stream up to the endpoint's
  // exposed layout (ES-101 step 1). The endpoint may be held by another
  // exclusive client or reject every candidate format — fall back to
  // shared mode once rather than failing the open outright.
  StreamPick pick;
  uint32_t granted = 0;
  bool exclusive = true;
  hr = InitExclusive(device, &client, sample_rate, buffer_frames, &pick,
                     &granted);
  if (FAILED(hr)) {
    char buf[192];
    snprintf(buf, sizeof(buf),
             "WASAPI exclusive init failed (%s) for '%s'; retrying in "
             "shared mode",
             HrDesc(hr).c_str(), dev_name.c_str());
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "device", buf);
    exclusive = false;
    hr = ActivateClient(device, &client);
    if (FAILED(hr)) return fail("activate IAudioClient", hr);
    hr = InitShared(client, &pick, &granted);
    if (FAILED(hr)) {
      client->Release();
      return fail("IAudioClient::Initialize (shared)", hr);
    }
  }
  impl_->client = client;
  impl_->exclusive = exclusive;
  impl_->device_buffer_frames = granted;
  impl_->write = pick.writer;
  impl_->bytes_per_sample = pick.bytes_per_sample;

  impl_->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (impl_->event == nullptr) return fail("create render event", E_FAIL);
  hr = client->SetEventHandle(impl_->event);
  if (FAILED(hr)) return fail("SetEventHandle", hr);
  hr = client->GetService(__uuidof(IAudioRenderClient),
                          reinterpret_cast<void**>(&impl_->render));
  if (FAILED(hr)) return fail("get IAudioRenderClient", hr);

  // Engine-callback snapshot + FIFO. The engine keeps its fixed block
  // size (current_buffer_size()); the FIFO bridges it to the device's
  // granted period.
  cb_ = callback;
  cb_user_ = user_data;
  impl_->cb = cb_;
  impl_->cb_user = cb_user_;
  impl_->channels = pick.fmt.Format.nChannels;
  impl_->callback_frames = buffer_frames > 0 ? buffer_frames : granted;
  impl_->stage.assign(
      static_cast<size_t>(impl_->callback_frames) * impl_->channels, 0.0f);
  impl_->stage_pos = 0;
  impl_->stage_len = 0;

  // Exclusive mode: pre-fill the (one-period) buffer with silence so
  // the stream never starts on stale data. Shared mode starts clean
  // from an empty buffer, and its buffer spans several periods —
  // pre-filling it all would just add a buffer's worth of latency.
  if (exclusive) {
    BYTE* out = nullptr;
    if (SUCCEEDED(impl_->render->GetBuffer(granted, &out))) {
      impl_->render->ReleaseBuffer(granted, AUDCLNT_BUFFERFLAGS_SILENT);
    }
  }

  impl_->run.store(true, std::memory_order_release);
  impl_->thread =
      CreateThread(nullptr, 0, RenderThread, impl_.get(), 0, nullptr);
  if (impl_->thread == nullptr) return fail("create render thread", E_FAIL);

  hr = client->Start();
  if (FAILED(hr)) return fail("IAudioClient::Start", hr);

  open_channels_ = impl_->channels;
  current_sample_rate_ = pick.fmt.Format.nSamplesPerSec;
  hardware_sample_rate_ = current_sample_rate_;
  current_buffer_size_ = impl_->callback_frames;

  {
    char buf[160];
    snprintf(buf, sizeof(buf), "Device opened: actualChannels=%u (%s, %s)",
             impl_->channels, exclusive ? "exclusive" : "shared", pick.desc);
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "device", buf);
  }
  {
    char buf[192];
    snprintf(buf, sizeof(buf),
             "Device buffer: requested=%u callback=%u hw_period=%u "
             "rate=%u hw_rate=%u channels=%u",
             buffer_frames, current_buffer_size_, granted, current_sample_rate_,
             hardware_sample_rate_, impl_->channels);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "device", buf);
  }
  // Co-locate the success-state writes so the contract is obvious:
  // last_error_ is empty iff running_ is true at function exit.
  {
    std::lock_guard<std::mutex> lock(last_error_mu_);
    last_error_.clear();
  }
  impl_->asio_active = false;  // defensive: this stream is WASAPI's
  running_ = true;
  return true;
}

uint32_t DeviceManager::query_hardware_sample_rate() const {
  if (!running_) return 0;
  if (impl_->asio_active) {
    // Kept live by the driver's sampleRateDidChange callback.
    return AsioBackend::instance().current_sample_rate();
  }
  // The open-time snapshot is the live answer here: WASAPI invalidates
  // an open stream on device format changes (AUDCLNT_E_DEVICE_
  // INVALIDATED) rather than re-clocking it underneath the client, so
  // the rate cannot drift the way a CoreAudio nominal rate can.
  if (impl_->client == nullptr) return 0;
  return hardware_sample_rate_;
}

void DeviceManager::stop() {
  if (!running_) return;
  if (impl_->asio_active) {
    AsioBackend::instance().stop();
    impl_->asio_active = false;
  } else {
    CloseStream(impl_.get());
  }
  open_channels_ = 0;
  running_ = false;
}
