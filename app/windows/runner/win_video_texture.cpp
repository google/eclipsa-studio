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

#include "win_video_texture.h"

int64_t WinGpuSurfaceSink::Register(flutter::TextureRegistrar* registrar) {
  if (registrar == nullptr) return -1;
  Unregister();
  registrar_ = registrar;
  state_ = std::make_shared<State>();
  // The callback captures the shared State, NOT `this`: the sink may be
  // destroyed (with its owning player) right after Unregister(), while the
  // raster thread keeps calling in until the async unregister completes.
  std::shared_ptr<State> state = state_;
  texture_ = std::make_unique<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(
          kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
          [state](size_t w, size_t h) { return state->ObtainDescriptor(w, h); }));
  texture_id_ = registrar_->RegisterTexture(texture_.get());
  return texture_id_;
}

void WinGpuSurfaceSink::Present(HANDLE handle, int width, int height) {
  if (state_ != nullptr) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->handle = handle;
    state_->width = width;
    state_->height = height;
  }
  if (registrar_ != nullptr && texture_id_ >= 0) {
    registrar_->MarkTextureFrameAvailable(texture_id_);
  }
}

void WinGpuSurfaceSink::Unregister() {
  if (state_ != nullptr) {
    // Drop the handle first so any in-flight ObtainDescriptor returns nullptr
    // instead of a handle we're about to release ownership of.
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->handle = nullptr;
  }
  if (registrar_ != nullptr && texture_id_ >= 0) {
    // UnregisterTexture is asynchronous: the raster thread may still invoke
    // the GpuSurfaceTexture callback (which reads State) until the completion
    // fires. Keep both the TextureVariant and the State alive until then; the
    // sink itself is free to die as soon as this returns.
    std::shared_ptr<flutter::TextureVariant> keep_texture(texture_.release());
    std::shared_ptr<State> keep_state = state_;
    registrar_->UnregisterTexture(
        texture_id_, [keep_texture, keep_state]() mutable {
          keep_texture.reset();
          keep_state.reset();
        });
  }
  texture_id_ = -1;
  registrar_ = nullptr;
  texture_.reset();
  state_.reset();
}

const FlutterDesktopGpuSurfaceDescriptor*
WinGpuSurfaceSink::State::ObtainDescriptor(size_t /*width*/,
                                           size_t /*height*/) {
  std::lock_guard<std::mutex> lock(mutex);
  if (handle == nullptr) return nullptr;
  descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  descriptor.handle = handle;
  descriptor.width = descriptor.visible_width = static_cast<size_t>(width);
  descriptor.height = descriptor.visible_height = static_cast<size_t>(height);
  descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
  // Handle is borrowed (producer-owned, kept valid across frames), so no
  // per-open release is needed.
  descriptor.release_callback = nullptr;
  descriptor.release_context = nullptr;
  return &descriptor;
}
