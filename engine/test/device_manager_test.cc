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

#include "io/device_manager.h"

#include <cstdint>
#include <vector>

#include "gtest/gtest.h"

namespace {

using DeviceInfo = DeviceManager::DeviceInfo;

DeviceInfo MakeDevice(const char* name, bool is_default) {
  DeviceInfo d;
  d.name = name;
  d.is_default = is_default;
  return d;
}

// Explicit, in-range selection is preserved verbatim — the helper must
// not second-guess a user's device choice even when another device is
// marked default.
TEST(ResolveSelectedIndex, ReturnsExplicitInRangeIndex) {
  std::vector<DeviceInfo> devices = {
      MakeDevice("Built-in Output", true),
      MakeDevice("MOTU MicroBook II", false),
      MakeDevice("AirPods", false),
  };
  EXPECT_EQ(DeviceManager::ResolveSelectedIndex(devices, 1), 1u);
  EXPECT_EQ(DeviceManager::ResolveSelectedIndex(devices, 2), 2u);
}

// Sentinel UINT32_MAX ("system default") resolves to the first device
// whose is_default flag is set.
TEST(ResolveSelectedIndex, ResolvesSentinelToDefaultDevice) {
  std::vector<DeviceInfo> devices = {
      MakeDevice("MOTU MicroBook II", false),
      MakeDevice("Built-in Output", true),
      MakeDevice("AirPods", false),
  };
  EXPECT_EQ(DeviceManager::ResolveSelectedIndex(devices, UINT32_MAX), 1u);
}

// An out-of-range explicit index (e.g. stale saved preference whose
// device has since disappeared) falls back to the default device.
TEST(ResolveSelectedIndex, ResolvesOutOfRangeToDefaultDevice) {
  std::vector<DeviceInfo> devices = {
      MakeDevice("Built-in Output", true),
      MakeDevice("MOTU MicroBook II", false),
  };
  EXPECT_EQ(DeviceManager::ResolveSelectedIndex(devices, 99), 0u);
}

// If no device reports is_default, the helper returns UINT32_MAX so
// the caller falls back to the backend's notion of the system default —
// rather than silently selecting devices[0], which is not necessarily
// the system default.
TEST(ResolveSelectedIndex, NoDefaultDeviceReturnsSentinel) {
  std::vector<DeviceInfo> devices = {
      MakeDevice("MOTU MicroBook II", false),
      MakeDevice("AirPods", false),
  };
  EXPECT_EQ(DeviceManager::ResolveSelectedIndex(devices, UINT32_MAX),
            UINT32_MAX);
}

// Empty device list returns UINT32_MAX; the start() caller is
// expected to short-circuit before getting here, but the helper
// should still produce a defined result.
TEST(ResolveSelectedIndex, EmptyDeviceListReturnsSentinel) {
  std::vector<DeviceInfo> devices;
  EXPECT_EQ(DeviceManager::ResolveSelectedIndex(devices, 0), UINT32_MAX);
  EXPECT_EQ(DeviceManager::ResolveSelectedIndex(devices, UINT32_MAX),
            UINT32_MAX);
}

// Channel names are a property of the OPEN device (ES-349): with no
// device running the accessor must return empty for any index — the
// UI's unlabeled fallback — rather than stale or garbage data.
TEST(OutputChannelName, EmptyWhenNoDeviceOpen) {
  DeviceManager manager;
  EXPECT_EQ(manager.output_channel_name(0), "");
  EXPECT_EQ(manager.output_channel_name(7), "");
  EXPECT_EQ(manager.output_channel_name(UINT32_MAX), "");
}

// First device flagged is_default wins — guards against future
// regressions where enumeration order or flag handling changes.
TEST(ResolveSelectedIndex, PicksFirstDefaultWhenMultipleFlagged) {
  std::vector<DeviceInfo> devices = {
      MakeDevice("MOTU MicroBook II", false),
      MakeDevice("Built-in Output", true),
      MakeDevice("AirPods", true),
  };
  EXPECT_EQ(DeviceManager::ResolveSelectedIndex(devices, UINT32_MAX), 1u);
}

}  // namespace
