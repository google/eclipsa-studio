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

#include "ffmpeg_video_controller.h"

#include <cstdint>
#include <string>
#include <variant>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;

// Read an integer from the args map, tolerating either int or double encoding
// (Dart ints arrive as int64, but a value that was a double round-trips too).
bool GetInt(const EncodableMap& map, const char* key, int64_t* out) {
  auto it = map.find(EncodableValue(std::string(key)));
  if (it == map.end()) return false;
  if (const auto* i = std::get_if<int64_t>(&it->second)) {
    *out = *i;
    return true;
  }
  if (const auto* i = std::get_if<int32_t>(&it->second)) {
    *out = *i;
    return true;
  }
  if (const auto* d = std::get_if<double>(&it->second)) {
    *out = static_cast<int64_t>(*d);
    return true;
  }
  return false;
}
}  // namespace

FfmpegVideoPlugin::FfmpegVideoPlugin(flutter::BinaryMessenger* messenger,
                                     flutter::TextureRegistrar* textures)
    : textures_(textures) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "eclipsa/ffmpeg_video",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

FfmpegVideoPlugin::~FfmpegVideoPlugin() = default;

void FfmpegVideoPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());

  if (method == "create") {
    // Dart passes the clip's pixel dimensions so the GPU-surface descriptor can
    // report the physical texture size (present carries only the handle).
    int64_t w = 0, h = 0;
    if (args != nullptr) {
      GetInt(*args, "width", &w);
      GetInt(*args, "height", &h);
    }
    width_ = static_cast<int>(w);
    height_ = static_cast<int>(h);
    const int64_t id = sink_.Register(textures_);
    if (id < 0) {
      result->Error("register_failed", "could not register a video texture");
      return;
    }
    result->Success(EncodableValue(
        EncodableMap{{EncodableValue("textureId"), EncodableValue(id)}}));
    return;
  }

  if (method == "present") {
    int64_t addr = 0;
    if (args == nullptr || !GetInt(*args, "buffer", &addr) || addr == 0) {
      result->Error("bad_args", "buffer address required");
      return;
    }
    // The engine handed Dart a stable DXGI legacy shared handle (borrowed —
    // it stays valid for the engine's blitter texture's lifetime). Forward
    // it to the texture; the engine Flushes each blit before returning the
    // handle, so no adopt/retain or sync is needed here.
    sink_.Present(reinterpret_cast<HANDLE>(static_cast<intptr_t>(addr)), width_,
                  height_);
    result->Success();
    return;
  }

  if (method == "dispose") {
    sink_.Unregister();
    result->Success();
    return;
  }

  result->NotImplemented();
}
