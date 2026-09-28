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

#include "adm_import/adm/adm_audit.h"

#include <string>

#include "adm_import/adm/xml.h"
#include "gtest/gtest.h"

namespace adm2iamf {
namespace adm {
namespace {

AuditReport Audit(const std::string& xml) {
  auto root = ParseXml(xml);
  EXPECT_TRUE(root.ok()) << root.status().message();
  return AuditAxml(*root);
}

const AuditFinding* FindBySubject(const AuditReport& r,
                                  const std::string& subject) {
  for (const auto& f : r.findings) {
    if (f.subject == subject) return &f;
  }
  return nullptr;
}

constexpr char kCleanEbu[] = R"(
<audioFormatExtended>
  <audioProgramme audioProgrammeID="APR_1001" audioProgrammeName="Main">
    <audioContentIDRef>ACO_1001</audioContentIDRef>
    <loudnessMetadata>
      <integratedLoudness>-23.0</integratedLoudness>
      <maxTruePeak>-2.3</maxTruePeak>
    </loudnessMetadata>
  </audioProgramme>
  <audioContent audioContentID="ACO_1001" audioContentName="Bed">
    <audioObjectIDRef>AO_1001</audioObjectIDRef>
  </audioContent>
  <audioObject audioObjectID="AO_1001" audioObjectName="Bed"
               importance="10">
    <audioPackFormatIDRef>AP_00011001</audioPackFormatIDRef>
    <audioTrackUIDRef>ATU_00000001</audioTrackUIDRef>
    <gain gainUnit="dB">-3.0</gain>
  </audioObject>
  <audioPackFormat audioPackFormatID="AP_00011001"
                   audioPackFormatName="bed" typeDefinition="DirectSpeakers">
    <audioChannelFormatIDRef>AC_00011001</audioChannelFormatIDRef>
  </audioPackFormat>
  <audioChannelFormat audioChannelFormatID="AC_00011001"
                      audioChannelFormatName="L"
                      typeDefinition="DirectSpeakers">
    <audioBlockFormat audioBlockFormatID="AB_00011001_00000001">
      <speakerLabel>M+030</speakerLabel>
      <position coordinate="azimuth">30.0</position>
      <position coordinate="elevation">0.0</position>
    </audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>
)";

TEST(AdmAuditTest, CleanEbuFileHasNoFindings) {
  const AuditReport r = Audit(kCleanEbu);
  EXPECT_EQ(r.counts.unknown, 0) << r.ToJson();
  EXPECT_EQ(r.counts.invalid_value, 0) << r.ToJson();
  EXPECT_EQ(r.counts.lenient_value, 0) << r.ToJson();
  EXPECT_EQ(r.counts.spec_ignored, 0) << r.ToJson();
  EXPECT_TRUE(r.findings.empty()) << r.ToJson();
  EXPECT_GT(r.counts.elements, 10);
  EXPECT_GT(r.counts.ok, 0);
  EXPECT_EQ(r.wrapper_path, "");
}

TEST(AdmAuditTest, WrapperChainIsRecordedNotAudited) {
  const AuditReport r = Audit(R"(
<ebuCoreMain xmlns="urn:ebu:metadata-schema:ebuCore_2014">
  <coreMetadata><format>
    <audioFormatExtended>
      <audioContent audioContentID="ACO_1001" audioContentName="x">
        <audioObjectIDRef>AO_1001</audioObjectIDRef>
      </audioContent>
    </audioFormatExtended>
  </format></coreMetadata>
</ebuCoreMain>
)");
  EXPECT_EQ(r.wrapper_path, "ebuCoreMain/coreMetadata/format");
  EXPECT_EQ(r.counts.unknown, 0) << r.ToJson();
}

TEST(AdmAuditTest, XmlnsAndXsiAttributesAreSkipped) {
  const AuditReport r = Audit(R"(
<audioFormatExtended xmlns:adm="urn:x" xmlns="urn:y"
    xsi:schemaLocation="urn:z file.xsd">
  <audioContent audioContentID="ACO_1001" audioContentName="x">
    <audioObjectIDRef>AO_1001</audioObjectIDRef>
  </audioContent>
</audioFormatExtended>
)");
  EXPECT_TRUE(r.findings.empty()) << r.ToJson();
}

TEST(AdmAuditTest, NonSpecElementIsUnknownAndSubtreeSkipped) {
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioObject audioObjectID="AO_1001" audioObjectName="x">
    <dolbyProprietary><inner attr="1">v</inner></dolbyProprietary>
  </audioObject>
</audioFormatExtended>
)");
  ASSERT_EQ(r.counts.unknown, 1) << r.ToJson();
  const AuditFinding* f = FindBySubject(r, "dolbyProprietary");
  ASSERT_NE(f, nullptr);
  EXPECT_EQ(f->cls, AuditClass::kUnknown);
  EXPECT_NE(f->note.find("not defined by BS.2076-3"), std::string::npos);
  // The subtree is not walked: <inner> produces no separate finding.
  EXPECT_EQ(FindBySubject(r, "inner"), nullptr);
}

TEST(AdmAuditTest, MisplacedAdmElementIsCalledOut) {
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioObject audioObjectID="AO_1001" audioObjectName="x">
    <speakerLabel>M+030</speakerLabel>
  </audioObject>
</audioFormatExtended>
)");
  const AuditFinding* f = FindBySubject(r, "speakerLabel");
  ASSERT_NE(f, nullptr) << r.ToJson();
  EXPECT_EQ(f->cls, AuditClass::kUnknown);
  EXPECT_NE(f->note.find("not allowed in this context"), std::string::npos);
}

TEST(AdmAuditTest, UnknownAttributeIsFlagged) {
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioObject audioObjectID="AO_1001" audioObjectName="x"
               dolbyFlag="7"/>
</audioFormatExtended>
)");
  const AuditFinding* f = FindBySubject(r, "audioObject@dolbyFlag");
  ASSERT_NE(f, nullptr) << r.ToJson();
  EXPECT_EQ(f->cls, AuditClass::kUnknown);
  EXPECT_TRUE(f->is_attribute);
}

TEST(AdmAuditTest, ProprietarySpeakerLabelIsInvalidValue) {
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioChannelFormat audioChannelFormatID="AC_00011001"
                      audioChannelFormatName="L" typeDefinition="DirectSpeakers">
    <audioBlockFormat audioBlockFormatID="AB_00011001_00000001">
      <speakerLabel>RC_L</speakerLabel>
      <position coordinate="X">-1.0</position>
    </audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>
)");
  const AuditFinding* f = FindBySubject(r, "speakerLabel");
  ASSERT_NE(f, nullptr) << r.ToJson();
  EXPECT_EQ(f->cls, AuditClass::kInvalidValue);
  EXPECT_EQ(f->value, "RC_L");
}

TEST(AdmAuditTest, ConsumedFrequencyAuditsClean) {
  // <frequency> is parsed (the LFE marker) — no finding.
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioChannelFormat audioChannelFormatID="AC_00011001"
                      audioChannelFormatName="LFE"
                      typeDefinition="DirectSpeakers">
    <frequency typeDefinition="lowPass">120</frequency>
    <audioBlockFormat audioBlockFormatID="AB_00011001_00000001">
      <speakerLabel>LFE</speakerLabel>
    </audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>
)");
  EXPECT_EQ(FindBySubject(r, "frequency"), nullptr) << r.ToJson();
  EXPECT_EQ(r.counts.unknown, 0) << r.ToJson();
}

TEST(AdmAuditTest, SpecIgnoredElementIsReported) {
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioChannelFormat audioChannelFormatID="AC_00031001"
                      audioChannelFormatName="obj" typeDefinition="Objects">
    <audioBlockFormat audioBlockFormatID="AB_00031001_00000001">
      <position coordinate="azimuth">10.0</position>
      <position coordinate="elevation">0.0</position>
      <diffuse>0.5</diffuse>
    </audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>
)");
  const AuditFinding* f = FindBySubject(r, "diffuse");
  ASSERT_NE(f, nullptr) << r.ToJson();
  EXPECT_EQ(f->cls, AuditClass::kSpecIgnored);
  EXPECT_NE(f->note.find("BS.2076-3 §10.1"), std::string::npos);
  EXPECT_EQ(r.counts.unknown, 0) << r.ToJson();
}

TEST(AdmAuditTest, FractionalSampleTimecodeAuditsClean) {
  // Spec fractional-sample timecodes are fully parsed (ParseTimecode) —
  // they must not surface as findings.
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioChannelFormat audioChannelFormatID="AC_00031001"
                      audioChannelFormatName="obj" typeDefinition="Objects">
    <audioBlockFormat audioBlockFormatID="AB_00031001_00000001"
                      rtime="00:00:00.00000S48000"
                      duration="00:00:01.24000S48000">
      <position coordinate="azimuth">10.0</position>
      <position coordinate="elevation">0.0</position>
    </audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>
)");
  EXPECT_EQ(FindBySubject(r, "audioBlockFormat@rtime"), nullptr) << r.ToJson();
  EXPECT_EQ(FindBySubject(r, "audioBlockFormat@duration"), nullptr)
      << r.ToJson();
}

TEST(AdmAuditTest, LenientTimecodeFlagged) {
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioChannelFormat audioChannelFormatID="AC_00031001"
                      audioChannelFormatName="obj" typeDefinition="Objects">
    <audioBlockFormat audioBlockFormatID="AB_00031001_00000001"
                      rtime="00:05" duration="5">
      <position coordinate="azimuth">10.0</position>
      <position coordinate="elevation">0.0</position>
    </audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>
)");
  EXPECT_EQ(r.counts.lenient_value, 2) << r.ToJson();
}

TEST(AdmAuditTest, PositionRangeDependsOnCoordinate) {
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioChannelFormat audioChannelFormatID="AC_00031001"
                      audioChannelFormatName="obj" typeDefinition="Objects">
    <audioBlockFormat audioBlockFormatID="AB_00031001_00000001">
      <position coordinate="azimuth">200.0</position>
      <position coordinate="elevation">-95.0</position>
      <position coordinate="distance">-0.5</position>
    </audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>
)");
  EXPECT_EQ(r.counts.invalid_value, 3) << r.ToJson();
}

TEST(AdmAuditTest, BlockChildrenNarrowedByTypeDefinition) {
  // speakerLabel is a DirectSpeakers block child; under an Objects block it
  // must be flagged as misplaced.
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioChannelFormat audioChannelFormatID="AC_00031001"
                      audioChannelFormatName="obj" typeLabel="0003">
    <audioBlockFormat audioBlockFormatID="AB_00031001_00000001">
      <speakerLabel>M+030</speakerLabel>
      <position coordinate="azimuth">0.0</position>
      <position coordinate="elevation">0.0</position>
    </audioBlockFormat>
  </audioChannelFormat>
</audioFormatExtended>
)");
  const AuditFinding* f = FindBySubject(r, "speakerLabel");
  ASSERT_NE(f, nullptr) << r.ToJson();
  EXPECT_EQ(f->cls, AuditClass::kUnknown);
  EXPECT_NE(f->note.find("not allowed in this context"), std::string::npos);
}

TEST(AdmAuditTest, RepeatedFindingsAreDeduplicatedWithCounts) {
  const AuditReport r = Audit(R"(
<audioFormatExtended>
  <audioObject audioObjectID="AO_1001" audioObjectName="a">
    <dolbyProprietary/>
  </audioObject>
  <audioObject audioObjectID="AO_1002" audioObjectName="b">
    <dolbyProprietary/>
  </audioObject>
</audioFormatExtended>
)");
  ASSERT_EQ(r.findings.size(), 1u) << r.ToJson();
  EXPECT_EQ(r.findings[0].count, 2);
  EXPECT_EQ(r.counts.unknown, 2);
  // Path keeps the first occurrence.
  EXPECT_NE(r.findings[0].path.find("AO_1001"), std::string::npos);
}

TEST(AdmAuditTest, TreeJsonWithSiblingCap) {
  const std::string xml = R"(
<audioFormatExtended>
  <audioChannelFormat audioChannelFormatID="AC_00031001"
                      audioChannelFormatName="obj" typeDefinition="Objects">
    <audioBlockFormat audioBlockFormatID="AB_00031001_00000001"
                      rtime="00:00:00.00000" duration="00:00:01.00000">
      <position coordinate="azimuth">10.0</position>
      <position coordinate="elevation">0.0</position>
    </audioBlockFormat>
    <audioBlockFormat audioBlockFormatID="AB_00031001_00000002"
                      rtime="00:00:01.00000" duration="00:00:01.00000"/>
    <audioBlockFormat audioBlockFormatID="AB_00031001_00000003"
                      rtime="00:00:02.00000" duration="00:00:01.00000"/>
  </audioChannelFormat>
</audioFormatExtended>
)";
  auto root = ParseXml(xml);
  ASSERT_TRUE(root.ok());
  AuditOptions options;
  options.tree_siblings_cap = 1;
  const AuditReport r = AuditAxml(*root, options);
  // All three blocks are audited even though only one is in the tree.
  EXPECT_EQ(r.counts.elements, 6);
  ASSERT_FALSE(r.tree_json.empty());
  EXPECT_NE(r.tree_json.find("\"n\":\"audioChannelFormat\""),
            std::string::npos);
  EXPECT_NE(r.tree_json.find("\"s\":{\"audioBlockFormat\":2}"),
            std::string::npos)
      << r.tree_json;
  // Attribute entries carry their classification.
  EXPECT_NE(
      r.tree_json.find("{\"k\":\"coordinate\",\"v\":\"azimuth\",\"c\":\"ok\"}"),
      std::string::npos)
      << r.tree_json;
  // ToJson embeds the tree.
  EXPECT_NE(r.ToJson().find("\"tree\":{"), std::string::npos);
  // Without options the tree stays empty.
  EXPECT_TRUE(AuditAxml(*root).tree_json.empty());
}

TEST(AdmAuditTest, SiblingCapAppliesToAnonymousRootContainer) {
  // No audioFormatExtended wrapper and an unknown root: the walker audits
  // the root as an anonymous container. The sibling cap must hold there
  // too, or a wrapper-less file produces an unbounded top-level tree.
  const std::string xml = R"(
<someExport>
  <audioProgramme audioProgrammeID="APR_1001"/>
  <audioProgramme audioProgrammeID="APR_1002"/>
  <audioProgramme audioProgrammeID="APR_1003"/>
</someExport>
)";
  auto root = ParseXml(xml);
  ASSERT_TRUE(root.ok());
  AuditOptions options;
  options.tree_siblings_cap = 1;
  const AuditReport r = AuditAxml(*root, options);
  ASSERT_FALSE(r.tree_json.empty());
  EXPECT_NE(r.tree_json.find("\"c\":\"container\""), std::string::npos);
  EXPECT_NE(r.tree_json.find("\"s\":{\"audioProgramme\":2}"), std::string::npos)
      << r.tree_json;
}

TEST(AdmAuditTest, ToJsonSmoke) {
  const AuditReport r = Audit(kCleanEbu);
  const std::string json = r.ToJson();
  EXPECT_NE(json.find("\"counts\""), std::string::npos);
  EXPECT_NE(json.find("\"unknown\":0"), std::string::npos);
  EXPECT_NE(json.find("\"findings\":[]"), std::string::npos);
}

}  // namespace
}  // namespace adm
}  // namespace adm2iamf
