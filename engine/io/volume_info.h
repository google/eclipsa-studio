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

#ifndef ECLIPSA_STUDIO_IO_VOLUME_INFO_H_
#define ECLIPSA_STUDIO_IO_VOLUME_INFO_H_

#include <cstdint>
#include <string>

namespace eclipsa_studio {

// Free space and identity of the volume holding `path`, for the export
// dialog's disk-space check (ES-742). `path` must exist; a file or a
// directory both work. `free_bytes` is the space available to this
// process (not root's reserve). `volume_id` identifies the volume so a
// caller can tell whether two paths share one: st_dev on POSIX, the
// volume serial number on Windows. Returns false, leaving the outputs
// untouched, when the path does not exist or the OS query fails.
bool VolumeInfo(const std::string& path, uint64_t* free_bytes,
                uint64_t* volume_id);

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_IO_VOLUME_INFO_H_
