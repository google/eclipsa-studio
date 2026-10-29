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

// Pins OAR's channel order and speaker geometry per layout (ES-592).
//
// The app names, meters and draws channels from tables in Dart
// (`SpeakerLayout`, `iamfChannelLabels`). Those were pinned only against
// hand-transcribed copies of themselves, so an OAR_COMMIT bump that
// reordered a layout or moved a speaker would change what the engine
// renders while every Dart test stayed green. The ES-552 mislabels had
// the same cause one layer up, in the Dart tables.
//
// The order is defined by the OAR fork's own table
// (src/renderer/olr/object_audio_renderer/layout.c). That package is
// visible only inside the oar repo, so this test cannot read the table;
// it pins the behaviour the table produces instead. For every speaker of
// every target layout it renders one object placed at that speaker's
// nominal angles and asserts the signal comes out of that speaker's
// output channel alone. A reorder moves the energy to another index; a
// moved speaker spreads it across the pair that now straddles the angle.
// Either change fails this test.
//
// The expected rows live in renderer/channel_layouts.txt, the key to
// every channel name and order over the IAMF and OAR layer, which
// app/test/renderer/channel_layouts_test.dart reads as well, so the
// Dart tables are pinned to the same transcription this test verifies.
// Each row also carries the channel's IAMF name and the app's short and
// long labels ("L", "Left"); OAR does not define those, so this test
// only checks that they are present, distinct within a layout and
// consistent across layouts, and the Dart test pins them.
//
// On the binaural target OAR passes a channel-based element to OBR,
// which renders each channel from a virtual loudspeaker of its own table
// (obr/renderer/loudspeaker_layouts.h) rather than from the angles OLR
// uses. The table's `<layout id>-binaural` sections transcribe those
// positions for the 3D scene. The OBR table is private to its package
// too, but obr::ObrImpl lists each element's channel positions in the
// table GetAudioElementConfigLogMessage() returns, so this test reads
// them from there.

#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <ostream>
#include <set>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#include "absl/status/status.h"
#include "adm_import/scene/layouts.h"
#include "gtest/gtest.h"
#include "obr/renderer/audio_element_type.h"
#include "obr/renderer/obr_impl.h"
#include "renderer/channel_order.h"

extern "C" {
#include "oar.h"
}

namespace {

constexpr uint32_t kBlock = 512;
constexpr uint32_t kRate = 48000;
constexpr uint32_t kElemId = 1;
// Blocks rendered per position: OAR ramps element gains across a block,
// so the first blocks after a move still carry the previous position.
// Only the last block is measured.
constexpr uint32_t kSettleBlocks = 8;
// Input level, low enough that the output limiter never engages.
constexpr float kInputLevel = 0.25f;
// A source at a speaker's exact angles pans entirely onto that speaker.
// The margins allow for the gain ramp's final step and float rounding.
constexpr float kMinOnAxis = 0.99f;
constexpr float kMaxOffAxis = 0.01f;

// A binaural row carries only the OAR code and the angles: its names are
// empty and is_lfe stays false, so the LFE flag of a binaural section's
// channel is the one in its layout section's row.
struct Row {
  std::string label;       // OAR's own code, e.g. "M+030".
  std::string iamf_label;  // The IAMF name, e.g. "L". Dart-side only.
  std::string app_label;   // Eclipsa Studio's short label, e.g. "L".
  std::string full_name;   // Eclipsa Studio's long label, e.g. "Left".
  float azimuth = 0.0f;
  float elevation = 0.0f;
  bool is_lfe = false;
};

struct Section {
  std::string id;
  int oar_value = 0;
  bool monitoring = false;  // A monitoring target (OAR output order).
  bool element = false;     // An element layout (OAR input order).
  std::vector<Row> rows;
};

// A `<layout id>-alt` section lists the app's channel order for a
// layout OAR renders and takes in another order (ES-960); its rows are
// `<OAR code> <IAMF name> <Eclipsa Studio label>`.
constexpr std::string_view kAltSuffix = "-alt";

// A `<layout id>-binaural` section gives OBR's virtual loudspeaker
// position for each channel of an element layout, in the layout
// section's order; its rows are `<OAR code> <azimuth> <elevation>`.
constexpr std::string_view kBinauralSuffix = "-binaural";

bool HasSuffix(const std::string& id, std::string_view suffix) {
  return id.size() > suffix.size() && id.ends_with(suffix);
}

// The layout id a section with `suffix` refers to ("9.1.6-alt" ->
// "9.1.6").
std::string StripSuffix(const std::string& id, std::string_view suffix) {
  return id.substr(0, id.size() - suffix.size());
}

bool IsAltSection(const std::string& id) { return HasSuffix(id, kAltSuffix); }

std::string AltLayoutId(const std::string& id) {
  return StripSuffix(id, kAltSuffix);
}

bool IsBinauralSection(const std::string& id) {
  return HasSuffix(id, kBinauralSuffix);
}

std::string BinauralLayoutId(const std::string& id) {
  return StripSuffix(id, kBinauralSuffix);
}

// Whether `id` names a layout section rather than an alt or binaural
// section, which describes another section's channels and names no role.
bool IsLayoutSection(const std::string& id) {
  return !IsAltSection(id) && !IsBinauralSection(id);
}

// Without this gtest prints the parameter as a byte dump.
void PrintTo(const Section& s, std::ostream* os) {
  *os << s.id << " (" << s.rows.size() << " channels)";
}

std::string FindTable() {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir == nullptr) srcdir = ".";
  const std::string name = "renderer/channel_layouts.txt";
  const std::string candidates[] = {
      std::string(srcdir) + "/_main/" + name,
      std::string(srcdir) + "/_main/engine/" + name,
      std::string(srcdir) + "/eclipsa_studio_engine/" + name,
      name,
      "engine/" + name,
  };
  for (const auto& c : candidates) {
    std::ifstream probe(c);
    if (probe) return c;
  }
  return {};
}

// Parses the table described at the head of channel_layouts.txt.
// Returns an empty vector on any malformed line, a line with a trailing
// token included.
std::vector<Section> ParseTable(const std::string& path) {
  std::ifstream in(path);
  std::vector<Section> sections;
  std::string line;
  while (std::getline(in, line)) {
    const size_t first = line.find_first_not_of(" \t\r");
    if (first == std::string::npos || line[first] == '#') continue;
    std::istringstream fields(line);
    if (line[first] == '[') {
      std::string id;
      Section s;
      if (!(fields >> id)) return {};
      if (id.size() < 3 || id.back() != ']') return {};
      s.id = id.substr(1, id.size() - 2);
      if (!(fields >> s.oar_value)) return {};
      // A layout section names one or two roles; an alt or binaural
      // section none.
      std::string role;
      while (fields >> role) {
        if (!IsLayoutSection(s.id)) return {};
        if (role == "monitoring") {
          s.monitoring = true;
        } else if (role == "element") {
          s.element = true;
        } else {
          return {};
        }
      }
      if (IsLayoutSection(s.id) && !s.monitoring && !s.element) return {};
      sections.push_back(std::move(s));
      continue;
    }
    if (sections.empty()) return {};
    Row r;
    if (IsBinauralSection(sections.back().id)) {
      std::string extra;
      if (!(fields >> r.label >> r.azimuth >> r.elevation) || fields >> extra) {
        return {};
      }
      sections.back().rows.push_back(std::move(r));
      continue;
    }
    if (IsAltSection(sections.back().id)) {
      if (!(fields >> r.label >> r.iamf_label >> r.app_label)) return {};
    } else {
      std::string lfe;
      if (!(fields >> r.label >> r.iamf_label >> r.app_label >> r.azimuth >>
            r.elevation >> lfe)) {
        return {};
      }
      if (lfe != "lfe" && lfe != "-") return {};
      r.is_lfe = lfe == "lfe";
    }
    // The long label runs to the end of the line: it has spaces.
    if (!std::getline(fields >> std::ws, r.full_name) || r.full_name.empty()) {
      return {};
    }
    sections.back().rows.push_back(std::move(r));
  }
  return sections;
}

// The oar_layout_t constant each layout id names. Keeping the mapping
// here rather than in the table pins the table's integers — which the
// Dart OarLayout enum repeats — against the header's enumerators, so an
// upstream renumbering fails too.
bool OarLayoutForId(const std::string& id, oar_layout_t* out) {
  static const struct {
    const char* id;
    oar_layout_t layout;
  } kLayouts[] = {
      {"mono", ck_oar_layout_mono},
      {"stereo", ck_oar_layout_stereo},
      {"3.1.2", ck_oar_layout_312},
      {"5.1", ck_oar_layout_51},
      {"5.1.2", ck_oar_layout_512},
      {"5.1.4", ck_oar_layout_514},
      {"7.1", ck_oar_layout_71},
      {"7.1.2", ck_oar_layout_712},
      {"7.1.4", ck_oar_layout_714},
      {"9.1.6", ck_oar_layout_916},
      {"7.1.5.4", ck_oar_layout_7154},
      {"10.2.9.3", ck_oar_layout_a293},
      {"binaural", ck_oar_layout_binaural},
  };
  for (const auto& entry : kLayouts) {
    if (id == entry.id) {
      *out = entry.layout;
      return true;
    }
  }
  return false;
}

// One object element on a target layout, rendered block by block.
class ObjectRender {
 public:
  explicit ObjectRender(oar_layout_t layout) {
    oar_config_t cfg = {};
    cfg.target_layout = layout;
    cfg.samples_per_channel = kBlock;
    cfg.sampling_rate = kRate;
    oar_ = oar_create(&cfg);
    if (oar_ == nullptr) return;
    const int gid = oar_add_audio_group(oar_);
    oar_audio_element_config_t ecfg;
    std::memset(&ecfg, 0, sizeof(ecfg));
    ecfg.type = ck_object_based;
    ecfg.obc.num_objects = 1;
    if (gid < 0 || oar_add_audio_element(oar_, static_cast<uint32_t>(gid),
                                         kElemId, &ecfg) != 0) {
      oar_destroy(oar_);
      oar_ = nullptr;
      return;
    }
    channels_ = oar_get_number_of_output_channels(oar_);
    in_.assign(kBlock, kInputLevel);
    out_.assign(static_cast<size_t>(channels_) * kBlock, 0.0f);
  }

  ~ObjectRender() {
    if (oar_ != nullptr) oar_destroy(oar_);
  }

  ObjectRender(const ObjectRender&) = delete;
  ObjectRender& operator=(const ObjectRender&) = delete;

  bool ok() const { return oar_ != nullptr; }
  uint32_t channels() const { return channels_; }

  // Holds the object at (azimuth, elevation) for kSettleBlocks blocks and
  // returns the last block's per-channel peak magnitude.
  std::vector<float> PeaksAt(float azimuth, float elevation) {
    for (uint32_t block = 0; block < kSettleBlocks; ++block) {
      oar_audio_block_t ib = {in_.data(), 1, kBlock};
      if (oar_update_audio_element_data(oar_, kElemId, &ib) != 0) return {};

      oar_metadata_t md;
      std::memset(&md, 0, sizeof(md));
      md.type = ck_metadata_object_positions;
      md.duration = static_cast<int>(kBlock);
      md.object_positions.param_type = ck_param_constant;
      md.object_positions.num_objects = 1;
      md.object_positions.position_type = ck_polar;
      md.object_positions.polar_positions[0] = {azimuth, elevation, 1.0f};
      if (oar_update_audio_element_metadata(oar_, kElemId, &md) != 0) return {};

      oar_audio_block_t ob = {out_.data(), channels_, kBlock};
      if (oar_render(oar_, &ob) != 0) return {};
    }
    // OAR writes contiguous planar blocks: channel c owns
    // out_[c * kBlock .. (c + 1) * kBlock).
    std::vector<float> peaks(channels_, 0.0f);
    for (uint32_t c = 0; c < channels_; ++c) {
      for (uint32_t i = 0; i < kBlock; ++i) {
        const float v = std::fabs(out_[static_cast<size_t>(c) * kBlock + i]);
        if (v > peaks[c]) peaks[c] = v;
      }
    }
    return peaks;
  }

 private:
  oar_t* oar_ = nullptr;
  uint32_t channels_ = 0;
  std::vector<float> in_;
  std::vector<float> out_;
};

class ChannelLayoutsTest : public ::testing::TestWithParam<Section> {};

TEST_P(ChannelLayoutsTest, EachSpeakerRendersToItsOwnChannel) {
  const Section& section = GetParam();
  oar_layout_t layout = ck_oar_layout_none;
  ASSERT_TRUE(OarLayoutForId(section.id, &layout)) << section.id;
  EXPECT_EQ(static_cast<int>(layout), section.oar_value)
      << section.id << ": oar_layout_t value in the table is stale";
  // Binaural renders through HRTFs, not to loudspeakers; its rows are the
  // stereo geometry the 3D scene draws, which this test cannot render.
  if (layout == ck_oar_layout_binaural) return;

  ObjectRender render(layout);
  ASSERT_TRUE(render.ok()) << section.id << ": oar_create/add failed";
  ASSERT_EQ(render.channels(), section.rows.size()) << section.id;

  std::vector<size_t> lfe_indices;
  for (size_t i = 0; i < section.rows.size(); ++i) {
    if (section.rows[i].is_lfe) lfe_indices.push_back(i);
  }

  for (size_t want = 0; want < section.rows.size(); ++want) {
    const Row& row = section.rows[want];
    // OLR pans over the layout's speakers minus the LFE, so no object
    // position reaches the LFE channel. Its index is pinned below, by
    // every other speaker's render leaving it silent.
    if (row.is_lfe) continue;

    const std::vector<float> peaks = render.PeaksAt(row.azimuth, row.elevation);
    ASSERT_EQ(peaks.size(), section.rows.size())
        << section.id << " " << row.label << ": render failed";

    for (size_t ch = 0; ch < peaks.size(); ++ch) {
      const std::string where = section.id + " " + row.label + " -> channel " +
                                std::to_string(ch) + " (" +
                                section.rows[ch].label + ")";
      if (ch == want) {
        EXPECT_GE(peaks[ch], kInputLevel * kMinOnAxis) << where << ": quiet";
      } else {
        EXPECT_LE(peaks[ch], kInputLevel * kMaxOffAxis) << where << ": leaked";
      }
    }
    for (const size_t lfe : lfe_indices) {
      EXPECT_EQ(peaks[lfe], 0.0f)
          << section.id << " " << row.label << ": reached LFE channel " << lfe;
    }
  }
}

std::vector<Section> TableSections() {
  const std::string path = FindTable();
  if (path.empty()) return {};
  std::vector<Section> layouts;
  for (Section& s : ParseTable(path)) {
    if (IsLayoutSection(s.id)) layouts.push_back(std::move(s));
  }
  return layouts;
}

std::string SectionName(const ::testing::TestParamInfo<Section>& info) {
  std::string name = info.param.id;
  for (char& c : name) {
    if (!std::isalnum(static_cast<unsigned char>(c))) c = '_';
  }
  return name;
}

INSTANTIATE_TEST_SUITE_P(Layouts, ChannelLayoutsTest,
                         ::testing::ValuesIn(TableSections()), SectionName);

// The ADM importer renders to 7.1.4 and writes WAV in that layout's
// channel order, from its own copy of the table (adm_import/scene/
// layouts.cc). Pin it against the same rows, so the importer's output
// order cannot drift from what OAR renders either.
TEST(ChannelLayoutsTable, ImportLayoutMatchesTheTable) {
  const std::string path = FindTable();
  ASSERT_FALSE(path.empty()) << "renderer/channel_layouts.txt not found";
  const std::vector<Section> sections = ParseTable(path);
  const Section* want = nullptr;
  for (const Section& s : sections) {
    if (s.id == "7.1.4") want = &s;
  }
  ASSERT_NE(want, nullptr) << "no 7.1.4 section";

  const adm2iamf::Layout& got = adm2iamf::ImportLayout();
  EXPECT_EQ(got.name, want->id);
  EXPECT_EQ(static_cast<int>(got.oar_layout), want->oar_value);
  ASSERT_EQ(got.speakers.size(), want->rows.size());
  for (size_t i = 0; i < want->rows.size(); ++i) {
    const Row& row = want->rows[i];
    EXPECT_EQ(got.speakers[i].name, row.label) << "channel " << i;
    EXPECT_FLOAT_EQ(got.speakers[i].azimuth, row.azimuth) << "channel " << i;
    EXPECT_FLOAT_EQ(got.speakers[i].elevation, row.elevation)
        << "channel " << i;
    EXPECT_EQ(got.speakers[i].is_lfe, row.is_lfe) << "channel " << i;
  }
}

// A malformed table parses as empty rather than as a shorter table: a
// header without a role or with an unknown one, a row without a long
// label, a short row, an alt or binaural header with a role, and a
// binaural row that is short or carries a trailing token are
// transcription slips.
TEST(ChannelLayoutsTable, RejectsMalformedLines) {
  const std::string good =
      "[stereo] 2 monitoring element\nM+030 L L 30 0 - Left\n"
      "M-030 R R -30 0 - Right\n[stereo-alt] 2\nM-030 R R Right\n"
      "M+030 L L Left\n[stereo-binaural] 2\nM+030 30 0\nM-030 -30 0\n";
  const std::string bad[] = {
      "[stereo] 2\nM+030 L L 30 0 - Left\n",
      "[stereo] 2 scene\nM+030 L L 30 0 - Left\n",
      "[stereo] 2 element\nM+030 L L 30 0 -\n",
      "[stereo] 2 element\nM+030 L L 30 0 x Left\n",
      "[stereo] 2 element\nM+030 L L 30 0 - Left\n[stereo-alt] 2 element\n"
      "M+030 L L Left\n",
      "[stereo] 2 element\nM+030 L L 30 0 - Left\n[stereo-alt] 2\n"
      "M+030 L\n",
      "[stereo] 2 element\nM+030 L L 30 0 - Left\n[stereo-binaural] 2 "
      "element\nM+030 30 0\n",
      "[stereo] 2 element\nM+030 L L 30 0 - Left\n[stereo-binaural] 2\n"
      "M+030 30\n",
      "[stereo] 2 element\nM+030 L L 30 0 - Left\n[stereo-binaural] 2\n"
      "M+030 30 0 - Left\n",
  };
  const std::string dir = ::testing::TempDir();
  const auto parse = [&dir](const std::string& text, const char* name) {
    const std::string path = dir + "/" + name;
    std::ofstream(path) << text;
    return ParseTable(path);
  };
  const std::vector<Section> parsed = parse(good, "good.txt");
  ASSERT_EQ(parsed.size(), 3u);
  EXPECT_TRUE(parsed[0].monitoring);
  EXPECT_TRUE(parsed[0].element);
  EXPECT_EQ(parsed[0].rows[0].full_name, "Left");
  EXPECT_EQ(parsed[1].rows[1].full_name, "Left");
  ASSERT_EQ(parsed[2].rows.size(), 2u);
  EXPECT_EQ(parsed[2].rows[1].label, "M-030");
  EXPECT_FLOAT_EQ(parsed[2].rows[1].azimuth, -30.0f);
  for (size_t i = 0; i < std::size(bad); ++i) {
    EXPECT_TRUE(parse(bad[i], "bad.txt").empty()) << "case " << i;
  }
}

TEST(ChannelLayoutsTable, ParsesEveryLayout) {
  const std::string path = FindTable();
  ASSERT_FALSE(path.empty()) << "renderer/channel_layouts.txt not found";
  const std::vector<Section> sections = ParseTable(path);
  ASSERT_FALSE(sections.empty()) << path << ": malformed";
  int layouts = 0;
  // Short label -> long label, across every layout: one name per label.
  std::map<std::string, std::string> long_labels;
  const auto note_label = [&long_labels](const Section& s, const Row& row) {
    EXPECT_FALSE(row.full_name.empty())
        << s.id << " " << row.label << ": no long label";
    const auto it = long_labels.find(row.app_label);
    if (it == long_labels.end()) {
      long_labels[row.app_label] = row.full_name;
    } else {
      EXPECT_EQ(it->second, row.full_name)
          << s.id << ": " << row.app_label << " has another long label";
    }
  };
  // Every lookup by id takes one section, so a second section with the
  // same id would go unchecked.
  std::set<std::string> ids;
  for (const Section& s : sections) {
    EXPECT_TRUE(ids.insert(s.id).second) << s.id << ": section appears twice";
    EXPECT_FALSE(s.rows.empty()) << s.id << ": no rows";
    // A binaural section lists its element layout's OAR codes in the
    // layout section's order. OBR's positions are pinned below.
    if (IsBinauralSection(s.id)) {
      const std::string layout_id = BinauralLayoutId(s.id);
      const Section* layout = nullptr;
      for (const Section& t : sections) {
        if (t.id == layout_id) layout = &t;
      }
      ASSERT_NE(layout, nullptr) << s.id << ": no [" << layout_id << "]";
      EXPECT_TRUE(layout->element) << s.id << ": not an element layout";
      EXPECT_EQ(s.oar_value, layout->oar_value) << s.id;
      ASSERT_EQ(s.rows.size(), layout->rows.size()) << s.id;
      for (size_t i = 0; i < s.rows.size(); ++i) {
        EXPECT_EQ(s.rows[i].label, layout->rows[i].label)
            << s.id << " channel " << i;
      }
      continue;
    }
    // An alt section is a permutation of its layout section: every OAR
    // code of the layout once, and no other, each row repeating that
    // row's names.
    if (IsAltSection(s.id)) {
      const std::string layout_id = AltLayoutId(s.id);
      const Section* layout = nullptr;
      for (const Section& t : sections) {
        if (t.id == layout_id) layout = &t;
      }
      ASSERT_NE(layout, nullptr) << s.id << ": no [" << layout_id << "]";
      EXPECT_EQ(s.oar_value, layout->oar_value) << s.id;
      std::set<std::string> layout_codes;
      for (const Row& row : layout->rows) layout_codes.insert(row.label);
      std::set<std::string> oar_codes;
      for (const Row& row : s.rows) {
        EXPECT_TRUE(oar_codes.insert(row.label).second)
            << s.id << ": OAR code " << row.label << " appears twice";
        for (const Row& source : layout->rows) {
          if (source.label != row.label) continue;
          EXPECT_EQ(row.iamf_label, source.iamf_label)
              << s.id << " " << row.label << ": IAMF name";
          EXPECT_EQ(row.app_label, source.app_label)
              << s.id << " " << row.label << ": short label";
          EXPECT_EQ(row.full_name, source.full_name)
              << s.id << " " << row.label << ": long label";
        }
      }
      EXPECT_EQ(oar_codes, layout_codes) << s.id;
      continue;
    }
    ++layouts;
    oar_layout_t layout = ck_oar_layout_none;
    EXPECT_TRUE(OarLayoutForId(s.id, &layout)) << s.id << ": unknown layout id";
    EXPECT_TRUE(s.monitoring || s.element) << s.id << ": no role";
    // Each name identifies one channel within a layout, so a duplicate
    // is a copy-paste slip rather than a legal table.
    std::set<std::string> oar_codes;
    std::set<std::string> iamf_names;
    std::set<std::string> app_names;
    for (const Row& row : s.rows) {
      EXPECT_TRUE(oar_codes.insert(row.label).second)
          << s.id << ": OAR code " << row.label << " appears twice";
      EXPECT_TRUE(iamf_names.insert(row.iamf_label).second)
          << s.id << ": IAMF name " << row.iamf_label << " appears twice";
      EXPECT_TRUE(app_names.insert(row.app_label).second)
          << s.id << ": label " << row.app_label << " appears twice";
      note_label(s, row);
    }
  }
  EXPECT_EQ(layouts, 13);
}

// The engine's 9.1.6 alt order (renderer/channel_order.h) is the
// [9.1.6-alt] section: alt channel a is the [9.1.6] row whose OAR label
// the section's row a names, in both directions (ES-960).
TEST(ChannelLayoutsTable, AltOrder916MatchesTheTable) {
  const std::string path = FindTable();
  ASSERT_FALSE(path.empty()) << "renderer/channel_layouts.txt not found";
  const std::vector<Section> sections = ParseTable(path);
  const Section* layout = nullptr;
  const Section* alt = nullptr;
  for (const Section& s : sections) {
    if (s.id == "9.1.6") layout = &s;
    if (s.id == "9.1.6-alt") alt = &s;
  }
  ASSERT_NE(layout, nullptr) << "no [9.1.6] section";
  ASSERT_NE(alt, nullptr) << "no [9.1.6-alt] section";
  EXPECT_EQ(static_cast<int>(ck_oar_layout_916), alt->oar_value);
  ASSERT_EQ(alt->rows.size(), layout->rows.size());

  // Monitoring: alt output channel a takes OLR channel source[a].
  const eclipsa_studio::ChannelOrder* order =
      eclipsa_studio::MonitoringChannelOrder(
          static_cast<uint32_t>(alt->oar_value));
  ASSERT_NE(order, nullptr);
  ASSERT_EQ(order->channels, alt->rows.size());
  EXPECT_LE(order->channels, eclipsa_studio::kChannelOrderMaxChannels);

  // Element input: OLR channel c takes alt element channel input[c].
  const eclipsa_studio::ChannelOrder* input_order =
      eclipsa_studio::ElementInputOrder(eclipsa_studio::kChannelOrder916Alt,
                                        order->channels);
  ASSERT_NE(input_order, nullptr);
  ASSERT_EQ(input_order->channels, order->channels);
  const uint8_t* input = input_order->source;

  std::set<uint8_t> sources;
  for (size_t a = 0; a < alt->rows.size(); ++a) {
    const Row& row = alt->rows[a];
    int want = -1;
    for (size_t i = 0; i < layout->rows.size(); ++i) {
      if (layout->rows[i].label == row.label) want = static_cast<int>(i);
    }
    ASSERT_GE(want, 0) << row.label << ": not a [9.1.6] row";
    EXPECT_EQ(static_cast<int>(order->source[a]), want)
        << "alt channel " << a << " (" << row.iamf_label << ")";
    EXPECT_LT(order->source[a], order->channels);
    EXPECT_TRUE(sources.insert(order->source[a]).second)
        << "OLR channel " << static_cast<int>(order->source[a])
        << " is sent twice";
    EXPECT_EQ(static_cast<size_t>(input[order->source[a]]), a)
        << "element input is not the inverse at alt channel " << a;
  }
  EXPECT_EQ(sources.size(), order->channels) << "not a permutation";

  // Every other layout in the table is monitored as OLR renders it, and
  // an element in OAR's order, or of another channel count, is fed as it
  // is.
  for (const Section& s : sections) {
    if (!IsLayoutSection(s.id) || s.id == "9.1.6") continue;
    EXPECT_EQ(eclipsa_studio::MonitoringChannelOrder(
                  static_cast<uint32_t>(s.oar_value)),
              nullptr)
        << s.id;
  }
  EXPECT_EQ(eclipsa_studio::ElementInputOrder(eclipsa_studio::kChannelOrderOar,
                                              order->channels),
            nullptr);
  EXPECT_EQ(eclipsa_studio::ElementInputOrder(
                eclipsa_studio::kChannelOrder916Alt, 12),
            nullptr);
}

// The OBR element type for each element layout, copied from
// audio_element_type_rid_map in src/renderer/obr/obr.c in the oar module
// (9.1.6 maps to kLayout9_1_6_ch, not the alt order). Nothing pins this
// copy: an oar bump that changes that table needs this one changed by
// hand. A Binaural element registers as a stereo element, so it has no
// entry.
struct ObrType {
  const char* id;
  obr::AudioElementType type;
};
constexpr ObrType kObrTypes[] = {
    {"mono", obr::AudioElementType::kLayoutMono},
    {"stereo", obr::AudioElementType::kLayoutStereo},
    {"3.1.2", obr::AudioElementType::kLayout3_1_2_ch},
    {"5.1", obr::AudioElementType::kLayout5_1_0_ch},
    {"5.1.2", obr::AudioElementType::kLayout5_1_2_ch},
    {"5.1.4", obr::AudioElementType::kLayout5_1_4_ch},
    {"7.1", obr::AudioElementType::kLayout7_1_0_ch},
    {"7.1.2", obr::AudioElementType::kLayout7_1_2_ch},
    {"7.1.4", obr::AudioElementType::kLayout7_1_4_ch},
    {"9.1.6", obr::AudioElementType::kLayout9_1_6_ch},
    {"7.1.5.4", obr::AudioElementType::kLayout7_1_5_4_ch},
    {"10.2.9.3", obr::AudioElementType::kLayout10_2_9_3_ch},
};

bool ObrTypeForId(const std::string& id, obr::AudioElementType* out) {
  for (const ObrType& entry : kObrTypes) {
    if (id == entry.id) {
      *out = entry.type;
      return true;
    }
  }
  return false;
}

struct ObrChannel {
  float azimuth = 0.0f;
  float elevation = 0.0f;
  bool is_lfe = false;
};

// The virtual loudspeakers OBR renders one element of `type` from, in its
// input channel order, read from the table ObrImpl's
// GetAudioElementConfigLogMessage() returns. Each channel is a row
// `|AE ID|AE Type|HeadLckd|BinFltXOA|BinFltPrfl|Ch ID|Ch Label|Azimuth|
// Elevation|Distance|LFE|`; the header row and the borders do not start
// with a number. Empty, with a test failure naming the cause, when the
// element cannot be added, a row does not parse or the rows are not in
// channel order.
std::vector<ObrChannel> ObrChannels(obr::AudioElementType type) {
  obr::ObrImpl renderer(static_cast<int>(kBlock), static_cast<int>(kRate));
  const absl::Status added = renderer.AddAudioElement(type);
  if (!added.ok()) {
    ADD_FAILURE() << "ObrImpl::AddAudioElement: " << added;
    return {};
  }
  std::istringstream log(renderer.GetAudioElementConfigLogMessage());
  std::vector<ObrChannel> channels;
  std::string line;
  while (std::getline(log, line)) {
    if (line.empty() || line[0] != '|') continue;
    std::vector<std::string> cells;
    std::istringstream row(line.substr(1));
    std::string cell;
    while (std::getline(row, cell, '|')) cells.push_back(cell);
    if (cells.size() != 11) {
      ADD_FAILURE() << "unexpected OBR table row: " << line;
      return {};
    }
    const size_t digit = cells[0].find_first_not_of(' ');
    if (digit == std::string::npos ||
        !std::isdigit(static_cast<unsigned char>(cells[0][digit]))) {
      continue;
    }
    ObrChannel c;
    size_t index = 0;
    std::istringstream channel(cells[5]);
    std::istringstream azimuth(cells[7]);
    std::istringstream elevation(cells[8]);
    std::istringstream lfe(cells[10]);
    std::string flag;
    if (!(channel >> index) || !(azimuth >> c.azimuth) ||
        !(elevation >> c.elevation) || !(lfe >> flag) ||
        (flag != "Yes" && flag != "No")) {
      ADD_FAILURE() << "unparsed OBR table row: " << line;
      return {};
    }
    if (index != channels.size()) {
      ADD_FAILURE() << "OBR table row out of channel order: " << line;
      return {};
    }
    c.is_lfe = flag == "Yes";
    channels.push_back(c);
  }
  if (channels.empty()) ADD_FAILURE() << "no channel rows in the OBR table";
  return channels;
}

// -1, 0 or 1 by the sign of `degrees`. An azimuth of ±180 is the rear
// centre, so it counts as 0.
int Sign(float degrees) {
  if (std::fabs(degrees) == 180.0f) return 0;
  return (degrees > 0.0f) - (degrees < 0.0f);
}

// Every element layout OBR renders has a binaural section, and each row
// is the position OBR gives that channel. Two checks tie OBR's channel i
// to the layout section's channel i: the LFE flags match, and every
// other channel lies on the same side (left, centre or right) and in the
// same layer (upper, middle or bottom) under both renderers, so a
// transcription that followed a reorder in OBR would fail rather than
// move a channel across the head.
TEST(ChannelLayoutsTable, BinauralSectionsMatchObr) {
  const std::string path = FindTable();
  ASSERT_FALSE(path.empty()) << "renderer/channel_layouts.txt not found";
  const std::vector<Section> sections = ParseTable(path);
  ASSERT_FALSE(sections.empty()) << path << ": malformed";
  int pinned = 0;
  for (const Section& layout : sections) {
    obr::AudioElementType type = obr::AudioElementType::kInvalidType;
    if (!IsLayoutSection(layout.id) || !ObrTypeForId(layout.id, &type)) {
      continue;
    }
    const std::string binaural_id = layout.id + std::string(kBinauralSuffix);
    const Section* binaural = nullptr;
    for (const Section& s : sections) {
      if (s.id == binaural_id) binaural = &s;
    }
    ASSERT_NE(binaural, nullptr)
        << "no [" << layout.id << kBinauralSuffix << "]";
    const std::vector<ObrChannel> want = ObrChannels(type);
    ASSERT_EQ(want.size(), layout.rows.size())
        << layout.id << ": OBR element channels";
    ASSERT_EQ(binaural->rows.size(), want.size()) << binaural->id;
    for (size_t i = 0; i < want.size(); ++i) {
      const Row& row = binaural->rows[i];
      const std::string where = binaural->id + " " + row.label;
      EXPECT_FLOAT_EQ(row.azimuth, want[i].azimuth) << where;
      EXPECT_FLOAT_EQ(row.elevation, want[i].elevation) << where;
      EXPECT_EQ(layout.rows[i].is_lfe, want[i].is_lfe) << where << ": LFE";
      if (layout.rows[i].is_lfe) continue;
      EXPECT_EQ(Sign(layout.rows[i].azimuth), Sign(want[i].azimuth))
          << where << ": side";
      EXPECT_EQ(Sign(layout.rows[i].elevation), Sign(want[i].elevation))
          << where << ": layer";
    }
    ++pinned;
  }
  EXPECT_EQ(pinned, static_cast<int>(std::size(kObrTypes)));
  // Nothing else has a binaural section.
  for (const Section& s : sections) {
    if (!IsBinauralSection(s.id)) continue;
    obr::AudioElementType type = obr::AudioElementType::kInvalidType;
    EXPECT_TRUE(ObrTypeForId(BinauralLayoutId(s.id), &type)) << s.id;
  }
}

}  // namespace
