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

#include "io/volume_info.h"

#include <cstdio>
#include <cstdlib>
#include <string>

#include "gtest/gtest.h"

namespace {

std::string TempDir() {
  const char* base = std::getenv("TEST_TMPDIR");
  return base != nullptr ? base : ".";
}

TEST(VolumeInfo, ReportsFreeSpaceForDirectory) {
  uint64_t free_bytes = 0;
  uint64_t volume_id = 0;
  ASSERT_TRUE(eclipsa_studio::VolumeInfo(TempDir(), &free_bytes, &volume_id));
  EXPECT_GT(free_bytes, 0u);
}

TEST(VolumeInfo, FileAndItsDirectoryShareAVolume) {
  const std::string path = TempDir() + "/volume_info_probe.txt";
  FILE* f = std::fopen(path.c_str(), "wb");
  ASSERT_NE(f, nullptr);
  std::fputs("x", f);
  std::fclose(f);

  uint64_t free_dir = 0, id_dir = 0, free_file = 0, id_file = 0;
  ASSERT_TRUE(eclipsa_studio::VolumeInfo(TempDir(), &free_dir, &id_dir));
  ASSERT_TRUE(eclipsa_studio::VolumeInfo(path, &free_file, &id_file));
  EXPECT_EQ(id_dir, id_file);
  std::remove(path.c_str());
}

TEST(VolumeInfo, FailsForMissingPathAndLeavesOutputsAlone) {
  uint64_t free_bytes = 42;
  uint64_t volume_id = 7;
  EXPECT_FALSE(eclipsa_studio::VolumeInfo(TempDir() + "/no_such_dir/x",
                                          &free_bytes, &volume_id));
  EXPECT_EQ(free_bytes, 42u);
  EXPECT_EQ(volume_id, 7u);
  EXPECT_FALSE(eclipsa_studio::VolumeInfo("", &free_bytes, &volume_id));
  EXPECT_FALSE(eclipsa_studio::VolumeInfo(TempDir(), nullptr, &volume_id));
}

}  // namespace
