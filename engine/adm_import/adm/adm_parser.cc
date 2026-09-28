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

#include "adm_import/adm/adm_parser.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/numbers.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/str_split.h"
#include "absl/strings/string_view.h"
#include "absl/types/span.h"
#include "adm_import/adm/adm_model.h"
#include "adm_import/adm/xml.h"

namespace adm2iamf {
namespace adm {
namespace {

TypeDefinition ResolveTypeDefinition(const XmlNode& node) {
  // Prefer the textual typeDefinition; fall back to the numeric typeLabel.
  std::string td = node.AttrOr("typeDefinition", "");
  std::string tl = node.AttrOr("typeLabel", "");
  if (td == "DirectSpeakers" || tl == "0001")
    return TypeDefinition::kDirectSpeakers;
  if (td == "Matrix" || tl == "0002") return TypeDefinition::kMatrix;
  if (td == "Objects" || tl == "0003") return TypeDefinition::kObjects;
  if (td == "HOA" || tl == "0004") return TypeDefinition::kHoa;
  if (td == "Binaural" || tl == "0005") return TypeDefinition::kBinaural;
  return TypeDefinition::kUndefined;
}

bool AllDigits(absl::string_view s) {
  if (s.empty()) return false;
  for (char c : s) {
    if (c < '0' || c > '9') return false;
  }
  return true;
}

// Splits on ':' and validates digit runs (the last field may carry a
// ".digits" fraction). Returns nullopt unless there are 1-3 clean fields.
std::optional<double> ParseColonFields(absl::string_view s) {
  std::vector<absl::string_view> fields = absl::StrSplit(s, ':');
  if (fields.empty() || fields.size() > 3) return std::nullopt;
  for (size_t i = 0; i + 1 < fields.size(); ++i) {
    if (!AllDigits(fields[i])) return std::nullopt;
  }
  const absl::string_view last = fields.back();
  const size_t dot = last.find('.');
  if (dot == absl::string_view::npos) {
    if (!AllDigits(last)) return std::nullopt;
  } else if (!AllDigits(last.substr(0, dot)) ||
             !AllDigits(last.substr(dot + 1))) {
    return std::nullopt;
  }
  double value = 0;
  double scale = 1.0;
  for (size_t i = fields.size(); i-- > 0; scale *= 60.0) {
    double f = 0;
    absl::SimpleAtod(fields[i], &f);  // Validated above; cannot fail.
    value += f * scale;
  }
  // SimpleAtod rounds overflow to inf and still succeeds; a pathological
  // digit run must not leak a non-finite time into scene timing.
  if (!std::isfinite(value)) return std::nullopt;
  return value;
}

}  // namespace

std::optional<double> ParseTimecode(absl::string_view s) {
  if (s.empty()) return std::nullopt;

  const size_t s_pos = s.find('S');
  if (s_pos == absl::string_view::npos) {
    // Decimal form "hh:mm:ss.zzzzz" plus the lenient "mm:ss" and
    // bare-seconds shapes. The audit grades leniency; here any clean
    // colon/digit shape parses.
    return ParseColonFields(s);
  }

  // Fractional-sample forms (§5.13): the fraction is a sample count over a
  // sample rate rather than a decimal.
  uint64_t rate = 0;
  const absl::string_view den = s.substr(s_pos + 1);
  if (!AllDigits(den) || !absl::SimpleAtoi(den, &rate) || rate == 0) {
    return std::nullopt;
  }
  const absl::string_view num = s.substr(0, s_pos);
  if (num.find(':') == absl::string_view::npos) {
    // Shortform "<samples>S<rate>": a plain count of samples since zero.
    uint64_t samples = 0;
    if (!AllDigits(num) || !absl::SimpleAtoi(num, &samples)) {
      return std::nullopt;
    }
    return static_cast<double>(samples) / static_cast<double>(rate);
  }
  // Long form "hh:mm:ss.<samples>S<rate>".
  const size_t dot = num.find('.');
  if (dot == absl::string_view::npos) return std::nullopt;
  uint64_t samples = 0;
  const absl::string_view frac = num.substr(dot + 1);
  if (!AllDigits(frac) || !absl::SimpleAtoi(frac, &samples)) {
    return std::nullopt;
  }
  const std::optional<double> base = ParseColonFields(num.substr(0, dot));
  if (!base.has_value()) return std::nullopt;
  return *base + static_cast<double>(samples) / static_cast<double>(rate);
}

namespace {

float ParseFloatOr(absl::string_view s, float fallback) {
  double d = 0;
  // Reject empty, unparseable, and non-finite input. absl::SimpleAtod accepts
  // "inf"/"nan"; these ADM numeric fields feed gains and geometry, so a stray
  // non-finite value must fall back rather than propagate into the render.
  if (s.empty() || !absl::SimpleAtod(s, &d) || !std::isfinite(d)) {
    return fallback;
  }
  return static_cast<float>(d);
}

// Collects all descendants (self included) named `name`, document order.
void CollectDescendants(const XmlNode& node, absl::string_view name,
                        std::vector<const XmlNode*>& out) {
  if (node.name == name) out.push_back(&node);
  for (const auto& c : node.children) CollectDescendants(c, name, out);
}

AudioBlockFormat ParseBlock(const XmlNode& b) {
  AudioBlockFormat block;
  block.id = b.AttrOr("audioBlockFormatID", "");
  block.rtime_s = ParseTimecode(b.AttrOr("rtime", "")).value_or(0.0);
  if (const std::string* d = b.Attr("duration")) {
    block.duration_s = ParseTimecode(*d).value_or(0.0);
    block.has_duration = true;
  }

  PolarPosition polar;
  CartesianPosition cart;
  bool have_polar = false, have_cart = false;

  for (const XmlNode* pos : b.Children("position")) {
    const std::string coord = pos->AttrOr("coordinate", "");
    const float v = ParseFloatOr(pos->text, 0.0f);
    if (coord == "azimuth") {
      polar.azimuth = v;
      have_polar = true;
    } else if (coord == "elevation") {
      polar.elevation = v;
      have_polar = true;
    } else if (coord == "distance") {
      polar.distance = v;
      have_polar = true;
    } else if (coord == "X") {
      cart.x = v;
      have_cart = true;
    } else if (coord == "Y") {
      cart.y = v;
      have_cart = true;
    } else if (coord == "Z") {
      cart.z = v;
      have_cart = true;
    }
  }

  if (const XmlNode* c = b.Child("cartesian")) {
    block.cartesian = (c->text == "1" || c->text == "true");
  } else if (have_cart && !have_polar) {
    block.cartesian = true;
  }
  if (have_polar) block.polar = polar;
  if (have_cart) block.cart = cart;

  if (const XmlNode* sl = b.Child("speakerLabel"))
    block.speaker_label = sl->text;
  if (const XmlNode* g = b.Child("gain")) {
    float val = ParseFloatOr(g->text, 1.0f);
    if (g->AttrOr("gainUnit", "linear") == "dB")
      val = std::pow(10.0f, val / 20.0f);
    block.gain = val;
  }
  if (const XmlNode* w = b.Child("width"))
    block.width = ParseFloatOr(w->text, 0);
  if (const XmlNode* h = b.Child("height"))
    block.height = ParseFloatOr(h->text, 0);
  if (const XmlNode* d = b.Child("depth"))
    block.depth = ParseFloatOr(d->text, 0);
  if (const XmlNode* j = b.Child("jumpPosition")) {
    block.jump_position = (j->text == "1" || j->text == "true");
    if (const std::string* il = j->Attr("interpolationLength")) {
      block.interpolation_length_s = ParseTimecode(*il).value_or(0.0);
    }
  }
  return block;
}

}  // namespace

Model BuildModel(const XmlNode& root) {
  // ADM elements may sit under various wrappers; gather them by descendant
  // search from whichever node holds them.
  const XmlNode* scope = root.FindDescendant("audioFormatExtended");
  if (scope == nullptr) scope = &root;

  Model model;

  std::vector<const XmlNode*> nodes;

  nodes.clear();
  CollectDescendants(*scope, "audioProgramme", nodes);
  for (const XmlNode* n : nodes) {
    AudioProgramme p;
    p.id = n->AttrOr("audioProgrammeID", "");
    p.name = n->AttrOr("audioProgrammeName", "");
    for (const XmlNode* r : n->Children("audioContentIDRef")) {
      p.content_id_refs.push_back(r->text);
    }
    if (const XmlNode* lm = n->FindDescendant("loudnessMetadata")) {
      if (const XmlNode* il = lm->Child("integratedLoudness")) {
        p.loudness.integrated_loudness = ParseFloatOr(il->text, 0);
      }
      if (const XmlNode* tp = lm->Child("maxTruePeak")) {
        p.loudness.max_true_peak = ParseFloatOr(tp->text, 0);
      }
      if (const XmlNode* dl = lm->Child("dialogueLoudness")) {
        p.loudness.dialogue_loudness = ParseFloatOr(dl->text, 0);
      }
    }
    model.programmes.push_back(std::move(p));
  }

  nodes.clear();
  CollectDescendants(*scope, "audioContent", nodes);
  for (const XmlNode* n : nodes) {
    AudioContent c;
    c.id = n->AttrOr("audioContentID", "");
    c.name = n->AttrOr("audioContentName", "");
    for (const XmlNode* r : n->Children("audioObjectIDRef")) {
      c.object_id_refs.push_back(r->text);
    }
    model.contents.push_back(std::move(c));
  }

  nodes.clear();
  CollectDescendants(*scope, "audioObject", nodes);
  for (const XmlNode* n : nodes) {
    AudioObject o;
    o.id = n->AttrOr("audioObjectID", "");
    o.name = n->AttrOr("audioObjectName", "");
    // BS.2076 importance is an integer in [0, 10]; a value outside the
    // range (or a non-integer) is clamped rather than propagated, so a
    // min_importance filter compares against a legal value.
    o.importance = static_cast<int>(std::lround(std::clamp(
        ParseFloatOr(n->AttrOr("importance", "10"), 10), 0.0f, 10.0f)));
    for (const XmlNode* r : n->Children("audioPackFormatIDRef")) {
      o.pack_format_id_refs.push_back(r->text);
    }
    for (const XmlNode* r : n->Children("audioTrackUIDRef")) {
      o.track_uid_refs.push_back(r->text);
    }
    if (const XmlNode* g = n->Child("gain")) {
      float val = ParseFloatOr(g->text, 1.0f);
      if (g->AttrOr("gainUnit", "linear") == "dB") {
        val = std::pow(10.0f, val / 20.0f);
      }
      o.gain = val;
    }
    model.objects.push_back(std::move(o));
  }

  nodes.clear();
  CollectDescendants(*scope, "audioPackFormat", nodes);
  for (const XmlNode* n : nodes) {
    AudioPackFormat p;
    p.id = n->AttrOr("audioPackFormatID", "");
    p.name = n->AttrOr("audioPackFormatName", "");
    p.type = ResolveTypeDefinition(*n);
    for (const XmlNode* r : n->Children("audioChannelFormatIDRef")) {
      p.channel_format_id_refs.push_back(r->text);
    }
    for (const XmlNode* r : n->Children("audioPackFormatIDRef")) {
      p.pack_format_id_refs.push_back(r->text);
    }
    model.packs.push_back(std::move(p));
  }

  nodes.clear();
  CollectDescendants(*scope, "audioChannelFormat", nodes);
  for (const XmlNode* n : nodes) {
    AudioChannelFormat c;
    c.id = n->AttrOr("audioChannelFormatID", "");
    c.name = n->AttrOr("audioChannelFormatName", "");
    c.type = ResolveTypeDefinition(*n);
    for (const XmlNode* f : n->Children("frequency")) {
      const float hz = ParseFloatOr(f->text, 0.0f);
      if (hz <= 0.0f) continue;
      const std::string td = f->AttrOr("typeDefinition", "");
      if (td == "lowPass") {
        c.low_pass_hz = hz;
      } else if (td == "highPass") {
        c.high_pass_hz = hz;
      }
    }
    for (const XmlNode* b : n->Children("audioBlockFormat")) {
      c.blocks.push_back(ParseBlock(*b));
    }
    model.channels.push_back(std::move(c));
  }

  return model;
}

absl::StatusOr<Model> ParseAxml(absl::string_view axml) {
  auto root = ParseXml(axml);
  if (!root.ok()) return root.status();
  return BuildModel(*root);
}

absl::StatusOr<std::vector<ChnaEntry>> ParseChna(
    absl::Span<const uint8_t> chna) {
  // BS.2088 chna: numTracks(2) numUIDs(2), then 40-byte rows.
  if (chna.size() < 4) {
    return absl::InvalidArgumentError("chna chunk too small.");
  }
  const uint16_t num_uids =
      static_cast<uint16_t>(chna[2]) | (static_cast<uint16_t>(chna[3]) << 8);

  constexpr size_t kRow = 40;
  auto field = [&](size_t off, size_t len) {
    const char* p = reinterpret_cast<const char*>(chna.data() + off);
    // Stop at the first NUL: ADM UIDs are ASCII, so an interior NUL is
    // malformed padding. Keeping bytes past it would leave an embedded NUL in
    // the string, which silently breaks downstream UID / channel-format
    // lookups. Then strip any trailing spaces.
    size_t n = static_cast<size_t>(std::find(p, p + len, '\0') - p);
    while (n > 0 && p[n - 1] == ' ') --n;
    return std::string(p, n);
  };

  std::vector<ChnaEntry> out;
  for (uint16_t i = 0; i < num_uids; ++i) {
    const size_t base = 4 + static_cast<size_t>(i) * kRow;
    if (base + kRow > chna.size()) break;  // Truncated table; stop.
    ChnaEntry e;
    e.track_index = static_cast<uint16_t>(chna[base]) |
                    (static_cast<uint16_t>(chna[base + 1]) << 8);
    e.uid = field(base + 2, 12);
    e.track_ref = field(base + 14, 14);
    e.pack_ref = field(base + 28, 11);
    out.push_back(std::move(e));
  }
  return out;
}

}  // namespace adm
}  // namespace adm2iamf
