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

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

#include "adm_import/convert/convert.h"
#include "adm_import/wav/bwf_fixture.h"
#include "gtest/gtest.h"

namespace adm2iamf {
namespace {

// A 7.1.2 DirectSpeakers bed authored at top-FRONT (U+/-045). Channel ids match
// the ids the chna trackRefs derive (AT_L_01 -> AC_L, ...).
constexpr char kAxml712[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1" audioProgrammeName="Main">
    <audioContentIDRef>ACO_1</audioContentIDRef></audioProgramme>
  <audioContent audioContentID="ACO_1"><audioObjectIDRef>AO_1</audioObjectIDRef></audioContent>
  <audioObject audioObjectID="AO_1" audioObjectName="Bed">
    <audioPackFormatIDRef>AP_712</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_712" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_R</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_C</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LFE</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LSS</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_RSS</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LRS</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_RRS</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_LTF</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_RTF</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+030</speakerLabel>
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_R" audioChannelFormatName="R" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-030</speakerLabel>
      <position coordinate="azimuth">-30</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_C" audioChannelFormatName="C" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+000</speakerLabel>
      <position coordinate="azimuth">0</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LFE" audioChannelFormatName="LFE" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>LFE</speakerLabel></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LSS" audioChannelFormatName="Lss" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+090</speakerLabel>
      <position coordinate="azimuth">90</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_RSS" audioChannelFormatName="Rss" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-090</speakerLabel>
      <position coordinate="azimuth">-90</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LRS" audioChannelFormatName="Lrs" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+135</speakerLabel>
      <position coordinate="azimuth">135</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_RRS" audioChannelFormatName="Rrs" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-135</speakerLabel>
      <position coordinate="azimuth">-135</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_LTF" audioChannelFormatName="Ltf" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>U+045</speakerLabel>
      <position coordinate="azimuth">45</position><position coordinate="elevation">30</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_RTF" audioChannelFormatName="Rtf" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>U-045</speakerLabel>
      <position coordinate="azimuth">-45</position><position coordinate="elevation">30</position></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";

std::string TempPath(const char* name) {
  const char* dir = std::getenv("TEST_TMPDIR");
  return std::string(dir ? dir : "/tmp") + "/" + name;
}

// Writes the 7.1.2 fixture: track i (1-based) carries constant DC 0.1*i.
std::string WriteFixture(uint32_t sample_rate = 48000, int frames = 64) {
  std::vector<std::vector<float>> tracks;
  for (int i = 1; i <= 10; ++i) {
    tracks.emplace_back(frames, 0.1f * i);
  }
  auto chna = test::MakeChna({
      {1, "ATU_00000001", "AT_L_01", "AP_712"},
      {2, "ATU_00000002", "AT_R_01", "AP_712"},
      {3, "ATU_00000003", "AT_C_01", "AP_712"},
      {4, "ATU_00000004", "AT_LFE_01", "AP_712"},
      {5, "ATU_00000005", "AT_LSS_01", "AP_712"},
      {6, "ATU_00000006", "AT_RSS_01", "AP_712"},
      {7, "ATU_00000007", "AT_LRS_01", "AP_712"},
      {8, "ATU_00000008", "AT_RRS_01", "AP_712"},
      {9, "ATU_00000009", "AT_LTF_01", "AP_712"},
      {10, "ATU_00000010", "AT_RTF_01", "AP_712"},
  });
  const std::string path = TempPath("bed_712.wav");
  EXPECT_TRUE(
      test::WriteAdmBwf(path, tracks, sample_rate, kAxml712, chna).ok());
  return path;
}

TEST(ConvertIntegration, SevenOneTwoBedToSevenOneFour) {
  const std::string path = WriteFixture();
  auto r = ConvertAdmFileToChannelBed(path);
  ASSERT_TRUE(r.ok()) << r.status();
  EXPECT_EQ(r->sample_rate, kBedSampleRate);
  ASSERT_EQ(r->channels.size(), 12u);
  EXPECT_EQ(r->stats.passthrough, 9);
  EXPECT_EQ(r->stats.lfe, 1);
  EXPECT_EQ(r->stats.olr, 0);

  const float kExpect[12] = {0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f,
                             0.7f, 0.8f, 0.9f, 1.0f, 0.0f, 0.0f};
  for (int ch = 0; ch < 12; ++ch) {
    EXPECT_NEAR(r->channels[ch][0], kExpect[ch], 1e-6f) << "ch=" << ch;
  }
}

// A master at another rate is resampled to kBedSampleRate after the render:
// the bed keeps its duration (frames scale by the rate ratio) and its
// steady-state levels, and the progress range ends at exactly 1.0 with the
// resample pass included.
TEST(ConvertIntegration, ResamplesNon48kMasterToBedRate) {
  const std::string path = WriteFixture(96000, /*frames=*/4800);
  uint64_t last_done = 0;
  uint64_t last_total = 0;
  RenderProgress progress;
  progress.report = [&](uint64_t done, uint64_t total) {
    last_done = done;
    last_total = total;
  };
  auto r = ConvertAdmFileToChannelBed(path, 0, &progress);
  ASSERT_TRUE(r.ok()) << r.status();
  EXPECT_EQ(r->sample_rate, kBedSampleRate);
  ASSERT_EQ(r->channels.size(), 12u);
  for (int ch = 0; ch < 12; ++ch) {
    EXPECT_EQ(r->channels[ch].size(), 2400u) << "ch=" << ch;
  }
  // DC through the sinc converter is exact once the filter has settled;
  // check mid-stream, away from both edges.
  const float kExpect[12] = {0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f,
                             0.7f, 0.8f, 0.9f, 1.0f, 0.0f, 0.0f};
  for (int ch = 0; ch < 12; ++ch) {
    EXPECT_NEAR(r->channels[ch][1200], kExpect[ch], 1e-3f) << "ch=" << ch;
  }
  EXPECT_GT(last_total, 0u);
  EXPECT_EQ(last_done, last_total);
}

// A bed (L/R/LFE) plus one dynamic Objects object, to exercise the full object
// read path: object -> Objects pack -> channel blocks, track via UID -> chna.
constexpr char kBedPlusObjectAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1"><audioContentIDRef>ACO_1</audioContentIDRef></audioProgramme>
  <audioContent audioContentID="ACO_1">
    <audioObjectIDRef>AO_BED</audioObjectIDRef><audioObjectIDRef>AO_OBJ</audioObjectIDRef></audioContent>
  <audioObject audioObjectID="AO_BED">
    <audioPackFormatIDRef>AP_BED</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000001</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000002</audioTrackUIDRef></audioObject>
  <audioObject audioObjectID="AO_OBJ" audioObjectName="mover" importance="10">
    <audioPackFormatIDRef>AP_OBJ</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000003</audioTrackUIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_BED" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_R</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioPackFormat audioPackFormatID="AP_OBJ" typeDefinition="Objects">
    <audioChannelFormatIDRef>AC_OBJ</audioChannelFormatIDRef></audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+030</speakerLabel>
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_R" audioChannelFormatName="R" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-030</speakerLabel>
      <position coordinate="azimuth">-30</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_OBJ" audioChannelFormatName="mover" typeDefinition="Objects">
    <audioBlockFormat rtime="00:00:00.00000" duration="00:00:00.50000"><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">0</position><position coordinate="Z">0</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:00.50000"><cartesian>1</cartesian>
      <position coordinate="X">1</position><position coordinate="Y">0</position><position coordinate="Z">0</position></audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>)";

// An EBU-style bed carried as a single object that references a BS.2094
// common-definition pack (AP_00010016 = 7.1.2), with NO audioPackFormat or
// audioChannelFormat inlined -- the channels exist only as chna track bindings.
// The common-definition resolver must synthesize the bed so it renders.
constexpr char kCommonDefBedAxml[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1"><audioContentIDRef>ACO_1</audioContentIDRef></audioProgramme>
  <audioContent audioContentID="ACO_1"><audioObjectIDRef>AO_BED</audioObjectIDRef></audioContent>
  <audioObject audioObjectID="AO_BED" audioObjectName="Bed_1">
    <audioPackFormatIDRef>AP_00010016</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000001</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000002</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000003</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000004</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000005</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000006</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000007</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000008</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000009</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_0000000a</audioTrackUIDRef>
  </audioObject>
</audioFormatExtended>)";

TEST(ConvertIntegration, ResolvesCommonDefinitionBed) {
  std::vector<std::vector<float>> tracks;
  for (int i = 1; i <= 10; ++i) tracks.emplace_back(64, 0.1f * i);
  // Bed track order: L R C LFE Lss Rss Lrs Rrs Lts Rts (common-def channel
  // ids).
  auto chna = test::MakeChna({
      {1, "ATU_00000001", "AT_00010001_01", "AP_00010016"},
      {2, "ATU_00000002", "AT_00010002_01", "AP_00010016"},
      {3, "ATU_00000003", "AT_00010003_01", "AP_00010016"},
      {4, "ATU_00000004", "AT_00010004_01", "AP_00010016"},
      {5, "ATU_00000005", "AT_0001000a_01", "AP_00010016"},
      {6, "ATU_00000006", "AT_0001000b_01", "AP_00010016"},
      {7, "ATU_00000007", "AT_0001001c_01", "AP_00010016"},
      {8, "ATU_00000008", "AT_0001001d_01", "AP_00010016"},
      {9, "ATU_00000009", "AT_00010013_01", "AP_00010016"},
      {10, "ATU_0000000a", "AT_00010014_01", "AP_00010016"},
  });
  const std::string path = TempPath("commondef_bed.wav");
  ASSERT_TRUE(
      test::WriteAdmBwf(path, tracks, 48000, kCommonDefBedAxml, chna).ok());

  // Into 7.1.4 the bed's seven ear-level channels are coincident and pass
  // through, the LFE routes to LFE, and the top-side pair (U+/-090, no 7.1.4
  // speaker) phantom-renders through OLR. That it renders at all proves the
  // bed was resolved.
  auto r = ConvertAdmFileToChannelBed(path);
  ASSERT_TRUE(r.ok()) << r.status();
  EXPECT_EQ(r->stats.passthrough, 7);
  EXPECT_EQ(r->stats.olr, 2);
  EXPECT_EQ(r->stats.lfe, 1);
  // FC (track 3, DC 0.3) lands on 7.1.4 FC (index 2), exactly.
  EXPECT_NEAR(r->channels[2][0], 0.3f, 1e-6f);
}

TEST(ConvertIntegration, RendersBedPlusDynamicObject) {
  std::vector<std::vector<float>> tracks = {
      std::vector<float>(96, 0.4f),  // L
      std::vector<float>(96, 0.4f),  // R
      std::vector<float>(96, 0.5f),  // object
  };
  auto chna = test::MakeChna({
      {1, "ATU_00000001", "AT_L_01", "AP_BED"},
      {2, "ATU_00000002", "AT_R_01", "AP_BED"},
      {3, "ATU_00000003", "AT_OBJ_01", "AP_OBJ"},
  });
  const std::string path = TempPath("bed_plus_obj.wav");
  ASSERT_TRUE(
      test::WriteAdmBwf(path, tracks, 48000, kBedPlusObjectAxml, chna).ok());

  auto r = ConvertAdmFileToChannelBed(path);
  ASSERT_TRUE(r.ok()) << r.status();
  EXPECT_EQ(r->stats.objects, 1);
  EXPECT_EQ(r->stats.passthrough, 2);  // L, R
  // The object (left side -> right side) puts energy on a surround channel that
  // the L/R-only bed never touches (Lss = ch4).
  float lss_peak = 0;
  for (float v : r->channels[4]) lss_peak = std::max(lss_peak, std::fabs(v));
  EXPECT_GT(lss_peak, 0.05f);

  // Filtering it out leaves only the bed.
  auto bed_only = ConvertAdmFileToChannelBed(path, /*min=*/11);
  ASSERT_TRUE(bed_only.ok());
  EXPECT_EQ(bed_only->stats.objects, 0);
  EXPECT_EQ(bed_only->stats.objects_dropped, 1);
}

}  // namespace
}  // namespace adm2iamf
