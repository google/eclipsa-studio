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

#include "iamf/read_only_file_map.h"

#include <cstdio>
#include <cstring>
#include <string>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#endif

namespace eclipsa_studio {

ReadOnlyFileMap::~ReadOnlyFileMap() { close(); }

#ifdef _WIN32

bool ReadOnlyFileMap::open(const char* path, std::string* err) {
  close();

  // Convert UTF-8 path → UTF-16 so non-ASCII paths work without relying
  // on the active code page.
  const int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
  if (wlen <= 0) {
    if (err)
      *err = std::string("io: invalid utf-8 path: ") + (path ? path : "");
    return false;
  }
  std::wstring wpath(static_cast<std::size_t>(wlen), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath.data(), wlen);
  if (!wpath.empty() && wpath.back() == L'\0') wpath.pop_back();

  HANDLE h =
      CreateFileW(wpath.c_str(), GENERIC_READ,
                  FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                  FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (h == INVALID_HANDLE_VALUE) {
    if (err) {
      char buf[256];
      std::snprintf(buf, sizeof(buf),
                    "io: could not open '%s' (GetLastError=%lu)",
                    path ? path : "", GetLastError());
      *err = buf;
    }
    return false;
  }
  LARGE_INTEGER size_li{};
  if (!GetFileSizeEx(h, &size_li) || size_li.QuadPart <= 0) {
    if (err) *err = "io: GetFileSizeEx failed or empty file";
    CloseHandle(h);
    return false;
  }
  HANDLE mh = CreateFileMappingW(h, nullptr, PAGE_READONLY, 0, 0, nullptr);
  if (mh == nullptr) {
    if (err) *err = "io: CreateFileMappingW failed";
    CloseHandle(h);
    return false;
  }
  void* p = MapViewOfFile(mh, FILE_MAP_READ, 0, 0, 0);
  if (p == nullptr) {
    if (err) *err = "io: MapViewOfFile failed";
    CloseHandle(mh);
    CloseHandle(h);
    return false;
  }
  data_ = static_cast<const uint8_t*>(p);
  size_ = static_cast<std::size_t>(size_li.QuadPart);
  file_handle_ = h;
  mapping_handle_ = mh;
  return true;
}

void ReadOnlyFileMap::hint_sequential() {
  // FILE_FLAG_SEQUENTIAL_SCAN at open() already provides this.
}

void ReadOnlyFileMap::close() {
  if (data_ != nullptr) {
    UnmapViewOfFile(const_cast<uint8_t*>(data_));
    data_ = nullptr;
    size_ = 0;
  }
  if (mapping_handle_ != nullptr) {
    CloseHandle(static_cast<HANDLE>(mapping_handle_));
    mapping_handle_ = nullptr;
  }
  if (file_handle_ != nullptr) {
    CloseHandle(static_cast<HANDLE>(file_handle_));
    file_handle_ = nullptr;
  }
}

#else  // _WIN32

bool ReadOnlyFileMap::open(const char* path, std::string* err) {
  close();
  const int fd = ::open(path, O_RDONLY);
  if (fd < 0) {
    if (err) {
      char buf[256];
      std::snprintf(buf, sizeof(buf), "io: could not open '%s': %s",
                    path ? path : "", std::strerror(errno));
      *err = buf;
    }
    return false;
  }
  struct stat st = {};
  if (::fstat(fd, &st) != 0 || st.st_size <= 0) {
    if (err) *err = "io: fstat failed or empty file";
    ::close(fd);
    return false;
  }
  const std::size_t len = static_cast<std::size_t>(st.st_size);
  void* p = ::mmap(nullptr, len, PROT_READ, MAP_PRIVATE, fd, 0);
  if (p == MAP_FAILED) {
    if (err) *err = "io: mmap failed";
    ::close(fd);
    return false;
  }
  data_ = static_cast<const uint8_t*>(p);
  size_ = len;
  fd_ = fd;
  return true;
}

void ReadOnlyFileMap::hint_sequential() {
  if (data_ != nullptr && size_ > 0) {
    ::madvise(const_cast<uint8_t*>(data_), size_, MADV_SEQUENTIAL);
  }
}

void ReadOnlyFileMap::close() {
  if (data_ != nullptr) {
    ::munmap(const_cast<uint8_t*>(data_), size_);
    data_ = nullptr;
    size_ = 0;
  }
  if (fd_ >= 0) {
    ::close(fd_);
    fd_ = -1;
  }
}

#endif  // _WIN32

}  // namespace eclipsa_studio
