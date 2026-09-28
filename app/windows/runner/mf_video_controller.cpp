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

#include "mf_video_controller.h"

// Native Windows Media Foundation video backend. Decode + D3D11 NV12→BGRA
// conversion run on a dedicated worker thread so the pull-based per-tick
// renderAt (called every frame during playback) never blocks the platform/UI
// thread — the Windows analogue of AVFoundation servicing seek-then-pull on its
// own threads. NOTE: like the FFmpeg D3D11 path this needs on-device bring-up
// (HW decoder availability, color range/primaries, driver quirks).

// clang-format off
#include <windows.h>
#include <d3d11.h>
#include <d3d11_4.h>  // ID3D11Multithread (device multithread protection)
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <mfobjects.h>
#include <propvarutil.h>
#include <wrl/client.h>
// clang-format on

#include <cstdint>
#include <cstdio>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <variant>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

// The MF_SOURCE_READER_* stream selectors are signed enum values; cast once to
// the DWORD the IMFSourceReader API expects so every call site is C4245-clean
// (the runner builds warnings-as-errors).
constexpr DWORD kMfFirstVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kMfAllStreams =
    static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
constexpr DWORD kMfMediaSource =
    static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE);

// Process-wide MFStartup ref-count: multiple windows (main + pop-out) each host
// a plugin, and MFStartup/MFShutdown calls must balance.
std::mutex g_mf_mutex;
int g_mf_refs = 0;

void MfAddRef() {
  std::lock_guard<std::mutex> lock(g_mf_mutex);
  if (g_mf_refs++ == 0) MFStartup(MF_VERSION, MFSTARTUP_LITE);
}
void MfRelease() {
  std::lock_guard<std::mutex> lock(g_mf_mutex);
  if (--g_mf_refs == 0) MFShutdown();
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                    static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0],
                      n);
  return w;
}

bool GetString(const EncodableMap& m, const char* key, std::string* out) {
  auto it = m.find(EncodableValue(std::string(key)));
  if (it == m.end()) return false;
  if (const auto* s = std::get_if<std::string>(&it->second)) {
    *out = *s;
    return true;
  }
  return false;
}

bool GetDouble(const EncodableMap& m, const char* key, double* out) {
  auto it = m.find(EncodableValue(std::string(key)));
  if (it == m.end()) return false;
  if (const auto* d = std::get_if<double>(&it->second)) {
    *out = *d;
    return true;
  }
  if (const auto* i = std::get_if<int64_t>(&it->second)) {
    *out = static_cast<double>(*i);
    return true;
  }
  return false;
}

// Display name for a video subtype GUID. FOURCC-based MF video subtypes are
// the MF base GUID with Data1 swapped for the codec fourcc (e.g. 'H264');
// anything else (RGB/uncompressed formats) reports empty (= unknown).
std::string CodecName(const GUID& subtype) {
  GUID base = MFVideoFormat_Base;
  base.Data1 = subtype.Data1;
  if (subtype != base) return "";
  char cc[5] = {};
  for (int i = 0; i < 4; ++i) {
    const char c = static_cast<char>((subtype.Data1 >> (8 * i)) & 0xFF);
    if (c < 0x20 || c > 0x7E) return "";
    cc[i] = c;
  }
  const std::string raw(cc);
  if (raw == "H264") return "H.264 (H264)";
  if (raw == "HEVC") return "HEVC";
  if (raw == "H265") return "HEVC (H265)";
  if (raw == "VP90") return "VP9 (VP90)";
  if (raw == "AV01") return "AV1 (AV01)";
  if (raw == "MP4V") return "MPEG-4 (MP4V)";
  return raw;
}

// Transfer-function display name (matching the macOS backend's vocabulary),
// or empty when the stream doesn't carry the attribute.
std::string TransferName(IMFMediaType* type) {
  switch (MFGetAttributeUINT32(type, MF_MT_TRANSFER_FUNCTION,
                               MFVideoTransFunc_Unknown)) {
    case MFVideoTransFunc_2084:
      return "PQ (HDR10)";
    case MFVideoTransFunc_HLG:
      return "HLG";
    case MFVideoTransFunc_709:
      return "BT.709";
    case MFVideoTransFunc_2020:
    case MFVideoTransFunc_2020_const:
      return "BT.2020";
    default:
      return "";
  }
}

// Color-primaries display name, or empty when absent.
std::string PrimariesName(IMFMediaType* type) {
  switch (MFGetAttributeUINT32(type, MF_MT_VIDEO_PRIMARIES,
                               MFVideoPrimaries_Unknown)) {
    case MFVideoPrimaries_BT2020:
      return "BT.2020";
    case MFVideoPrimaries_BT709:
      return "BT.709";
    case MFVideoPrimaries_DCI_P3:
      return "P3";
    default:
      return "";
  }
}
}  // namespace

// Metadata reported back to Dart on load.
struct PlayerMeta {
  int width = 0;
  int height = 0;
  double fps = 0.0;
  int64_t duration_ms = 0;
  int64_t container_duration_ms = 0;  // presentation (longest-track) length
  int64_t bit_rate = 0;               // video track average, bits/s
  std::string codec;                  // e.g. "H.264 (H264)"; empty = unknown
  std::string color_transfer;         // e.g. "PQ (HDR10)"; empty = unknown
  std::string color_primaries;        // e.g. "BT.2020"; empty = unknown
  int64_t texture_id = -1;
  bool ok = false;
};

// Owns one clip: its D3D11 device, the IMFSourceReader, the NV12→BGRA
// VideoProcessor and the shared BGRA texture, all driven from a private worker
// thread. Render requests are latest-wins.
class MfVideoPlayer {
 public:
  MfVideoPlayer(flutter::TextureRegistrar* textures, std::wstring path)
      : textures_(textures), path_(std::move(path)) {
    thread_ = std::thread([this] { ThreadMain(); });
  }

  ~MfVideoPlayer() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stop_ = true;
    }
    cv_.notify_one();
    if (thread_.joinable()) thread_.join();
  }

  MfVideoPlayer(const MfVideoPlayer&) = delete;
  MfVideoPlayer& operator=(const MfVideoPlayer&) = delete;

  // Blocks until the worker finishes opening the clip; returns its metadata.
  PlayerMeta WaitForInit() {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [this] { return init_done_; });
    return meta_;
  }

  // Request the frame at [seconds] (latest-wins; non-blocking).
  void RenderAt(double seconds) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      request_seconds_ = seconds;
      has_request_ = true;
    }
    cv_.notify_one();
  }

  // Render diagnostics for the renderAt reply: presented / decoded frame
  // counts and the FIRST recorded native failure (empty when healthy). The
  // worker's failures are otherwise invisible — RenderOnce returns void and
  // the JSONL log lives on the Dart side, so Dart logs what this reports.
  // Because RenderAt is async, a reply describes the renders before it.
  flutter::EncodableMap DiagMap() {
    std::lock_guard<std::mutex> lock(mutex_);
    return flutter::EncodableMap{
        {EncodableValue("presented"), EncodableValue(presented_)},
        {EncodableValue("reads"), EncodableValue(reads_)},
        {EncodableValue("error"), EncodableValue(diag_)},
    };
  }

 private:
  // Record the first native failure (stage + HRESULT) for DiagMap. Later
  // failures are dropped — the first one is where the story starts.
  void SetDiag(const char* stage, HRESULT hr) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!diag_.empty()) return;
    char buf[96];
    snprintf(buf, sizeof(buf), "%s hr=0x%08lX", stage,
             static_cast<unsigned long>(hr));
    diag_ = buf;
  }
  void ThreadMain() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MfAddRef();

    const bool ok = Open();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      meta_.ok = ok;
      init_done_ = true;
    }
    cv_.notify_all();

    if (ok) {
      for (;;) {
        double seconds;
        {
          std::unique_lock<std::mutex> lock(mutex_);
          cv_.wait(lock, [this] { return has_request_ || stop_; });
          if (stop_) break;
          seconds = request_seconds_;
          has_request_ = false;
        }
        RenderOnce(seconds);
      }
    }

    Teardown();
    MfRelease();
    CoUninitialize();
  }

  bool Open() {
    // HW-capable, multithread-protected D3D11 device.
    UINT flags =
        D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 flags, nullptr, 0, D3D11_SDK_VERSION, &device_,
                                 nullptr, &context_))) {
      return false;
    }
    ComPtr<ID3D11Multithread> mt;
    if (SUCCEEDED(context_.As(&mt))) mt->SetMultithreadProtected(TRUE);
    if (FAILED(device_.As(&video_device_))) return false;
    if (FAILED(context_.As(&video_context_))) return false;

    UINT token = 0;
    if (FAILED(MFCreateDXGIDeviceManager(&token, &dxgi_manager_))) return false;
    if (FAILED(dxgi_manager_->ResetDevice(device_.Get(), token))) return false;

    ComPtr<IMFAttributes> attrs;
    if (FAILED(MFCreateAttributes(&attrs, 2))) return false;
    attrs->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, dxgi_manager_.Get());
    // Let the HW decoder hand us its native NV12 D3D surface; we do the
    // NV12→BGRA conversion ourselves (reliable across drivers), rather than
    // asking the reader's advanced video processor to output RGB in D3D.
    attrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, FALSE);

    if (FAILED(MFCreateSourceReaderFromURL(path_.c_str(), attrs.Get(),
                                           &reader_))) {
      return false;
    }
    // Decode only the first video stream — structurally avoids the IAMF audio
    // decoder (ES-219), mirroring the AVFoundation composition trick.
    reader_->SetStreamSelection(kMfAllStreams, FALSE);
    reader_->SetStreamSelection(kMfFirstVideoStream, TRUE);

    ComPtr<IMFMediaType> want;
    if (SUCCEEDED(MFCreateMediaType(&want))) {
      want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
      // Best-effort: a decoder that won't hand NV12 keeps its default type.
      reader_->SetCurrentMediaType(kMfFirstVideoStream, nullptr,
                                   want.Get());
    }

    ComPtr<IMFMediaType> cur;
    if (FAILED(reader_->GetCurrentMediaType(kMfFirstVideoStream,
                                            &cur))) {
      return false;
    }
    UINT32 w = 0, h = 0;
    MFGetAttributeSize(cur.Get(), MF_MT_FRAME_SIZE, &w, &h);
    if (w == 0 || h == 0) return false;
    width_ = static_cast<int>(w);
    height_ = static_cast<int>(h);
    UINT32 fn = 0, fd = 0;
    double fps = 0.0;
    if (SUCCEEDED(MFGetAttributeRatio(cur.Get(), MF_MT_FRAME_RATE, &fn, &fd)) &&
        fd != 0) {
      fps = static_cast<double>(fn) / fd;
    }

    // Prefer the video *stream's* duration over the presentation duration:
    // on a muxed master whose audio outlasts the picture, MF_PD_DURATION is
    // the longest track, overshooting the last frame (ES-459). MF_PD_DURATION
    // is documented on the presentation descriptor only; the MP4 source has
    // been observed to stamp it on stream descriptors too (verify via the
    // Dart meta log's "duration ... (container ...)" pair) — when a source
    // doesn't, the query fails and the presentation value is the fallback.
    // The presentation duration is reported alongside so the inspector can
    // surface a container/stream mismatch (ES-462).
    const auto duration_ms_of = [this](DWORD selector) -> int64_t {
      PROPVARIANT pv;
      PropVariantInit(&pv);
      int64_t out = 0;
      if (SUCCEEDED(reader_->GetPresentationAttribute(selector,
                                                      MF_PD_DURATION, &pv)) &&
          pv.vt == VT_UI8) {
        out = static_cast<int64_t>(pv.uhVal.QuadPart / 10000);  // 100ns → ms
      }
      PropVariantClear(&pv);
      return out;
    };
    int64_t dur_ms = duration_ms_of(kMfFirstVideoStream);
    const int64_t container_ms = duration_ms_of(kMfMediaSource);
    if (dur_ms == 0) dur_ms = container_ms;

    // Codec / bit rate / color metadata for the inspector (ES-462) come from
    // the stream's *native* (compressed) media type — `cur` above is the
    // reader's decoded NV12 output type, which no longer carries the
    // subtype. Bit rate and color often live only on one of the two
    // (demuxers frequently omit MF_MT_AVG_BITRATE on the native type, while
    // decoders sometimes propagate color onto the output type), so fall
    // back to the decoded type for those.
    std::string codec;
    std::string color_transfer;
    std::string color_primaries;
    int64_t bit_rate = 0;
    ComPtr<IMFMediaType> native;
    if (SUCCEEDED(reader_->GetNativeMediaType(kMfFirstVideoStream, 0,
                                              &native))) {
      GUID subtype = GUID_NULL;
      if (SUCCEEDED(native->GetGUID(MF_MT_SUBTYPE, &subtype))) {
        codec = CodecName(subtype);
      }
      bit_rate = MFGetAttributeUINT32(native.Get(), MF_MT_AVG_BITRATE, 0);
      color_transfer = TransferName(native.Get());
      color_primaries = PrimariesName(native.Get());
    }
    if (bit_rate == 0) {
      bit_rate = MFGetAttributeUINT32(cur.Get(), MF_MT_AVG_BITRATE, 0);
    }
    if (color_transfer.empty()) color_transfer = TransferName(cur.Get());
    if (color_primaries.empty()) {
      color_primaries = PrimariesName(cur.Get());
    }

    // Nominal frame duration in 100ns, for the nearest-frame pacing in
    // RenderOnce. Falls back to 30 fps when the container reports no rate;
    // variable-frame-rate content paces off the nominal rate (best-effort).
    frame_dur_ = (fps > 0.0) ? static_cast<LONGLONG>(1e7 / fps) : 333333;

    // Coded == display until the reader's first CURRENTMEDIATYPECHANGED
    // reveals the decoder's aligned size (see RenderOnce).
    coded_w_ = width_;
    coded_h_ = height_;
    if (!InitBlitter(coded_w_, coded_h_)) return false;

    const int64_t id = sink_.Register(textures_);
    if (id < 0) return false;

    std::lock_guard<std::mutex> lock(mutex_);
    meta_.width = width_;
    meta_.height = height_;
    meta_.fps = fps;
    meta_.duration_ms = dur_ms;
    meta_.container_duration_ms = container_ms;
    meta_.bit_rate = bit_rate;
    meta_.codec = codec;
    meta_.color_transfer = color_transfer;
    meta_.color_primaries = color_primaries;
    meta_.texture_id = id;
    return true;
  }

  // Build the NV12→BGRA video processor and the single shared BGRA texture
  // (stable legacy share handle), mirroring the engine's D3D11Blitter.
  //
  // [in_w]x[in_h] is the *coded* input size — the decoder's NV12 texture,
  // which H.264 16-aligns (1920x1080 content decodes as 1920x1088). The
  // shared output texture stays at the display size (width_ x height_) and
  // the stream source rect crops the alignment padding. Called from Open
  // with coded == display, and again from RenderOnce when the reader's
  // first CURRENTMEDIATYPECHANGED reveals the real coded size.
  bool InitBlitter(int in_w, int in_h) {
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC content = {};
    content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    content.InputWidth = static_cast<UINT>(in_w);
    content.InputHeight = static_cast<UINT>(in_h);
    content.OutputWidth = static_cast<UINT>(width_);
    content.OutputHeight = static_cast<UINT>(height_);
    content.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    if (FAILED(video_device_->CreateVideoProcessorEnumerator(&content,
                                                             &vp_enum_))) {
      return false;
    }
    if (FAILED(video_device_->CreateVideoProcessor(vp_enum_.Get(), 0,
                                                   &processor_))) {
      return false;
    }
    // Input: decoded NV12 is studio (limited) range by convention, BT.709
    // matrix for HD / BT.601 for SD. Output: full-range RGB. Without the
    // explicit input color space the processor's defaults (driver-dependent,
    // often full-range) wash out or crush the levels.
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE in_cs = {};
    in_cs.YCbCr_Matrix = (height_ >= 720) ? 1u : 0u;  // BT.709 : BT.601
    in_cs.Nominal_Range = 1;  // D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235
    video_context_->VideoProcessorSetStreamColorSpace(processor_.Get(), 0,
                                                      &in_cs);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE out_cs = {};
    out_cs.RGB_Range = 0;  // full range
    video_context_->VideoProcessorSetOutputColorSpace(processor_.Get(),
                                                      &out_cs);

    // Crop the coded frame to the display region (drops H.264 alignment
    // padding rows, e.g. 1088→1080) and map it onto the whole output.
    RECT display = {0, 0, width_, height_};
    video_context_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0,
                                                      TRUE, &display);
    video_context_->VideoProcessorSetStreamDestRect(processor_.Get(), 0, TRUE,
                                                    &display);

    D3D11_TEXTURE2D_DESC td = {};
    td.Width = static_cast<UINT>(width_);
    td.Height = static_cast<UINT>(height_);
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    // Legacy share handle (not NT), no keyed mutex: Flutter/ANGLE consumes
    // this texture via ANGLE's share-handle pbuffer, which opens it with the
    // legacy ID3D11Device::OpenSharedResource — an NT handle is rejected
    // there with E_INVALIDARG and the picture silently composites black
    // (verified on-device; see the engine decoder's shared-handle diag).
    // ANGLE takes no part in the keyed-mutex handshake, so producer→consumer
    // ordering is a Flush() at the end of Blit instead.
    td.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    if (FAILED(device_->CreateTexture2D(&td, nullptr, &shared_tex_))) {
      return false;
    }
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd = {};
    ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
    ovd.Texture2D.MipSlice = 0;
    if (FAILED(video_device_->CreateVideoProcessorOutputView(
            shared_tex_.Get(), vp_enum_.Get(), &ovd, &shared_view_))) {
      return false;
    }

    // The legacy handle is BORROWED from the texture (GetSharedHandle does
    // not transfer ownership; closing it is invalid) and stays valid for the
    // texture's lifetime.
    ComPtr<IDXGIResource> res;
    if (FAILED(shared_tex_.As(&res))) return false;
    if (FAILED(res->GetSharedHandle(&shared_handle_))) return false;
    return true;
  }

  void RenderOnce(double seconds) {
    if (format_broken_) return;  // format recovery failed; see decode loop
    const LONGLONG target = static_cast<LONGLONG>(seconds * 1e7);  // 100ns
    const LONGLONG one_second = 10000000LL;
    // Nearest-frame pacing: the frame on screen represents the interval
    // [last_ts_ - dur/2, last_ts_ + dur/2). While the target stays inside
    // it there is nothing to decode — without this, a 60 Hz tick over a
    // 30 fps clip consumed a fresh sample EVERY tick, showing each frame
    // one early and then seeking backwards (a keyframe re-decode) on the
    // next tick — visible as strobing and decode churn.
    if (last_ts_ >= 0 && target >= last_ts_ - frame_dur_ / 2 &&
        target < last_ts_ + frame_dur_ / 2) {
      return;
    }
    // Seek only when jumping back or far forward; small forward steps decode on
    // (mirrors the engine decoder's seek heuristic).
    const bool need_seek =
        last_ts_ < 0 || target < last_ts_ || target > last_ts_ + one_second;
    if (need_seek) {
      // VT_I8 holds no allocation, so init by hand (avoids propsys.lib's
      // InitPropVariantFromInt64) and skip the matching clear.
      PROPVARIANT pv;
      pv.vt = VT_I8;
      pv.hVal.QuadPart = target;
      reader_->SetCurrentPosition(GUID_NULL, pv);
      last_ts_ = -1;
    }

    // Decode forward until we reach (or pass) the target PTS. Observe stop_
    // each iteration: the destructor joins this thread from the platform
    // thread, and a far scrub can queue hundreds of ReadSample calls — an
    // uninterruptible loop here would freeze the UI for the whole decode.
    ComPtr<IMFSample> kept;
    bool eos = false;
    for (int i = 0; i < 600 && !StopRequested(); ++i) {
      DWORD flags = 0, actual = 0;
      LONGLONG ts = 0;
      ComPtr<IMFSample> sample;
      const HRESULT read = reader_->ReadSample(kMfFirstVideoStream, 0, &actual,
                                               &flags, &ts, &sample);
      if (FAILED(read)) {
        SetDiag("ReadSample", read);
        break;
      }
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
        eos = true;
        break;
      }
      if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
        // The decoder finalized (or changed) its output type. This fires
        // once at the first sample on most H.264 clips: the coded frame
        // size gets 16-aligned (1920x1080 → 1920x1088). That's negotiation,
        // not corruption — rebuild the blitter for the new coded input
        // size; the shared output texture keeps the display size and the
        // source rect crops the padding. Only a failed query/rebuild stops
        // rendering.
        UINT32 w = 0, h = 0;
        ComPtr<IMFMediaType> cur;
        HRESULT fc = reader_->GetCurrentMediaType(kMfFirstVideoStream, &cur);
        if (SUCCEEDED(fc)) {
          fc = MFGetAttributeSize(cur.Get(), MF_MT_FRAME_SIZE, &w, &h);
        }
        if (FAILED(fc)) {
          SetDiag("format_query", fc);
          format_broken_ = true;
          return;
        }
        if (static_cast<int>(w) != coded_w_ ||
            static_cast<int>(h) != coded_h_) {
          if (!InitBlitter(static_cast<int>(w), static_cast<int>(h))) {
            SetDiag("format_rebuild", 0);
            format_broken_ = true;
            return;
          }
          coded_w_ = static_cast<int>(w);
          coded_h_ = static_cast<int>(h);
        }
      }
      if (!sample) continue;  // stream gap / no sample this call
      {
        std::lock_guard<std::mutex> lock(mutex_);
        ++reads_;
      }
      kept = sample;
      last_ts_ = ts;
      // Stop at the frame NEAREST the target: break once this sample's
      // interval covers it. Bare `ts >= target` overshoots by one frame
      // whenever the target lands mid-interval (or pts sit a hair below a
      // tick-quantized target), which is where the early-frame/seek-back
      // strobe started.
      if (ts + frame_dur_ / 2 >= target) break;
    }
    if (!kept) {
      // End-of-stream with the playhead past the clip is normal (the audio
      // timeline can be longer than the video) — keep the last frame and
      // don't poison the first-error diag with it.
      if (!eos) SetDiag("no_sample", 0);
      return;
    }

    ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = kept->GetBufferByIndex(0, &buffer);
    if (FAILED(hr)) {
      SetDiag("GetBufferByIndex", hr);
      return;
    }
    ComPtr<IMFDXGIBuffer> dxgi;
    hr = buffer.As(&dxgi);
    if (FAILED(hr)) {
      SetDiag("IMFDXGIBuffer", hr);
      return;
    }
    ComPtr<ID3D11Texture2D> nv12;
    hr = dxgi->GetResource(IID_PPV_ARGS(&nv12));
    if (FAILED(hr)) {
      SetDiag("GetResource", hr);
      return;
    }
    UINT slice = 0;
    dxgi->GetSubresourceIndex(&slice);

    if (Blit(nv12.Get(), slice)) {
      sink_.Present(shared_handle_, width_, height_);
      std::lock_guard<std::mutex> lock(mutex_);
      ++presented_;
    }
  }

  bool Blit(ID3D11Texture2D* nv12, UINT slice) {
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {};
    ivd.FourCC = 0;
    ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    ivd.Texture2D.MipSlice = 0;
    ivd.Texture2D.ArraySlice = slice;
    ComPtr<ID3D11VideoProcessorInputView> input_view;
    const HRESULT iv = video_device_->CreateVideoProcessorInputView(
        nv12, vp_enum_.Get(), &ivd, &input_view);
    if (FAILED(iv)) {
      SetDiag("CreateInputView", iv);
      return false;
    }
    D3D11_VIDEO_PROCESSOR_STREAM stream = {};
    stream.Enable = TRUE;
    stream.pInputSurface = input_view.Get();
    const HRESULT blt = video_context_->VideoProcessorBlt(
        processor_.Get(), shared_view_.Get(), 0 /*OutputFrame*/, 1, &stream);
    // No keyed mutex on the legacy-shared texture (see CreateSharedTexture),
    // so Flush is the producer→consumer ordering: it submits the blit to the
    // GPU before Flutter's next sample of the shared texture.
    if (SUCCEEDED(blt)) {
      context_->Flush();
    } else {
      SetDiag("VideoProcessorBlt", blt);
    }
    return SUCCEEDED(blt);
  }

  bool StopRequested() {
    std::lock_guard<std::mutex> lock(mutex_);
    return stop_;
  }

  void Teardown() {
    sink_.Unregister();
    reader_.Reset();
    dxgi_manager_.Reset();
    // shared_handle_ is a legacy share handle borrowed from shared_tex_ —
    // it must not be closed; it dies with the texture.
    shared_handle_ = nullptr;
  }

  flutter::TextureRegistrar* textures_;
  std::wstring path_;
  WinGpuSurfaceSink sink_;

  // D3D + MF (worker-thread owned).
  ComPtr<ID3D11Device> device_;
  ComPtr<ID3D11DeviceContext> context_;
  ComPtr<ID3D11VideoDevice> video_device_;
  ComPtr<ID3D11VideoContext> video_context_;
  ComPtr<ID3D11VideoProcessor> processor_;
  ComPtr<ID3D11VideoProcessorEnumerator> vp_enum_;
  ComPtr<ID3D11Texture2D> shared_tex_;
  ComPtr<ID3D11VideoProcessorOutputView> shared_view_;
  HANDLE shared_handle_ = nullptr;  // legacy share handle, borrowed
  ComPtr<IMFDXGIDeviceManager> dxgi_manager_;
  ComPtr<IMFSourceReader> reader_;
  int width_ = 0;   // display size (reported to Dart; shared texture size)
  int height_ = 0;
  int coded_w_ = 0;  // decoder's coded NV12 size (16-aligned, e.g. 1088);
  int coded_h_ = 0;  // blitter input — tracks CURRENTMEDIATYPECHANGED
  LONGLONG last_ts_ = -1;  // 100ns of last decoded frame; <0 forces a seek
  LONGLONG frame_dur_ = 333333;  // nominal frame duration (100ns); pacing
  bool format_broken_ = false;  // format query/rebuild failed; render stopped

  // Worker coordination.
  std::thread thread_;
  std::mutex mutex_;
  std::condition_variable cv_;
  bool init_done_ = false;
  bool has_request_ = false;
  bool stop_ = false;
  double request_seconds_ = 0.0;
  PlayerMeta meta_;

  // Render diagnostics (guarded by mutex_); see DiagMap / SetDiag.
  int presented_ = 0;       // frames handed to the sink
  int reads_ = 0;           // samples decoded by the reader
  std::string diag_;        // first native failure ("" = healthy)
};

MfVideoPlugin::MfVideoPlugin(flutter::BinaryMessenger* messenger,
                             flutter::TextureRegistrar* textures)
    : textures_(textures) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "eclipsa/mf_video",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

MfVideoPlugin::~MfVideoPlugin() = default;

void MfVideoPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());

  if (method == "load") {
    std::string path;
    if (args == nullptr || !GetString(*args, "path", &path)) {
      result->Error("bad_args", "path required");
      return;
    }
    player_ = std::make_unique<MfVideoPlayer>(textures_, Utf8ToWide(path));
    const PlayerMeta meta = player_->WaitForInit();
    if (!meta.ok) {
      player_.reset();
      result->Error("load_failed", "could not open the video");
      return;
    }
    EncodableMap reply{
        {EncodableValue("textureId"), EncodableValue(meta.texture_id)},
        {EncodableValue("width"), EncodableValue(meta.width)},
        {EncodableValue("height"), EncodableValue(meta.height)},
        {EncodableValue("fps"), EncodableValue(meta.fps)},
        {EncodableValue("durationMs"), EncodableValue(meta.duration_ms)},
        {EncodableValue("containerDurationMs"),
         EncodableValue(meta.container_duration_ms)},
    };
    // Optional inspector metadata (ES-462) — omitted when unresolved, matching
    // the macOS backend's contract.
    if (meta.bit_rate > 0) {
      reply[EncodableValue("bitRate")] = EncodableValue(meta.bit_rate);
    }
    if (!meta.codec.empty()) {
      reply[EncodableValue("codec")] = EncodableValue(meta.codec);
    }
    if (!meta.color_transfer.empty()) {
      reply[EncodableValue("colorTransfer")] =
          EncodableValue(meta.color_transfer);
    }
    if (!meta.color_primaries.empty()) {
      reply[EncodableValue("colorPrimaries")] =
          EncodableValue(meta.color_primaries);
    }
    result->Success(EncodableValue(std::move(reply)));
    return;
  }

  if (method == "renderAt") {
    double seconds = 0.0;
    if (args == nullptr || !GetDouble(*args, "seconds", &seconds)) {
      result->Error("bad_args", "seconds required");
      return;
    }
    if (player_ != nullptr) {
      player_->RenderAt(seconds);
      // Reply with the render diagnostics so the Dart side can surface the
      // worker thread's failures into the app log (they are invisible
      // otherwise). Async render, so this describes the renders so far.
      result->Success(EncodableValue(player_->DiagMap()));
      return;
    }
    result->Success();
    return;
  }

  if (method == "setPlaying") {
    // Pull-based: frames are driven entirely by renderAt, so there is no
    // internal clock to start or stop.
    result->Success();
    return;
  }

  if (method == "unload" || method == "dispose") {
    player_.reset();  // joins the worker thread and tears everything down
    result->Success();
    return;
  }

  result->NotImplemented();
}
