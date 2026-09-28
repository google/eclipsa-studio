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

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#include "absl/strings/str_cat.h"
#include "adm_import/convert/convert.h"
#include "adm_import/ffi/adm2iamf_ffi.h"
#include "adm_import/render/channel_renderer.h"
#include "adm_import/render/image_spread.h"
#include "adm_import/scene/layouts.h"
#include "adm_import/wav/bwf_fixture.h"
#include "gtest/gtest.h"

namespace {

// A minimal 7.1.2 DirectSpeakers bed (mirrors the convert integration fixture).
constexpr char kAxml712[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1001" audioProgrammeName="Main">
    <audioContentIDRef>ACO_1001</audioContentIDRef></audioProgramme>
  <audioContent audioContentID="ACO_1001"><audioObjectIDRef>AO_1001</audioObjectIDRef></audioContent>
  <audioObject audioObjectID="AO_1001" audioObjectName="Bed">
    <audioPackFormatIDRef>AP_00011001</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_00011001" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_00011001</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00011002</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00011003</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00011004</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00011005</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00011006</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00011007</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00011008</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00011009</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_0001100a</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011001" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+030</speakerLabel>
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011002" audioChannelFormatName="R" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-030</speakerLabel>
      <position coordinate="azimuth">-30</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011003" audioChannelFormatName="C" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+000</speakerLabel>
      <position coordinate="azimuth">0</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011004" audioChannelFormatName="LFE" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>LFE</speakerLabel></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011005" audioChannelFormatName="Lss" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+090</speakerLabel>
      <position coordinate="azimuth">90</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011006" audioChannelFormatName="Rss" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-090</speakerLabel>
      <position coordinate="azimuth">-90</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011007" audioChannelFormatName="Lrs" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+135</speakerLabel>
      <position coordinate="azimuth">135</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011008" audioChannelFormatName="Rrs" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-135</speakerLabel>
      <position coordinate="azimuth">-135</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011009" audioChannelFormatName="Ltf" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>U+045</speakerLabel>
      <position coordinate="azimuth">45</position><position coordinate="elevation">30</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_0001100a" audioChannelFormatName="Rtf" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>U-045</speakerLabel>
      <position coordinate="azimuth">-45</position><position coordinate="elevation">30</position></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";

std::string TempPath(const char* name) {
  const char* dir = std::getenv("TEST_TMPDIR");
  return std::string(dir ? dir : "/tmp") + "/" + name;
}

std::string WriteFixture(const char* name) {
  const int kFrames = 64;
  std::vector<std::vector<float>> tracks;
  for (int i = 1; i <= 10; ++i) tracks.emplace_back(kFrames, 0.1f * i);
  auto chna = adm2iamf::test::MakeChna({
      {1, "ATU_00000001", "AT_00011001_01", "AP_00011001"},
      {2, "ATU_00000002", "AT_00011002_01", "AP_00011001"},
      {3, "ATU_00000003", "AT_00011003_01", "AP_00011001"},
      {4, "ATU_00000004", "AT_00011004_01", "AP_00011001"},
      {5, "ATU_00000005", "AT_00011005_01", "AP_00011001"},
      {6, "ATU_00000006", "AT_00011006_01", "AP_00011001"},
      {7, "ATU_00000007", "AT_00011007_01", "AP_00011001"},
      {8, "ATU_00000008", "AT_00011008_01", "AP_00011001"},
      {9, "ATU_00000009", "AT_00011009_01", "AP_00011001"},
      {10, "ATU_0000000a", "AT_0001100a_01", "AP_00011001"},
  });
  const std::string path = TempPath(name);
  EXPECT_TRUE(
      adm2iamf::test::WriteAdmBwf(path, tracks, 48000, kAxml712, chna).ok());
  return path;
}

// Polls a job to a terminal state (or fails after a generous timeout).
int AwaitTerminal(int job) {
  for (int i = 0; i < 2000; ++i) {  // up to ~20 s
    const int st = adm2iamf_render_state(job);
    if (st != kAdm2iamfRenderRunning) return st;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return adm2iamf_render_state(job);
}

// The render's image shape at `p`, from the meter the probe uses. Shared
// across the expectations below so each one asserts the probe emits this
// meter's figures rather than numbers copied into the test.
adm2iamf::ImageSpread SpreadAt(const adm2iamf::Polar& p) {
  static adm2iamf::ImageSpreadMeter* meter =
      adm2iamf::ImageSpreadMeter::Create(adm2iamf::ImportLayout()).release();
  return meter == nullptr ? adm2iamf::ImageSpread{} : meter->Measure(p);
}

// The four fields the probe writes for one measured position, in the same
// absl float formatting it uses so substrings match exactly.
std::string SpreadJson(const adm2iamf::Polar& p) {
  const adm2iamf::ImageSpread s = SpreadAt(p);
  return absl::StrCat("\"spread\":", s.rms_deg, ",\"spread_ratio\":", s.ratio,
                      ",\"spread_tilt\":", s.tilt_deg,
                      ",\"spread_focus\":", s.focus);
}

bool FileExists(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  return f.good();
}

// Drains the job table after every test so no finished-but-unjoined
// worker handle survives to process exit (TSan reports that as a thread
// leak). This mirrors the library contract: the host calls
// adm2iamf_shutdown() before unloading. Shutdown on an empty table is a
// no-op, so tests that never start a job (or already shut down) are
// unaffected.
class Ffi : public ::testing::Test {
 protected:
  void TearDown() override { adm2iamf_shutdown(); }
};

TEST_F(Ffi, ProbeReportsFormatAndScene) {
  const std::string path = WriteFixture("ffi_probe.wav");
  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  EXPECT_NE(s.find("\"ok\":true"), std::string::npos) << s;
  EXPECT_NE(s.find("\"sample_rate\":48000"), std::string::npos) << s;
  EXPECT_NE(s.find("\"channels\":10"), std::string::npos) << s;
  EXPECT_NE(s.find("\"objects\":[]"), std::string::npos) << s;  // bed only
  EXPECT_NE(s.find("\"unresolved\":[]"), std::string::npos) << s;
  // Ten bed sources -> ten track entries.
  size_t tracks = 0, pos = 0;
  while ((pos = s.find("\"track\":", pos)) != std::string::npos) {
    ++tracks;
    pos += 1;
  }
  EXPECT_EQ(tracks, 10u) << s;
}

// How wide the render images each position it reports (ES-640): a figure per
// bed source, per object and per trajectory vertex, straight off
// ImageSpreadMeter. The 7.1.2 fixture is a bed of speaker-angle channels, so
// every one of them images as a point; the LFE routes rather than pans and
// carries no figure at all.
TEST_F(Ffi, ProbeReportsHowWideTheRenderImagesEachPosition) {
  const std::string path = WriteFixture("ffi_probe_spread.wav");
  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  size_t spreads = 0, pos = 0;
  while ((pos = s.find("\"spread\":", pos)) != std::string::npos) {
    ++spreads;
    pos += 1;
  }
  EXPECT_EQ(spreads, 9u) << s;  // 10 bed channels, one of them the LFE.
  EXPECT_NE(s.find("\"lfe\":true,\"azimuth\":0,\"elevation\":0,\"distance\":1,"
                   "\"gain\":1"),
            std::string::npos)
      << s;
  // U+045 sits on a 7.1.4 speaker, so the render puts it there alone.
  const adm2iamf::Polar top = {45.0f, 30.0f, 1.0f};
  EXPECT_LT(SpreadAt(top).rms_deg, 0.05f);
  EXPECT_NE(s.find(absl::StrCat("\"elevation\":30,\"distance\":1,\"gain\":1,"
                                "\"track\":9,",
                                SpreadJson(top))),
            std::string::npos)
      << s;
}

TEST_F(Ffi, ProbeReportsResolutionsAuditAndWarnings) {
  const std::string path = WriteFixture("ffi_probe_warn.wav");
  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  // Clean spec fixture: per-source resolution records present (polar for
  // speakers, lfe_label for the LFE), audit clean, no warnings.
  EXPECT_NE(s.find("\"resolution\":{\"method\":\"polar\""), std::string::npos)
      << s;
  EXPECT_NE(s.find("\"method\":\"lfe_label\""), std::string::npos) << s;
  EXPECT_NE(s.find("\"unresolved_channels\":[]"), std::string::npos) << s;
  EXPECT_NE(s.find("\"audit\":{"), std::string::npos) << s;
  EXPECT_NE(s.find("\"warnings\":[]"), std::string::npos) << s;
}

// A vendor-shaped bed (unrecognized labels + cube positions): the probe
// surfaces per-channel fallbacks as warnings.
constexpr char kAxmlVendor[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_1001" audioObjectName="Bed">
    <audioPackFormatIDRef>AP_1</audioPackFormatIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_1" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_00011001</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_00011002</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011001" audioChannelFormatName="TheL" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_L</speakerLabel><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">1</position><position coordinate="Z">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011002" audioChannelFormatName="TheR" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>RC_R</speakerLabel><cartesian>1</cartesian>
      <position coordinate="X">1</position><position coordinate="Y">1</position><position coordinate="Z">0</position></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";

TEST_F(Ffi, ProbeSurfacesFallbackWarnings) {
  const int kFrames = 16;
  std::vector<std::vector<float>> tracks(2, std::vector<float>(kFrames, 0.1f));
  auto chna = adm2iamf::test::MakeChna({
      {1, "ATU_00000001", "AT_00011001_01", "AP_1"},
      {2, "ATU_00000002", "AT_00011002_01", "AP_1"},
  });
  const std::string path = TempPath("ffi_probe_vendor.wav");
  ASSERT_TRUE(
      adm2iamf::test::WriteAdmBwf(path, tracks, 48000, kAxmlVendor, chna).ok());

  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  EXPECT_NE(s.find("\"method\":\"cube_slot\""), std::string::npos) << s;
  // A fallback that resolved is a notice, not a warning (ES-553).
  EXPECT_NE(s.find("\"severity\":\"info\",\"code\":\"channel_fallback\""),
            std::string::npos)
      << s;
  EXPECT_NE(s.find("RC_L"), std::string::npos) << s;
  // The non-spec labels also roll up as an audit finding class.
  EXPECT_NE(s.find("\"severity\":\"info\",\"code\":\"audit_invalid\""),
            std::string::npos)
      << s;
}

// A 2-ch bed plus two Objects: "mover" ramps 30° -> -30° over 0.5 s (two
// blocks, the second with a duration so the renderer interpolates), and
// "parked" is a single static block.
constexpr char kAxmlBedPlusObjects[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1"><audioContentIDRef>ACO_1</audioContentIDRef></audioProgramme>
  <audioContent audioContentID="ACO_1">
    <audioObjectIDRef>AO_BED</audioObjectIDRef>
    <audioObjectIDRef>AO_MOVER</audioObjectIDRef>
    <audioObjectIDRef>AO_PARKED</audioObjectIDRef></audioContent>
  <audioObject audioObjectID="AO_BED">
    <audioPackFormatIDRef>AP_BED</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000001</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000002</audioTrackUIDRef></audioObject>
  <audioObject audioObjectID="AO_MOVER" audioObjectName="mover">
    <audioPackFormatIDRef>AP_MOVER</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000003</audioTrackUIDRef></audioObject>
  <audioObject audioObjectID="AO_PARKED" audioObjectName="parked">
    <audioPackFormatIDRef>AP_PARKED</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000004</audioTrackUIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_BED" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_R</audioChannelFormatIDRef></audioPackFormat>
  <audioPackFormat audioPackFormatID="AP_MOVER" typeDefinition="Objects">
    <audioChannelFormatIDRef>AC_MOVER</audioChannelFormatIDRef></audioPackFormat>
  <audioPackFormat audioPackFormatID="AP_PARKED" typeDefinition="Objects">
    <audioChannelFormatIDRef>AC_PARKED</audioChannelFormatIDRef></audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+030</speakerLabel>
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_R" audioChannelFormatName="R" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-030</speakerLabel>
      <position coordinate="azimuth">-30</position><position coordinate="elevation">0</position></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_MOVER" audioChannelFormatName="mover" typeDefinition="Objects">
    <audioBlockFormat rtime="00:00:00.00000" duration="00:00:00.50000">
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:00.50000" duration="00:00:00.50000">
      <position coordinate="azimuth">-30</position><position coordinate="elevation">0</position></audioBlockFormat>
  </audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_PARKED" audioChannelFormatName="parked" typeDefinition="Objects">
    <audioBlockFormat rtime="00:00:00.00000">
      <position coordinate="azimuth">0</position><position coordinate="elevation">45</position></audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>)";

// One probe trajectory vertex, `[az,el,dist,t,spread,ratio,tilt,focus]`, in
// the same absl float formatting the probe uses so substrings match exactly.
std::string Vertex(const adm2iamf::Polar& p, double t) {
  const adm2iamf::ImageSpread sp = SpreadAt(p);
  return absl::StrCat("[", p.azimuth, ",", p.elevation, ",", p.distance, ",", t,
                      ",", sp.rms_deg, ",", sp.ratio, ",", sp.tilt_deg, ",",
                      sp.focus, "]");
}

// "HH:MM:SS.sssss" for a whole number of hundredths of a second (under a
// minute), the rtime/duration format the ADM fixtures below are written in.
std::string AdmTime(int hundredths) {
  const int sec = hundredths / 100;
  std::string frac = std::to_string((hundredths % 100) * 1000);
  frac.insert(0, 5 - frac.size(), '0');
  return absl::StrCat("00:00:", sec < 10 ? "0" : "", sec, ".", frac);
}

// `count` back-to-back 0.01 s object blocks whose azimuth alternates between
// -60 and +60. Every block boundary is a corner of the path and every ramp is
// 0.01 s long, so a sampler on any grid coarser than that cuts chords through
// the turns instead of drawing them.
std::string ZigZagBlocks(int count) {
  std::string s;
  for (int i = 0; i < count; ++i) {
    absl::StrAppend(&s, "<audioBlockFormat rtime=\"", AdmTime(i),
                    "\" duration=\"", AdmTime(1),
                    "\"><position coordinate=\"azimuth\">",
                    i % 2 == 0 ? "-60" : "60",
                    "</position><position coordinate=\"elevation\">0"
                    "</position></audioBlockFormat>");
  }
  return s;
}

// Number of `[az,el,dist,t,spread,...]` points inside the first "trajectory"
// at or after `from`, or 0 if none. Requires the key to open directly onto a
// point
// (`[[`) so an empty or malformed array cannot latch onto a later `]]`.
size_t CountTrajectoryPoints(const std::string& s, size_t from = 0) {
  const size_t key = s.find("\"trajectory\":[", from);
  if (key == std::string::npos) return 0;
  const size_t open = key + std::strlen("\"trajectory\":[");
  if (open >= s.size() || s[open] != '[') return 0;
  const size_t close = s.find("]]", open);
  if (close == std::string::npos) return 0;
  size_t points = 1, pos = open;
  while ((pos = s.find("],[", pos)) != std::string::npos && pos < close) {
    ++points;
    pos += 1;
  }
  return points;
}

TEST_F(Ffi, ProbeEmitsInterpolatedObjectTrajectory) {
  const int kFrames = 48000;  // 1 s, so both object blocks fit.
  std::vector<std::vector<float>> tracks(4, std::vector<float>(kFrames, 0.1f));
  auto chna = adm2iamf::test::MakeChna({
      {1, "ATU_00000001", "AT_L_01", "AP_BED"},
      {2, "ATU_00000002", "AT_R_01", "AP_BED"},
      {3, "ATU_00000003", "AT_MOVER_01", "AP_MOVER"},
      {4, "ATU_00000004", "AT_PARKED_01", "AP_PARKED"},
  });
  const std::string path = TempPath("ffi_probe_traj.wav");
  ASSERT_TRUE(adm2iamf::test::WriteAdmBwf(path, tracks, 48000,
                                          kAxmlBedPlusObjects, chna)
                  .ok());

  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  // Only the mover gets a trajectory; the single-block object stays a plain
  // marker (its `blocks:1` is the "static" signal).
  size_t keys = 0, pos = 0;
  while ((pos = s.find("\"trajectory\":[", pos)) != std::string::npos) {
    ++keys;
    pos += 1;
  }
  EXPECT_EQ(keys, 1u) << s;
  // The corners of the path and nothing else: the object holds at 30 degrees
  // through the first block, then ramps to -30 over the second. The ramp is
  // linear, so its two ends describe it exactly and the decimation keeps no
  // vertex inside it. Each vertex carries its own time, and the span precedes
  // the array; the whole array is pinned, so an implementation that snapped
  // instead of ramping, or that placed a vertex off a corner, fails here.
  const adm2iamf::Polar hold{30.0f, 0.0f, 1.0f};
  EXPECT_EQ(CountTrajectoryPoints(s), 3u) << s;
  EXPECT_NE(s.find(absl::StrCat("\"start_s\":0,\"end_s\":1,\"trajectory\":[",
                                Vertex(hold, 0), ",", Vertex(hold, 0.5), ",",
                                Vertex({-30.0f, 0.0f, 1.0f}, 1), "]")),
            std::string::npos)
      << s;
  // The parked object has no path, so it carries no span either: one pair
  // of span fields in the whole probe.
  size_t spans = 0;
  pos = 0;
  while ((pos = s.find("\"start_s\":", pos)) != std::string::npos) {
    ++spans;
    pos += 1;
  }
  EXPECT_EQ(spans, 1u) << s;
  spans = 0;
  pos = 0;
  while ((pos = s.find("\"end_s\":", pos)) != std::string::npos) {
    ++spans;
    pos += 1;
  }
  EXPECT_EQ(spans, 1u) << s;
  // Polar-authored objects report the flag and carry no cube: emitting zeros
  // would assert a room position they never had (ES-635).
  EXPECT_NE(s.find("\"cartesian\":false"), std::string::npos) << s;
  EXPECT_EQ(s.find("\"x\":"), std::string::npos) << s;
  // Nothing was starved, so the truncation marker must be absent.
  EXPECT_EQ(s.find("\"trajectory_objects_dropped\""), std::string::npos) << s;
}

// Two polar Objects with multi-block timelines. "held" sits at 30° for three
// 0.5 s blocks, then ramps to -30° over a 0.75 s block; "still" is the same
// three blocks with no ramp after them (a multi-block object that never
// moves).
constexpr char kAxmlHeldObjects[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1"><audioContentIDRef>ACO_1</audioContentIDRef></audioProgramme>
  <audioContent audioContentID="ACO_1">
    <audioObjectIDRef>AO_HELD</audioObjectIDRef>
    <audioObjectIDRef>AO_STILL</audioObjectIDRef></audioContent>
  <audioObject audioObjectID="AO_HELD" audioObjectName="held">
    <audioPackFormatIDRef>AP_HELD</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000001</audioTrackUIDRef></audioObject>
  <audioObject audioObjectID="AO_STILL" audioObjectName="still">
    <audioPackFormatIDRef>AP_STILL</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000002</audioTrackUIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_HELD" typeDefinition="Objects">
    <audioChannelFormatIDRef>AC_HELD</audioChannelFormatIDRef></audioPackFormat>
  <audioPackFormat audioPackFormatID="AP_STILL" typeDefinition="Objects">
    <audioChannelFormatIDRef>AC_STILL</audioChannelFormatIDRef></audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_HELD" audioChannelFormatName="held" typeDefinition="Objects">
    <audioBlockFormat rtime="00:00:00.00000" duration="00:00:00.50000">
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:00.50000" duration="00:00:00.50000">
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:01.00000" duration="00:00:00.50000">
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:01.50000" duration="00:00:00.75000">
      <position coordinate="azimuth">-30</position><position coordinate="elevation">0</position></audioBlockFormat>
  </audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_STILL" audioChannelFormatName="still" typeDefinition="Objects">
    <audioBlockFormat rtime="00:00:00.00000" duration="00:00:00.50000">
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:00.50000" duration="00:00:00.50000">
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:01.00000" duration="00:00:00.50000">
      <position coordinate="azimuth">30</position><position coordinate="elevation">0</position></audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>)";

std::string WriteHeldObjectsFixture(const char* name) {
  const int kFrames = 108000;  // 2.25 s, the end of the ramp.
  std::vector<std::vector<float>> tracks(2, std::vector<float>(kFrames, 0.1f));
  auto chna = adm2iamf::test::MakeChna({
      {1, "ATU_00000001", "AT_HELD_01", "AP_HELD"},
      {2, "ATU_00000002", "AT_STILL_01", "AP_STILL"},
  });
  const std::string path = TempPath(name);
  EXPECT_TRUE(
      adm2iamf::test::WriteAdmBwf(path, tracks, 48000, kAxmlHeldObjects, chna)
          .ok());
  return path;
}

// A hold keeps both of its ends. The inspector interpolates between
// consecutive vertices by time, so a hold collapsed to one vertex would read
// as motion through it (ES-637). "held" spans 0..2.25 s and sits at 30 degrees
// for its first three blocks; the ramp into -30 starts at 1.5 s, a corner of
// the path, so the hold's closing vertex sits exactly there.
TEST_F(Ffi, ProbeKeepsBothEndsOfAHold) {
  const std::string path = WriteHeldObjectsFixture("ffi_probe_hold.wav");
  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  const adm2iamf::Polar hold{30.0f, 0.0f, 1.0f};
  const size_t traj = s.find("\"start_s\":0,\"end_s\":2.25,\"trajectory\":[");
  ASSERT_NE(traj, std::string::npos) << s;
  // Exactly two vertices at the held position: the first sample and the
  // ramp start, 1.5 s apart.
  EXPECT_NE(s.find(absl::StrCat("\"trajectory\":[", Vertex(hold, 0), ",",
                                Vertex(hold, 1.5), ",[")),
            std::string::npos)
      << s;
  size_t held = 0, pos = 0;
  while ((pos = s.find("[30,0,1,", pos)) != std::string::npos) {
    ++held;
    pos += 1;
  }
  EXPECT_EQ(held, 2u) << s;
  // The two hold vertices and the end of the ramp: the ramp is linear, so no
  // vertex inside it survives the decimation.
  EXPECT_EQ(CountTrajectoryPoints(s, traj), 3u) << s;
  EXPECT_NE(s.find(absl::StrCat(Vertex({-30.0f, 0.0f, 1.0f}, 2.25), "]")),
            std::string::npos)
      << s;
}

// A multi-block object whose blocks all sit at one position has no path:
// no trajectory and no span, so the inspector does not draw it as moving.
// Pins that the hold's closing vertex is only appended once a distinct
// sample has been seen.
TEST_F(Ffi, ProbeEmitsNoTrajectoryForStationaryMultiBlockObject) {
  const std::string path = WriteHeldObjectsFixture("ffi_probe_still.wav");
  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  const size_t still = s.find("\"label\":\"still\"");
  ASSERT_NE(still, std::string::npos) << s;
  const size_t close = s.find('}', still);
  ASSERT_NE(close, std::string::npos) << s;
  const std::string record = s.substr(still, close - still + 1);
  EXPECT_NE(record.find("\"blocks\":3"), std::string::npos) << record;
  EXPECT_EQ(record.find("\"trajectory\""), std::string::npos) << record;
  EXPECT_EQ(record.find("\"start_s\""), std::string::npos) << record;
  EXPECT_EQ(record.find("\"end_s\""), std::string::npos) << record;
  // "held" is the only path in the probe, and nothing was starved.
  size_t keys = 0, pos = 0;
  while ((pos = s.find("\"trajectory\":[", pos)) != std::string::npos) {
    ++keys;
    pos += 1;
  }
  EXPECT_EQ(keys, 1u) << s;
  EXPECT_EQ(s.find("\"trajectory_objects_dropped\""), std::string::npos) << s;
}

// Two cartesian Objects: "corner" parked at the top-rear-left cube corner
// (-1, -1, 1) and "wall" sliding down the right wall from the front corner
// (1, 1, 0) to the rear corner (1, -1, 0) over the second half of a 1 s span.
constexpr char kAxmlCartesianObjects[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1"><audioContentIDRef>ACO_1</audioContentIDRef></audioProgramme>
  <audioContent audioContentID="ACO_1">
    <audioObjectIDRef>AO_CORNER</audioObjectIDRef>
    <audioObjectIDRef>AO_WALL</audioObjectIDRef></audioContent>
  <audioObject audioObjectID="AO_CORNER" audioObjectName="corner">
    <audioPackFormatIDRef>AP_CORNER</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000001</audioTrackUIDRef></audioObject>
  <audioObject audioObjectID="AO_WALL" audioObjectName="wall">
    <audioPackFormatIDRef>AP_WALL</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000002</audioTrackUIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_CORNER" typeDefinition="Objects">
    <audioChannelFormatIDRef>AC_CORNER</audioChannelFormatIDRef></audioPackFormat>
  <audioPackFormat audioPackFormatID="AP_WALL" typeDefinition="Objects">
    <audioChannelFormatIDRef>AC_WALL</audioChannelFormatIDRef></audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_CORNER" audioChannelFormatName="corner" typeDefinition="Objects">
    <audioBlockFormat rtime="00:00:00.00000"><cartesian>1</cartesian>
      <position coordinate="X">-1</position><position coordinate="Y">-1</position><position coordinate="Z">1</position></audioBlockFormat>
  </audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_WALL" audioChannelFormatName="wall" typeDefinition="Objects">
    <audioBlockFormat rtime="00:00:00.00000" duration="00:00:00.50000"><cartesian>1</cartesian>
      <position coordinate="X">1</position><position coordinate="Y">1</position><position coordinate="Z">0</position></audioBlockFormat>
    <audioBlockFormat rtime="00:00:00.50000" duration="00:00:00.50000"><cartesian>1</cartesian>
      <position coordinate="X">1</position><position coordinate="Y">-1</position><position coordinate="Z">0</position></audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>)";

// The probe converts cartesian positions with the render's anchors, so the
// preview pins cube corners to the real speakers exactly as the bake does
// (ES-607). Expected values come from the render's own conversion (same
// helper, same ImportLayout() anchors), so probe == render by construction;
// one literal pin (the corner on Ltb at +135, where the sector map the probe
// used before said +110) keeps it from being a tautology.
TEST_F(Ffi, ProbeConvertsCartesianObjectsWithTheRenderAnchors) {
  const int kFrames = 48000;
  std::vector<std::vector<float>> tracks(2, std::vector<float>(kFrames, 0.1f));
  auto chna = adm2iamf::test::MakeChna({
      {1, "ATU_00000001", "AT_CORNER_01", "AP_CORNER"},
      {2, "ATU_00000002", "AT_WALL_01", "AP_WALL"},
  });
  const std::string path = TempPath("ffi_probe_cart.wav");
  ASSERT_TRUE(adm2iamf::test::WriteAdmBwf(path, tracks, 48000,
                                          kAxmlCartesianObjects, chna)
                  .ok());

  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  const adm2iamf::AnchorsHandle anchors =
      adm2iamf::MakeAnchors(adm2iamf::ImportLayout());
  ASSERT_NE(anchors, nullptr);
  const auto convert = [&](float x, float y, float z) {
    adm2iamf::ObjectPosition p;
    p.cartesian = true;
    p.cube = {x, y, z};
    return adm2iamf::ConvertObjectPosition(p, anchors.get());
  };
  const adm2iamf::Polar corner = convert(-1, -1, 1);
  const adm2iamf::Polar front = convert(1, 1, 0);
  const adm2iamf::Polar rear = convert(1, -1, 0);
  EXPECT_FLOAT_EQ(corner.azimuth, 135.0f);
  EXPECT_NEAR(corner.elevation, 30.0f, 1e-3f);
  EXPECT_FLOAT_EQ(rear.azimuth, -135.0f);

  EXPECT_NE(s.find("\"label\":\"corner\""), std::string::npos) << s;
  EXPECT_NE(
      s.find(absl::StrCat(
          "\"azimuth\":", corner.azimuth, ",\"elevation\":", corner.elevation,
          ",\"distance\":", corner.distance, ",\"cartesian\":true,",
          SpreadJson(corner), ",\"x\":-1,\"y\":-1,\"z\":1")),
      std::string::npos)
      << s;
  // The wall slide: first point on the front corner (R) at 0 s, last on the
  // rear corner (Rrs) at 1 s.
  EXPECT_NE(s.find(absl::StrCat("\"trajectory\":[", Vertex(front, 0))),
            std::string::npos)
      << s;
  EXPECT_NE(s.find(absl::StrCat(Vertex(rear, 1), "]")), std::string::npos) << s;
  // The static corner must not report the sector map's station.
  EXPECT_EQ(s.find("\"azimuth\":110,"), std::string::npos) << s;
}

// A passage that turns faster than any fixed sampling grid could follow: 400
// blocks of 0.01 s alternating between -60 and +60 degrees over 4 s (ES-608).
// Vertices land on the corners of the interpolated path, never on a grid, so
// each one is a position the object actually held and the chords between them
// are the ramps it actually travelled.
TEST_F(Ffi, ProbePlacesTrajectoryVerticesOnFastPassageCorners) {
  const int kBlocks = 400;
  const std::string axml =
      std::string(
          R"(<?xml version="1.0"?><audioFormatExtended>)"
          R"(<audioObject audioObjectID="AO_1" audioObjectName="zigzag">)"
          R"(<audioPackFormatIDRef>AP_1</audioPackFormatIDRef>)"
          R"(<audioTrackUIDRef>ATU_00000001</audioTrackUIDRef></audioObject>)"
          R"(<audioPackFormat audioPackFormatID="AP_1" )"
          R"(typeDefinition="Objects">)"
          R"(<audioChannelFormatIDRef>AC_1</audioChannelFormatIDRef>)"
          R"(</audioPackFormat>)"
          R"(<audioChannelFormat audioChannelFormatID="AC_1" )"
          R"(audioChannelFormatName="zigzag" typeDefinition="Objects">)") +
      ZigZagBlocks(kBlocks) + "</audioChannelFormat></audioFormatExtended>";

  std::vector<std::vector<float>> tracks(1, std::vector<float>(192000, 0.1f));
  auto chna = adm2iamf::test::MakeChna({
      {1, "ATU_00000001", "AT_1_01", "AP_1"},
  });
  const std::string path = TempPath("ffi_probe_traj_fast.wav");
  ASSERT_TRUE(
      adm2iamf::test::WriteAdmBwf(path, tracks, 48000, axml, chna).ok());

  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  EXPECT_NE(s.find("\"blocks\":400"), std::string::npos) << s;
  EXPECT_NE(s.find("\"start_s\":0,\"end_s\":4,\"trajectory\":["),
            std::string::npos)
      << s;
  // 401 corner instants, all of them kept: the lone mover's share of the
  // budget covers them, so the drawn path is the authored one exactly.
  EXPECT_EQ(CountTrajectoryPoints(s), 401u) << s;
  // Every kept vertex sits on a turn, at -60 or +60. Uniform sampling lands
  // between the turns and reports azimuths the object never held.
  size_t corners = 0, pos = 0;
  while ((pos = s.find("[60,", pos)) != std::string::npos) {
    ++corners;
    pos += 1;
  }
  pos = 0;
  while ((pos = s.find("[-60,", pos)) != std::string::npos) {
    ++corners;
    pos += 1;
  }
  EXPECT_EQ(corners, 401u) << s;
  EXPECT_EQ(s.find("\"trajectory_objects_dropped\""), std::string::npos) << s;
}

// Blocks with no usable rtime all collapse to frame 0 (a degenerate span);
// the fallback emits the raw keyframe positions, still under the per-object
// ceiling — a 1200-block object must not claim 1200 points (let alone the
// whole probe budget).
TEST_F(Ffi, ProbeCapsDegenerateTimelineTrajectory) {
  std::string axml =
      R"(<?xml version="1.0"?><audioFormatExtended>)"
      R"(<audioObject audioObjectID="AO_1" audioObjectName="swarm">)"
      R"(<audioPackFormatIDRef>AP_1</audioPackFormatIDRef>)"
      R"(<audioTrackUIDRef>ATU_00000001</audioTrackUIDRef></audioObject>)"
      R"(<audioPackFormat audioPackFormatID="AP_1" typeDefinition="Objects">)"
      R"(<audioChannelFormatIDRef>AC_1</audioChannelFormatIDRef>)"
      R"(</audioPackFormat>)"
      R"(<audioChannelFormat audioChannelFormatID="AC_1" )"
      R"(audioChannelFormatName="swarm" typeDefinition="Objects">)";
  for (int i = 0; i < 1200; ++i) {  // No rtime; distinct positions.
    axml += "<audioBlockFormat><position coordinate=\"azimuth\">" +
            std::to_string(i % 360) +
            "</position><position coordinate=\"elevation\">0</position>"
            "</audioBlockFormat>";
  }
  axml += "</audioChannelFormat></audioFormatExtended>";

  std::vector<std::vector<float>> tracks(1, std::vector<float>(64, 0.1f));
  auto chna = adm2iamf::test::MakeChna({
      {1, "ATU_00000001", "AT_1_01", "AP_1"},
  });
  const std::string path = TempPath("ffi_probe_traj_degen.wav");
  ASSERT_TRUE(
      adm2iamf::test::WriteAdmBwf(path, tracks, 48000, axml, chna).ok());

  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  EXPECT_NE(s.find("\"blocks\":1200"), std::string::npos) << s;
  EXPECT_EQ(CountTrajectoryPoints(s), 1024u) << s;
}

// The probe-wide budget divides between the movers instead of going
// first-come (ES-608). Each of these 200 movers turns at every one of its 50
// blocks, so every candidate instant is a corner the decimation would keep
// if it could: 51 apiece, 10200 in all, past the 8192-point budget. A
// first-come split would hand the movers at the head of the list everything
// they asked for and starve the tail; an even split gives every mover a
// path.
TEST_F(Ffi, ProbeSharesTrajectoryBudgetBetweenMovers) {
  const int kObjects = 200;
  const int kBlocks = 50;
  std::string axml =
      R"(<?xml version="1.0"?><audioFormatExtended>)"
      R"(<audioProgramme audioProgrammeID="APR_1">)"
      R"(<audioContentIDRef>ACO_1</audioContentIDRef></audioProgramme>)"
      R"(<audioContent audioContentID="ACO_1">)";
  for (int i = 1; i <= kObjects; ++i) {
    axml += "<audioObjectIDRef>AO_" + std::to_string(i) + "</audioObjectIDRef>";
  }
  axml += "</audioContent>";
  std::vector<adm2iamf::test::ChnaRow> rows;
  for (int i = 1; i <= kObjects; ++i) {
    const std::string n = std::to_string(i);
    axml += "<audioObject audioObjectID=\"AO_" + n + "\" audioObjectName=\"o" +
            n + "\"><audioPackFormatIDRef>AP_" + n +
            "</audioPackFormatIDRef><audioTrackUIDRef>ATU_" + n +
            "</audioTrackUIDRef></audioObject>";
    axml += "<audioPackFormat audioPackFormatID=\"AP_" + n +
            "\" typeDefinition=\"Objects\"><audioChannelFormatIDRef>AC_" + n +
            "</audioChannelFormatIDRef></audioPackFormat>";
    axml += "<audioChannelFormat audioChannelFormatID=\"AC_" + n +
            "\" audioChannelFormatName=\"o" + n +
            "\" typeDefinition=\"Objects\">" + ZigZagBlocks(kBlocks) +
            "</audioChannelFormat>";
    rows.push_back(
        {static_cast<uint16_t>(i), "ATU_" + n, "AT_" + n + "_01", "AP_" + n});
  }
  axml += "</audioFormatExtended>";

  const int kFrames = 24000;  // 0.5 s covers all 50 blocks.
  std::vector<std::vector<float>> tracks(kObjects,
                                         std::vector<float>(kFrames, 0.1f));
  const std::string path = TempPath("ffi_probe_traj_share.wav");
  ASSERT_TRUE(adm2iamf::test::WriteAdmBwf(path, tracks, 48000, axml,
                                          adm2iamf::test::MakeChna(rows))
                  .ok());

  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  size_t keys = 0, total = 0, pos = 0, smallest = 8192, largest = 0;
  while ((pos = s.find("\"trajectory\":[", pos)) != std::string::npos) {
    const size_t n = CountTrajectoryPoints(s, pos);
    total += n;
    smallest = std::min(smallest, n);
    largest = std::max(largest, n);
    ++keys;
    pos += 1;
  }
  // Every mover drew, nothing was starved, and the budget held.
  EXPECT_EQ(keys, static_cast<size_t>(kObjects)) << s;
  EXPECT_LE(total, 8192u);
  EXPECT_EQ(s.find("\"trajectory_objects_dropped\""), std::string::npos) << s;
  // The share is even: the last mover in the list gets what the first did,
  // give or take the rounding of an integer division. The old first-come
  // split would have made this range 51 to 0.
  EXPECT_GE(smallest, 35u) << s;
  EXPECT_LE(largest - smallest, 4u) << s;
  // ... and the share is what the budget allows, not the 51 each would take
  // on its own.
  EXPECT_LT(largest, 51u) << s;
}

// More movers than the budget can seat. Each mover is guaranteed two points
// while the budget lasts (two being the shortest useful polyline), so an
// 8192-point budget seats 4096 of these 4200 two-block movers and the rest
// get no trajectory — which the probe must say out loud, as the audit's
// `findings_dropped` does.
TEST_F(Ffi, ProbeDropsTrajectoriesTheBudgetCannotSeat) {
  const int kObjects = 4200;
  std::string axml =
      R"(<?xml version="1.0"?><audioFormatExtended>)"
      R"(<audioProgramme audioProgrammeID="APR_1">)"
      R"(<audioContentIDRef>ACO_1</audioContentIDRef></audioProgramme>)"
      R"(<audioContent audioContentID="ACO_1">)";
  for (int i = 1; i <= kObjects; ++i) {
    axml += "<audioObjectIDRef>AO_" + std::to_string(i) + "</audioObjectIDRef>";
  }
  axml += "</audioContent>";
  std::vector<adm2iamf::test::ChnaRow> rows;
  const std::string blocks = ZigZagBlocks(2);
  for (int i = 1; i <= kObjects; ++i) {
    const std::string n = std::to_string(i);
    axml += "<audioObject audioObjectID=\"AO_" + n + "\" audioObjectName=\"o" +
            n + "\"><audioPackFormatIDRef>AP_" + n +
            "</audioPackFormatIDRef><audioTrackUIDRef>ATU_" + n +
            "</audioTrackUIDRef></audioObject>";
    axml += "<audioPackFormat audioPackFormatID=\"AP_" + n +
            "\" typeDefinition=\"Objects\"><audioChannelFormatIDRef>AC_" + n +
            "</audioChannelFormatIDRef></audioPackFormat>";
    axml += "<audioChannelFormat audioChannelFormatID=\"AC_" + n +
            "\" audioChannelFormatName=\"o" + n +
            "\" typeDefinition=\"Objects\">" + blocks + "</audioChannelFormat>";
    rows.push_back(
        {static_cast<uint16_t>(i), "ATU_" + n, "AT_" + n + "_01", "AP_" + n});
  }
  axml += "</audioFormatExtended>";

  const int kFrames = 1440;  // 0.03 s covers both 0.01 s blocks.
  std::vector<std::vector<float>> tracks(kObjects,
                                         std::vector<float>(kFrames, 0.1f));
  const std::string path = TempPath("ffi_probe_traj_drop.wav");
  ASSERT_TRUE(adm2iamf::test::WriteAdmBwf(path, tracks, 48000, axml,
                                          adm2iamf::test::MakeChna(rows))
                  .ok());

  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  size_t keys = 0, total = 0, pos = 0;
  while ((pos = s.find("\"trajectory\":[", pos)) != std::string::npos) {
    total += CountTrajectoryPoints(s, pos);
    ++keys;
    pos += 1;
  }
  EXPECT_EQ(total, 8192u) << "budget spent exactly, two points per mover";
  EXPECT_EQ(keys, 4096u);
  const std::string marker =
      "\"trajectory_objects_dropped\":" + std::to_string(kObjects - keys);
  EXPECT_NE(s.find(marker), std::string::npos) << s;
}

// A 2-ch bed plus a first-order HOA pack. The bed renders; the HOA channels
// are reported, not dropped in silence (ES-623).
constexpr char kAxmlBedPlusHoa[] = R"(<?xml version="1.0"?>
<audioFormatExtended>
  <audioObject audioObjectID="AO_BED"><audioPackFormatIDRef>AP_BED</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000001</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000002</audioTrackUIDRef></audioObject>
  <audioObject audioObjectID="AO_HOA" audioObjectName="ambience">
    <audioPackFormatIDRef>AP_HOA</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000003</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000004</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000005</audioTrackUIDRef>
    <audioTrackUIDRef>ATU_00000006</audioTrackUIDRef></audioObject>
  <audioPackFormat audioPackFormatID="AP_BED" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_L</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_R</audioChannelFormatIDRef></audioPackFormat>
  <audioPackFormat audioPackFormatID="AP_HOA" typeDefinition="HOA">
    <audioChannelFormatIDRef>AC_W</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_Y</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_Z</audioChannelFormatIDRef>
    <audioChannelFormatIDRef>AC_X</audioChannelFormatIDRef></audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_L" audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M+030</speakerLabel></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_R" audioChannelFormatName="R" typeDefinition="DirectSpeakers">
    <audioBlockFormat><speakerLabel>M-030</speakerLabel></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_W" audioChannelFormatName="W" typeDefinition="HOA">
    <audioBlockFormat><order>0</order><degree>0</degree></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_Y" audioChannelFormatName="Y" typeDefinition="HOA">
    <audioBlockFormat><order>1</order><degree>-1</degree></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_Z" audioChannelFormatName="Z" typeDefinition="HOA">
    <audioBlockFormat><order>1</order><degree>0</degree></audioBlockFormat></audioChannelFormat>
  <audioChannelFormat audioChannelFormatID="AC_X" audioChannelFormatName="X" typeDefinition="HOA">
    <audioBlockFormat><order>1</order><degree>1</degree></audioBlockFormat></audioChannelFormat>
</audioFormatExtended>)";

TEST_F(Ffi, ProbeReportsUnsupportedPackChannels) {
  const int kFrames = 16;
  std::vector<std::vector<float>> tracks(6, std::vector<float>(kFrames, 0.1f));
  auto chna = adm2iamf::test::MakeChna({
      {1, "ATU_00000001", "AT_L_01", "AP_BED"},
      {2, "ATU_00000002", "AT_R_01", "AP_BED"},
      {3, "ATU_00000003", "AT_W_01", "AP_HOA"},
      {4, "ATU_00000004", "AT_Y_01", "AP_HOA"},
      {5, "ATU_00000005", "AT_Z_01", "AP_HOA"},
      {6, "ATU_00000006", "AT_X_01", "AP_HOA"},
  });
  const std::string path = TempPath("ffi_probe_hoa.wav");
  ASSERT_TRUE(
      adm2iamf::test::WriteAdmBwf(path, tracks, 48000, kAxmlBedPlusHoa, chna)
          .ok());

  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);

  EXPECT_NE(s.find("\"ok\":true"), std::string::npos) << s;
  EXPECT_NE(s.find("\"code\":\"pack_type_unsupported\""), std::string::npos)
      << s;
  EXPECT_NE(s.find("Channel W belongs to an HOA pack; this content type is "
                   "not yet supported and will not be rendered."),
            std::string::npos)
      << s;
  // Listed with the other dropped channels, with the same reason text.
  EXPECT_NE(s.find("\"unresolved_channels\":[{\"id\":\"AC_W\""),
            std::string::npos)
      << s;
  // The bed is untouched: both channels resolved on their own tracks.
  EXPECT_NE(s.find("\"label\":\"L\",\"lfe\":false,\"azimuth\":30"),
            std::string::npos)
      << s;
  EXPECT_NE(s.find("\"label\":\"R\",\"lfe\":false,\"azimuth\":-30"),
            std::string::npos)
      << s;
}

// A malformed chna chunk (shorter than its 4-byte header) fails the probe
// with the same message the import reports, instead of previewing a
// sequentially numbered scene the render then rejects (ES-626).
TEST_F(Ffi, ProbeRejectsMalformedChnaLikeTheImport) {
  const int kFrames = 16;
  std::vector<std::vector<float>> tracks(2, std::vector<float>(kFrames, 0.1f));
  const std::vector<uint8_t> bad_chna = {0x02, 0x00};  // numTracks only.
  const std::string path = TempPath("ffi_probe_bad_chna.wav");
  ASSERT_TRUE(adm2iamf::test::WriteAdmBwf(path, tracks, 48000,
                                          kAxmlBedPlusObjects, bad_chna)
                  .ok());

  char* json = adm2iamf_probe_json(path.c_str());
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);
  EXPECT_NE(s.find("\"ok\":false"), std::string::npos) << s;
  EXPECT_NE(s.find("chna chunk too small"), std::string::npos) << s;

  auto r = adm2iamf::ConvertAdmFileToChannelBed(path);
  ASSERT_FALSE(r.ok());
  EXPECT_NE(r.status().message().find("chna chunk too small"),
            std::string::npos)
      << r.status();
}

TEST_F(Ffi, ProbeBadPathReturnsError) {
  char* json = adm2iamf_probe_json("/no/such/file.wav");
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);
  EXPECT_NE(s.find("\"ok\":false"), std::string::npos) << s;
}

TEST_F(Ffi, RenderChannelBedToWavThroughJobTable) {
  const std::string in = WriteFixture("ffi_render_in.wav");
  const std::string out = TempPath("ffi_render_out.wav");

  Adm2iamfRenderConfig cfg;
  std::memset(&cfg, 0, sizeof(cfg));
  cfg.in_path = in.c_str();
  cfg.out_path = out.c_str();

  const int job = adm2iamf_render_start(&cfg);
  ASSERT_GT(job, 0);
  const int st = AwaitTerminal(job);
  EXPECT_EQ(st, kAdm2iamfRenderDone);
  EXPECT_FLOAT_EQ(adm2iamf_render_progress(job), 1.0f);

  char* json = adm2iamf_render_result_json(job);
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);
  EXPECT_NE(s.find("\"ok\":true"), std::string::npos) << s;
  EXPECT_NE(s.find("\"channels\":12"), std::string::npos) << s;  // 7.1.4
  EXPECT_NE(s.find("\"passthrough\":9"), std::string::npos) << s;
  EXPECT_TRUE(FileExists(out));
}

TEST_F(Ffi, RenderBadInputReportsError) {
  const std::string out = TempPath("ffi_err_out.wav");
  Adm2iamfRenderConfig cfg;
  std::memset(&cfg, 0, sizeof(cfg));
  const std::string bad = "/no/such/input.wav";
  cfg.in_path = bad.c_str();
  cfg.out_path = out.c_str();

  const int job = adm2iamf_render_start(&cfg);
  ASSERT_GT(job, 0);
  EXPECT_EQ(AwaitTerminal(job), kAdm2iamfRenderError);
  char* json = adm2iamf_render_result_json(job);
  ASSERT_NE(json, nullptr);
  const std::string s(json);
  adm2iamf_string_free(json);
  EXPECT_NE(s.find("\"ok\":false"), std::string::npos) << s;
}

TEST_F(Ffi, NullConfigRejected) {
  EXPECT_LT(adm2iamf_render_start(nullptr), 0);
}

TEST_F(Ffi, UnknownJobQueries) {
  EXPECT_EQ(adm2iamf_render_state(999999), kAdm2iamfRenderUnknownJob);
  EXPECT_FLOAT_EQ(adm2iamf_render_progress(999999), -1.0f);
  EXPECT_EQ(adm2iamf_render_result_json(999999), nullptr);
  adm2iamf_render_cancel(999999);  // no-op, must not crash
}

TEST_F(Ffi, ShutdownWithNoJobsIsNoOp) {
  adm2iamf_shutdown();  // Must return promptly and not crash.
  SUCCEED();
}

TEST_F(Ffi, ShutdownDrainsAndClearsJobs) {
  const std::string in = WriteFixture("ffi_shutdown_in.wav");
  const std::string out = TempPath("ffi_shutdown_out.wav");
  Adm2iamfRenderConfig cfg;
  std::memset(&cfg, 0, sizeof(cfg));
  cfg.in_path = in.c_str();
  cfg.out_path = out.c_str();

  const int job = adm2iamf_render_start(&cfg);
  ASSERT_GT(job, 0);
  adm2iamf_shutdown();  // Cancels + joins the worker, then clears the table.
  // The table is drained, so the job id is no longer known.
  EXPECT_EQ(adm2iamf_render_state(job), kAdm2iamfRenderUnknownJob);
}

TEST_F(Ffi, StartAfterTerminalReapsPriorJob) {
  const std::string in = WriteFixture("ffi_reap_in.wav");
  const std::string out = TempPath("ffi_reap_out.wav");
  Adm2iamfRenderConfig cfg;
  std::memset(&cfg, 0, sizeof(cfg));
  cfg.in_path = in.c_str();
  cfg.out_path = out.c_str();

  const int first = adm2iamf_render_start(&cfg);
  ASSERT_GT(first, 0);
  ASSERT_EQ(AwaitTerminal(first), kAdm2iamfRenderDone);

  const int second = adm2iamf_render_start(&cfg);  // Reaps (joins) `first`.
  ASSERT_GT(second, 0);
  EXPECT_NE(second, first);
  EXPECT_EQ(adm2iamf_render_state(first), kAdm2iamfRenderUnknownJob);
  EXPECT_EQ(AwaitTerminal(second), kAdm2iamfRenderDone);
}

}  // namespace
