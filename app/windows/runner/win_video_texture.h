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

#ifndef RUNNER_WIN_VIDEO_TEXTURE_H_
#define RUNNER_WIN_VIDEO_TEXTURE_H_

#include <windows.h>

#include <flutter/texture_registrar.h>

#include <cstdint>
#include <memory>
#include <mutex>

// A Flutter GPU-surface texture sink fed by DXGI *legacy* shared handles.
// Shared by the FFmpeg-in-engine (eclipsa/ffmpeg_video) and native Media
// Foundation (eclipsa/mf_video) Windows video backends: both produce a BGRA
// D3D11 texture and hand its shared handle here each frame; this registers a
// Flutter GpuSurfaceTexture (kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle)
// and forwards the handle to Flutter's zero-copy DXGI-shared-handle path —
// no CPU readback. The handle must be a legacy share handle (MISC_SHARED +
// GetSharedHandle): Flutter/ANGLE opens it with the legacy
// OpenSharedResource, which rejects NT handles with E_INVALIDARG (silent
// black picture — verified on-device).
//
// The handle is BORROWED: the producer owns the underlying texture and the
// handle stays valid for the texture's lifetime; this sink never closes it.
// The producer orders its writes against Flutter's reads with a Flush()
// after each blit (no keyed mutex — ANGLE doesn't participate).
class WinGpuSurfaceSink {
 public:
  WinGpuSurfaceSink() = default;
  ~WinGpuSurfaceSink() { Unregister(); }

  WinGpuSurfaceSink(const WinGpuSurfaceSink&) = delete;
  WinGpuSurfaceSink& operator=(const WinGpuSurfaceSink&) = delete;

  // Register a GpuSurfaceTexture on [registrar] and return its id (>= 0), or -1
  // on failure. Replaces any previously registered texture.
  int64_t Register(flutter::TextureRegistrar* registrar);

  // Publish the newest frame: [handle] is a DXGI legacy shared handle to a
  // BGRA texture of [width]x[height]. Borrowed — must stay valid until the
  // next Present or Unregister.
  void Present(HANDLE handle, int width, int height);

  // Unregister the texture and drop the current handle (idempotent).
  void Unregister();

  int64_t texture_id() const { return texture_id_; }

 private:
  // Everything the raster-thread callback touches, heap-owned via shared_ptr
  // so it can outlive the sink itself: UnregisterTexture is asynchronous, and
  // Flutter's raster thread may still invoke the GpuSurfaceTexture callback
  // after Unregister() returns. The sink may be a member of a transient
  // player (the MF backend's per-clip player) destroyed right after
  // Unregister(), so the callback must not capture `this` — it captures this
  // State, and the unregister completion holds the last reference until
  // Flutter is done sampling.
  struct State {
    // Raster-thread callback: hand Flutter the current shared handle, or
    // nullptr when no frame has been presented (or Unregister dropped it).
    const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor(size_t width,
                                                               size_t height);

    std::mutex mutex;         // guards handle/width/height (platform vs raster)
    HANDLE handle = nullptr;  // borrowed
    int width = 0;
    int height = 0;
    // Filled and returned only from ObtainDescriptor (single raster thread).
    FlutterDesktopGpuSurfaceDescriptor descriptor = {};
  };

  flutter::TextureRegistrar* registrar_ = nullptr;
  std::unique_ptr<flutter::TextureVariant> texture_;
  std::shared_ptr<State> state_;
  int64_t texture_id_ = -1;
};

#endif  // RUNNER_WIN_VIDEO_TEXTURE_H_
