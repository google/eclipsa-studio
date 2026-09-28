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

// Pins OAR's output channel order and speaker geometry (ES-592).
//
// The app names, meters and draws output channels from tables in Dart
// (`SpeakerLayout`, `iamfChannelLabels`). Those were pinned only against
// hand-transcribed copies of themselves, so an OAR_COMMIT bump that
// reordered a layout or moved a speaker would change what the engine
// actually renders while every Dart test stayed green — the mechanism
// behind the ES-552 mislabels, one level down.
//
// The order is defined by the OAR fork's own table
// (src/renderer/olr/object_audio_renderer/layout.c). That package is
// visible only inside the oar repo, so this test cannot read the table;
// it pins the behaviour the table produces instead. For every speaker of
// every target layout it renders one object placed at that speaker's
// nominal angles and asserts the signal comes out of that speaker's
// output channel alone. A reorder moves the energy to another index; a
// moved speaker spreads it across the pair that now straddles the angle.
// Either fails here, at the layer that defines the order.
//
// The expected rows live in renderer/oar_output_channels.txt, which
// app/test/renderer/oar_output_channels_test.dart reads as well, so the
// Dart tables are pinned to the same transcription this test verifies.
// Each row also carries the app's own name for the channel ("L", "Ltf");
// OAR does not define those, so this test only checks that they are
// present and distinct within a layout, and the Dart test pins them.

#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <ostream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "adm_import/scene/layouts.h"
#include "gtest/gtest.h"

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

struct Row {
  std::string label;      // OAR's own name, e.g. "M+030".
  std::string app_label;  // Eclipsa Studio's, e.g. "L". Dart-side only.
  std::string full_name;  // Tooltip copy, glossary rows only.
  float azimuth = 0.0f;
  float elevation = 0.0f;
  bool is_lfe = false;
};

struct Section {
  std::string id;
  int oar_value = 0;
  std::vector<Row> rows;
};

// The glossary section: app label -> the full name a tooltip shows.
constexpr const char* kNamesSection = "names";

// Without this gtest prints the parameter as a byte dump.
void PrintTo(const Section& s, std::ostream* os) {
  *os << s.id << " (" << s.rows.size() << " channels)";
}

std::string FindTable() {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir == nullptr) srcdir = ".";
  const std::string name = "renderer/oar_output_channels.txt";
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

// Parses the table described at the head of oar_output_channels.txt.
// Returns an empty vector on any malformed line.
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
      // Every section but the glossary names its oar_layout_t value.
      if (s.id != kNamesSection && !(fields >> s.oar_value)) return {};
      sections.push_back(std::move(s));
      continue;
    }
    if (sections.empty()) return {};
    Row r;
    if (sections.back().id == kNamesSection) {
      std::string rest;
      if (!(fields >> r.app_label) || !std::getline(fields >> std::ws, rest) ||
          rest.empty()) {
        return {};
      }
      r.full_name = rest;
      sections.back().rows.push_back(std::move(r));
      continue;
    }
    std::string lfe;
    if (!(fields >> r.label >> r.app_label >> r.azimuth >> r.elevation >>
          lfe)) {
      return {};
    }
    if (lfe != "lfe" && lfe != "-") return {};
    r.is_lfe = lfe == "lfe";
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
      {"mono", ck_oar_layout_mono}, {"stereo", ck_oar_layout_stereo},
      {"3.1.2", ck_oar_layout_312}, {"5.1", ck_oar_layout_51},
      {"5.1.2", ck_oar_layout_512}, {"5.1.4", ck_oar_layout_514},
      {"7.1", ck_oar_layout_71},    {"7.1.2", ck_oar_layout_712},
      {"7.1.4", ck_oar_layout_714}, {"9.1.6", ck_oar_layout_916},
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

class OarOutputChannelsTest : public ::testing::TestWithParam<Section> {};

TEST_P(OarOutputChannelsTest, EachSpeakerRendersToItsOwnChannel) {
  const Section& section = GetParam();
  oar_layout_t layout = ck_oar_layout_none;
  ASSERT_TRUE(OarLayoutForId(section.id, &layout)) << section.id;
  EXPECT_EQ(static_cast<int>(layout), section.oar_value)
      << section.id << ": oar_layout_t value in the table is stale";

  ObjectRender render(layout);
  ASSERT_TRUE(render.ok()) << section.id << ": oar_create/add failed";
  ASSERT_EQ(render.channels(), section.rows.size()) << section.id;

  const int lfe_index = [&] {
    for (size_t i = 0; i < section.rows.size(); ++i) {
      if (section.rows[i].is_lfe) return static_cast<int>(i);
    }
    return -1;
  }();

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
    if (lfe_index >= 0) {
      EXPECT_EQ(peaks[lfe_index], 0.0f)
          << section.id << " " << row.label << ": reached the LFE channel";
    }
  }
}

std::vector<Section> TableSections() {
  const std::string path = FindTable();
  if (path.empty()) return {};
  std::vector<Section> layouts;
  for (Section& s : ParseTable(path)) {
    if (s.id != kNamesSection) layouts.push_back(std::move(s));
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

INSTANTIATE_TEST_SUITE_P(Layouts, OarOutputChannelsTest,
                         ::testing::ValuesIn(TableSections()), SectionName);

// The ADM importer renders to 7.1.4 and writes WAV in that layout's
// channel order, from its own copy of the table (adm_import/scene/
// layouts.cc). Pin it against the same rows, so the importer's output
// order cannot drift from what OAR renders either.
TEST(OarOutputChannelsTable, ImportLayoutMatchesTheTable) {
  const std::string path = FindTable();
  ASSERT_FALSE(path.empty()) << "renderer/oar_output_channels.txt not found";
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

TEST(OarOutputChannelsTable, ParsesEveryLayout) {
  const std::string path = FindTable();
  ASSERT_FALSE(path.empty()) << "renderer/oar_output_channels.txt not found";
  const std::vector<Section> sections = ParseTable(path);
  ASSERT_FALSE(sections.empty()) << path << ": malformed";
  const Section* glossary = nullptr;
  int layouts = 0;
  std::set<std::string> used_labels;
  for (const Section& s : sections) {
    EXPECT_FALSE(s.rows.empty()) << s.id << ": no rows";
    if (s.id == kNamesSection) {
      EXPECT_EQ(glossary, nullptr) << "more than one [names] section";
      glossary = &s;
      continue;
    }
    ++layouts;
    oar_layout_t layout = ck_oar_layout_none;
    EXPECT_TRUE(OarLayoutForId(s.id, &layout)) << s.id << ": unknown layout id";
    // Both names identify one channel within a layout, so a duplicate is
    // a copy-paste slip rather than a legal table.
    std::set<std::string> oar_names;
    std::set<std::string> app_names;
    for (const Row& row : s.rows) {
      EXPECT_TRUE(oar_names.insert(row.label).second)
          << s.id << ": OAR label " << row.label << " appears twice";
      EXPECT_TRUE(app_names.insert(row.app_label).second)
          << s.id << ": app label " << row.app_label << " appears twice";
      used_labels.insert(row.app_label);
    }
  }
  EXPECT_EQ(layouts, 10);

  // The glossary covers what these layouts render, and nothing else: an
  // uncovered label leaves the tooltip echoing the short name back, and
  // an unused entry is a leftover from a layout that has changed.
  ASSERT_NE(glossary, nullptr) << "no [names] section";
  std::set<std::string> named;
  for (const Row& row : glossary->rows) {
    EXPECT_FALSE(row.full_name.empty()) << row.app_label << ": no full name";
    EXPECT_TRUE(named.insert(row.app_label).second)
        << "names: " << row.app_label << " appears twice";
  }
  EXPECT_EQ(named, used_labels);
}

}  // namespace
