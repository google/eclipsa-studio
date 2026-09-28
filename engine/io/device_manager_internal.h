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

#ifndef ECLIPSA_STUDIO_IO_DEVICE_MANAGER_INTERNAL_H_
#define ECLIPSA_STUDIO_IO_DEVICE_MANAGER_INTERNAL_H_

#include <sstream>
#include <string>

// Helpers shared by DeviceManager backend implementations. Not part of
// the public device_manager.h surface.

namespace device_backend {

// Format an audio-device failure as "<phase> FAILED: rc=<code> (<desc>)
// on \"<dev_name>\"". `code` is the backend's native error code
// (ma_result, OSStatus, ...) and `desc` its human-readable description.
// Built via ostringstream so long device names and backend descriptions
// can't be silently truncated by a fixed-size stack buffer.
inline std::string FormatDeviceError(const char* phase, long code,
                                     const char* desc,
                                     const std::string& dev_name) {
  std::ostringstream oss;
  oss << phase << " FAILED: rc=" << code << " (" << desc << ") on \""
      << dev_name << "\"";
  return oss.str();
}

}  // namespace device_backend

#endif  // ECLIPSA_STUDIO_IO_DEVICE_MANAGER_INTERNAL_H_
