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

#include <cstdio>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "absl/types/span.h"
#include "engine_log.h"
#include "iamf/gpac_system.h"
#include "iamf/read_only_file_map.h"

namespace eclipsa_studio {
namespace {

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

// An open MP4 and its IAMF track. Closes the file on destruction.
class OpenIamfTrack {
 public:
  OpenIamfTrack() = default;
  ~OpenIamfTrack() {
    if (iso_ != nullptr) gf_isom_close(iso_);
  }
  OpenIamfTrack(const OpenIamfTrack&) = delete;
  OpenIamfTrack& operator=(const OpenIamfTrack&) = delete;

  // Opens `input_mp4`, finds its IAMF track and appends the track's
  // descriptor OBUs (IA Sequence Header, Codec Config, Audio Element and
  // Mix Presentation OBUs, serialised from the sample entry's IAMF config)
  // to `*descriptor_obus`. Returns false and sets `*err` on failure.
  bool open(const std::string& input_mp4, std::vector<uint8_t>* descriptor_obus,
            std::string* err) {
    iso_ = gf_isom_open(input_mp4.c_str(), GF_ISOM_OPEN_READ, nullptr);
    if (iso_ == nullptr) {
      *err = "io: failed to open MP4 " + input_mp4;
      LogErr("iamf demux: " + *err);
      return false;
    }
    track_ = FindIamfTrack(iso_);
    if (track_ == 0) {
      *err = "unsupported: no IAMF audio track in " + input_mp4;
      LogWarn("iamf demux: " + *err);
      return false;
    }
    GF_IAConfig* cfg = gf_isom_iamf_config_get(iso_, track_, 1);
    if (cfg == nullptr) {
      *err = "malformed: missing IAMF config on track";
      LogErr("iamf demux: " + *err);
      return false;
    }
    GF_BitStream* bs = gf_bs_new(nullptr, 0, GF_BITSTREAM_WRITE);
    if (bs == nullptr) {
      gf_odf_iamf_cfg_del(cfg);
      *err = "io: failed to allocate bitstream";
      LogErr("iamf demux: " + *err);
      return false;
    }
    const GF_Err write_err = gf_odf_iamf_cfg_write_obus(cfg, bs);
    gf_odf_iamf_cfg_del(cfg);
    u8* data = nullptr;
    u32 size = 0;
    if (write_err >= GF_OK) gf_bs_get_content(bs, &data, &size);
    gf_bs_del(bs);
    if (write_err < GF_OK || data == nullptr || size == 0) {
      if (data != nullptr) gf_free(data);
      *err = std::string("malformed: write descriptor OBUs failed: ") +
             gf_error_to_string(write_err < GF_OK ? write_err : GF_BAD_PARAM);
      LogErr("iamf demux: " + *err);
      return false;
    }
    descriptor_obus->insert(descriptor_obus->end(), data, data + size);
    gf_free(data);
    WarnOnLeadingEdit(iso_, track_);
    return true;
  }

  GF_ISOFile* iso() const { return iso_; }
  u32 track() const { return track_; }
  u32 sample_count() const { return gf_isom_get_sample_count(iso_, track_); }

 private:
  GF_ISOFile* iso_ = nullptr;
  u32 track_ = 0;
};

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

  // Append in place; on failure, drop what this call appended.
  const size_t original_size = out_bytes->size();
  OpenIamfTrack track;
  if (!track.open(input_mp4, out_bytes, &last_error_)) {
    out_bytes->resize(original_size);
    return false;
  }

  // Append every frame's OBUs (the sample payloads) in sample order, which
  // is presentation order for an audio track with no reordering. Samples
  // go straight into `*out_bytes`, so the track is held once and its size
  // is not limited to 32 bits.
  const u32 sample_count = track.sample_count();
  for (u32 i = 1; i <= sample_count; ++i) {
    u32 desc_index = 0;
    GF_ISOSample* sample =
        gf_isom_get_sample(track.iso(), track.track(), i, &desc_index);
    if (sample == nullptr) {
      last_error_ = "io: failed to read IAMF sample " + std::to_string(i);
      LogErr("iamf demux: " + last_error_);
      out_bytes->resize(original_size);
      return false;
    }
    // As in IndexTrack: the descriptor OBUs come from sample entry 1.
    if (desc_index != 1) {
      gf_isom_sample_del(&sample);
      last_error_ = "unsupported: IAMF track has more than one sample entry";
      LogWarn("iamf demux: " + last_error_);
      out_bytes->resize(original_size);
      return false;
    }
    out_bytes->insert(out_bytes->end(), sample->data,
                      sample->data + sample->dataLength);
    gf_isom_sample_del(&sample);
  }

  char buf[128];
  std::snprintf(buf, sizeof(buf), "iamf demux: %u frames -> %zu bytes",
                sample_count, out_bytes->size() - original_size);
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "iamf", buf);
  return true;
}

bool IamfDemuxer::IndexTrack(const std::string& input_mp4,
                             IamfTrackIndex* out_index) {
  last_error_.clear();
  sample_data_external_ = false;
  if (out_index == nullptr) {
    last_error_ = "invalid_argument: null output";
    return false;
  }
  if (input_mp4.empty()) {
    last_error_ = "invalid_argument: empty path";
    return false;
  }
  GpacSystem gpac;
  if (!gpac.ok()) {
    last_error_ = "io: GPAC system init failed";
    LogErr("iamf demux: " + last_error_);
    return false;
  }

  IamfTrackIndex index;
  OpenIamfTrack track;
  if (!track.open(input_mp4, &index.descriptor_obus, &last_error_)) {
    return false;
  }

  // Sample offsets and sizes come from the sample table; no sample data is
  // read. Adjacent samples (one chunk) merge into a single range.
  const u32 sample_count = track.sample_count();
  u32 last_desc_index = 0;
  for (u32 i = 1; i <= sample_count; ++i) {
    u32 desc_index = 0;
    u64 offset = 0;
    GF_ISOSample* sample = gf_isom_get_sample_info(track.iso(), track.track(),
                                                   i, &desc_index, &offset);
    if (sample == nullptr) {
      last_error_ = "io: failed to read IAMF sample info " + std::to_string(i);
      LogErr("iamf demux: " + last_error_);
      return false;
    }
    const uint64_t size = sample->dataLength;
    gf_isom_sample_del(&sample);
    if (desc_index != last_desc_index) {
      // The descriptor OBUs come from sample entry 1, so samples bound to
      // another entry (with its own IAMF config) cannot be read with them.
      if (desc_index != 1) {
        last_error_ = "unsupported: IAMF track has more than one sample entry";
        LogWarn("iamf demux: " + last_error_);
        return false;
      }
      if (!gf_isom_is_self_contained(track.iso(), track.track(), desc_index)) {
        last_error_ =
            "unsupported: IAMF sample data is stored outside " + input_mp4;
        LogWarn("iamf demux: " + last_error_);
        sample_data_external_ = true;
        return false;
      }
      last_desc_index = desc_index;
    }
    if (size == 0) continue;
    if (!index.samples.empty() &&
        index.samples.back().offset + index.samples.back().size == offset) {
      index.samples.back().size += size;
    } else {
      index.samples.push_back({offset, size});
    }
  }
  *out_index = std::move(index);
  return true;
}

bool IamfMp4Source::open(const std::string& path, std::string* err,
                         bool* sample_data_external) {
  close();
  if (sample_data_external != nullptr) *sample_data_external = false;
  IamfDemuxer demuxer;
  if (!demuxer.IndexTrack(path, &index_)) {
    if (err != nullptr) *err = demuxer.last_error();
    if (sample_data_external != nullptr) {
      *sample_data_external = demuxer.sample_data_external();
    }
    return false;
  }
  std::string map_err;
  if (!map_.open(path.c_str(), &map_err)) {
    if (err != nullptr) *err = map_err;
    close();
    return false;
  }
  map_.hint_sequential();

  segments_.reserve(index_.samples.size() + 1);
  segments_.push_back(absl::MakeConstSpan(index_.descriptor_obus));
  total_bytes_ = index_.descriptor_obus.size();
  for (const IamfTrackIndex::Range& range : index_.samples) {
    if (range.offset > map_.size() || range.size > map_.size() - range.offset) {
      if (err != nullptr) {
        *err = "malformed: IAMF sample lies outside the file " + path;
      }
      close();
      return false;
    }
    segments_.push_back(
        absl::MakeConstSpan(map_.data() + range.offset, range.size));
    total_bytes_ += range.size;
  }
  return true;
}

void IamfMp4Source::close() {
  segments_.clear();
  index_ = IamfTrackIndex{};
  map_.close();
  total_bytes_ = 0;
}

}  // namespace eclipsa_studio
