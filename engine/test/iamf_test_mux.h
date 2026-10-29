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

#ifndef ECLIPSA_STUDIO_TEST_IAMF_TEST_MUX_H_
#define ECLIPSA_STUDIO_TEST_IAMF_TEST_MUX_H_

#include <gpac/filters.h>
#include <gpac/tools.h>

#include <string>

namespace iamf_test_mux {

// Mux a bare `.iamf` into an IAMF-in-ISOBMFF `.mp4` via a libgpac filter
// session — the same Phase-1 path IamfMuxer uses. With `input_video`
// empty the output is audio-only; otherwise the video file's visual
// track is muxed beside the IAMF track. No IAMF-in-MP4 fixture is
// checked in, so tests that need one build it with this on the fly.
// Returns true on success.
inline bool MuxIamfToMp4(const std::string& input_iamf,
                         const std::string& output_mp4,
                         const std::string& input_video = {}) {
  // Bracket gpac use with gf_sys_init / gf_sys_close, the same as IamfMuxer
  // and IamfDemuxer do. The demuxer's gf_sys_close would otherwise tear the
  // filter registry out from under a later test's mux that had relied on
  // gpac being implicitly initialised.
  if (gf_sys_init(GF_MemTrackerNone, nullptr) != GF_OK) return false;
  GF_Err err = GF_OK;
  bool ok = false;
  GF_FilterSession* session = gf_fs_new_defaults(GF_FilterSessionFlags(0));
  if (session != nullptr) {
    GF_Filter* src =
        gf_fs_load_source(session, input_iamf.c_str(), nullptr, nullptr, &err);
    if (err == GF_OK && src != nullptr && !input_video.empty()) {
      src = gf_fs_load_source(session, (input_video + "#video").c_str(),
                              nullptr, nullptr, &err);
    }
    GF_Filter* dst = nullptr;
    if (err == GF_OK && src != nullptr) {
      // With a video track, 20 ms chunks make the writer alternate audio
      // and video chunks, so the IAMF samples end up in several runs.
      const std::string dst_url =
          input_video.empty() ? output_mp4 : output_mp4 + ":cdur=0.02";
      dst = gf_fs_load_destination(session, dst_url.c_str(), nullptr, nullptr,
                                   &err);
    }
    if (err == GF_OK && dst != nullptr) {
      err = gf_fs_run(session);
      if (err >= GF_OK) err = gf_fs_get_last_connect_error(session);
      if (err >= GF_OK) err = gf_fs_get_last_process_error(session);
      ok = err >= GF_OK;
    }
    gf_fs_del(session);
  }
  gf_sys_close();
  return ok;
}

}  // namespace iamf_test_mux

#endif  // ECLIPSA_STUDIO_TEST_IAMF_TEST_MUX_H_
