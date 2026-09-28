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

#ifndef ECLIPSA_STUDIO_VIDEO_VIDEO_FFI_H_
#define ECLIPSA_STUDIO_VIDEO_VIDEO_FFI_H_

// C FFI surface for the FFmpeg-in-engine video decoder (issue ES-249, step 5).
// The stable contract Dart binds via dart:ffi: open a file, query info, pull
// the RGBA frame nearest a presentation time, close. "Frame at time T" is the
// engine-clock-driven primitive the Flutter Texture renders each tick.
//
// Linked into the engine shared library (//video:video_ffi is a dep of
// //:eclipsa_studio_engine) and bound from Dart in
// app/lib/video/ffmpeg_video_ffi. See video/README.md.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EclipsaStudioVideoDecoder EclipsaStudioVideoDecoder;

typedef struct {
  int width;
  int height;
  double fps;
  int64_t duration_ms;
  int ok;  // 0 = failed to open / no video stream.
  int hw;  // 1 = a HW decoder (VideoToolbox/D3D11VA) is attached; 0 = software.
  // Clockwise quarter turns (0-3) the frame needs for display, from the
  // container's display matrix. width / height are the stored frame size,
  // and frames are returned unrotated.
  int quarter_turns;
} EclipsaStudioVideoInfo;

// Open [path]; returns an opaque decoder handle or null on failure.
EclipsaStudioVideoDecoder* eclipsa_studio_video_open(const char* path);

// Stream info for [dec]; .ok == 0 if [dec] is null or unopened.
EclipsaStudioVideoInfo eclipsa_studio_video_info(
    EclipsaStudioVideoDecoder* dec);

// Decode the frame nearest [seconds] into an RGBA8888 buffer owned by [dec]
// (valid until the next call or eclipsa_studio_video_close). Writes width /
// height / row-stride through the out-params. Returns the buffer, or null on
// failure.
const uint8_t* eclipsa_studio_video_frame_at_seconds(
    EclipsaStudioVideoDecoder* dec, double seconds, int* out_w, int* out_h,
    int* out_stride);

// Zero-copy path: decode the frame nearest [seconds] and return an opaque
// native GPU surface handle for a native FlutterTexture to sample with no
// readback. Writes width / height. Returns null when the frame is software-
// decoded (no HW surface) or on failure — callers fall back to
// eclipsa_studio_video_frame_at_seconds.
//   * macOS: a VideoToolbox CVPixelBuffer with a +1 retain the caller owns
//     (balance with eclipsa_studio_video_release_pixbuf or by adopting it
//     natively).
//   * Windows: a stable DXGI legacy shared handle borrowed from the decoder's
//     blitter texture (valid for its lifetime) — the caller must not close it.
void* eclipsa_studio_video_frame_at_seconds_pixbuf(
    EclipsaStudioVideoDecoder* dec, double seconds, int* out_w, int* out_h);

// Release a handle from eclipsa_studio_video_frame_at_seconds_pixbuf
// (null-safe). macOS: CFRelease the CVPixelBuffer (only for a handle obtained
// but never adopted by the texture side — a teardown race). Windows: a no-op
// (the handle is borrowed, not owned by the caller).
void eclipsa_studio_video_release_pixbuf(void* pixbuf);

// Close and free [dec] (null-safe).
void eclipsa_studio_video_close(EclipsaStudioVideoDecoder* dec);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ECLIPSA_STUDIO_VIDEO_VIDEO_FFI_H_
