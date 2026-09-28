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

#include "adm_import/adm/adm_vocabulary.h"

#include "absl/strings/str_cat.h"
#include "gtest/gtest.h"

namespace adm2iamf {
namespace adm {
namespace vocab {
namespace {

constexpr ValueDomain kTime{.kind = ValueDomain::Kind::kTimecode};
constexpr ValueDomain kBool{.kind = ValueDomain::Kind::kBool};
constexpr ValueDomain kGainUnit{.kind = ValueDomain::Kind::kEnum,
                                .enums = "linear|dB"};
constexpr ValueDomain kPackId{.kind = ValueDomain::Kind::kId,
                              .pattern = "AP_hhhhhhhh"};
constexpr ValueDomain kImportance{
    .kind = ValueDomain::Kind::kInt, .min = 0, .max = 10};
constexpr ValueDomain kUnitRange{
    .kind = ValueDomain::Kind::kFloat, .min = 0, .max = 1};

TEST(CheckValueTest, TimecodeSpecForms) {
  EXPECT_EQ(CheckValue(kTime, "00:00:00.00000"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kTime, "01:34:16.25000"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kTime, "00:00:05.000000000"), ValueCheck::kValid);
  // Decimal ss.zzzzz form (>= 5 decimal places) is spec too.
  EXPECT_EQ(CheckValue(kTime, "12.50000"), ValueCheck::kValid);
  // Long-form fractional-sample: digit counts must match.
  EXPECT_EQ(CheckValue(kTime, "01:34:16.12000S48000"), ValueCheck::kValid);
  // Shortform: variable digit counts, numerator may exceed denominator.
  EXPECT_EQ(CheckValue(kTime, "2460S48000"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kTime, "0S48000"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kTime, "500000S48000"), ValueCheck::kValid);
}

TEST(CheckValueTest, TimecodeLenientForms) {
  EXPECT_EQ(CheckValue(kTime, "5"), ValueCheck::kLenient);
  EXPECT_EQ(CheckValue(kTime, "5.2"), ValueCheck::kLenient);
  EXPECT_EQ(CheckValue(kTime, "00:05"), ValueCheck::kLenient);
  EXPECT_EQ(CheckValue(kTime, "00:00:05"), ValueCheck::kLenient);
  EXPECT_EQ(CheckValue(kTime, "00:00:05.5"), ValueCheck::kLenient);
  // Long form whose sample count is not padded to the rate's digit count:
  // ParseTimecode reads it, so it is a leniency, not a discarded value.
  EXPECT_EQ(CheckValue(kTime, "01:34:16.120S48000"), ValueCheck::kLenient);
}

TEST(CheckValueTest, TimecodeInvalidForms) {
  EXPECT_EQ(CheckValue(kTime, ""), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kTime, "abc"), ValueCheck::kInvalid);
  // Long form with a non-numeric sample count.
  EXPECT_EQ(CheckValue(kTime, "01:34:16.abcS48000"), ValueCheck::kInvalid);
  // Long form with no fractional part at all.
  EXPECT_EQ(CheckValue(kTime, "01:34:16S48000"), ValueCheck::kInvalid);
  // Zero denominator.
  EXPECT_EQ(CheckValue(kTime, "5S0"), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kTime, "00:00:00:00"), ValueCheck::kInvalid);
}

TEST(CheckValueTest, Bool) {
  EXPECT_EQ(CheckValue(kBool, "0"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kBool, "1"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kBool, "true"), ValueCheck::kLenient);
  EXPECT_EQ(CheckValue(kBool, "false"), ValueCheck::kLenient);
  EXPECT_EQ(CheckValue(kBool, "2"), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kBool, ""), ValueCheck::kInvalid);
}

TEST(CheckValueTest, EnumCaseSensitivity) {
  EXPECT_EQ(CheckValue(kGainUnit, "dB"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kGainUnit, "linear"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kGainUnit, "db"), ValueCheck::kLenient);
  EXPECT_EQ(CheckValue(kGainUnit, "decibel"), ValueCheck::kInvalid);
}

TEST(CheckValueTest, IdPattern) {
  EXPECT_EQ(CheckValue(kPackId, "AP_00010002"), ValueCheck::kValid);
  // Hex digits are case-insensitive (BS.2076-3 §6).
  EXPECT_EQ(CheckValue(kPackId, "AP_0001000a"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kPackId, "AP_0001000A"), ValueCheck::kValid);
  // Prefix is literal.
  EXPECT_EQ(CheckValue(kPackId, "ap_00010002"), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kPackId, "AP_0001"), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kPackId, "AP_0001000g"), ValueCheck::kInvalid);
}

TEST(CheckValueTest, IntRange) {
  EXPECT_EQ(CheckValue(kImportance, "10"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kImportance, "0"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kImportance, "11"), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kImportance, "-1"), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kImportance, "10.0"), ValueCheck::kLenient);
  EXPECT_EQ(CheckValue(kImportance, "x"), ValueCheck::kInvalid);
}

TEST(CheckValueTest, FloatRangeAndNonFinite) {
  EXPECT_EQ(CheckValue(kUnitRange, "0.5"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kUnitRange, "1.5"), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kUnitRange, "inf"), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kUnitRange, "nan"), ValueCheck::kInvalid);
}

TEST(SpeakerLabelTest, SpecLabels) {
  EXPECT_TRUE(IsSpecSpeakerLabel("M+030"));
  EXPECT_TRUE(IsSpecSpeakerLabel("M-110"));
  EXPECT_TRUE(IsSpecSpeakerLabel("U+045"));
  EXPECT_TRUE(IsSpecSpeakerLabel("T+000"));
  EXPECT_TRUE(IsSpecSpeakerLabel("UH+180"));
  EXPECT_TRUE(IsSpecSpeakerLabel("B+045"));
  EXPECT_TRUE(IsSpecSpeakerLabel("M+SC"));
  // BS.2094-2 additions absent from BS.2051 Table 1.
  EXPECT_TRUE(IsSpecSpeakerLabel("M+150"));
  // All three LFE spellings are spec (BS.2094-2 Table 1A).
  EXPECT_TRUE(IsSpecSpeakerLabel("LFE"));
  EXPECT_TRUE(IsSpecSpeakerLabel("LFE1"));
  EXPECT_TRUE(IsSpecSpeakerLabel("LFE2"));
  // Cartesian cube labels (BS.2094-2 Table 1B).
  EXPECT_TRUE(IsSpecSpeakerLabel("M_FL"));
  EXPECT_TRUE(IsSpecSpeakerLabel("U_BC67"));
  EXPECT_TRUE(IsSpecSpeakerLabel("M_FLSc"));
}

TEST(SpeakerLabelTest, UrnForm) {
  EXPECT_TRUE(IsSpecSpeakerLabel("urn:itu:bs:2051:0:speaker:M+030"));
  EXPECT_TRUE(IsSpecSpeakerLabel("urn:itu:bs:2051:1:speaker:LFE"));
  EXPECT_FALSE(IsSpecSpeakerLabel("urn:itu:bs:2051:0:speaker:RC_L"));
  EXPECT_FALSE(IsSpecSpeakerLabel("urn:itu:bs:2051:speaker:M+030"));
}

TEST(SpeakerLabelTest, StripSpeakerLabelUrn) {
  EXPECT_EQ(StripSpeakerLabelUrn("urn:itu:bs:2051:0:speaker:M+030"), "M+030");
  EXPECT_EQ(StripSpeakerLabelUrn("urn:itu:bs:2051:12:speaker:RC_L"), "RC_L");
  // Bare labels pass through.
  EXPECT_EQ(StripSpeakerLabelUrn("M+030"), "M+030");
  EXPECT_EQ(StripSpeakerLabelUrn(""), "");
  // Malformed URNs are returned verbatim.
  EXPECT_EQ(StripSpeakerLabelUrn("urn:itu:bs:2051:speaker:M+030"),
            "urn:itu:bs:2051:speaker:M+030");
  EXPECT_EQ(StripSpeakerLabelUrn("urn:itu:bs:2051:x:speaker:M+030"),
            "urn:itu:bs:2051:x:speaker:M+030");
}

TEST(SpeakerLabelTest, NonSpecLabelsRejected) {
  // Proprietary room-centric vocabularies are not spec.
  EXPECT_FALSE(IsSpecSpeakerLabel("RC_L"));
  EXPECT_FALSE(IsSpecSpeakerLabel("RC_Ltf"));
  EXPECT_FALSE(IsSpecSpeakerLabel("RoomCentricLeft"));
  EXPECT_FALSE(IsSpecSpeakerLabel("LFEch"));
  // Structurally plausible but not an enumerated position.
  EXPECT_FALSE(IsSpecSpeakerLabel("M+075"));
  EXPECT_FALSE(IsSpecSpeakerLabel(""));
}

TEST(SpeakerLabelTest, GrammarShape) {
  const auto fl = ParseSpeakerLabelGrammar("M+030");
  ASSERT_TRUE(fl.has_value());
  EXPECT_EQ(fl->layer, "M");
  EXPECT_EQ(fl->sign, 1);
  EXPECT_EQ(fl->azimuth, 30);
  EXPECT_FALSE(fl->screen);

  const auto uh = ParseSpeakerLabelGrammar("UH+180");
  ASSERT_TRUE(uh.has_value());
  EXPECT_EQ(uh->layer, "UH");  // Longer prefix wins over "U".

  const auto sc = ParseSpeakerLabelGrammar("M-SC");
  ASSERT_TRUE(sc.has_value());
  EXPECT_TRUE(sc->screen);
  EXPECT_EQ(sc->sign, -1);

  // Accepts the URN spelling, like the rest of the label surface.
  EXPECT_TRUE(ParseSpeakerLabelGrammar("urn:itu:bs:2051:0:speaker:M+030"));

  // Shape violations.
  EXPECT_FALSE(ParseSpeakerLabelGrammar("RC_L"));
  EXPECT_FALSE(ParseSpeakerLabelGrammar("M030"));   // No sign.
  EXPECT_FALSE(ParseSpeakerLabelGrammar("M+03x"));  // Non-digit azimuth.
  EXPECT_FALSE(ParseSpeakerLabelGrammar("M+999"));  // Azimuth out of range.
  EXPECT_FALSE(ParseSpeakerLabelGrammar("U+SC"));   // Screen pair is M only.
  EXPECT_FALSE(ParseSpeakerLabelGrammar("X+030"));
  EXPECT_FALSE(ParseSpeakerLabelGrammar(""));
}

TEST(CheckValueTest, SpeakerLabelGrading) {
  constexpr ValueDomain kLabel{.kind = ValueDomain::Kind::kSpeakerLabel};
  // Enumerated by the specs.
  EXPECT_EQ(CheckValue(kLabel, "M+030"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kLabel, "M_FL"), ValueCheck::kValid);
  EXPECT_EQ(CheckValue(kLabel, "LFE1"), ValueCheck::kValid);
  // Not enumerated, but the importer's structural parser resolves it to a
  // direction and uses it -- a leniency, not a substituted fallback.
  EXPECT_EQ(CheckValue(kLabel, "M+075"), ValueCheck::kLenient);
  EXPECT_EQ(CheckValue(kLabel, "B-180"), ValueCheck::kLenient);
  // Genuinely outside the domain: the importer falls back to geometry.
  EXPECT_EQ(CheckValue(kLabel, "RC_L"), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kLabel, "RoomCentricLeft"), ValueCheck::kInvalid);
  EXPECT_EQ(CheckValue(kLabel, ""), ValueCheck::kInvalid);
}

TEST(FindElementTest, LookupAndContexts) {
  ASSERT_NE(FindElement("audioObject"), nullptr);
  EXPECT_TRUE(FindElement("audioObject")->consumed);
  ASSERT_NE(FindElement("ds/audioBlockFormat"), nullptr);
  ASSERT_NE(FindElement("obj/position"), nullptr);
  ASSERT_NE(FindElement("profileList"), nullptr);
  EXPECT_FALSE(FindElement("profileList")->consumed);
  // Context-narrowed: read under audioProgramme, ignored under audioContent.
  ASSERT_NE(FindElement("audioContent/loudnessMetadata"), nullptr);
  EXPECT_FALSE(FindElement("audioContent/loudnessMetadata")->consumed);
  EXPECT_TRUE(FindElement("loudnessMetadata")->consumed);
  ASSERT_NE(FindElement("audioObject/audioObjectIDRef"), nullptr);
  EXPECT_FALSE(FindElement("audioObject/audioObjectIDRef")->consumed);
  EXPECT_TRUE(FindElement("audioObjectIDRef")->consumed);
  EXPECT_EQ(FindElement("dbmd"), nullptr);
  EXPECT_EQ(FindElement("nonsense"), nullptr);
}

TEST(FindElementTest, KnownNames) {
  EXPECT_TRUE(IsKnownElementName("position"));
  EXPECT_TRUE(IsKnownElementName("audioBlockFormat"));
  EXPECT_TRUE(IsKnownElementName("tagGroup"));
  EXPECT_FALSE(IsKnownElementName("dolbyElement"));
}

// Mirrors the audit walker's ResolveChild fallback: type-prefix qualified,
// then parent qualified, then unqualified.
bool ChildResolves(absl::string_view parent, absl::string_view name) {
  if (FindElement(name) != nullptr) return true;
  if (FindElement(absl::StrCat(parent, "/", name)) != nullptr) return true;
  for (const absl::string_view prefix : {"ds", "obj", "hoa", "mtx", "bin"}) {
    if (FindElement(absl::StrCat(prefix, "/", name)) != nullptr) return true;
  }
  return false;
}

TEST(FindElementTest, EveryAllowedChildHasASpec) {
  // A name listed as an allowed child but missing its own ElementSpec would
  // be misreported as "not defined by BS.2076-3" — a table gap invisible to
  // hand review, so gate it structurally.
  for (const ElementSpec& e : AllElements()) {
    const absl::string_view parent = absl::string_view(e.key).substr(
        absl::string_view(e.key).rfind('/') + 1);
    for (const char* child : e.children) {
      EXPECT_TRUE(ChildResolves(parent, child))
          << e.key << " lists child " << child << " with no ElementSpec";
    }
  }
}

}  // namespace
}  // namespace vocab
}  // namespace adm
}  // namespace adm2iamf
