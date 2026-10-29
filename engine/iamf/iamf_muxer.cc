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

#include "iamf/iamf_muxer.h"

#include <gpac/filters.h>
#include <gpac/isomedia.h>
#include <gpac/tools.h>

#include <cstdio>
#include <filesystem>
#include <string>

#include "engine_log.h"
#include "iamf/gpac_system.h"

namespace eclipsa_studio {
namespace {

// Paths cross the FFI as UTF-8. A std::filesystem::path built from a
// narrow std::string is decoded with the ANSI code page on Windows, so a
// non-ASCII path tests as missing; build it from UTF-8 explicitly.
std::filesystem::path Utf8Path(const std::string& utf8) {
  return std::filesystem::path(std::u8string(utf8.begin(), utf8.end()));
}

void LogErr(const std::string& message) {
  engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", message.c_str());
}

// Phase 1 — write the IAMF bitstream into a fresh MP4 via a GPAC filter
// session. The IAMF source filter knows how to emit the `iamf` sample
// entry + config; we leave the source→destination link implicit so GPAC
// inserts any reframer it needs.
bool MuxAudio(const std::string& input_iamf, const std::string& output_mp4) {
  GF_Err err = GF_OK;
  GF_FilterSession* session = gf_fs_new_defaults(GF_FilterSessionFlags(0));
  if (session == nullptr) {
    LogErr("iamf mux: failed to create GPAC filter session");
    return false;
  }

  GF_Filter* src =
      gf_fs_load_source(session, input_iamf.c_str(), nullptr, nullptr, &err);
  if (err != GF_OK || src == nullptr) {
    LogErr("iamf mux: failed to load .iamf source " + input_iamf + ": " +
           gf_error_to_string(err));
    gf_fs_del(session);
    return false;
  }

  GF_Filter* dst = gf_fs_load_destination(session, output_mp4.c_str(), nullptr,
                                          nullptr, &err);
  if (err != GF_OK || dst == nullptr) {
    LogErr("iamf mux: failed to load MP4 destination " + output_mp4 + ": " +
           gf_error_to_string(err));
    gf_fs_del(session);
    return false;
  }

  err = gf_fs_run(session);
  if (err >= GF_OK) {
    err = gf_fs_get_last_connect_error(session);
    if (err >= GF_OK) {
      err = gf_fs_get_last_process_error(session);
    }
  }
  gf_fs_del(session);

  // GPAC's GF_Err has positive non-error values (GF_EOS=1, GF_PENDING_PACKET,
  // …); only negatives are failures. Test `< GF_OK`, matching the `>= GF_OK`
  // guards above — `!= GF_OK` would mis-report a positive status as failure.
  if (err < GF_OK) {
    LogErr(std::string("iamf mux: filter session failed: ") +
           gf_error_to_string(err));
    return false;
  }
  return true;
}

enum class SourceOpen { kOk, kCannotOpen, kNoVisualTrack };

// Opens `input_video` for reading and finds its first visual track.
// Returns the open file with `*track` set and `*status` kOk, or nullptr
// with `*status` saying why, after logging it under `context` ("video
// mux" or "video probe"). Shared by the mux and the pre-export probe so
// both accept exactly the same files.
GF_ISOFile* OpenSourceVideo(const std::string& input_video,
                            const std::string& context, u32* track,
                            SourceOpen* status) {
  *track = 0;
  GF_ISOFile* src =
      gf_isom_open(input_video.c_str(), GF_ISOM_OPEN_READ, nullptr);
  if (src == nullptr) {
    LogErr(context + ": failed to open source video " + input_video);
    *status = SourceOpen::kCannotOpen;
    return nullptr;
  }
  const u32 src_track_count = gf_isom_get_track_count(src);
  for (u32 i = 1; i <= src_track_count; ++i) {
    if (gf_isom_get_media_type(src, i) == GF_ISOM_MEDIA_VISUAL) {
      *track = i;
      *status = SourceOpen::kOk;
      return src;
    }
  }
  LogErr(context + ": no video track in " + input_video);
  gf_isom_close(src);
  *status = SourceOpen::kNoVisualTrack;
  return nullptr;
}

// Phase 2 — clone the source video track into the MP4 that already holds
// the IAMF audio, copying its samples verbatim (stream-copy, no
// re-encode). Source must be ISOBMFF (.mp4/.mov).
bool MuxVideo(const std::string& input_video, const std::string& output_mp4) {
  u32 src_track = 0;
  SourceOpen status = SourceOpen::kOk;
  GF_ISOFile* src =
      OpenSourceVideo(input_video, "video mux", &src_track, &status);
  if (src == nullptr) return false;

  GF_ISOFile* dst =
      gf_isom_open(output_mp4.c_str(), GF_ISOM_OPEN_EDIT, nullptr);
  if (dst == nullptr) {
    LogErr("video mux: failed to open " + output_mp4 + " for editing");
    gf_isom_close(src);
    return false;
  }
  const u32 tracks_before = gf_isom_get_track_count(dst);

  // Clone clones the track structure (sample descriptions, timing), not
  // the media samples — those we copy by hand below.
  u32 dst_track = 0;
  GF_Err err = gf_isom_clone_track(src, src_track, dst,
                                   GF_ISOTrackCloneFlags(0), &dst_track);
  if (err != GF_OK) {
    LogErr(std::string("video mux: clone_track failed: ") +
           gf_error_to_string(err));
    gf_isom_close(dst);
    gf_isom_close(src);
    return false;
  }

  const u32 sample_count = gf_isom_get_sample_count(src, src_track);
  u32 last_dur = 0;
  for (u32 i = 1; i <= sample_count; ++i) {
    u32 sample_desc_index = 0;
    GF_ISOSample* sample =
        gf_isom_get_sample(src, src_track, i, &sample_desc_index);
    if (sample == nullptr) {
      LogErr("video mux: failed to read source sample " + std::to_string(i));
      gf_isom_close(dst);
      gf_isom_close(src);
      return false;
    }
    last_dur = sample->duration;
    err = gf_isom_add_sample(dst, dst_track, sample_desc_index, sample);
    gf_isom_sample_del(&sample);
    if (err < GF_OK) {
      LogErr(std::string("video mux: add_sample ") + std::to_string(i) +
             " failed: " + gf_error_to_string(err));
      gf_isom_close(dst);
      gf_isom_close(src);
      return false;
    }
  }
  // gf_isom_add_sample derives each sample's duration from the next sample's
  // DTS, so the final frame has no successor and GPAC would default it to the
  // previous delta. Set it explicitly from the source so VFR (or a differing
  // final frame) keeps the correct track duration — which also feeds the
  // audio edit-list clamp below.
  if (last_dur > 0) {
    const GF_Err dur_err =
        gf_isom_set_last_sample_duration(dst, dst_track, last_dur);
    if (dur_err < GF_OK) {
      LogErr(std::string("video mux: set_last_sample_duration failed: ") +
             gf_error_to_string(dur_err));
    }
  }
  gf_isom_close(src);

  // Clamp the movie duration to the video. Without this, an IAMF track
  // longer than the picture would make the container report the audio
  // length as the movie duration.
  const u64 video_duration = gf_isom_get_track_duration(dst, dst_track);
  if (video_duration > 0) {
    const u32 track_count = gf_isom_get_track_count(dst);
    for (u32 i = 1; i <= track_count; ++i) {
      if (i == dst_track) continue;
      // Only clamp tracks longer than the video; a shorter track already
      // ends before the picture, and an edit here would extend it past its
      // own media instead of trimming.
      if (gf_isom_get_track_duration(dst, i) <= video_duration) continue;
      gf_isom_remove_edits(dst, i);
      const GF_Err edit_err =
          gf_isom_set_edit(dst, i, /*EditTime=*/0,
                           /*EditDuration=*/video_duration, /*MediaTime=*/0,
                           GF_ISOM_EDIT_NORMAL);
      if (edit_err < GF_OK) {  // positive (e.g. GF_EOS) is not a failure
        LogErr(std::string("video mux: set_edit on audio track failed: ") +
               gf_error_to_string(edit_err));
      }
    }
    gf_isom_update_duration(dst);
  }

  err = gf_isom_set_storage_mode(dst, GF_ISOM_STORE_INTERLEAVED);
  if (err != GF_OK) {
    LogErr(std::string("video mux: set_storage_mode failed: ") +
           gf_error_to_string(err));
    gf_isom_close(dst);
    return false;
  }

  // EDIT mode writes to a new file; close, then swap it over the original.
  const std::string temp_output = output_mp4 + ".muxed";
  err = gf_isom_set_final_name(dst, const_cast<char*>(temp_output.c_str()));
  if (err != GF_OK) {
    LogErr(std::string("video mux: set_final_name failed: ") +
           gf_error_to_string(err));
    gf_isom_close(dst);
    return false;
  }
  err = gf_isom_close(dst);
  if (err != GF_OK) {
    LogErr(std::string("video mux: close failed: ") + gf_error_to_string(err));
    return false;
  }

  std::error_code ec;
  std::filesystem::remove(Utf8Path(output_mp4), ec);
  std::filesystem::rename(Utf8Path(temp_output), Utf8Path(output_mp4), ec);
  if (ec) {
    LogErr("video mux: failed to move muxed file into place: " + ec.message());
    return false;
  }

  // Sanity-check: the muxed file should have exactly one more track than
  // the audio-only intermediate.
  GF_ISOFile* verify =
      gf_isom_open(output_mp4.c_str(), GF_ISOM_OPEN_READ, nullptr);
  if (verify == nullptr) {
    LogErr("video mux: failed to reopen muxed file for verification");
    return false;
  }
  const u32 tracks_after = gf_isom_get_track_count(verify);
  gf_isom_close(verify);
  if (tracks_after != tracks_before + 1) {
    LogErr("video mux: track-count check failed (expected " +
           std::to_string(tracks_before + 1) + ", got " +
           std::to_string(tracks_after) + ")");
    return false;
  }
  return true;
}

}  // namespace

int32_t IamfMuxer::Mux(const std::string& input_iamf,
                       const std::string& input_video,
                       const std::string& output_mp4) {
  if (input_iamf.empty() || input_video.empty() || output_mp4.empty()) {
    LogErr("iamf mux: empty argument");
    return -1;
  }
  std::error_code ec;
  if (!std::filesystem::exists(Utf8Path(input_iamf), ec)) {
    LogErr("iamf mux: input .iamf not found: " + input_iamf);
    return -2;
  }
  if (!std::filesystem::exists(Utf8Path(input_video), ec)) {
    LogErr("iamf mux: input video not found: " + input_video);
    return -3;
  }

  int32_t rc = 0;
  {
    GpacSystem gpac;
    if (!gpac.ok()) {
      LogErr("iamf mux: GPAC system init failed");
      return -10;
    }
    if (!MuxAudio(input_iamf, output_mp4)) {
      rc = -11;
    } else if (!MuxVideo(input_video, output_mp4)) {
      rc = -12;
    }
  }

  // A failed mux must not leave a file behind: Phase 1 produces an
  // audio-only MP4 at output_mp4, so a Phase-2 failure would otherwise
  // leave a plausible-looking but video-less file (and a possible orphaned
  // ".muxed" temp from the swap). Remove both so failure yields no output.
  if (rc != 0) {
    std::error_code ignore;
    std::filesystem::remove(Utf8Path(output_mp4), ignore);
    std::filesystem::remove(Utf8Path(output_mp4 + ".muxed"), ignore);
  }

  return rc;
}

int32_t IamfMuxer::MuxAudioOnly(const std::string& input_iamf,
                                const std::string& output_mp4) {
  if (input_iamf.empty() || output_mp4.empty()) {
    LogErr("iamf mux: empty argument");
    return -1;
  }
  std::error_code ec;
  if (!std::filesystem::exists(Utf8Path(input_iamf), ec)) {
    LogErr("iamf mux: input .iamf not found: " + input_iamf);
    return -2;
  }
  int32_t rc = 0;
  {
    GpacSystem gpac;
    if (!gpac.ok()) {
      LogErr("iamf mux: GPAC system init failed");
      return -10;
    }
    if (!MuxAudio(input_iamf, output_mp4)) rc = -11;
  }
  if (rc != 0) {
    std::error_code ignore;
    std::filesystem::remove(Utf8Path(output_mp4), ignore);
  }
  return rc;
}

int32_t IamfMuxer::ProbeVideo(const std::string& input_video) {
  if (input_video.empty()) {
    LogErr("video probe: empty argument");
    return -1;
  }
  std::error_code ec;
  if (!std::filesystem::exists(Utf8Path(input_video), ec)) {
    LogErr("video probe: input video not found: " + input_video);
    return -3;
  }
  GpacSystem gpac;
  if (!gpac.ok()) {
    LogErr("video probe: GPAC system init failed");
    return -10;
  }
  u32 track = 0;
  SourceOpen status = SourceOpen::kOk;
  GF_ISOFile* src =
      OpenSourceVideo(input_video, "video probe", &track, &status);
  if (src != nullptr) gf_isom_close(src);
  switch (status) {
    case SourceOpen::kOk:
      return 0;
    case SourceOpen::kCannotOpen:
      return -12;
    case SourceOpen::kNoVisualTrack:
      return -13;
  }
  return -12;
}

}  // namespace eclipsa_studio
