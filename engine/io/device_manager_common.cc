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

// Backend-independent DeviceManager logic: device selection,
// name-based remapping across re-enumeration, and the channel-count
// fallback ladder. The platform backend (device_manager_coreaudio.cc /
// device_manager_wasapi.cc) implements enumerate(), start(), stop()
// and query_hardware_sample_rate().

#include <cstdio>

#include "engine_log.h"
#include "io/device_manager.h"

bool DeviceManager::refresh() {
  std::string selected_name;
  if (selected_index_ < devices_.size()) {
    selected_name = devices_[selected_index_].name;
  }
  if (!enumerate()) return false;
  if (!selected_name.empty()) {
    for (uint32_t i = 0; i < devices_.size(); ++i) {
      if (devices_[i].name == selected_name) {
        selected_index_ = i;
        return true;
      }
    }
    char buf[160];
    snprintf(buf, sizeof(buf),
             "refresh: selected device '%s' disappeared, falling back to "
             "default",
             selected_name.c_str());
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "device", buf);
  }
  selected_index_ = ResolveSelectedIndex(devices_, UINT32_MAX);
  return true;
}

const std::string& DeviceManager::device_name(uint32_t index) const {
  static const std::string empty{};
  if (index < devices_.size()) return devices_[index].name;
  return empty;
}

const std::string& DeviceManager::output_channel_name(uint32_t channel) const {
  static const std::string empty{};
  if (!running_ || channel >= channel_names_.size()) return empty;
  return channel_names_[channel];
}

bool DeviceManager::select_device(uint32_t index) {
  if (index >= devices_.size()) return false;
  selected_index_ = index;
  return true;
}

uint32_t DeviceManager::channel_count() const {
  if (running_ && open_channels_ > 0) return open_channels_;
  if (selected_index_ < devices_.size()) {
    return devices_[selected_index_].channel_count;
  }
  return 2;
}

uint32_t DeviceManager::ResolveSelectedIndex(
    const std::vector<DeviceInfo>& devices, uint32_t selected_index) {
  if (selected_index < devices.size()) return selected_index;
  for (uint32_t i = 0; i < devices.size(); ++i) {
    if (devices[i].is_default) return i;
  }
  return UINT32_MAX;
}
