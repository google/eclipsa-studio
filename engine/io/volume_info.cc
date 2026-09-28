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

#ifdef _WIN32
#include <windows.h>

#include <vector>
#elif defined(__APPLE__)
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>
#else
#include <sys/stat.h>
#include <sys/statvfs.h>
#endif

namespace eclipsa_studio {

#ifdef _WIN32

bool VolumeInfo(const std::string& path, uint64_t* free_bytes,
                uint64_t* volume_id) {
  if (path.empty() || free_bytes == nullptr || volume_id == nullptr) {
    return false;
  }
  const int wide_len =
      MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
  if (wide_len <= 0) return false;
  std::vector<wchar_t> wide(static_cast<size_t>(wide_len));
  MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, wide.data(), wide_len);

  // GetVolumePathNameW can succeed for a path that does not exist, so
  // check existence first; the contract is "false for a missing path".
  if (GetFileAttributesW(wide.data()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  // Both queries take the volume's mount point (a directory with a
  // trailing backslash), which GetVolumePathNameW resolves for any path on
  // it, file or directory, drive letter or mounted folder.
  wchar_t mount[MAX_PATH + 1] = {};
  if (!GetVolumePathNameW(wide.data(), mount, MAX_PATH)) return false;
  ULARGE_INTEGER available = {};
  if (!GetDiskFreeSpaceExW(mount, &available, nullptr, nullptr)) {
    return false;
  }
  DWORD serial = 0;
  if (!GetVolumeInformationW(mount, nullptr, 0, &serial, nullptr, nullptr,
                             nullptr, 0)) {
    return false;
  }
  *free_bytes = available.QuadPart;
  *volume_id = serial;
  return true;
}

#else

bool VolumeInfo(const std::string& path, uint64_t* free_bytes,
                uint64_t* volume_id) {
  if (path.empty() || free_bytes == nullptr || volume_id == nullptr) {
    return false;
  }
  // f_bavail is what an unprivileged process can use; f_bfree includes
  // the reserve only root may fill.
#if defined(__APPLE__)
  // Darwin's statvfs reports block counts in 32 bits and wraps above
  // 2^32 blocks (16 TiB at 4 KiB); statfs carries 64-bit counts.
  struct statfs fs = {};
  if (statfs(path.c_str(), &fs) != 0) return false;
  const uint64_t available =
      static_cast<uint64_t>(fs.f_bavail) * static_cast<uint64_t>(fs.f_bsize);
#else
  struct statvfs vfs = {};
  if (statvfs(path.c_str(), &vfs) != 0) return false;
  const uint64_t available =
      static_cast<uint64_t>(vfs.f_bavail) * static_cast<uint64_t>(vfs.f_frsize);
#endif
  struct stat st = {};
  if (stat(path.c_str(), &st) != 0) return false;
  *free_bytes = available;
  *volume_id = static_cast<uint64_t>(st.st_dev);
  return true;
}

#endif

}  // namespace eclipsa_studio
