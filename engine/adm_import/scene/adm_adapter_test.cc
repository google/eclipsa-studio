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

#include <chrono>
#include <cstdint>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "adm_import/adm/adm_model.h"
#include "adm_import/adm/adm_parser.h"
#include "gtest/gtest.h"

namespace adm2iamf {
namespace {

// A 4-channel DirectSpeakers bed: L, R, LFE, and a top-front Ltf at U+045.
constexpr char kAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1" audioProgrammeName="P">
    <audioContentIDRef>ACO_1</audioContentIDRef>
  </audioProgramme>
  <audioContent audioContentID="ACO_1"><audioObjectIDRef>AO_1</audioObjectIDRef></audioContent>
  <audioObject audioObjectID="AO_1" audioObjectName="Bed">
    <audioPackFormatIDRef>AP_1</audioPackFormatIDRef>
    <gain gainUnit="dB">0.0</gain>
  </audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_R</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LFE</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LTF</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_L</speakerLabel>
      <position coordinate="azimuth">30</position>
      <position coordinate="elevation">0</position></audioBlockFormat>
  </audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_R" audioChannelFormatName="R" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_R</speakerLabel>
      <position coordinate="azimuth">-30</position>
      <position coordinate="elevation">0</position></audioBlockFormat>
  </audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LFE" audioChannelFormatName="LFE" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>LFE</speakerLabel></audioBlockFormat>
  </audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LTF" audioChannelFormatName="Ltf" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_Ltf</speakerLabel>
      <position coordinate="azimuth">45</position>
      <position coordinate="elevation">30</position></audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>)";

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
  for (int i = 0; i < 2; ++i) {
    v.push_back(n & 0xFF);
    v.push_back((n >> 8) & 0xFF);
  }
  for (const auto& [idx, uid, track, pack] : rows) {
    v.push_back(idx & 0xFF);
    v.push_back((idx >> 8) & 0xFF);
    AppendField(v, uid, 12);
    AppendField(v, track, 14);
    AppendField(v, pack, 11);
    v.push_back(0);
  }
  return v;
}

adm::Model BuildModel() {
  auto model = adm::ParseAxml(kAxml);
  EXPECT_TRUE(model.ok()) << model.status();
  // chna binds each channel format to a WAV track (note: out of pack order to
  // prove we map by channel id, not position).
  auto chna = adm::ParseChna(MakeChna({
      {1, "ATU_00000001", "AT_L_01", "AP_1"},
      {2, "ATU_00000002", "AT_R_01", "AP_1"},
      {4, "ATU_00000004", "AT_LFE_01", "AP_1"},
      {3, "ATU_00000003", "AT_LTF_01", "AP_1"},
  }));
  EXPECT_TRUE(chna.ok());
  model->chna = *chna;
  return *model;
}

TEST(AdmAdapter, BuildsStaticBedSources) {
  adm::Model model = BuildModel();
  // chna trackRef "AT_L_01" derives channel id "AC_L", matching the pack's
  // channel ids, so tracks map by id (not pack order).
  auto scene = BuildSceneFromAdm(model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->sources.size(), 4u);

  const Source& l = scene->sources[0];
  EXPECT_EQ(l.label, "L");
  EXPECT_FLOAT_EQ(l.position.azimuth, 30.0f);
  EXPECT_FALSE(l.is_lfe);
  EXPECT_EQ(l.track_index, 1);

  const Source& lfe = scene->sources[2];
  EXPECT_TRUE(lfe.is_lfe);
  EXPECT_EQ(lfe.track_index, 4);  // Mapped by id, not pack order.

  const Source& ltf = scene->sources[3];
  EXPECT_FLOAT_EQ(ltf.position.azimuth, 45.0f);
  EXPECT_FLOAT_EQ(ltf.position.elevation, 30.0f);
  EXPECT_EQ(ltf.track_index, 3);

  // Every bed channel carries a resolution record. Polar positions win
  // (the vendor labels are unrecognized, so no divergence check applies);
  // the LFE spelling resolves as an LFE label.
  ASSERT_EQ(scene->resolutions.size(), 4u);
  EXPECT_EQ(scene->resolutions[0].method, ResolutionMethod::kPolar);
  EXPECT_TRUE(scene->resolutions[0].resolved);
  EXPECT_FALSE(scene->resolutions[0].fallback);
  EXPECT_EQ(scene->resolutions[2].method, ResolutionMethod::kLfeLabel);
  EXPECT_TRUE(scene->resolutions[2].is_lfe);
}

// An allocentric *cartesian* bed as vendor authoring tools write it:
// proprietary labels + cube positions + the cartesian flag. Bed channels must
// resolve to their nominal loudspeaker direction (side -> 90, top-side ->
// 90/30), NOT the BS.2127 object warp (which would give 70). This guards the
// Phase-1 correction validated against the 7.1.4 corpus master.
constexpr char kCartesianAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1"><audioContentIDRef>ACO_1</audioContentIDRef></audioProgramme>
  <audioContent audioContentID="ACO_1"><audioObjectIDRef>AO_1</audioObjectIDRef></audioContent>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LFE</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LSS</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LTS</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_L</speakerLabel><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">1</position><position coordinate="Z">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LFE" audioChannelFormatName="LFE" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_LFE</speakerLabel><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">1</position><position coordinate="Z">-1</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LSS" audioChannelFormatName="Lss" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_Lss</speakerLabel><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">0</position><position coordinate="Z">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LTS" audioChannelFormatName="Lts" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_Lts</speakerLabel><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">0</position><position coordinate="Z">1</position></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";

TEST(AdmAdapter, CartesianBedResolvesToNominalSpeakerAngles) {
  auto model = adm::ParseAxml(kCartesianAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto chna = adm::ParseChna(MakeChna({
      {1, "ATU_00000001", "AT_L_01", "AP_1"},
      {2, "ATU_00000002", "AT_LFE_01", "AP_1"},
      {3, "ATU_00000003", "AT_LSS_01", "AP_1"},
      {4, "ATU_00000004", "AT_LTS_01", "AP_1"},
  }));
  ASSERT_TRUE(chna.ok());
  model->chna = *chna;

  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->sources.size(), 4u);

  EXPECT_FLOAT_EQ(scene->sources[0].position.azimuth, 30.0f);  // L
  EXPECT_TRUE(scene->sources[1].is_lfe);                       // LFE
  EXPECT_FLOAT_EQ(scene->sources[2].position.azimuth,
                  90.0f);  // Lss: 90, not 70
  EXPECT_FLOAT_EQ(scene->sources[2].position.elevation, 0.0f);
  EXPECT_FLOAT_EQ(scene->sources[3].position.azimuth, 90.0f);  // Lts: top-side
  EXPECT_FLOAT_EQ(scene->sources[3].position.elevation, 30.0f);

  // The vendor labels are unrecognized, so every channel resolves through
  // the cube grid and is recorded as a fallback (surfaced as warnings).
  ASSERT_EQ(scene->resolutions.size(), 4u);
  EXPECT_EQ(scene->resolutions[0].method, ResolutionMethod::kCubeSlot);
  EXPECT_TRUE(scene->resolutions[0].fallback);
  EXPECT_NE(scene->resolutions[0].note.find("RC_L"), std::string::npos);
  // The LFE channel: its name is the spec spelling "LFE", so it resolves
  // through the lenient name path before the cube stage.
  EXPECT_EQ(scene->resolutions[1].method, ResolutionMethod::kLfeLabel);
  EXPECT_TRUE(scene->resolutions[1].is_lfe);
  EXPECT_TRUE(scene->resolutions[1].fallback);
}

// A 7.x-style cartesian bed with rears: the pack occupies the side slots,
// so the rear slots must resolve to M±135 (BS.2094 Table 2B), matching the
// retired vendor label table for RC_Lrs/RC_Rrs.
TEST(AdmAdapter, PackContextResolvesRearsTo135) {
  constexpr char kRearsAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_LSS</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LRS</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_LSS" audioChannelFormatName="Lss" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_Lss</speakerLabel><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">0</position><position coordinate="Z">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LRS" audioChannelFormatName="Lrs" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_Lrs</speakerLabel><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">-1</position><position coordinate="Z">0</position></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kRearsAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);  // No chna: sequential tracks.
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->sources.size(), 2u);
  EXPECT_FLOAT_EQ(scene->sources[0].position.azimuth, 90.0f);
  EXPECT_FLOAT_EQ(scene->sources[1].position.azimuth, 135.0f);
}

// A 5.x-style cartesian bed without side slots: rears stay at M±110.
TEST(AdmAdapter, RearsWithoutSidesResolveTo110) {
  constexpr char kNoSidesAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LS</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">1</position><position coordinate="Z">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LS" audioChannelFormatName="Ls" typeDefinition="DirectSpeakers">
    <audioBlockFormat><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">-1</position><position coordinate="Z">0</position></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kNoSidesAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->sources.size(), 2u);
  EXPECT_FLOAT_EQ(scene->sources[1].position.azimuth, 110.0f);
}

// An EBU-style bed: spec labels + polar positions. Everything resolves
// clean — no fallbacks, no warnings-worthy records.
TEST(AdmAdapter, EbuPolarBedResolvesClean) {
  constexpr char kEbuAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LFE</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="FrontLeft" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>urn:itu:bs:2051:0:speaker:M+030</speakerLabel>
      <position coordinate="azimuth">30</position>
      <position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LFE" audioChannelFormatName="LowFrequencyEffects" typeDefinition="DirectSpeakers">
    <frequency typeDefinition="lowPass">120</frequency>
    <audioBlockFormat><speakerLabel>urn:itu:bs:2051:0:speaker:LFE</speakerLabel>
      <position coordinate="azimuth">0</position>
      <position coordinate="elevation">-30</position></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kEbuAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->sources.size(), 2u);
  EXPECT_FLOAT_EQ(scene->sources[0].position.azimuth, 30.0f);
  EXPECT_TRUE(scene->sources[1].is_lfe);
  ASSERT_EQ(scene->resolutions.size(), 2u);
  EXPECT_EQ(scene->resolutions[0].method, ResolutionMethod::kPolar);
  EXPECT_FALSE(scene->resolutions[0].fallback);
  EXPECT_FALSE(scene->resolutions[0].divergence);
  // The LFE resolves from the spec frequency marker before anything else.
  EXPECT_EQ(scene->resolutions[1].method, ResolutionMethod::kLfeFrequency);
  EXPECT_FALSE(scene->resolutions[1].fallback);
}

// A recognized label whose direction disagrees with the authored polar
// position: the position wins, and the divergence is recorded.
TEST(AdmAdapter, LabelPositionDivergenceIsRecorded) {
  constexpr char kDivergentAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+030</speakerLabel>
      <position coordinate="azimuth">60</position>
      <position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kDivergentAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->sources.size(), 1u);
  EXPECT_FLOAT_EQ(scene->sources[0].position.azimuth, 60.0f);  // Position.
  ASSERT_EQ(scene->resolutions.size(), 1u);
  EXPECT_EQ(scene->resolutions[0].method, ResolutionMethod::kPolar);
  EXPECT_TRUE(scene->resolutions[0].divergence);
  EXPECT_NE(scene->resolutions[0].note.find("M+030"), std::string::npos);
}

// A lowPass <frequency> outranks the speaker label, but when the label is a
// recognized *non-LFE* speaker the contradiction must be surfaced — this is
// the only rung that can silently make a channel unpannable.
TEST(AdmAdapter, LowPassContradictingSpeakerLabelIsRecorded) {
  constexpr char kAxmlLowPassVsLabel[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LFE</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <frequency typeDefinition="lowPass">120</frequency>
    <audioBlockFormat><speakerLabel>M+030</speakerLabel>
      <position coordinate="azimuth">30</position>
      <position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LFE" audioChannelFormatName="LFE" typeDefinition="DirectSpeakers">
    <frequency typeDefinition="lowPass">120</frequency>
    <audioBlockFormat><speakerLabel>LFE</speakerLabel></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kAxmlLowPassVsLabel);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->resolutions.size(), 2u);

  // Both route to LFE (the marker wins) ...
  EXPECT_EQ(scene->resolutions[0].method, ResolutionMethod::kLfeFrequency);
  EXPECT_TRUE(scene->resolutions[0].is_lfe);
  // ... but only the contradicting one is flagged, naming the label.
  EXPECT_TRUE(scene->resolutions[0].divergence);
  EXPECT_NE(scene->resolutions[0].note.find("M+030"), std::string::npos);

  EXPECT_EQ(scene->resolutions[1].method, ResolutionMethod::kLfeFrequency);
  EXPECT_FALSE(scene->resolutions[1].divergence);
  EXPECT_TRUE(scene->resolutions[1].note.empty());
}

// An off-grid cartesian bed channel falls back to its naive physical
// direction and is always flagged.
TEST(AdmAdapter, OffGridCartesianFallsBackToPhysicalDirection) {
  constexpr char kOffGridAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_X</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_X" audioChannelFormatName="Odd" typeDefinition="DirectSpeakers">
    <audioBlockFormat><cartesian>1</cartesian>
      <position coordinate="X">-0.7</position>
      <position coordinate="Y">0.7</position>
      <position coordinate="Z">0</position></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kOffGridAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->resolutions.size(), 1u);
  EXPECT_EQ(scene->resolutions[0].method, ResolutionMethod::kPhysicalFallback);
  EXPECT_TRUE(scene->resolutions[0].fallback);
  EXPECT_FLOAT_EQ(scene->sources[0].position.azimuth, 45.0f);
}

// A channel with no usable information is dropped but surfaced.
TEST(AdmAdapter, UnresolvedChannelIsSurfaced) {
  constexpr char kUnresolvedAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_OK</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_NADA</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_OK" audioChannelFormatName="C" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+000</speakerLabel></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_NADA" audioChannelFormatName="Mystery" typeDefinition="DirectSpeakers">
    <audioBlockFormat></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kUnresolvedAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->sources.size(), 1u);  // AC_NADA dropped.
  ASSERT_EQ(scene->resolutions.size(), 2u);
  EXPECT_EQ(scene->resolutions[0].method, ResolutionMethod::kSpecLabel);
  EXPECT_EQ(scene->resolutions[1].method, ResolutionMethod::kUnresolved);
  EXPECT_FALSE(scene->resolutions[1].resolved);
  EXPECT_EQ(scene->resolutions[1].channel_id, "AC_NADA");
}

// A pack type the importer cannot render (here HOA) in a mixed master: its
// channels are recorded, each with the dedicated method and a note naming
// the type, and they still consume their sequential tracks, so the bed that
// follows keeps its own tracks (ES-623).
TEST(AdmAdapter, UnsupportedPackChannelsAreRecordedAndConsumeTracks) {
  constexpr char kMixedHoaAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_HOA" audioObjectName="ambience">
    <audioPackFormatIDRef>AP_HOA</audioPackFormatIDRef></audioObject>
  <audioObject audioObjectID="AO_BED"><audioPackFormatIDRef>AP_BED</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_HOA" typeDefinition="HOA">
    <audioChannelFormatIDRef>AC_W</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_Y</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_Z</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_X</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioPackFormat audioPackFormatID="AP_BED" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_R</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_W" audioChannelFormatName="W" typeDefinition="HOA">
    <audioBlockFormat><order>0</order><degree>0</degree></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_Y" audioChannelFormatName="Y" typeDefinition="HOA">
    <audioBlockFormat><order>1</order><degree>-1</degree></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_Z" audioChannelFormatName="Z" typeDefinition="HOA">
    <audioBlockFormat><order>1</order><degree>0</degree></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_X" audioChannelFormatName="X" typeDefinition="HOA">
    <audioBlockFormat><order>1</order><degree>1</degree></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+030</speakerLabel></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_R" audioChannelFormatName="R" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-030</speakerLabel></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kMixedHoaAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();

  ASSERT_EQ(scene->sources.size(), 2u);
  EXPECT_EQ(scene->sources[0].label, "L");
  EXPECT_EQ(scene->sources[0].track_index, 5);  // After the four HOA tracks.
  EXPECT_EQ(scene->sources[1].track_index, 6);

  ASSERT_EQ(scene->resolutions.size(), 6u);
  const char* const kHoa[] = {"AC_W", "AC_Y", "AC_Z", "AC_X"};
  for (int i = 0; i < 4; ++i) {
    const ChannelResolution& r = scene->resolutions[i];
    EXPECT_EQ(r.channel_id, kHoa[i]);
    EXPECT_EQ(r.method, ResolutionMethod::kUnsupportedPack);
    EXPECT_FALSE(r.resolved);
    EXPECT_NE(r.note.find("an HOA pack"), std::string::npos) << r.note;
  }
  EXPECT_TRUE(scene->resolutions[4].resolved);
  EXPECT_TRUE(scene->resolutions[5].resolved);
}

// A master with only unsupported content still fails, but the error now
// names the dropped channels (ES-623).
TEST(AdmAdapter, UnsupportedOnlyMasterFailsNamingItsChannels) {
  constexpr char kMatrixOnlyAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_M</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_M" typeDefinition="Matrix">
    <audioChannelFormatIDRef>AC_MT</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_MT" audioChannelFormatName="Mt" typeDefinition="Matrix">
    <audioBlockFormat></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kMatrixOnlyAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_FALSE(scene.ok());
  EXPECT_NE(scene.status().message().find("AC_MT"), std::string::npos)
      << scene.status();
}

// Polar object azimuths are wrapped to (-180, 180] the way OLR wraps them
// before panning, so the probe's label matches the rendered direction (ES-627).
TEST(AdmAdapter, PolarObjectAzimuthIsWrappedLikeOlr) {
  constexpr char kWrapAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1" audioObjectName="o">
    <audioPackFormatIDRef>AP_O</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_O" typeDefinition="Objects">
    <audioChannelFormatIDRef>AC_O</audioChannelFormatIDRef></audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_O" audioChannelFormatName="o" typeDefinition="Objects">
    <audioBlockFormat rtime="00:00:00.00000" duration="00:00:01.00000">
      <position coordinate="azimuth">270</position><position coordinate="elevation">0</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:01.00000" duration="00:00:01.00000">
      <position coordinate="azimuth">-190</position><position coordinate="elevation">0</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:02.00000" duration="00:00:01.00000">
      <position coordinate="azimuth">180</position><position coordinate="elevation">0</position></audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kWrapAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->objects.size(), 1u);
  const auto& tl = scene->objects[0].timeline;
  ASSERT_EQ(tl.size(), 3u);
  EXPECT_FLOAT_EQ(tl[0].position.polar.azimuth, -90.0f);
  EXPECT_FLOAT_EQ(tl[1].position.polar.azimuth, 170.0f);
  EXPECT_FLOAT_EQ(tl[2].position.polar.azimuth, 180.0f);
}

TEST(AdmAdapter, DanglingChannelRefStillConsumesItsSequentialTrack) {
  // No chna table: tracks are assigned sequentially in pack order. A ref to
  // a missing audioChannelFormat must still burn its index, or every later
  // channel in the pack shifts one track down.
  constexpr char kDanglingAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_GONE</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_R</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+030</speakerLabel></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_R" audioChannelFormatName="R" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-030</speakerLabel></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kDanglingAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->sources.size(), 2u);
  EXPECT_EQ(scene->sources[0].label, "L");
  EXPECT_EQ(scene->sources[0].track_index, 1);
  EXPECT_EQ(scene->sources[1].label, "R");
  // Track 2 belongs to the dangling AC_GONE ref; R keeps track 3.
  EXPECT_EQ(scene->sources[1].track_index, 3);
}

// Records name the source they produced. A bed that mixes resolved and
// dropped channels must still annotate each source with its own record --
// consumers (the probe JSON) pair through source_index, not by position.
TEST(AdmAdapter, RecordsNameTheSourceTheyProduced) {
  constexpr char kMixedAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1"><audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_A</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_NADA</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_C</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_A" audioChannelFormatName="A" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+030</speakerLabel>
      <position coordinate="azimuth">30</position>
      <position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_NADA" audioChannelFormatName="Mystery" typeDefinition="DirectSpeakers">
    <audioBlockFormat></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_C" audioChannelFormatName="C" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_Lss</speakerLabel><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">0</position>
      <position coordinate="Z">0</position></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kMixedAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();

  ASSERT_EQ(scene->sources.size(), 2u);
  ASSERT_EQ(scene->resolutions.size(), 3u);
  EXPECT_EQ(scene->resolutions[0].source_index, 0);
  EXPECT_EQ(scene->resolutions[1].source_index, -1);  // Dropped channel.
  EXPECT_EQ(scene->resolutions[2].source_index, 1);
  // Following the indices lands on the right source, not a shifted one.
  EXPECT_EQ(scene->sources[scene->resolutions[2].source_index].label, "C");
  EXPECT_EQ(scene->resolutions[2].method, ResolutionMethod::kCubeSlot);
}

// Dynamic-object positions stay in their authored coordinate system (ES-567):
// cartesian blocks keep their cube coordinates (clamped to the room cube)
// for render-time layout-anchored conversion; polar blocks stay polar.
TEST(AdmAdapter, ObjectKeyframesKeepAuthoredCoordinateSystem) {
  constexpr char kObjAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1" audioObjectName="mover">
    <audioPackFormatIDRef>AP_1</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000001</audioTrackUIDRef>
  </audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="Objects">
    <audioChannelFormatIDRef>AC_1</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_1" audioChannelFormatName="mover" typeDefinition="Objects">
    <audioBlockFormat rtime="00:00:00.00000" duration="00:00:01.00000"><cartesian>1</cartesian>
      <position coordinate="X">-1.5</position><position coordinate="Y">1</position><position coordinate="Z">0.5</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:01.00000">
      <position coordinate="azimuth">30</position><position coordinate="elevation">10</position><position coordinate="distance">0.8</position></audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>)";
  auto model = adm::ParseAxml(kObjAxml);
  ASSERT_TRUE(model.ok()) << model.status();
  auto scene = BuildSceneFromAdm(*model);
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->objects.size(), 1u);
  const auto& tl = scene->objects[0].timeline;
  ASSERT_EQ(tl.size(), 2u);
  ASSERT_TRUE(tl[0].position.cartesian);
  EXPECT_FLOAT_EQ(tl[0].position.cube.x, -1.0f);  // Clamped to the cube.
  EXPECT_EQ(scene->clamped_object_values, 1);     // ...and counted for the
                                                  // probe's clamp warning.
  EXPECT_FLOAT_EQ(tl[0].position.cube.y, 1.0f);
  EXPECT_FLOAT_EQ(tl[0].position.cube.z, 0.5f);
  ASSERT_FALSE(tl[1].position.cartesian);
  EXPECT_FLOAT_EQ(tl[1].position.polar.azimuth, 30.0f);
  EXPECT_FLOAT_EQ(tl[1].position.polar.elevation, 10.0f);
  EXPECT_FLOAT_EQ(tl[1].position.polar.distance, 0.8f);
}

TEST(AdmAdapter, FailsWhenNoBedReachable) {
  adm::Model empty;
  EXPECT_FALSE(BuildSceneFromAdm(empty).ok());
}

// A bed of kChannels channels, each with its own channel format and chna
// row. Each channel ref used to scan the channel formats, and the chna
// rows with a channel id built per row, so the scene build was quadratic
// in the channel count (ES-849).
TEST(AdmAdapter, LargeBedBuildsInLinearTime) {
  constexpr int kChannels = 20000;
  adm::Model model;
  adm::AudioObject obj;
  obj.id = "AO_1";
  obj.pack_format_id_refs = {"AP_1"};
  model.objects.push_back(std::move(obj));
  adm::AudioPackFormat pack;
  pack.id = "AP_1";
  pack.type = adm::TypeDefinition::kDirectSpeakers;
  for (int i = 0; i < kChannels; ++i) {
    const std::string n = std::to_string(i);
    pack.channel_format_id_refs.push_back("AC_" + n);
    adm::AudioChannelFormat ch;
    ch.id = "AC_" + n;
    ch.type = adm::TypeDefinition::kDirectSpeakers;
    adm::AudioBlockFormat block;
    block.speaker_label = "M+030";
    ch.blocks.push_back(std::move(block));
    model.channels.push_back(std::move(ch));
    adm::ChnaEntry row;
    row.track_index = static_cast<uint16_t>(i + 1);
    row.uid = "ATU_" + n;
    row.track_ref = "AT_" + n + "_01";
    row.pack_ref = "AP_1";
    model.chna.push_back(std::move(row));
  }
  model.packs.push_back(std::move(pack));

  const auto start = std::chrono::steady_clock::now();
  auto scene = BuildSceneFromAdm(model);
  const auto elapsed = std::chrono::steady_clock::now() - start;
  ASSERT_TRUE(scene.ok()) << scene.status();
  ASSERT_EQ(scene->sources.size(), size_t{kChannels});
  EXPECT_EQ(scene->sources.front().track_index, 1);
  EXPECT_EQ(scene->sources.back().track_index, kChannels);
  EXPECT_LT(elapsed, std::chrono::seconds(5));
}

// A programme that references kContents contents. Each content ref used
// to scan every content (ES-849).
TEST(AdmAdapter, ManyContentsResolveInLinearTime) {
  constexpr int kContents = 80000;
  adm::Model model = BuildModel();  // APR_1 -> ACO_1 -> AO_1, a 4-channel bed.
  ASSERT_EQ(model.programmes.size(), 1u);
  for (int i = 0; i < kContents; ++i) {
    adm::AudioContent content;
    content.id = "ACO_X" + std::to_string(i);
    model.programmes[0].content_id_refs.push_back(content.id);
    model.contents.push_back(std::move(content));
  }

  const auto start = std::chrono::steady_clock::now();
  auto scene = BuildSceneFromAdm(model);
  const auto elapsed = std::chrono::steady_clock::now() - start;
  ASSERT_TRUE(scene.ok()) << scene.status();
  EXPECT_EQ(scene->sources.size(), 4u);
  EXPECT_LT(elapsed, std::chrono::seconds(5));
}

}  // namespace
}  // namespace adm2iamf
