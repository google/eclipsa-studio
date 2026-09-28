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

#ifndef ECLIPSA_STUDIO_IAMF_READ_ONLY_FILE_MAP_H_
#define ECLIPSA_STUDIO_IAMF_READ_ONLY_FILE_MAP_H_

#include <cstddef>
#include <cstdint>
#include <string>

namespace eclipsa_studio {

// RAII read-only memory map of a file. Used by the IAMF readers/probe
// so we don't double-buffer multi-hundred-MB IAMF inputs in process
// memory: pages stay shared with the page cache and survive across
// successive open/probe calls on the same path.
//
// POSIX backend uses mmap()/munmap() with O_RDONLY + MADV_SEQUENTIAL.
// Windows backend uses CreateFileW + CreateFileMapping(PAGE_READONLY) +
// MapViewOfFile, with FILE_FLAG_SEQUENTIAL_SCAN at open time.
class ReadOnlyFileMap {
 public:
  ReadOnlyFileMap() = default;
  ~ReadOnlyFileMap();

  ReadOnlyFileMap(const ReadOnlyFileMap&) = delete;
  ReadOnlyFileMap& operator=(const ReadOnlyFileMap&) = delete;

  // Open `path` and map it read-only. Returns false on failure and, if
  // `err` is non-null, fills it with a human-readable message.
  bool open(const char* path, std::string* err);

  // Hint to the OS that we'll read the mapping sequentially. Advisory.
  // No-op on Windows (FILE_FLAG_SEQUENTIAL_SCAN already covers it).
  void hint_sequential();

  // Release the mapping and the underlying file handle. Idempotent.
  void close();

  const uint8_t* data() const { return data_; }
  std::size_t size() const { return size_; }
  bool is_open() const { return data_ != nullptr; }

 private:
  const uint8_t* data_ = nullptr;
  std::size_t size_ = 0;
#ifdef _WIN32
  void* file_handle_ = nullptr;     // HANDLE
  void* mapping_handle_ = nullptr;  // HANDLE
#else
  int fd_ = -1;
#endif
};

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_IAMF_READ_ONLY_FILE_MAP_H_
