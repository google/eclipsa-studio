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

#include "video/video_decoder.h"

// Hardware (VideoToolbox) decode with a software (swscale) RGBA fallback,
// against the FFmpeg send-packet/receive-frame API (developed on FFmpeg 5/6;
// builds and decodes on 8). Validated on macOS across H.264 / ProRes / HEVC
// via the eclipsa_studio_video_* FFI. See video_decoder.h.

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
#include <libswscale/swscale.h>
}

#ifdef _WIN32
// D3D11 NV12→BGRA video processing + DXGI shared-handle export for the Windows
// zero-copy texture path (IDXGIResource::GetSharedHandle legacy sharing).
// These are C++ headers, so they must sit OUTSIDE the extern
// "C" block above. FFmpeg's hwcontext_d3d11va.h (which pulls in <d3d11.h> and
// only declares the AVD3D11VADeviceContext struct — no functions) is included
// here after d3d11.h for the same reason.
#include <d3d11.h>
#include <d3d11_1.h>  // ID3D11Device1::OpenSharedResource1 (handle diag).
#include <dxgi1_2.h>
#include <libavutil/hwcontext_d3d11va.h>
#include <wrl/client.h>
// D3D11CreateDevice for the one-shot shared-handle diagnostic below. The
// rest of this file only calls COM methods on FFmpeg's device, so d3d11.lib
// wasn't linked before; pull it in the same way the WASAPI device backend
// pulls its system libs (see the linkopts comment in //:eclipsa_studio_engine).
#pragma comment(lib, "d3d11")
#endif

#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstring>

#include "engine_log.h"
#include "video/rotation.h"

#ifdef __APPLE__
// For CFRetain/CFRelease on the VideoToolbox CVPixelBuffer handed to the
// zero-copy texture path. CVPixelBufferRef is a CFTypeRef (toll-free), so the
// generic CF retain/release suffice without linking CoreVideo directly.
#include <CoreFoundation/CoreFoundation.h>
#endif

namespace eclipsa_studio::video {
namespace {

// The hardware decoder FFmpeg attaches on this OS (VideoToolbox on macOS,
// D3D11VA on Windows). AV_HWDEVICE_TYPE_NONE elsewhere selects software decode.
#ifdef __APPLE__
constexpr AVHWDeviceType kHwDeviceType = AV_HWDEVICE_TYPE_VIDEOTOOLBOX;
#elif defined(_WIN32)
constexpr AVHWDeviceType kHwDeviceType = AV_HWDEVICE_TYPE_D3D11VA;
#else
constexpr AVHWDeviceType kHwDeviceType = AV_HWDEVICE_TYPE_NONE;
#endif

// Route FFmpeg's libav* diagnostics into the engine log pipeline (→ JSONL)
// instead of letting them flood raw stderr, rate-limited to ~1/s with a
// suppressed count. Some MP4s make the h264 *parser* log "Invalid NAL unit
// size" / "Error splitting the input into NAL units" on nearly every packet
// while VideoToolbox still decodes the frames fine — unbounded, that is
// hundreds of stderr lines a second.
void FfmpegLogCallback(void* /*avcl*/, int level, const char* fmt,
                       va_list args) {
  if (level > AV_LOG_WARNING) return;  // drop info / verbose / debug / trace
  static std::atomic<int64_t> last_ms{0};
  static std::atomic<int> suppressed{0};
  const int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now().time_since_epoch())
                          .count();
  if (now - last_ms.load(std::memory_order_relaxed) < 1000) {
    suppressed.fetch_add(1, std::memory_order_relaxed);
    return;
  }
  last_ms.store(now, std::memory_order_relaxed);
  const int dropped = suppressed.exchange(0, std::memory_order_relaxed);

  char msg[256];
  if (vsnprintf(msg, sizeof(msg), fmt, args) < 0) return;
  size_t len = strnlen(msg, sizeof(msg));  // trim FFmpeg's trailing newline
  while (len > 0 && (msg[len - 1] == '\n' || msg[len - 1] == '\r')) {
    msg[--len] = '\0';
  }
  char out[320];
  if (dropped > 0) {
    snprintf(out, sizeof(out), "ffmpeg: %s (+%d suppressed)", msg, dropped);
  } else {
    snprintf(out, sizeof(out), "ffmpeg: %s", msg);
  }
  engine_log(level <= AV_LOG_FATAL ? ECLIPSA_STUDIO_LOG_ERROR
                                   : ECLIPSA_STUDIO_LOG_WARN,
             "video", out);
}

// Install FfmpegLogCallback once for the process (av_log is global).
void EnsureFfmpegLogRouting() {
  static std::atomic<bool> installed{false};
  bool expected = false;
  if (installed.compare_exchange_strong(expected, true)) {
    av_log_set_callback(FfmpegLogCallback);
  }
}

// get_format callback: pin the hardware surface format when the decoder offers
// it, so frames come back as VideoToolbox HW frames (AV_PIX_FMT_VIDEOTOOLBOX)
// rather than silently falling to software. Returns the first (software) format
// when the HW format isn't in the list — a codec VideoToolbox can't take. HW
// frames keep VideoToolbox's native CVPixelBuffer format (NV12/P010): the
// texture side converts to BGRA on the GPU (CoreImage) and the readback path
// scales via swscale — forcing a BGRA decode frame pool here is rejected by
// av_hwframe_ctx_init for VideoToolbox and drops the codec to software.
enum AVPixelFormat PickHwFormat(AVCodecContext* ctx,
                                const enum AVPixelFormat* fmts) {
  const int want = static_cast<VideoDecoder*>(ctx->opaque)->hw_pix_fmt();
  for (const enum AVPixelFormat* p = fmts; *p != AV_PIX_FMT_NONE; ++p) {
    if (static_cast<int>(*p) == want) return *p;
  }
  // Info().hw stays true (the device is attached) but frames decode in
  // software from here; the per-frame format checks route them to the
  // software path. Log it so a texture-create-then-downgrade is explicable.
  engine_log(ECLIPSA_STUDIO_LOG_WARN, "video",
             "hw surface format not offered by codec; decoding in software");
  return fmts[0];
}

// PTS of a decoded frame (best-effort, falling back to pts).
int64_t BestEffortPts(const AVFrame* f) {
  return (f->best_effort_timestamp != AV_NOPTS_VALUE) ? f->best_effort_timestamp
                                                      : f->pts;
}

}  // namespace

#ifdef _WIN32
using Microsoft::WRL::ComPtr;

namespace {

// One-shot diagnostic for the Windows black-picture investigation: after the
// blitter exports its shared handle, probe how a *consumer* would fare
// opening it. Flutter/ANGLE's DXGI-shared-handle texture path dates from the
// legacy share-handle era, so if ID3D11Device::OpenSharedResource (legacy)
// rejects our NT handle while ID3D11Device1::OpenSharedResource1 accepts it,
// the silent black picture is explained: the compositor can't open the
// texture and has no error path that reaches our logs. Also logs the
// producer adapter vs. the default adapter (what ANGLE composites on) to
// rule multi-GPU adapter mismatch in or out. TEMPORARY — remove once the
// texture path is validated.
void LogSharedHandleDiagnostics(ID3D11Device* producer, HANDLE shared) {
  static std::atomic<bool> done{false};
  bool expected = false;
  if (!done.compare_exchange_strong(expected, true)) return;

  char buf[192];

  // Producer (decoder) adapter.
  LUID prod_luid = {};
  {
    ComPtr<IDXGIDevice> dxgi;
    ComPtr<IDXGIAdapter> adapter;
    DXGI_ADAPTER_DESC desc = {};
    if (SUCCEEDED(ComPtr<ID3D11Device>(producer).As(&dxgi)) &&
        SUCCEEDED(dxgi->GetAdapter(&adapter)) &&
        SUCCEEDED(adapter->GetDesc(&desc))) {
      prod_luid = desc.AdapterLuid;
      snprintf(buf, sizeof(buf),
               "d3d11 diag: producer adapter luid=%08lx:%08lx vram=%zuMB",
               static_cast<unsigned long>(desc.AdapterLuid.HighPart),
               static_cast<unsigned long>(desc.AdapterLuid.LowPart),
               desc.DedicatedVideoMemory >> 20);
      engine_log(ECLIPSA_STUDIO_LOG_INFO, "video", buf);
    }
  }

  // Scratch device on the default adapter — the adapter ANGLE picks.
  ComPtr<ID3D11Device> scratch;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                 D3D11_SDK_VERSION, &scratch, nullptr, nullptr);
  if (FAILED(hr)) {
    snprintf(buf, sizeof(buf), "d3d11 diag: scratch device create hr=0x%08lx",
             static_cast<unsigned long>(hr));
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "video", buf);
    return;
  }
  {
    ComPtr<IDXGIDevice> dxgi;
    ComPtr<IDXGIAdapter> adapter;
    DXGI_ADAPTER_DESC desc = {};
    if (SUCCEEDED(scratch.As(&dxgi)) && SUCCEEDED(dxgi->GetAdapter(&adapter)) &&
        SUCCEEDED(adapter->GetDesc(&desc))) {
      const bool same = desc.AdapterLuid.HighPart == prod_luid.HighPart &&
                        desc.AdapterLuid.LowPart == prod_luid.LowPart;
      snprintf(buf, sizeof(buf),
               "d3d11 diag: default adapter luid=%08lx:%08lx (%s producer)",
               static_cast<unsigned long>(desc.AdapterLuid.HighPart),
               static_cast<unsigned long>(desc.AdapterLuid.LowPart),
               same ? "same as" : "DIFFERENT from");
      engine_log(same ? ECLIPSA_STUDIO_LOG_INFO : ECLIPSA_STUDIO_LOG_WARN,
                 "video", buf);
    }
  }

  // Legacy open — what a GetSharedHandle-era consumer (ANGLE's share-handle
  // pbuffer) calls. NT handles are documented to be rejected here.
  {
    ComPtr<ID3D11Texture2D> tex;
    hr = scratch->OpenSharedResource(shared, IID_PPV_ARGS(&tex));
    snprintf(buf, sizeof(buf),
             "d3d11 diag: OpenSharedResource(legacy) hr=0x%08lx%s",
             static_cast<unsigned long>(hr), SUCCEEDED(hr) ? " ok" : " FAIL");
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "video", buf);
  }

  // NT-handle open — requires the newer ID3D11Device1 API.
  {
    ComPtr<ID3D11Device1> dev1;
    if (SUCCEEDED(scratch.As(&dev1))) {
      ComPtr<ID3D11Texture2D> tex;
      hr = dev1->OpenSharedResource1(shared, IID_PPV_ARGS(&tex));
      snprintf(buf, sizeof(buf),
               "d3d11 diag: OpenSharedResource1(NT) hr=0x%08lx%s",
               static_cast<unsigned long>(hr), SUCCEEDED(hr) ? " ok" : " FAIL");
      engine_log(ECLIPSA_STUDIO_LOG_INFO, "video", buf);
    }
  }
}

}  // namespace

// Converts a decoded D3D11VA frame (an NV12 slice of the decoder's texture
// array) into a shareable BGRA texture via ID3D11VideoProcessor and exposes it
// as a stable DXGI *legacy* shared handle so a Flutter GpuSurfaceTexture can
// sample it with no CPU readback. Built lazily on the decoder's own D3D11
// device (the same device the decode textures live on — required for the
// VideoProcessor input view).
//
// Legacy handle, not NT: Flutter feeds the handle to ANGLE's share-handle
// pbuffer, which opens it with the legacy ID3D11Device::OpenSharedResource —
// an NT handle (MISC_SHARED_NTHANDLE + CreateSharedHandle) is rejected there
// with E_INVALIDARG and the picture silently composites black (verified
// on-device via LogSharedHandleDiagnostics). No keyed mutex either: ANGLE
// takes no part in the keyed-mutex handshake, so producer→consumer ordering
// is a Flush() at the end of Blit instead. Single-buffered: one shared BGRA
// texture, blitted in place each frame and handed out under the SAME handle
// every call (Flutter caches the opened resource by handle). Without a mutex
// a sample can theoretically race a blit and tear one preview frame; the
// pull-based one-frame-in-flight model makes that window tiny, and tearing
// beats black — double-buffering is the upgrade path if it shows. The handle
// is BORROWED from the texture (GetSharedHandle does not transfer ownership;
// closing it is invalid) and stays valid for the texture's lifetime. NOTE:
// this path needs on-device bring-up (color range / primaries below may need
// per-clip tuning); the RGBA readback path is the always-correct fallback.
struct D3D11Blitter {
  ComPtr<ID3D11VideoDevice> video_device;
  ComPtr<ID3D11VideoContext> video_context;
  ComPtr<ID3D11VideoProcessor> processor;
  ComPtr<ID3D11VideoProcessorEnumerator> enumerator;
  ComPtr<ID3D11Texture2D> texture;  // BGRA, legacy shared handle.
  ComPtr<ID3D11VideoProcessorOutputView> output_view;
  AVD3D11VADeviceContext* hwctx = nullptr;  // For the device-context lock.
  HANDLE shared = nullptr;  // Stable legacy shared handle (borrowed).
  int width = 0;            // display size — the shared output texture
  int height = 0;
  int coded_width = 0;  // decoder texture size (16-aligned, e.g. 1088 rows)
  int coded_height = 0;

  // [in_w]x[in_h] is the *coded* input size — the decoder's NV12 texture,
  // which H.264 16-aligns (1920x1080 content decodes as 1920x1088); the
  // caller reads it off the first decoded frame's texture desc. The shared
  // output texture stays at the display size [out_w]x[out_h] and the stream
  // source rect crops the alignment padding (mirrors the Media Foundation
  // controller's InitBlitter).
  bool Init(AVD3D11VADeviceContext* dev, int in_w, int in_h, int out_w,
            int out_h);
  // Blit the frame into the shared texture; returns the stable (borrowed)
  // handle, or nullptr on failure.
  HANDLE Blit(AVFrame* frame);
};

bool D3D11Blitter::Init(AVD3D11VADeviceContext* dev, int in_w, int in_h,
                        int out_w, int out_h) {
  hwctx = dev;
  width = out_w;
  height = out_h;
  coded_width = in_w;
  coded_height = in_h;

  // FFmpeg populates video_device / video_context on its D3D11VA device
  // context; fall back to a QueryInterface if a build ever leaves them null.
  video_device = dev->video_device;
  video_context = dev->video_context;
  if (!video_device &&
      FAILED(ComPtr<ID3D11Device>(dev->device).As(&video_device))) {
    return false;
  }
  if (!video_context && FAILED(ComPtr<ID3D11DeviceContext>(dev->device_context)
                                   .As(&video_context))) {
    return false;
  }

  D3D11_VIDEO_PROCESSOR_CONTENT_DESC content = {};
  content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
  content.InputWidth = static_cast<UINT>(in_w);
  content.InputHeight = static_cast<UINT>(in_h);
  content.OutputWidth = static_cast<UINT>(out_w);
  content.OutputHeight = static_cast<UINT>(out_h);
  content.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
  if (FAILED(video_device->CreateVideoProcessorEnumerator(&content,
                                                          &enumerator))) {
    return false;
  }
  if (FAILED(video_device->CreateVideoProcessor(enumerator.Get(), 0,
                                                &processor))) {
    return false;
  }
  // Input: decoded NV12 is studio (limited) range by convention, BT.709
  // matrix for HD / BT.601 for SD. Output: full-range RGB. Without the
  // explicit input color space the processor's defaults (driver-dependent,
  // often full-range) wash out or crush the levels. Best-effort defaults —
  // per-clip metadata (frame->color_range / colorspace) could refine them.
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE in_cs = {};
  in_cs.YCbCr_Matrix = (out_h >= 720) ? 1u : 0u;  // 1 = BT.709, 0 = BT.601
  in_cs.Nominal_Range = 1;  // D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235
  video_context->VideoProcessorSetStreamColorSpace(processor.Get(), 0, &in_cs);
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE out_cs = {};
  out_cs.RGB_Range = 0;  // full range
  video_context->VideoProcessorSetOutputColorSpace(processor.Get(), &out_cs);

  // Crop the coded frame to the display region (drops the 16-alignment
  // padding rows, e.g. 1088→1080) and map it onto the whole output. Without
  // the source rect the processor reads the full aligned surface and scales
  // the padding garbage into the picture.
  RECT display = {0, 0, out_w, out_h};
  video_context->VideoProcessorSetStreamSourceRect(processor.Get(), 0, TRUE,
                                                   &display);
  video_context->VideoProcessorSetStreamDestRect(processor.Get(), 0, TRUE,
                                                 &display);

  ComPtr<ID3D11Device> device(dev->device);
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = static_cast<UINT>(out_w);
  td.Height = static_cast<UINT>(out_h);
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  // Legacy sharing — see the struct comment for why NT handles + keyed
  // mutex black out under Flutter/ANGLE's OpenSharedResource consumer.
  td.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  if (FAILED(device->CreateTexture2D(&td, nullptr, &texture))) return false;

  D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd = {};
  ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
  ovd.Texture2D.MipSlice = 0;
  if (FAILED(video_device->CreateVideoProcessorOutputView(
          texture.Get(), enumerator.Get(), &ovd, &output_view))) {
    return false;
  }

  ComPtr<IDXGIResource> res;
  if (FAILED(texture.As(&res))) return false;
  if (FAILED(res->GetSharedHandle(&shared))) return false;
  LogSharedHandleDiagnostics(device.Get(), shared);
  return true;
}

HANDLE D3D11Blitter::Blit(AVFrame* frame) {
  // A D3D11VA frame stores the decoder's texture array in data[0] and the
  // slice index in data[1].
  auto* nv12 = reinterpret_cast<ID3D11Texture2D*>(frame->data[0]);
  const UINT slice =
      static_cast<UINT>(reinterpret_cast<intptr_t>(frame->data[1]));
  if (nv12 == nullptr) return nullptr;

  // The processor was enumerated for the first frame's coded size; a
  // mid-stream re-negotiation (rare) hands us a different texture. Bail to
  // the RGBA fallback rather than blit through a mismatched source rect.
  D3D11_TEXTURE2D_DESC in_td = {};
  nv12->GetDesc(&in_td);
  if (static_cast<int>(in_td.Width) != coded_width ||
      static_cast<int>(in_td.Height) != coded_height) {
    return nullptr;
  }

  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {};
  ivd.FourCC = 0;
  ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
  ivd.Texture2D.MipSlice = 0;
  ivd.Texture2D.ArraySlice = slice;
  ComPtr<ID3D11VideoProcessorInputView> input_view;
  if (FAILED(video_device->CreateVideoProcessorInputView(nv12, enumerator.Get(),
                                                         &ivd, &input_view))) {
    return nullptr;
  }

  // Serialize with the decode path's use of the (shared, not thread-safe)
  // device context. FFmpeg's D3D11VA device is multithread-protected, but the
  // documented contract is to take its lock around device-context use.
  if (hwctx->lock != nullptr) hwctx->lock(hwctx->lock_ctx);
  D3D11_VIDEO_PROCESSOR_STREAM stream = {};
  stream.Enable = TRUE;
  stream.pInputSurface = input_view.Get();
  const HRESULT blt = video_context->VideoProcessorBlt(
      processor.Get(), output_view.Get(), 0 /*OutputFrame*/, 1, &stream);
  // No keyed mutex on the legacy-shared texture (see the struct comment), so
  // Flush is the producer→consumer ordering: it submits the blit to the GPU
  // before Flutter's next sample of the shared texture.
  if (SUCCEEDED(blt)) hwctx->device_context->Flush();
  if (hwctx->unlock != nullptr) hwctx->unlock(hwctx->lock_ctx);
  // On a failed blit the shared texture holds a stale frame — report failure
  // so the caller falls back to the RGBA path instead of showing it.
  if (FAILED(blt)) return nullptr;
  return shared;
}
#endif  // _WIN32

VideoDecoder::VideoDecoder() = default;

VideoDecoder::~VideoDecoder() { Close(); }

void VideoDecoder::TryInitHardwareDecode(const AVCodec* decoder) {
  if (kHwDeviceType == AV_HWDEVICE_TYPE_NONE) return;  // No HW path on this OS.

  // Find the codec's HW config for this platform's device type (the FFmpeg
  // hw_decode.c pattern): a config offering a hw_device_ctx method for
  // kHwDeviceType names the surface pixel format we must pin in get_format
  // (AV_PIX_FMT_VIDEOTOOLBOX on macOS, AV_PIX_FMT_D3D11 on Windows).
  enum AVPixelFormat hw_pix = AV_PIX_FMT_NONE;
  for (int i = 0;; ++i) {
    const AVCodecHWConfig* cfg = avcodec_get_hw_config(decoder, i);
    if (cfg == nullptr) break;
    if ((cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 &&
        cfg->device_type == kHwDeviceType) {
      hw_pix = cfg->pix_fmt;
      break;
    }
  }
  if (hw_pix == AV_PIX_FMT_NONE) return;  // Codec has no HW path on this OS.

  if (av_hwdevice_ctx_create(&hw_device_ctx_, kHwDeviceType, nullptr, nullptr,
                             0) < 0) {
    hw_device_ctx_ = nullptr;  // Leave software decode in place.
    return;
  }
  codec_->hw_device_ctx = av_buffer_ref(hw_device_ctx_);
  codec_->opaque = this;
  codec_->get_format = PickHwFormat;
  // The decoder holds up to two decoded HW frames outside the codec (the
  // displayed frame_ plus the next_frame_ lookahead); reserve pool headroom
  // so a tightly-sized D3D11VA/VideoToolbox surface pool can't starve.
  codec_->extra_hw_frames = 2;
  hw_pix_fmt_ = static_cast<int>(hw_pix);
}

bool VideoDecoder::Open(const std::string& path) {
  Close();
  EnsureFfmpegLogRouting();

  if (avformat_open_input(&fmt_, path.c_str(), nullptr, nullptr) != 0) {
    return false;
  }
  // Discard non-video streams before probing so avformat_find_stream_info
  // doesn't parse them — in particular the IAMF audio track, whose
  // experimental FFmpeg parser logs "Underread in mix_presentation_obu" while
  // probing. (Streams whose type isn't known until probing fall through to the
  // post-find discard below.)
  for (unsigned i = 0; i < fmt_->nb_streams; ++i) {
    if (fmt_->streams[i]->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
      fmt_->streams[i]->discard = AVDISCARD_ALL;
    }
  }
  if (avformat_find_stream_info(fmt_, nullptr) < 0) {
    Close();
    return false;
  }

  const AVCodec* decoder = nullptr;
  video_stream_index_ =
      av_find_best_stream(fmt_, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0);
  if (video_stream_index_ < 0 || decoder == nullptr) {
    Close();
    return false;
  }

  // Keep only the selected video stream active for demuxing — catches any
  // stream the pre-probe pass left on (a second video track, or one whose type
  // resolved only during probing).
  for (unsigned i = 0; i < fmt_->nb_streams; ++i) {
    if (static_cast<int>(i) != video_stream_index_) {
      fmt_->streams[i]->discard = AVDISCARD_ALL;
    }
  }

  AVStream* stream = fmt_->streams[video_stream_index_];
  codec_ = avcodec_alloc_context3(decoder);
  if (codec_ == nullptr ||
      avcodec_parameters_to_context(codec_, stream->codecpar) < 0) {
    Close();
    return false;
  }
  // Attach VideoToolbox before opening. Best-effort: on failure the codec
  // opens for software decode and hw_pix_fmt_ stays -1.
  TryInitHardwareDecode(decoder);
  if (avcodec_open2(codec_, decoder, nullptr) < 0) {
    Close();
    return false;
  }

  frame_ = av_frame_alloc();
  decode_frame_ = av_frame_alloc();
  next_frame_ = av_frame_alloc();
  sw_frame_ = av_frame_alloc();
  rgba_ = av_frame_alloc();
  packet_ = av_packet_alloc();
  if (frame_ == nullptr || decode_frame_ == nullptr || next_frame_ == nullptr ||
      sw_frame_ == nullptr || rgba_ == nullptr || packet_ == nullptr) {
    Close();
    return false;
  }

  info_.width = codec_->width;
  info_.height = codec_->height;
  const AVRational fr = av_guess_frame_rate(fmt_, stream, nullptr);
  info_.fps = (fr.den != 0) ? static_cast<double>(fr.num) / fr.den : 0.0;
  if (stream->duration != AV_NOPTS_VALUE) {
    info_.duration_ms = static_cast<int64_t>(
        stream->duration * av_q2d(stream->time_base) * 1000.0);
  } else if (fmt_->duration != AV_NOPTS_VALUE) {
    info_.duration_ms = fmt_->duration / (AV_TIME_BASE / 1000);
  }
  // Portrait phone recordings store a landscape frame plus a display matrix
  // that rotates it (ES-796). Frames stay unrotated here; the app rotates the
  // picture when it draws it. A flipped matrix is left unrotated: the app has
  // no mirror transform, and reading the flip as a turn draws it upside down.
  const AVPacketSideData* side = av_packet_side_data_get(
      stream->codecpar->coded_side_data, stream->codecpar->nb_coded_side_data,
      AV_PKT_DATA_DISPLAYMATRIX);
  if (side != nullptr && side->size >= sizeof(int32_t[9])) {
    const auto* matrix = reinterpret_cast<const int32_t*>(side->data);
    const double ccw_degrees = av_display_rotation_get(matrix);
    char buf[128];
    if (IsMirrored(matrix)) {
      snprintf(buf, sizeof(buf),
               "display matrix is mirrored (read as %.1f deg); drawn unrotated",
               ccw_degrees);
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "video", buf);
    } else {
      info_.quarter_turns = QuarterTurnsClockwise(ccw_degrees);
      if (info_.quarter_turns != 0) {
        snprintf(buf, sizeof(buf),
                 "display matrix: %.1f deg ccw -> %d clockwise quarter turns",
                 ccw_degrees, info_.quarter_turns);
        engine_log(ECLIPSA_STUDIO_LOG_INFO, "video", buf);
      }
    }
  }
  info_.hw = hw_device_ctx_ != nullptr;
  info_.ok = true;
  return true;
}

bool VideoDecoder::DecodeAtSeconds(double seconds) {
  if (!info_.ok) return false;

  AVStream* stream = fmt_->streams[video_stream_index_];
  // PTS is measured from the stream's start_time, not necessarily 0
  // (common in MPEG-TS / some MP4).
  const int64_t start =
      (stream->start_time != AV_NOPTS_VALUE) ? stream->start_time : 0;
  const int64_t target_pts =
      start + static_cast<int64_t>(seconds / av_q2d(stream->time_base) + 0.5);

  // "One second" expressed in this stream's PTS ticks = den/num.
  const int64_t one_second_pts =
      (stream->time_base.num > 0)
          ? stream->time_base.den / stream->time_base.num
          : stream->time_base.den;

  // Seek backward to the nearest keyframe only when jumping back or far
  // forward; small forward steps decode on from the current position so
  // continuous playback doesn't re-seek every frame.
  const bool need_seek = last_pts_ == INT64_MIN || target_pts < last_pts_ ||
                         target_pts > last_pts_ + one_second_pts;
  if (need_seek) {
    if (av_seek_frame(fmt_, video_stream_index_, target_pts,
                      AVSEEK_FLAG_BACKWARD) < 0) {
      return false;
    }
    avcodec_flush_buffers(codec_);
    // The current and lookahead frames predate the seek: forget them so the
    // floor logic in DecodeForwardTo can't hand back a pre-seek frame.
    av_frame_unref(next_frame_);
    has_next_ = false;
    next_pts_ = INT64_MIN;
    last_pts_ = INT64_MIN;
  }

  return DecodeForwardTo(target_pts);
}

const uint8_t* VideoDecoder::FrameAtSeconds(double seconds, int* out_w,
                                            int* out_h, int* out_stride) {
  if (!DecodeAtSeconds(seconds)) return nullptr;

  // A HW-decoded frame lives in GPU/VideoToolbox memory; pull it down to
  // system memory (NV12/P010) before swscale. Software frames are already in
  // CPU memory and scale directly. Transferring only the kept frame here (not
  // every frame in DecodeForwardTo) avoids a GPU->CPU copy per decoded frame.
  AVFrame* cpu = frame_;
  if (frame_->format == hw_pix_fmt_) {
    av_frame_unref(sw_frame_);
    if (av_hwframe_transfer_data(sw_frame_, frame_, 0) < 0) return nullptr;
    cpu = sw_frame_;
  }
  if (!ScaleToRgba(cpu, out_stride)) return nullptr;

  if (out_w != nullptr) *out_w = info_.width;
  if (out_h != nullptr) *out_h = info_.height;
  return rgba_->data[0];
}

void* VideoDecoder::FrameAtSecondsPixbuf(double seconds, int* out_w,
                                         int* out_h) {
#ifdef __APPLE__
  // Zero-copy path: hand out the VideoToolbox CVPixelBuffer (IOSurface-backed)
  // for the decoded frame so a native FlutterTexture can sample it on the GPU
  // with no readback. Only HW frames carry one — for a software frame (an AV1
  // clip, or a mid-stream get_format fallback) return null and let the caller
  // fall back to the RGBA path. The returned buffer carries a +1 retain the
  // caller adopts (and must release, e.g. Swift Unmanaged.takeRetainedValue).
  if (!DecodeAtSeconds(seconds)) return nullptr;
  if (frame_->format != hw_pix_fmt_) return nullptr;  // software frame
  // FFmpeg stores the CVPixelBufferRef in data[3] for VideoToolbox frames.
  void* pixbuf = frame_->data[3];
  if (pixbuf == nullptr) return nullptr;
  CFRetain(static_cast<CFTypeRef>(pixbuf));
  if (out_w != nullptr) *out_w = info_.width;
  if (out_h != nullptr) *out_h = info_.height;
  return pixbuf;
#elif defined(_WIN32)
  // Zero-copy path: blit the decoded D3D11 NV12 surface into the blitter's
  // shared BGRA texture and hand out its stable DXGI legacy shared handle.
  // Only HW (D3D11VA) frames carry a D3D11 surface — a software frame
  // (AV1/dav1d, or a get_format fallback) returns null so the caller falls
  // back to the RGBA path. The handle is BORROWED from the texture and valid
  // for the blitter's lifetime; the caller must not close it, and
  // ReleasePixbuf is a no-op on Windows.
  if (!DecodeAtSeconds(seconds)) return nullptr;
  if (frame_->format != hw_pix_fmt_) return nullptr;  // software frame
  if (hw_device_ctx_ == nullptr) return nullptr;
  auto* devctx = reinterpret_cast<AVHWDeviceContext*>(hw_device_ctx_->data);
  auto* d3dctx = static_cast<AVD3D11VADeviceContext*>(devctx->hwctx);
  if (blitter_ == nullptr) {
    // The decoder's NV12 texture is coded-size (H.264 16-aligns rows:
    // 1920x1080 decodes as 1920x1088) — read the real size off this frame's
    // texture desc so the blitter can crop the alignment padding; the
    // shared output texture stays at the display size.
    auto* nv12 = reinterpret_cast<ID3D11Texture2D*>(frame_->data[0]);
    if (nv12 == nullptr) return nullptr;
    D3D11_TEXTURE2D_DESC in_td = {};
    nv12->GetDesc(&in_td);
    blitter_ = std::make_unique<D3D11Blitter>();
    if (!blitter_->Init(d3dctx, static_cast<int>(in_td.Width),
                        static_cast<int>(in_td.Height), info_.width,
                        info_.height)) {
      blitter_.reset();
      return nullptr;
    }
  }
  HANDLE shared = blitter_->Blit(frame_);
  if (shared == nullptr) return nullptr;
  if (out_w != nullptr) *out_w = info_.width;
  if (out_h != nullptr) *out_h = info_.height;
  return shared;
#else
  (void)seconds;
  (void)out_w;
  (void)out_h;
  return nullptr;
#endif
}

void VideoDecoder::ReleasePixbuf(void* pixbuf) {
#ifdef __APPLE__
  if (pixbuf != nullptr) CFRelease(static_cast<CFTypeRef>(pixbuf));
#else
  // Windows: the shared handle is borrowed (the decoder's D3D11Blitter owns it
  // and frees it on Close). Nothing to release here.
  (void)pixbuf;
#endif
}

bool VideoDecoder::DecodeForwardTo(int64_t target_pts) {
  // Floor semantics: the frame on screen at the target is the LAST frame
  // whose PTS is at or before it — returning the first frame at-or-after
  // instead would make the picture lead the audio clock by up to one frame
  // interval. The stream can't be stepped backward, so the first frame
  // decoded PAST the target is parked in next_frame_ (not discarded) and
  // promoted once a later call's target reaches its PTS.

  // Fast path: the current frame is still the one on screen (the lookahead
  // hasn't been reached). Common whenever ticks outpace the clip's fps.
  if (last_pts_ != INT64_MIN && last_pts_ <= target_pts && has_next_ &&
      next_pts_ > target_pts) {
    return true;
  }
  // The target has reached the lookahead: promote it to current.
  if (has_next_ && next_pts_ <= target_pts) {
    av_frame_unref(frame_);
    av_frame_move_ref(frame_, next_frame_);
    last_pts_ = next_pts_;
    has_next_ = false;
    next_pts_ = INT64_MIN;
  }

  bool draining = false;
  for (;;) {
    // Drain all pending decoded frames BEFORE sending more input: a previous
    // call may have returned with frames still queued (frame-threaded
    // decoders pipeline several), and avcodec_send_packet returns EAGAIN
    // until they are read — sending first would drop packets.
    for (;;) {
      const int recv = avcodec_receive_frame(codec_, decode_frame_);
      if (recv == AVERROR(EAGAIN)) break;  // decoder needs more input
      if (recv < 0) {
        // AVERROR_EOF (fully drained — past the last frame the closest one
        // stays on screen) or a decode error: keep the floor frame if any.
        return last_pts_ != INT64_MIN;
      }
      const int64_t pts = BestEffortPts(decode_frame_);
      if (pts > target_pts && last_pts_ != INT64_MIN) {
        // First frame past the target: frame_ already holds the floor frame.
        // Park this one for the next call — it can't be re-decoded.
        av_frame_unref(next_frame_);
        av_frame_move_ref(next_frame_, decode_frame_);
        next_pts_ = pts;
        has_next_ = true;
        return true;
      }
      // At/before the target: the new floor candidate. (Also taken when the
      // very first frame already lies past the target — with nothing earlier,
      // at-or-after is the best available — in which case the return below
      // fires immediately.)
      av_frame_unref(frame_);
      av_frame_move_ref(frame_, decode_frame_);
      last_pts_ = pts;
      if (pts >= target_pts) return true;
    }
    if (draining) return last_pts_ != INT64_MIN;  // no more output will come

    // Feed the decoder the next video packet, or start the EOF drain so the
    // final GOP's buffered frames come out (otherwise a seek into the last
    // GOP would render a stale earlier frame).
    for (;;) {
      if (av_read_frame(fmt_, packet_) < 0) {
        avcodec_send_packet(codec_, nullptr);
        draining = true;
        break;
      }
      if (packet_->stream_index != video_stream_index_) {
        av_packet_unref(packet_);
        continue;
      }
      const int send = avcodec_send_packet(codec_, packet_);
      av_packet_unref(packet_);
      // The receive loop above drained to EAGAIN, so EAGAIN can't happen
      // here; treat any send error as a corrupt packet and skip it.
      if (send == 0) break;
      if (send == AVERROR_EOF) {  // decoder already in drain mode
        draining = true;
        break;
      }
    }
  }
}

bool VideoDecoder::ScaleToRgba(AVFrame* src, int* out_stride) {
  // Uses the codec dimensions as the source size and allocates the RGBA
  // target once. Correct for fixed-resolution streams; a variable-resolution
  // or cropped stream would need per-frame source dims (src->width/height)
  // and reallocation — out of scope for this foundation, so reject a
  // mismatched frame rather than scale with wrong dimensions. [src] is the
  // CPU frame: frame_ for software decode, sw_frame_ (NV12/P010) after a HW
  // transfer; sws_getCachedContext re-derives on the source format.
  if (src->width != info_.width || src->height != info_.height) return false;
  sws_ = sws_getCachedContext(sws_, info_.width, info_.height,
                              static_cast<AVPixelFormat>(src->format),
                              info_.width, info_.height, AV_PIX_FMT_RGBA,
                              SWS_BILINEAR, nullptr, nullptr, nullptr);
  if (sws_ == nullptr) return false;

  if (rgba_->data[0] == nullptr) {
    if (av_image_alloc(rgba_->data, rgba_->linesize, info_.width, info_.height,
                       AV_PIX_FMT_RGBA, 1) < 0) {
      return false;
    }
  }
  sws_scale(sws_, src->data, src->linesize, 0, info_.height, rgba_->data,
            rgba_->linesize);
  if (out_stride != nullptr) *out_stride = rgba_->linesize[0];
  return true;
}

void VideoDecoder::Close() {
#ifdef _WIN32
  // Drop the D3D11 blitter (and its refs on the decoder's device) before the
  // codec / device context below.
  blitter_.reset();
#endif
  if (sws_ != nullptr) {
    sws_freeContext(sws_);
    sws_ = nullptr;
  }
  if (rgba_ != nullptr && rgba_->data[0] != nullptr) {
    av_freep(&rgba_->data[0]);
  }
  if (packet_ != nullptr) av_packet_free(&packet_);
  if (frame_ != nullptr) av_frame_free(&frame_);
  if (decode_frame_ != nullptr) av_frame_free(&decode_frame_);
  if (next_frame_ != nullptr) av_frame_free(&next_frame_);
  if (sw_frame_ != nullptr) av_frame_free(&sw_frame_);
  if (rgba_ != nullptr) av_frame_free(&rgba_);
  // Free the codec (drops its ref on the device) before the device itself.
  if (codec_ != nullptr) avcodec_free_context(&codec_);
  if (hw_device_ctx_ != nullptr) av_buffer_unref(&hw_device_ctx_);
  if (fmt_ != nullptr) avformat_close_input(&fmt_);
  video_stream_index_ = -1;
  hw_pix_fmt_ = -1;
  last_pts_ = INT64_MIN;
  next_pts_ = INT64_MIN;
  has_next_ = false;
  info_ = VideoInfo{};
}

}  // namespace eclipsa_studio::video
