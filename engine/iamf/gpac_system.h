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

#ifndef ECLIPSA_STUDIO_IAMF_GPAC_SYSTEM_H_
#define ECLIPSA_STUDIO_IAMF_GPAC_SYSTEM_H_

#include <mutex>

// gpac last: its setup.h redefines strcpy and friends as #error tokens.
#include <gpac/tools.h>

namespace eclipsa_studio {

// RAII bracket around libgpac's global system init, serialized across
// threads. gf_sys_init / gf_sys_close keep a plain static refcount with no
// lock, and the engine brackets libgpac from several threads at once: the
// muxer and the container probe on export worker isolates, the demuxer for
// the length of each DemuxToBytes call (on the control thread and on the
// IAMF probe worker isolates), and the still-video encoder. A torn increment or
// decrement would drop the count to zero and tear down libgpac's globals under
// a live user, so every bracket goes through this class and its one
// process-wide mutex. Scoping the bracket per call keeps each user independent
// of whatever state another code path left libgpac in.
class GpacSystem {
 public:
  GpacSystem() {
    std::lock_guard<std::mutex> lock(Mutex());
    ok_ = gf_sys_init(GF_MemTrackerNone, nullptr) == GF_OK;
  }
  ~GpacSystem() {
    if (!ok_) return;
    std::lock_guard<std::mutex> lock(Mutex());
    gf_sys_close();
  }
  GpacSystem(const GpacSystem&) = delete;
  GpacSystem& operator=(const GpacSystem&) = delete;

  // False when gf_sys_init failed; the destructor then does nothing.
  bool ok() const { return ok_; }

 private:
  static std::mutex& Mutex() {
    static std::mutex mutex;
    return mutex;
  }
  bool ok_ = false;
};

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_IAMF_GPAC_SYSTEM_H_
