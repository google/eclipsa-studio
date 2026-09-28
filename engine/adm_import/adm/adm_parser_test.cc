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

#include <cstdint>
#include <cstdio>
#include <string>
#include <tuple>
#include <vector>

#include "adm_import/adm/adm_model.h"
#include "gtest/gtest.h"

namespace adm2iamf {
namespace adm {
namespace {

// A small but representative DirectSpeakers bed: programme -> content -> object
// -> pack(DirectSpeakers) -> 3 channels (L/R/C), each with a polar block and a
// speakerLabel. Distance/gain defaults exercised on C.
constexpr char kAxml[] = R"(<?xml version="1.0" encoding="UTF-8"?>
<ebuCoreMain xmlns="urn:ebu:metadata-schema:ebuCore_2016">
 <coreMetadata><format><audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1001" audioProgrammeName="Main">
    <audioContentIDRef>ACO_1001</audioContentIDRef>
    <loudnessMetadata><integratedLoudness>-23.0</integratedLoudness></loudnessMetadata>
  </audioProgramme>
  <audioContent audioContentID="ACO_1001" audioContentName="Bed">
    <audioObjectIDRef>AO_1001</audioObjectIDRef>
  </audioContent>
  <audioObject audioObjectID="AO_1001" audioObjectName="Bed" importance="9">
    <audioPackFormatIDRef>AP_00010003</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000001</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000002</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000003</audioTrackUIDRef>
    <gain gainUnit="dB">-6.0</gain>
  </audioObject>
  <audioPackFormat audioPackFormatID="AP_00010003" audioPackFormatName="bed_712"
                   typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_00010001</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00010002</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00010003</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_00010001"
       audioChannelFormatName="RoomCentricLeft" typeDefinition="DirectSpeakers">
    <audioBlockFormat audioBlockFormatID="AB_00010001_00000001">
      <speakerLabel>RC_L</speakerLabel>
      <position coordinate="azimuth">30.0</position>
      <position coordinate="elevation">0.0</position>
      <position coordinate="distance">1.0</position>
    </audioBlockFormat>
  </audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00010002"
       audioChannelFormatName="RoomCentricRight" typeDefinition="DirectSpeakers">
    <audioBlockFormat audioBlockFormatID="AB_00010002_00000001">
      <speakerLabel>RC_R</speakerLabel>
      <position coordinate="azimuth">-30.0</position>
      <position coordinate="elevation">0.0</position>
    </audioBlockFormat>
  </audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00010003"
       audioChannelFormatName="RoomCentricCenter" typeDefinition="DirectSpeakers">
    <audioBlockFormat audioBlockFormatID="AB_00010003_00000001">
      <speakerLabel>RC_C</speakerLabel>
      <position coordinate="azimuth">0.0</position>
      <position coordinate="elevation">0.0</position>
    </audioBlockFormat>
  </audioChannelFormat>
 </audioFormatExtended></format></coreMetadata>
</ebuCoreMain>)";

void AppendField(std::vector<uint8_t>& v, const std::string& s, size_t len) {
  for (size_t i = 0; i < len; ++i) {
    v.push_back(i < s.size() ? static_cast<uint8_t>(s[i]) : ' ');
  }
}

std::vector<uint8_t> MakeChna(
    const std::vector<
        std::tuple<uint16_t, std::string, std::string, std::string>>& rows) {
  std::vector<uint8_t> v;
  uint16_t n = static_cast<uint16_t>(rows.size());
  v.push_back(n & 0xFF);
  v.push_back((n >> 8) & 0xFF);  // numTracks
  v.push_back(n & 0xFF);
  v.push_back((n >> 8) & 0xFF);  // numUIDs
  for (const auto& [idx, uid, track, pack] : rows) {
    v.push_back(idx & 0xFF);
    v.push_back((idx >> 8) & 0xFF);
    AppendField(v, uid, 12);
    AppendField(v, track, 14);
    AppendField(v, pack, 11);
    v.push_back(0);  // pad
  }
  return v;
}

TEST(ParseTimecode, SpecDecimalForm) {
  EXPECT_EQ(ParseTimecode("00:00:01.00000"), 1.0);
  EXPECT_EQ(ParseTimecode("10:02:00.00000"), 36120.0);
  EXPECT_EQ(ParseTimecode("00:00:00.50000"), 0.5);
}

TEST(ParseTimecode, SpecFractionalSampleForms) {
  // Long form: hh:mm:ss.<samples>S<rate>.
  EXPECT_EQ(ParseTimecode("00:00:00.24000S48000"), 0.5);
  EXPECT_EQ(ParseTimecode("00:01:00.24000S48000"), 60.5);
  EXPECT_EQ(ParseTimecode("01:00:00.00000S48000"), 3600.0);
  // Shortform: <samples>S<rate>.
  EXPECT_EQ(ParseTimecode("48000S48000"), 1.0);
  EXPECT_EQ(ParseTimecode("72000S48000"), 1.5);
  EXPECT_EQ(ParseTimecode("0S48000"), 0.0);
}

TEST(ParseTimecode, LenientForms) {
  EXPECT_EQ(ParseTimecode("5"), 5.0);
  EXPECT_EQ(ParseTimecode("1.5"), 1.5);
  EXPECT_EQ(ParseTimecode("01:30"), 90.0);
  EXPECT_EQ(ParseTimecode("00:00:00.5"), 0.5);
  EXPECT_EQ(ParseTimecode("0"), 0.0);
}

TEST(ParseTimecode, GarbageIsNullopt) {
  EXPECT_EQ(ParseTimecode(""), std::nullopt);
  EXPECT_EQ(ParseTimecode("abc"), std::nullopt);
  EXPECT_EQ(ParseTimecode("1:2:3:4"), std::nullopt);
  EXPECT_EQ(ParseTimecode("-5"), std::nullopt);
  EXPECT_EQ(ParseTimecode("1e3"), std::nullopt);
  EXPECT_EQ(ParseTimecode("5."), std::nullopt);
  EXPECT_EQ(ParseTimecode(".5"), std::nullopt);
  // Fractional-sample garbage: zero/missing rate, non-digit fields.
  EXPECT_EQ(ParseTimecode("48000S0"), std::nullopt);
  EXPECT_EQ(ParseTimecode("48000S"), std::nullopt);
  EXPECT_EQ(ParseTimecode("S48000"), std::nullopt);
  EXPECT_EQ(ParseTimecode("00:00:xxS48000"), std::nullopt);
  EXPECT_EQ(ParseTimecode("00:00:00S48000"), std::nullopt);
  EXPECT_EQ(ParseTimecode("1.5S48000"), std::nullopt);
}

TEST(AdmParser, InterpolationLengthUsesTimecodeGrammar) {
  constexpr char kJumpAxml[] = R"(<audioFormatExtended>
    <audioChannelFormat audioChannelFormatID="AC_00031001"
         audioChannelFormatName="Obj" typeDefinition="Objects">
      <audioBlockFormat audioBlockFormatID="AB_00031001_00000001"
                        rtime="00:00:00.24000S48000"
                        duration="00:00:01.00000">
        <position coordinate="azimuth">0.0</position>
        <position coordinate="elevation">0.0</position>
        <jumpPosition interpolationLength="12000S48000">1</jumpPosition>
      </audioBlockFormat>
    </audioChannelFormat>
  </audioFormatExtended>)";
  auto model = ParseAxml(kJumpAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  ASSERT_EQ(model->channels.size(), 1u);
  ASSERT_EQ(model->channels[0].blocks.size(), 1u);
  const AudioBlockFormat& b = model->channels[0].blocks[0];
  EXPECT_EQ(b.rtime_s, 0.5);
  EXPECT_TRUE(b.has_duration);
  EXPECT_EQ(b.duration_s, 1.0);
  EXPECT_TRUE(b.jump_position);
  EXPECT_EQ(b.interpolation_length_s, 0.25);
}

TEST(AdmParser, ParsesFrequencyAsLfeMarker) {
  constexpr char kLfeAxml[] = R"(<audioFormatExtended>
    <audioChannelFormat audioChannelFormatID="AC_00011001"
         audioChannelFormatName="LFE" typeDefinition="DirectSpeakers">
      <frequency typeDefinition="lowPass">120</frequency>
      <audioBlockFormat audioBlockFormatID="AB_00011001_00000001">
        <speakerLabel>LFE</speakerLabel>
      </audioBlockFormat>
    </audioChannelFormat>
    <audioChannelFormat audioChannelFormatID="AC_00011002"
         audioChannelFormatName="Hi" typeDefinition="DirectSpeakers">
      <frequency typeDefinition="highPass">200</frequency>
      <audioBlockFormat audioBlockFormatID="AB_00011002_00000001">
        <speakerLabel>M+030</speakerLabel>
      </audioBlockFormat>
    </audioChannelFormat>
    <audioChannelFormat audioChannelFormatID="AC_00011003"
         audioChannelFormatName="Bad" typeDefinition="DirectSpeakers">
      <frequency typeDefinition="lowPass">garbage</frequency>
      <audioBlockFormat audioBlockFormatID="AB_00011003_00000001">
        <speakerLabel>M-030</speakerLabel>
      </audioBlockFormat>
    </audioChannelFormat>
  </audioFormatExtended>)";
  auto model = ParseAxml(kLfeAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  ASSERT_EQ(model->channels.size(), 3u);
  ASSERT_TRUE(model->channels[0].low_pass_hz.has_value());
  EXPECT_FLOAT_EQ(*model->channels[0].low_pass_hz, 120.0f);
  EXPECT_FALSE(model->channels[0].high_pass_hz.has_value());
  ASSERT_TRUE(model->channels[1].high_pass_hz.has_value());
  EXPECT_FLOAT_EQ(*model->channels[1].high_pass_hz, 200.0f);
  EXPECT_FALSE(model->channels[1].low_pass_hz.has_value());
  // Unparseable cutoff: no marker.
  EXPECT_FALSE(model->channels[2].low_pass_hz.has_value());
}

TEST(AdmParser, ClampsImportanceToTheAdmRange) {
  constexpr char kAxmlTemplate[] = R"(<audioFormatExtended>
    <audioObject audioObjectID="AO_1001" audioObjectName="A" importance="%s">
      <audioPackFormatIDRef>AP_00010003</audioPackFormatIDRef>
    </audioObject>
  </audioFormatExtended>)";
  const struct {
    const char* attr;
    int want;
  } kCases[] = {{"27", 10}, {"-3", 0}, {"7.6", 8}, {"x", 10}};
  for (const auto& c : kCases) {
    char doc[512];
    snprintf(doc, sizeof(doc), kAxmlTemplate, c.attr);
    auto model = ParseAxml(doc);
    ASSERT_TRUE(model.ok()) << model.status();
    ASSERT_EQ(model->objects.size(), 1u);
    EXPECT_EQ(model->objects[0].importance, c.want) << "importance=" << c.attr;
  }
}

TEST(AdmParser, ParsesBedHierarchy) {
  auto model = ParseAxml(kAxml);
  ASSERT_TRUE(model.ok()) << model.status();

  ASSERT_EQ(model->programmes.size(), 1u);
  EXPECT_EQ(model->programmes[0].id, "APR_1001");
  ASSERT_TRUE(model->programmes[0].loudness.integrated_loudness.has_value());
  EXPECT_FLOAT_EQ(*model->programmes[0].loudness.integrated_loudness, -23.0f);

  ASSERT_EQ(model->objects.size(), 1u);
  EXPECT_EQ(model->objects[0].importance, 9);
  EXPECT_EQ(model->objects[0].track_uid_refs.size(), 3u);
  // gain -6 dB -> ~0.501 linear.
  EXPECT_NEAR(model->objects[0].gain, 0.50119f, 1e-4f);

  const AudioPackFormat* pack = model->Pack("AP_00010003");
  ASSERT_NE(pack, nullptr);
  EXPECT_EQ(pack->type, TypeDefinition::kDirectSpeakers);
  ASSERT_EQ(pack->channel_format_id_refs.size(), 3u);

  const AudioChannelFormat* left = model->Channel("AC_00010001");
  ASSERT_NE(left, nullptr);
  ASSERT_EQ(left->blocks.size(), 1u);
  ASSERT_TRUE(left->blocks[0].polar.has_value());
  EXPECT_FLOAT_EQ(left->blocks[0].polar->azimuth, 30.0f);
  EXPECT_FLOAT_EQ(left->blocks[0].polar->distance, 1.0f);
  EXPECT_EQ(left->blocks[0].speaker_label, "RC_L");

  // Right omitted distance -> default 1.0.
  const AudioChannelFormat* right = model->Channel("AC_00010002");
  ASSERT_NE(right, nullptr);
  EXPECT_FLOAT_EQ(right->blocks[0].polar->distance, 1.0f);
  EXPECT_FLOAT_EQ(right->blocks[0].polar->azimuth, -30.0f);
}

TEST(AdmParser, ParsesChnaAndMapsTrackIndex) {
  auto chna = MakeChna({
      {1, "ATU_00000001", "AT_00010001_01", "AP_00010003"},
      {2, "ATU_00000002", "AT_00010002_01", "AP_00010003"},
      {3, "ATU_00000003", "AT_00010003_01", "AP_00010003"},
  });
  auto entries = ParseChna(chna);
  ASSERT_TRUE(entries.ok()) << entries.status();
  ASSERT_EQ(entries->size(), 3u);
  EXPECT_EQ((*entries)[0].track_index, 1);
  EXPECT_EQ((*entries)[0].uid, "ATU_00000001");
  EXPECT_EQ((*entries)[0].pack_ref, "AP_00010003");
  // AT_00010001_01 -> AC_00010001.
  EXPECT_EQ((*entries)[0].ChannelFormatId(), "AC_00010001");

  Model model;
  model.chna = *entries;
  EXPECT_EQ(model.TrackIndexForChannel("AC_00010002"), 2);
  EXPECT_EQ(model.TrackIndexForChannel("AC_99999999"), 0);
}

TEST(AdmParser, ChnaChannelRefsDeriveChannelIds) {
  ChnaEntry e;
  e.track_ref = "AT_00010001_01";
  EXPECT_EQ(e.ChannelFormatId(), "AC_00010001");
  // BS.2076-2+ direct channel refs, with and without a counter suffix.
  e.track_ref = "AC_00010001";
  EXPECT_EQ(e.ChannelFormatId(), "AC_00010001");
  e.track_ref = "AC_00010001_00";
  EXPECT_EQ(e.ChannelFormatId(), "AC_00010001");
  e.track_ref = "";
  EXPECT_EQ(e.ChannelFormatId(), "");
  e.track_ref = "XX_1";
  EXPECT_EQ(e.ChannelFormatId(), "");
}

}  // namespace
}  // namespace adm
}  // namespace adm2iamf
