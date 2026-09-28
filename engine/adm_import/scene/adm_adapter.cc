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

#include "adm_import/scene/adm_adapter.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "absl/container/flat_hash_set.h"
#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/ascii.h"
#include "absl/strings/match.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/str_join.h"
#include "adm_import/adm/adm_model.h"
#include "adm_import/adm/adm_vocabulary.h"
#include "adm_import/scene/bs2127.h"
#include "adm_import/scene/cube_grid.h"
#include "adm_import/scene/layouts.h"
#include "adm_import/scene/scene.h"

namespace adm2iamf {
namespace {

using adm::AudioChannelFormat;
using adm::AudioObject;
using adm::AudioPackFormat;
using adm::Model;
using adm::TypeDefinition;

// A lowPass <frequency> at or below this cutoff marks an LFE channel
// (BS.2076-3 §5.3.2; in practice always ~120 Hz).
constexpr float kMaxLfeCutoffHz = 500.0f;

// Divergence threshold between a recognized label's nominal direction and
// the authored polar position before a warning is attached.
constexpr float kLabelDivergenceDeg = 5.0f;

float AngleDiff(float a, float b) {
  float d = std::fmod(std::abs(a - b), 360.0f);
  return d > 180.0f ? 360.0f - d : d;
}

bool ContainsLfe(absl::string_view s) {
  return absl::StrContains(absl::AsciiStrToLower(s), "lfe");
}

// A resolved bed channel: the Source to render (absent when unresolved)
// plus the always-present resolution record.
struct ResolvedChannel {
  std::optional<Source> source;
  ChannelResolution record;
};

// Pack-level context for cube classification: whether the pack occupies
// the side slots (±1,0,0) / M±090 — Table 2B's rear disambiguation.
PackContext ContextForPack(const Model& model, const AudioPackFormat& pack) {
  PackContext ctx;
  for (const std::string& ch_id : pack.channel_format_id_refs) {
    const AudioChannelFormat* ch = model.Channel(ch_id);
    if (ch == nullptr || ch->blocks.empty()) continue;
    const adm::AudioBlockFormat& b = ch->blocks.front();
    if (b.cart.has_value()) {
      auto m = ClassifyCubePosition(b.cart->x, b.cart->y, b.cart->z,
                                    /*prefer_lfe=*/false, PackContext{});
      if (m.has_value() &&
          (m->slot->label == "M_SL" || m->slot->label == "M_SR")) {
        ctx.has_sides = true;
        return ctx;
      }
    }
    if (!b.speaker_label.empty()) {
      auto s = ResolveSpeakerLabel(b.speaker_label);
      if (s.has_value() && !s->is_lfe && s->elevation == 0.0f &&
          std::abs(s->azimuth) == 90.0f) {
        ctx.has_sides = true;
        return ctx;
      }
    }
  }
  return ctx;
}

// Resolves one bed channel, position-first:
//   1. lowPass <frequency>  -> LFE (the spec marker).
//   2. Recognized LFE label -> LFE (labels route LFE regardless of position).
//   3. Explicit polar       -> used directly (EBU/ITU DirectSpeakers).
//   4. Recognized label     -> nominal loudspeaker direction.
//   5. Cartesian            -> cube-grid slot (BS.2094 Table 1B/2B).
//   6. Off-grid cartesian   -> naive physical direction, warned.
//   7. Nothing              -> unresolved, channel dropped but surfaced.
//
// Known degradation: the channel-name leniency (a label resolved from
// ch.name when the block carries no speakerLabel) participates in rung 4,
// so a structurally-parseable name outranks an authored cartesian position,
// and name-derived Table 1B labels resolve without pack context (rears at
// the no-sides ±110). Kept as-is deliberately: the corpus gate certifies
// current behavior byte-identical, and re-ranking needs a corpus re-run.
ResolvedChannel ResolveChannel(const AudioChannelFormat& ch,
                               const PackContext& context) {
  ResolvedChannel out;
  ChannelResolution& rec = out.record;
  rec.channel_id = ch.id;
  rec.channel_name = ch.name;

  const adm::AudioBlockFormat* block =
      ch.blocks.empty() ? nullptr : &ch.blocks.front();
  if (block != nullptr) rec.speaker_label = block->speaker_label;

  Source src;
  src.label = ch.name.empty() ? ch.id : ch.name;

  const auto resolve = [&](ResolutionMethod method, bool is_lfe, bool fallback,
                           std::string note) {
    rec.method = method;
    rec.resolved = true;
    rec.is_lfe = is_lfe;
    rec.fallback = fallback;
    rec.note = std::move(note);
    src.is_lfe = is_lfe;
    out.source = std::move(src);
  };

  // Label resolution: the block's speakerLabel, with the channel name as a
  // documented leniency (common-def channels synthesized from chna carry
  // their label as the name). Resolved up front so rung 1 can tell whether
  // the frequency marker agrees with an authored label.
  std::optional<Speaker> by_label;
  bool label_from_name = false;
  if (block != nullptr && !block->speaker_label.empty()) {
    by_label = ResolveSpeakerLabel(block->speaker_label);
  }
  if (!by_label.has_value() && !ch.name.empty()) {
    by_label = ResolveSpeakerLabel(ch.name);
    label_from_name = by_label.has_value();
  }

  // 1. The spec LFE marker: a lowPass frequency cutoff. It outranks the
  // label, but silently discarding an authored non-LFE direction would be
  // the one rung that can misroute audio without surfacing it -- so a
  // contradicting spec label is recorded as a divergence.
  if (ch.low_pass_hz.has_value() && *ch.low_pass_hz <= kMaxLfeCutoffHz) {
    const bool contradicts =
        by_label.has_value() && !by_label->is_lfe && !label_from_name;
    resolve(ResolutionMethod::kLfeFrequency, true, false,
            contradicts ? absl::StrCat("label ", by_label->name,
                                       " is a non-LFE speaker but a lowPass "
                                       "<frequency> of ",
                                       *ch.low_pass_hz,
                                       " Hz marks the channel as LFE; "
                                       "routed to LFE")
                        : "");
    rec.divergence = contradicts;
    return out;
  }

  // 2. A recognized LFE label routes to the LFE bus (never panned).
  if (by_label.has_value() && by_label->is_lfe) {
    resolve(ResolutionMethod::kLfeLabel, true, label_from_name,
            label_from_name ? "LFE resolved from the channel name" : "");
    return out;
  }

  // 3. Explicit egocentric polar (EBU/ITU DirectSpeakers) is authoritative.
  if (block != nullptr && block->polar.has_value() && !block->cartesian) {
    src.position = {block->polar->azimuth, block->polar->elevation,
                    block->polar->distance};
    std::string note;
    bool divergence = false;
    if (by_label.has_value() && !label_from_name &&
        (AngleDiff(by_label->azimuth, block->polar->azimuth) >
             kLabelDivergenceDeg ||
         AngleDiff(by_label->elevation, block->polar->elevation) >
             kLabelDivergenceDeg)) {
      divergence = true;
      note = absl::StrCat("label ", by_label->name, " is at (",
                          by_label->azimuth, ", ", by_label->elevation,
                          ") but the position element says (",
                          block->polar->azimuth, ", ", block->polar->elevation,
                          "); position used");
    }
    resolve(ResolutionMethod::kPolar, false, false, std::move(note));
    rec.divergence = divergence;
    return out;
  }

  // 4. Recognized speaker label -> nominal loudspeaker direction. Cube
  // labels (Table 1B) get the pack-context-aware Table 2B direction.
  if (by_label.has_value()) {
    Speaker sp = *by_label;
    if (!label_from_name && block != nullptr) {
      const CubeSlot* slot = CubeSlotByLabel(
          adm::vocab::StripSpeakerLabelUrn(block->speaker_label));
      if (slot != nullptr) {
        const CubeMatch m = ResolveCubeSlot(*slot, context);
        sp.name = std::string(m.polar_label);
        sp.azimuth = m.azimuth;
        sp.elevation = m.elevation;
      }
    }
    src.position = {sp.azimuth, sp.elevation, 1.0f};
    resolve(ResolutionMethod::kSpecLabel, false, label_from_name,
            label_from_name
                ? absl::StrCat("direction resolved from the channel name (",
                               sp.name, ")")
                : "");
    return out;
  }

  if (block != nullptr && block->cart.has_value()) {
    // 5. Cartesian position -> cube-grid slot. An "LFE" substring in the
    // (unrecognized) label or name corroborates the LFE cube slots.
    const bool prefer_lfe =
        ContainsLfe(block->speaker_label) || ContainsLfe(ch.name);
    const auto m = ClassifyCubePosition(block->cart->x, block->cart->y,
                                        block->cart->z, prefer_lfe, context);
    if (m.has_value()) {
      const std::string label_part =
          block->speaker_label.empty()
              ? "no speakerLabel"
              : absl::StrCat("unrecognized speakerLabel \"",
                             block->speaker_label, "\"");
      if (m->is_lfe) {
        resolve(ResolutionMethod::kLfeCube, true, true,
                absl::StrCat(label_part, "; cube position matched ",
                             m->slot->label));
        return out;
      }
      src.position = {m->azimuth, m->elevation, 1.0f};
      std::string note = absl::StrCat(label_part, "; cube position matched ",
                                      m->slot->label, " -> ", m->polar_label);
      if (m->lfe_ambiguous) {
        note += "; position coincides with an LFE slot";
      }
      resolve(ResolutionMethod::kCubeSlot, false, true, std::move(note));
      rec.lfe_ambiguous = m->lfe_ambiguous;
      return out;
    }

    // 6. Off-grid cartesian: a loudspeaker's room position maps to its
    // physical direction (naive atan2, not the BS.2127 object warp).
    src.position = {
        static_cast<float>(bs2127::Azimuth(block->cart->x, block->cart->y)),
        static_cast<float>(
            bs2127::Elevation(block->cart->x, block->cart->y, block->cart->z)),
        1.0f};
    resolve(ResolutionMethod::kPhysicalFallback, false, true,
            absl::StrCat("cartesian position (", block->cart->x, ", ",
                         block->cart->y, ", ", block->cart->z,
                         ") is off the BS.2094 cube grid; physical direction "
                         "used"));
    return out;
  }

  // 7. Nothing usable.
  rec.method = ResolutionMethod::kUnresolved;
  rec.resolved = false;
  rec.note = "no frequency marker, recognized label, or position";
  return out;
}

// Objects reachable from the programme/content graph; if there are no
// programmes, every object is considered used.
std::vector<const AudioObject*> UsedObjects(const Model& model) {
  std::vector<const AudioObject*> used;
  if (model.programmes.empty()) {
    for (const auto& o : model.objects) used.push_back(&o);
    return used;
  }
  absl::flat_hash_set<std::string> object_ids;
  for (const auto& prog : model.programmes) {
    for (const auto& cref : prog.content_id_refs) {
      for (const auto& content : model.contents) {
        if (content.id != cref) continue;
        for (const auto& oref : content.object_id_refs) object_ids.insert(oref);
      }
    }
  }
  for (const auto& o : model.objects) {
    if (object_ids.contains(o.id)) used.push_back(&o);
  }
  return used;
}

// Resolves a dynamic object block's position in its authored system.
// Cartesian/allocentric positions stay cartesian — the render backends
// convert per target layout (OAR layout-anchored conversion, ES-567) — with
// each coordinate clamped to the room cube (the §7.3.1 clamp's cartesian
// counterpart; the conversion's anchor solve assumes cube-bounded input).
// Clamping an out-of-cube position changes its direction, so each clamped
// value increments `*clamped` and the probe surfaces a warning — the spec
// itself does not bound X/Y/Z, which is why the audit deliberately does not
// flag them. Polar distance is clamped to [0,1] (§7.3.1); no 1/d level law
// applied. Polar azimuth is wrapped to (-180, 180] the way OLR wraps it
// before panning (`__wrap_azimuth`), so the probe's label and the rendered
// direction agree for out-of-range authored values (ES-627); the audit still
// flags those values.
float WrapAzimuth(float azimuth) {
  azimuth = std::fmod(azimuth, 360.0f);
  if (azimuth > 180.0f) {
    azimuth -= 360.0f;
  } else if (azimuth <= -180.0f) {
    azimuth += 360.0f;
  }
  return azimuth;
}

ObjectPosition ResolveObjectPosition(const adm::AudioBlockFormat& block,
                                     int* clamped) {
  ObjectPosition p;
  if (block.cart.has_value() && (block.cartesian || !block.polar.has_value())) {
    p.cartesian = true;
    const auto clamp1 = [&](double v) {
      const float c = std::clamp(static_cast<float>(v), -1.0f, 1.0f);
      if (static_cast<double>(c) != v) ++(*clamped);
      return c;
    };
    p.cube = {clamp1(block.cart->x), clamp1(block.cart->y),
              clamp1(block.cart->z)};
    return p;
  }
  if (block.polar.has_value()) {
    p.polar = {WrapAzimuth(block.polar->azimuth), block.polar->elevation,
               std::clamp(block.polar->distance, 0.0f, 1.0f)};
  }
  return p;
}

// Resolves the WAV track for a source: by audioTrackUID (objects) if available,
// else by audioChannelFormat id (beds), else sequential when no chna exists.
uint16_t ResolveTrack(const Model& model, const std::string& uid,
                      const std::string& channel_id, bool have_chna,
                      int& sequential) {
  if (!uid.empty()) {
    if (uint16_t t = model.TrackIndexForUid(uid)) return t;
  }
  if (uint16_t t = model.TrackIndexForChannel(channel_id)) return t;
  if (!have_chna) return static_cast<uint16_t>(++sequential);
  return 0;
}

// Records a channel that could not be turned into a source.
void RecordUnresolved(Scene& scene, const std::string& channel_id,
                      const std::string& channel_name, std::string note) {
  ChannelResolution rec;
  rec.channel_id = channel_id;
  rec.channel_name = channel_name;
  rec.method = ResolutionMethod::kUnresolved;
  rec.resolved = false;
  rec.note = std::move(note);
  scene.resolutions.push_back(std::move(rec));
}

// Records a channel of a pack the importer cannot render. The note reads as
// the middle of a sentence ("Channel X <note> and will not be rendered.") so
// the probe's warning and the unresolved-channel list share it.
void RecordUnsupportedPack(Scene& scene, const std::string& channel_id,
                           const std::string& channel_name,
                           TypeDefinition type) {
  ChannelResolution rec;
  rec.channel_id = channel_id;
  rec.channel_name = channel_name;
  rec.method = ResolutionMethod::kUnsupportedPack;
  rec.resolved = false;
  rec.note =
      type == TypeDefinition::kUndefined
          ? "belongs to a pack with no typeDefinition; this content cannot "
            "be interpreted"
          : absl::StrCat("belongs to ",
                         type == TypeDefinition::kHoa ? "an " : "a ",
                         adm::TypeDefinitionName(type),
                         " pack; this content type is not yet supported");
  scene.resolutions.push_back(std::move(rec));
}

}  // namespace

absl::StatusOr<Scene> BuildSceneFromAdm(const Model& model) {
  Scene scene;
  const bool have_chna = !model.chna.empty();
  int sequential_track = 0;  // Fallback when no chna table exists.

  absl::flat_hash_set<std::string> processed_packs;

  for (const AudioObject* obj : UsedObjects(model)) {
    for (const std::string& pack_ref : obj->pack_format_id_refs) {
      const AudioPackFormat* pack = model.Pack(pack_ref);
      if (pack == nullptr) continue;

      if (pack->type == TypeDefinition::kDirectSpeakers) {
        // Bed: shared across objects, so process each pack once.
        if (!processed_packs.insert(pack_ref).second) continue;
        const PackContext context = ContextForPack(model, *pack);
        for (const std::string& ch_id : pack->channel_format_id_refs) {
          const AudioChannelFormat* ch = model.Channel(ch_id);
          // Resolve the track before any bail-out: with no chna table the
          // fallback is sequential, so a dangling channel ref must still
          // consume its index or every later channel in the pack shifts one
          // track down (wrong audio on the wrong speaker).
          const uint16_t ti =
              ResolveTrack(model, "", ch_id, have_chna, sequential_track);
          if (ch == nullptr) {
            RecordUnresolved(scene, ch_id, "",
                             "audioChannelFormat definition not found");
            continue;
          }
          ResolvedChannel resolved = ResolveChannel(*ch, context);
          if (ti == 0) {
            resolved.record.resolved = false;
            resolved.record.method = ResolutionMethod::kUnresolved;
            if (resolved.record.note.empty()) {
              resolved.record.note = "no WAV track binds to this channel";
            } else {
              resolved.record.note +=
                  "; but no WAV track binds to this channel";
            }
            scene.resolutions.push_back(std::move(resolved.record));
            continue;
          }
          if (resolved.source.has_value()) {
            resolved.source->gain = obj->gain;
            resolved.source->track_index = ti;
            resolved.record.source_index =
                static_cast<int>(scene.sources.size());
            scene.sources.push_back(*std::move(resolved.source));
          }
          scene.resolutions.push_back(std::move(resolved.record));
        }
      } else if (pack->type == TypeDefinition::kObjects) {
        // Object: zip the pack's channel(s) with the object's track UID(s).
        const auto& cids = pack->channel_format_id_refs;
        for (size_t k = 0; k < cids.size(); ++k) {
          const AudioChannelFormat* ch = model.Channel(cids[k]);
          const std::string uid =
              k < obj->track_uid_refs.size() ? obj->track_uid_refs[k] : "";
          uint16_t ti =
              ResolveTrack(model, uid, cids[k], have_chna, sequential_track);
          if (ch == nullptr || ch->blocks.empty() || ti == 0) {
            RecordUnresolved(
                scene, cids[k], ch == nullptr ? "" : ch->name,
                ch == nullptr        ? "audioChannelFormat definition not found"
                : ch->blocks.empty() ? "object channel has no audioBlockFormat"
                                     : "no WAV track binds to this channel");
            continue;
          }
          ObjectSource os;
          os.label = obj->name.empty() ? obj->id : obj->name;
          os.track_index = ti;
          os.importance = obj->importance;
          os.timeline.reserve(ch->blocks.size());
          for (const adm::AudioBlockFormat& b : ch->blocks) {
            ObjectKeyframe kf;
            kf.start_s = b.rtime_s;
            kf.duration_s = b.duration_s;
            kf.has_duration = b.has_duration;
            kf.position =
                ResolveObjectPosition(b, &scene.clamped_object_values);
            kf.gain = b.gain * obj->gain;
            kf.jump = b.jump_position;
            kf.interp_length_s = b.interpolation_length_s;
            os.timeline.push_back(kf);
          }
          scene.objects.push_back(std::move(os));
        }
      } else {
        // A pack type the importer cannot render: HOA, Matrix, Binaural, or
        // no typeDefinition at all. Record every channel as unresolved with
        // its own method so the probe names the type, instead of dropping
        // the content in silence (ES-623). Each channel still consumes its
        // track exactly as a rendered one would: with no chna table the
        // fallback numbering is sequential, so a skipped channel that did not
        // burn its index would shift every later channel one track down. A
        // pack bound through the object's track UIDs is per object; one
        // bound by channel format (bed-like) is shared and recorded once.
        const bool per_object = !obj->track_uid_refs.empty();
        if (!per_object && !processed_packs.insert(pack_ref).second) continue;
        const auto& cids = pack->channel_format_id_refs;
        for (size_t k = 0; k < cids.size(); ++k) {
          const AudioChannelFormat* ch = model.Channel(cids[k]);
          const std::string uid =
              k < obj->track_uid_refs.size() ? obj->track_uid_refs[k] : "";
          ResolveTrack(model, uid, cids[k], have_chna, sequential_track);
          RecordUnsupportedPack(scene, cids[k], ch == nullptr ? "" : ch->name,
                                pack->type);
        }
      }
    }
  }

  if (scene.sources.empty() && scene.objects.empty()) {
    std::vector<std::string> unresolved;
    for (const ChannelResolution& r : scene.resolutions) {
      if (!r.resolved) unresolved.push_back(r.channel_id);
    }
    return absl::InvalidArgumentError(absl::StrCat(
        "No renderable bed or object reachable from the programme/objects.",
        unresolved.empty()
            ? ""
            : absl::StrCat(" Unresolved channels: ",
                           absl::StrJoin(unresolved, ", "), ".")));
  }
  return scene;
}

}  // namespace adm2iamf
