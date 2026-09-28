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

#ifndef ECLIPSA_STUDIO_VIDEO_VIDEO_DECODER_H_
#define ECLIPSA_STUDIO_VIDEO_VIDEO_DECODER_H_

// FFmpeg-in-engine video decoder (issue ES-249, step 5 — FOUNDATION / WIP).
//
// The architectural endgame from ES-249: the C++ engine decodes video
// (LGPL FFmpeg + a hardware decoder per platform) and exposes "frame at
// time T" so Flutter can render a Texture driven by the engine clock — one
// shared decode/seek core, only the HW-device type and texture bridge differ
// per platform.
//
// STATUS: hardware decode with a software fallback. FFmpeg send-packet/
// receive-frame plus RGBA scaling via swscale (developed on 5/6, builds on 8).
// A hw_device_ctx is attached when the codec supports it (issue ES-249, step 5,
// HW-decode phase) — VideoToolbox on macOS, D3D11VA on Windows: frames decode
// on the GPU/ASIC and are pulled down to system memory (av_hwframe_transfer_
// data) before swscale. Anything the HW decoder can't take — no HW config,
// device-create failure, an AV1 stream (dav1d) — decodes in software
// transparently. A zero-copy texture bridge that keeps the frame on the GPU is
// the fast path: on macOS the VideoToolbox CVPixelBuffer is handed straight to
// a FlutterTexture; on Windows the decoded D3D11 NV12 surface is converted to a
// shareable BGRA texture (ID3D11VideoProcessor) and handed over as a DXGI
// legacy shared handle. See video/README.md. The Bazel targets stay tagged
// `manual` so the `//...` wildcard doesn't build them standalone — they build
// transitively via //:eclipsa_studio_engine.
//
// The FFmpeg-free posture of the engine is being reversed deliberately here
// (LGPL FFmpeg, dynamically linked, no --enable-gpl) per the maintainer
// decision on ES-249 open decision #2.

#include <cstdint>
#include <memory>
#include <string>

struct AVFormatContext;
struct AVCodecContext;
struct AVCodec;
struct AVFrame;
struct AVPacket;
struct AVBufferRef;
struct SwsContext;

namespace eclipsa_studio::video {

// Windows-only D3D11 NV12→BGRA blitter that turns a decoded D3D11VA frame into
// a shareable BGRA texture and hands out a DXGI legacy shared handle for the
// zero-copy texture path. Opaque here (PImpl) so this header stays free of
// <d3d11.h>; defined in video_decoder.cc under _WIN32.
struct D3D11Blitter;

struct VideoInfo {
  int width = 0;
  int height = 0;
  double fps = 0.0;
  int64_t duration_ms = 0;
  bool ok = false;
  // A hardware decoder (VideoToolbox on macOS, D3D11VA on Windows) is attached
  // for this stream. False means software decode — either the codec has no HW
  // config, the HW device failed to create, or the format is HW-unsupported
  // (e.g. AV1/dav1d). Best-effort: attached is not a guarantee — get_format
  // can still fall back to software mid-negotiation (logged as a warning),
  // in which case the per-frame format checks route to the software path and
  // the zero-copy caller downgrades to the RGBA path.
  bool hw = false;
  // Clockwise quarter turns (0-3) the frame needs for display, from the
  // stream's display matrix; 0 when the matrix flips the picture. Width and
  // height are the stored (unrotated) frame size; frames are returned
  // unrotated.
  int quarter_turns = 0;
};

// Decodes a single video stream and produces the RGBA frame on screen at a
// requested presentation time (the last frame whose PTS is at or before it).
// Not thread-safe; drive it from one thread (the Dart control thread via
// FFI).
class VideoDecoder {
 public:
  // Constructor and destructor are defined out-of-line in the .cc, where the
  // Windows PImpl (D3D11Blitter) is a complete type — required because
  // unique_ptr<D3D11Blitter> can't be default-constructed or destroyed against
  // an incomplete type (video_ffi.cc includes only this header).
  VideoDecoder();
  ~VideoDecoder();

  VideoDecoder(const VideoDecoder&) = delete;
  VideoDecoder& operator=(const VideoDecoder&) = delete;

  // Open [path] and find the first video stream. Returns false on failure.
  bool Open(const std::string& path);

  const VideoInfo& Info() const { return info_; }

  // Decode the frame at [seconds] into an internal RGBA8888 buffer. Returns
  // a pointer to that buffer (owned by this; valid until the next call or
  // destruction) and writes the dimensions / row stride. Returns nullptr on
  // failure. Seeks backward to the nearest keyframe then decodes forward to
  // the target PTS, so successive forward requests are cheap.
  const uint8_t* FrameAtSeconds(double seconds, int* out_w, int* out_h,
                                int* out_stride);

  // Zero-copy path: decode the frame at [seconds] and return an opaque native
  // GPU surface handle for a native texture to sample with no CPU readback, or
  // null when the frame is software-decoded (no HW surface) or on failure — the
  // caller then falls back to [FrameAtSeconds]. Writes width / height.
  //   * macOS: the VideoToolbox CVPixelBuffer (IOSurface-backed), carrying a +1
  //     retain the caller owns — balance it with [ReleasePixbuf] (or by
  //     adopting it on the native texture side).
  //   * Windows: a stable DXGI *legacy* shared handle (HANDLE) to the
  //     blitter's BGRA texture, which the decoder blitted the D3D11 NV12
  //     surface into (legacy, not NT: Flutter/ANGLE opens it via the legacy
  //     OpenSharedResource, which rejects NT handles — see D3D11Blitter).
  //     The blit is Flushed before return so the consumer samples the new
  //     frame. The handle is BORROWED from the texture and valid for the
  //     blitter's lifetime; the caller must NOT close it.
  void* FrameAtSecondsPixbuf(double seconds, int* out_w, int* out_h);

  // Release a handle previously returned by [FrameAtSecondsPixbuf] (null-safe).
  // macOS: CFRelease the CVPixelBuffer (only needed when a buffer is obtained
  // but never adopted by the texture side, e.g. a teardown race). Windows:
  // a no-op — the Windows handle is borrowed, not owned by the caller.
  static void ReleasePixbuf(void* pixbuf);

  void Close();

  // The pixel format the attached hardware decoder emits (AV_PIX_FMT_*),
  // stored as int to keep this header free of FFmpeg includes. -1
  // (AV_PIX_FMT_NONE) when decoding in software. Read by the get_format
  // callback to pin the HW format; see PickHwFormat in the .cc.
  int hw_pix_fmt() const { return hw_pix_fmt_; }

 private:
  // Seek (when needed) and decode forward so the frame on screen at [seconds]
  // (floor: last PTS <= target) is in frame_. Shared by the RGBA and
  // pixel-buffer paths. Returns false on failure / no clip open.
  bool DecodeAtSeconds(double seconds);
  bool DecodeForwardTo(int64_t target_pts);
  // Scale [src] (the CPU-side decoded frame) into rgba_. [src] is frame_ for a
  // software decode, or sw_frame_ after a HW frame is transferred down.
  bool ScaleToRgba(AVFrame* src, int* out_stride);
  // Attach the platform hw_device_ctx (VideoToolbox on macOS, D3D11VA on
  // Windows) to codec_ when [decoder] advertises a matching HW config.
  // Best-effort: leaves software decode in place (and hw_pix_fmt_ == -1) on any
  // failure. Must run before avcodec_open2.
  void TryInitHardwareDecode(const AVCodec* decoder);

  AVFormatContext* fmt_ = nullptr;
  AVCodecContext* codec_ = nullptr;
  AVFrame* frame_ = nullptr;  // Current (displayed) frame; PTS = last_pts_.
  AVFrame* decode_frame_ = nullptr;  // Receive target for the decode loop.
  // Lookahead: the first frame decoded PAST the current target. The stream
  // can't be stepped backward, so DecodeForwardTo parks it here instead of
  // discarding it and promotes it to frame_ once the target reaches its PTS.
  AVFrame* next_frame_ = nullptr;
  int64_t next_pts_ = INT64_MIN;
  bool has_next_ = false;
  AVFrame* sw_frame_ = nullptr;  // CPU copy of a HW frame (transfer target).
  AVFrame* rgba_ = nullptr;
  AVPacket* packet_ = nullptr;
  SwsContext* sws_ = nullptr;
  AVBufferRef* hw_device_ctx_ = nullptr;  // HW decode device; null if SW.
  int video_stream_index_ = -1;
  int hw_pix_fmt_ = -1;           // AV_PIX_FMT_NONE
  int64_t last_pts_ = INT64_MIN;  // PTS of frame_; INT64_MIN = no frame yet.
  VideoInfo info_;
#ifdef _WIN32
  // Lazily created on the first Windows zero-copy request; converts the decoded
  // D3D11 NV12 surface to a shareable BGRA texture. Null under software decode.
  std::unique_ptr<D3D11Blitter> blitter_;
#endif
};

}  // namespace eclipsa_studio::video

#endif  // ECLIPSA_STUDIO_VIDEO_VIDEO_DECODER_H_
