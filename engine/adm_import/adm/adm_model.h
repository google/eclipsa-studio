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

// In-memory ADM model (BS.2076 element hierarchy) plus the `chna` track table.
//
// Richer than the iamf-tools reader's model: block formats carry polar *or*
// cartesian positions (whichever was authored), the `cartesian` flag, speaker
// labels, extent (width/height/depth) and timing; channel/pack formats carry
// their typeDefinition. This is the raw model the front-end adapters consume to
// build the profile-blind canonical scene.

#ifndef ADM2IAMF_ADM_ADM_MODEL_H_
#define ADM2IAMF_ADM_ADM_MODEL_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace adm2iamf {
namespace adm {

enum class TypeDefinition {
  kUndefined = 0,
  kDirectSpeakers = 1,
  kMatrix = 2,
  kObjects = 3,
  kHoa = 4,
  kBinaural = 5,
};

// The BS.2076 typeDefinition name, as authored ("HOA", "Matrix", ...);
// "undefined" for kUndefined.
constexpr const char* TypeDefinitionName(TypeDefinition t) {
  switch (t) {
    case TypeDefinition::kDirectSpeakers:
      return "DirectSpeakers";
    case TypeDefinition::kMatrix:
      return "Matrix";
    case TypeDefinition::kObjects:
      return "Objects";
    case TypeDefinition::kHoa:
      return "HOA";
    case TypeDefinition::kBinaural:
      return "Binaural";
    case TypeDefinition::kUndefined:
      return "undefined";
  }
  return "undefined";
}

// Egocentric polar position. ADM azimuth is positive anticlockwise (to the
// left); elevation positive up; distance normalized 0..1 (default 1).
struct PolarPosition {
  float azimuth = 0.0f;
  float elevation = 0.0f;
  float distance = 1.0f;
};

// Allocentric virtual-cube position (BS.2094-2 Table 1B) or egocentric
// cartesian, per the block's `cartesian` flag. Each component in [-1, 1].
struct CartesianPosition {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
};

struct AudioBlockFormat {
  std::string id;
  double rtime_s = 0.0;     // Start time within the channel (seconds).
  double duration_s = 0.0;  // 0 => static / whole-file.
  bool has_duration = false;
  float gain = 1.0f;  // Linear block gain (default 1).

  bool cartesian = false;  // True => `cart` is authoritative.
  std::optional<PolarPosition> polar;
  std::optional<CartesianPosition> cart;
  std::string speaker_label;  // DirectSpeakers label, e.g. "M+030".

  // Extent (ADM width/height/depth or size), 0 if absent.
  float width = 0.0f;
  float height = 0.0f;
  float depth = 0.0f;

  // Position interpolation: jumpPosition=1 snaps to this position at the block
  // start; 0 (default) interpolates from the previous block.
  // interpolationLength (seconds) is the ramp time when present (else the block
  // duration).
  bool jump_position = false;
  std::optional<double> interpolation_length_s;

  bool has_position() const { return polar.has_value() || cart.has_value(); }
};

struct AudioChannelFormat {
  std::string id;  // e.g. "AC_00010001".
  std::string name;
  TypeDefinition type = TypeDefinition::kUndefined;
  // <frequency> (BS.2076-3 §5.3.2): a lowPass cutoff (~120 Hz) is the spec
  // marker for an LFE channel.
  std::optional<float> low_pass_hz;
  std::optional<float> high_pass_hz;
  std::vector<AudioBlockFormat> blocks;
};

struct AudioPackFormat {
  std::string id;  // e.g. "AP_00010002".
  std::string name;
  TypeDefinition type = TypeDefinition::kUndefined;
  std::vector<std::string> channel_format_id_refs;  // In layout order.
  std::vector<std::string> pack_format_id_refs;     // Nested packs (rare).
};

struct AudioObject {
  std::string id;
  std::string name;
  float gain = 1.0f;  // Linear (ADM gainUnit resolved on parse).
  int importance = 10;
  std::vector<std::string> pack_format_id_refs;
  std::vector<std::string> track_uid_refs;
};

struct AudioContent {
  std::string id;
  std::string name;
  std::vector<std::string> object_id_refs;
};

struct LoudnessMetadata {
  std::optional<float> integrated_loudness;
  std::optional<float> max_true_peak;
  std::optional<float> dialogue_loudness;
};

struct AudioProgramme {
  std::string id;
  std::string name;
  std::vector<std::string> content_id_refs;
  LoudnessMetadata loudness;
};

// One `chna` row: binds a WAV track (1-based) to an audioTrackUID and its
// track/pack format references.
struct ChnaEntry {
  uint16_t track_index = 0;  // 1-based; 0 = unused row.
  std::string uid;           // audioTrackUID, e.g. "ATU_00000001".
  std::string track_ref;     // audioTrackFormatID "AT_..." (or "AC_...").
  std::string pack_ref;      // audioPackFormatID "AP_...".

  // Channel format implied by `track_ref` ("AT_00010001_01" => "AC_00010001";
  // an "AC_..." track_ref is returned as-is). Empty if not derivable.
  std::string ChannelFormatId() const;
};

struct Model {
  std::vector<AudioProgramme> programmes;
  std::vector<AudioContent> contents;
  std::vector<AudioObject> objects;
  std::vector<AudioPackFormat> packs;
  std::vector<AudioChannelFormat> channels;
  std::vector<ChnaEntry> chna;

  // Lookups by ADM id (nullptr if absent).
  const AudioPackFormat* Pack(const std::string& id) const;
  const AudioChannelFormat* Channel(const std::string& id) const;
  const AudioObject* Object(const std::string& id) const;

  // chna track index (1-based) for the given audioChannelFormat id, or 0.
  uint16_t TrackIndexForChannel(const std::string& channel_format_id) const;

  // chna track index (1-based) for the given audioTrackUID, or 0.
  uint16_t TrackIndexForUid(const std::string& uid) const;
};

}  // namespace adm
}  // namespace adm2iamf

#endif  // ADM2IAMF_ADM_ADM_MODEL_H_
