# FFmpeg-in-engine video decode (ES-249, step 5)

The architectural endgame from the pluggable-video-backend plan: the C++
engine decodes video and exposes **"frame at time T"** over a C FFI, so
Flutter renders the picture driven by the engine clock — one shared
decode/seek core, with only the hardware-decoder type and (eventually)
the zero-copy texture bridge differing per platform.

**Status: hardware decode (VideoToolbox) with a software fallback, wired
end-to-end and selectable.** `video_ffi` is linked into `//:eclipsa_studio_engine`,
bound from Dart in `app/lib/video/ffmpeg_video_ffi.dart`, and driven by
`FfmpegEngineBackend` (`app/lib/video/ffmpeg_engine_backend.dart`) — a
pull-based `VideoBackend`. It appears in Settings → Video backend as **FFmpeg**
on macOS (Windows is a follow-up). On macOS the decoder attaches a VideoToolbox
`hw_device_ctx` when the codec advertises one (H.264 / HEVC / ProRes); anything
VideoToolbox can't take (AV1 → dav1d, device-create failure) decodes in
software transparently. The `eclipsa_studio_video_info` FFI reports which path engaged
(`hw`), logged on load.

The backend renders in one of two modes, per clip: a **zero-copy texture**
path for HW clips (pending on-device validation) — the VideoToolbox
`CVPixelBuffer` (native NV12) is handed to a native `FlutterTexture`
(`macos/Runner/FfmpegVideoController.swift`, on the `eclipsa/ffmpeg_video`
channel, registered in the main and pop-out windows), converted to BGRA on the
GPU via CoreImage (Flutter samples 32BGRA), and sampled with no CPU readback;
and an **image** fallback for software clips (or any build without the native
plugin) — the engine returns a CPU RGBA buffer (`av_hwframe_transfer_data` +
swscale for a HW frame) painted as a `ui.Image`. Forcing a BGRA *decode* frame
pool in the engine was tried and abandoned — `av_hwframe_ctx_init` rejects it
for VideoToolbox and silently drops the codec to software — so the conversion
lives on the texture side. Remaining: the Windows build and unit tests (below).

## Posture change

The engine was deliberately FFmpeg-free (the bundled GPAC was built
`--use-curl=no`, no FFmpeg/x264). Per the maintainer decision on ES-249 open
decision #2, this reverses that: **LGPL FFmpeg, dynamically linked, no
`--enable-gpl`**. FFmpeg (+ dav1d) is vendored the same way as GPAC — a
pinned, minimal, LGPL build produced by
[`../deps/ffmpeg/build_ffmpeg.sh`](../deps/ffmpeg/README.md),
`cc_import`-ed with `@rpath` install names and shipped inside the app bundle's
`Frameworks/`. No system FFmpeg is needed at build or run time.

## What's here

| File | Role |
|---|---|
| `video_decoder.{h,cc}` | `eclipsa_studio::video::VideoDecoder` — FFmpeg demux + decode + swscale → RGBA8888, with backward-keyframe-seek then decode-forward to the target PTS. |
| `video_ffi.{h,cc}` | `extern "C"` FFI: `eclipsa_studio_video_open` / `_info` / `_frame_at_seconds` / `_close`. The stable contract Dart binds. |
| `BUILD.bazel` | `video_decoder` + `video_ffi` cc_libraries (`manual`, but built via the engine's per-OS dep on `video_ffi` — macOS and Windows). |
| `../deps/ffmpeg/` | the vendored LGPL FFmpeg + dav1d: `build_ffmpeg.sh`, `cc_import` `BUILD.bazel`, `NOTICE` / license texts. |

The Dart side: `app/lib/video/ffmpeg_video_ffi.dart` (FFI bindings + a decode
isolate) and `app/lib/video/ffmpeg_engine_backend.dart` (the pull-based
`FfmpegEngineBackend`, rendering each frame as a `ui.Image` in a `RawImage`).

## Remaining work

1. ~~**Hardware decode**~~ — done on macOS: a VideoToolbox `hw_device_ctx` is
   attached in `VideoDecoder::TryInitHardwareDecode` when the codec advertises
   an `AV_HWDEVICE_TYPE_VIDEOTOOLBOX` config, with a `get_format` callback
   pinning the surface format and `av_hwframe_transfer_data` pulling frames
   down for swscale. D3D11VA (Windows) landed with the Windows item below (ES-262).
2. ~~**Zero-copy texture bridge**~~ — done on macOS via the native
   `FlutterTexture` registry (the `AvfVideoController.swift` pattern):
   `FrameAtSecondsPixbuf` hands out the retained VideoToolbox `CVPixelBuffer`
   over the `eclipsa_studio_video_frame_at_seconds_pixbuf` FFI,
   `FfmpegVideoController.swift` converts it to BGRA on the GPU (CoreImage) and
   vends it as a texture, and `FfmpegEngineBackend` drives it (image-path
   fallback for software frames). **Pending on-device validation** — see the
   test-plan checklist. The Windows path (DXGI shared handle,
   flutter/flutter#121046) landed with the Windows item below (ES-262).
3. ~~**Windows**~~ — done (ES-262, **pending on-device validation**). A vendored
   Windows LGPL FFmpeg build (`build_ffmpeg.ps1` + `build.ps1 Ensure-Ffmpeg`)
   feeds the engine's Windows `select()` on `//video:video_ffi` (exports listed
   in `eclipsa_studio_engine_exports.def`); `TryInitHardwareDecode` attaches D3D11VA and
   `FrameAtSecondsPixbuf` blits the decoded NV12 surface to a shareable BGRA
   texture handed over as a DXGI *legacy* shared handle
   (`ID3D11VideoProcessor`, `Flush()`-ordered — NT handles are rejected by
   Flutter/ANGLE's legacy `OpenSharedResource` consumer and composite black).
   The native `ffmpeg_video_controller.{h,cpp}` vends it as a Flutter
   `GpuSurfaceTexture`. `VideoBackendKind.ffmpegEngine.supportedOs` now includes
   Windows.
4. **Unit tests** under `//test`, and on-device A/V-lock / teardown
   validation (incl. the pop-out window and backend hot-swap).

Once the texture path lands and the FFmpeg backend matches AVFoundation on the
video-backend benchmark, the experimental fvp/libmdk backend (ES-249 step 4)
can be retired — it exists only as an evaluation alternative and carries a
proprietary binary + watermark caveat.
