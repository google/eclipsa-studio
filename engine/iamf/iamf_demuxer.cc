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

#include "iamf/iamf_demuxer.h"

#include <gpac/bitstream.h>
#include <gpac/isomedia.h>
#include <gpac/mpeg4_odf.h>
#include <gpac/tools.h>

#include <cstring>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "engine_log.h"
#include "iamf/gpac_system.h"

namespace eclipsa_studio {
namespace {

// Backing slot for the probe -> session demux handoff (see header). A single
// entry keyed by source path; guarded so the probe isolate's stash and the
// engine session's take never race.
struct DemuxHandoff {
  std::mutex mu;
  std::string path;            // empty => slot is free
  std::vector<uint8_t> bytes;  // valid only while `path` is non-empty
};

DemuxHandoff& demux_handoff() {
  static DemuxHandoff handoff;
  return handoff;
}

void LogErr(const std::string& message) {
  engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", message.c_str());
}

void LogWarn(const std::string& message) {
  engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf", message.c_str());
}

// Find the first track whose (single) sample entry is the `iamf` 4CC.
// Returns 0 if the container has no IAMF track.
u32 FindIamfTrack(GF_ISOFile* iso) {
  const u32 track_count = gf_isom_get_track_count(iso);
  for (u32 i = 1; i <= track_count; ++i) {
    if (gf_isom_get_media_subtype(iso, i, 1) == GF_ISOM_SUBTYPE_IAMF) {
      return i;
    }
  }
  return 0;
}

// Log (but do not act on) a leading edit on the IAMF track. IamfMuxer only
// writes an EditTime=0/MediaTime=0 duration clamp, for which mediaOffset is
// 0 — our own exports are aligned. A non-zero offset or a complex edit list
// comes from an external authoring tool and would desync the video; flag it
// for the ES-36 follow-up rather than silently misaligning.
void WarnOnLeadingEdit(GF_ISOFile* iso, u32 track) {
  s64 media_offset = 0;
  const Bool complex = gf_isom_get_edit_list_type(iso, track, &media_offset);
  if (complex == GF_TRUE || media_offset != 0) {
    char buf[160];
    std::snprintf(buf, sizeof(buf),
                  "iamf demux: IAMF track has a leading edit "
                  "(complex=%d, mediaOffset=%lld); A/V may drift — playing "
                  "from media time 0 (not yet compensated, see ES-36)",
                  static_cast<int>(complex),
                  static_cast<long long>(media_offset));
    LogWarn(buf);
  }
}

}  // namespace

bool IamfDemuxer::IsIsoBmff(const uint8_t* bytes, size_t len) {
  // ISOBMFF is a sequence of boxes: [4-byte big-endian size][4-byte type].
  // The first top-level box of an MP4/MOV is `ftyp`.
  if (bytes == nullptr || len < 12) return false;
  return std::memcmp(bytes + 4, "ftyp", 4) == 0;
}

bool IamfDemuxer::DemuxToBytes(const std::string& input_mp4,
                               std::vector<uint8_t>* out_bytes) {
  last_error_.clear();
  if (out_bytes == nullptr) {
    last_error_ = "invalid_argument: null output";
    return false;
  }
  if (input_mp4.empty()) {
    last_error_ = "invalid_argument: empty path";
    return false;
  }

  // Scope gpac's system init to this call rather than leaning on whatever
  // global state the process happens to be in (see gpac_system.h).
  GpacSystem gpac;
  if (!gpac.ok()) {
    last_error_ = "io: GPAC system init failed";
    LogErr("iamf demux: " + last_error_);
    return false;
  }

  GF_ISOFile* iso = gf_isom_open(input_mp4.c_str(), GF_ISOM_OPEN_READ, nullptr);
  if (iso == nullptr) {
    last_error_ = "io: failed to open MP4 " + input_mp4;
    LogErr("iamf demux: " + last_error_);
    return false;
  }

  const u32 iamf_track = FindIamfTrack(iso);
  if (iamf_track == 0) {
    last_error_ = "unsupported: no IAMF audio track in " + input_mp4;
    LogWarn("iamf demux: " + last_error_);
    gf_isom_close(iso);
    return false;
  }

  // Serialize the descriptor OBUs from the track's IA config — these are
  // the IA Sequence Header + Codec Config + Audio Element + Mix
  // Presentation OBUs that prefix a standalone .iamf bitstream.
  GF_IAConfig* cfg = gf_isom_iamf_config_get(iso, iamf_track, 1);
  if (cfg == nullptr) {
    last_error_ = "malformed: missing IAMF config on track";
    LogErr("iamf demux: " + last_error_);
    gf_isom_close(iso);
    return false;
  }

  GF_BitStream* bs = gf_bs_new(nullptr, 0, GF_BITSTREAM_WRITE);
  if (bs == nullptr) {
    last_error_ = "io: failed to allocate bitstream";
    LogErr("iamf demux: " + last_error_);
    gf_odf_iamf_cfg_del(cfg);
    gf_isom_close(iso);
    return false;
  }

  GF_Err err = gf_odf_iamf_cfg_write_obus(cfg, bs);
  gf_odf_iamf_cfg_del(cfg);
  if (err < GF_OK) {
    last_error_ = std::string("malformed: write descriptor OBUs failed: ") +
                  gf_error_to_string(err);
    LogErr("iamf demux: " + last_error_);
    gf_bs_del(bs);
    gf_isom_close(iso);
    return false;
  }

  // Append every frame's OBUs (the sample payloads) in sample order, which
  // is presentation order for an audio track with no reordering.
  const u32 sample_count = gf_isom_get_sample_count(iso, iamf_track);
  for (u32 i = 1; i <= sample_count; ++i) {
    u32 desc_index = 0;
    GF_ISOSample* sample = gf_isom_get_sample(iso, iamf_track, i, &desc_index);
    if (sample == nullptr) {
      last_error_ = "io: failed to read IAMF sample " + std::to_string(i);
      LogErr("iamf demux: " + last_error_);
      gf_bs_del(bs);
      gf_isom_close(iso);
      return false;
    }
    gf_bs_write_data(bs, sample->data, sample->dataLength);
    gf_isom_sample_del(&sample);
  }

  WarnOnLeadingEdit(iso, iamf_track);

  u8* data = nullptr;
  u32 size = 0;
  gf_bs_get_content(bs, &data, &size);
  gf_bs_del(bs);
  gf_isom_close(iso);

  if (data == nullptr || size == 0) {
    last_error_ = "malformed: empty IAMF bitstream after demux";
    LogErr("iamf demux: " + last_error_);
    if (data != nullptr) gf_free(data);
    return false;
  }
  out_bytes->insert(out_bytes->end(), data, data + size);
  gf_free(data);

  char buf[128];
  std::snprintf(buf, sizeof(buf), "iamf demux: %u frames -> %u bytes",
                sample_count, size);
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "iamf", buf);
  return true;
}

void StashIamfDemux(const std::string& path,
                    const std::vector<uint8_t>& bytes) {
  DemuxHandoff& handoff = demux_handoff();
  std::lock_guard<std::mutex> lk(handoff.mu);
  handoff.path = path;
  handoff.bytes = bytes;  // copy — the producer keeps its own working buffer
}

bool TakeIamfDemux(const std::string& path, std::vector<uint8_t>* out) {
  if (out == nullptr) return false;
  DemuxHandoff& handoff = demux_handoff();
  std::lock_guard<std::mutex> lk(handoff.mu);
  if (handoff.path != path || handoff.bytes.empty()) return false;
  *out = std::move(handoff.bytes);
  handoff.path.clear();
  handoff.bytes.clear();  // defined post-move; drop any retained capacity
  return true;
}

}  // namespace eclipsa_studio
