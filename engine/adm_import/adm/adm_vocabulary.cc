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

// ADM spec vocabulary tables, transcribed from the published ITU-R
// recommendations (itu.int; the PDFs are not vendored):
//   - ITU-R BS.2076-3 -- element/attribute tables A1-1..A1-63, timecode
//     grammar §5.13, ID formats §6/Table A1-62.
//   - ITU-R BS.2051-3 Table 1 and ITU-R BS.2094-2 Tables 1A/1B -- the
//     loudspeaker-label inventory (polar + Cartesian + LFE spellings).
//
// `consumed` mirrors what ParseAxml() (adm_parser.cc) actually reads today;
// it must be updated when the parser grows.

#include "adm_import/adm/adm_vocabulary.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

#include "absl/base/no_destructor.h"
#include "absl/container/flat_hash_map.h"
#include "absl/container/flat_hash_set.h"
#include "absl/strings/ascii.h"
#include "absl/strings/match.h"
#include "absl/strings/numbers.h"
#include "absl/strings/str_split.h"
#include "absl/strings/string_view.h"

namespace adm2iamf {
namespace adm {
namespace vocab {
namespace {

using Kind = ValueDomain::Kind;

constexpr double kInf = std::numeric_limits<double>::infinity();

constexpr ValueDomain kAny{};
constexpr ValueDomain kBool{.kind = Kind::kBool};
constexpr ValueDomain kTime{.kind = Kind::kTimecode};
constexpr ValueDomain kLabel{.kind = Kind::kSpeakerLabel};

constexpr ValueDomain Id(const char* pattern) {
  return {.kind = Kind::kId, .pattern = pattern};
}
constexpr ValueDomain Enum(const char* enums) {
  return {.kind = Kind::kEnum, .enums = enums};
}
constexpr ValueDomain Float(double min = -kInf, double max = kInf) {
  return {.kind = Kind::kFloat, .min = min, .max = max};
}
constexpr ValueDomain Int(double min, double max) {
  return {.kind = Kind::kInt, .min = min, .max = max};
}

constexpr const char* kTypeDefs = "DirectSpeakers|Matrix|Objects|HOA|Binaural";
constexpr const char* kCoords = "azimuth|elevation|distance|X|Y|Z";
constexpr const char* kGainUnits = "linear|dB";

// ── Attribute tables ─────────────────────────────────────────────────────────

constexpr AttrSpec kFormatExtendedAttrs[] = {
    {"version", kAny, false},  // A1-61; absent => BS.2076-0 (§5.12.2).
};
constexpr AttrSpec kProgrammeAttrs[] = {
    {"audioProgrammeID", Id("APR_hhhh"), true},
    {"audioProgrammeName", kAny, true},
    {"audioProgrammeLanguage", kAny, false},
    {"start", kTime, false},
    {"end", kTime, false},
    {"maxDuckingDepth", Float(-62, 0), false},  // A1-41: 0 to −62 dB.
};
constexpr AttrSpec kContentAttrs[] = {
    {"audioContentID", Id("ACO_hhhh"), true},
    {"audioContentName", kAny, true},
    {"audioContentLanguage", kAny, false},
};
constexpr AttrSpec kObjectAttrs[] = {
    {"audioObjectID", Id("AO_hhhh"), true},
    {"audioObjectName", kAny, true},
    {"start", kTime, false},
    {"duration", kTime, false},
    {"dialogue", Int(0, 2), false},
    {"importance", Int(0, 10), true},
    {"interact", kBool, false},
    {"disableDucking", kBool, false},
};
constexpr AttrSpec kPackAttrs[] = {
    {"audioPackFormatID", Id("AP_hhhhhhhh"), true},
    {"audioPackFormatName", kAny, true},
    {"typeLabel", Id("hhhh"), true},
    {"typeDefinition", Enum(kTypeDefs), true},
    {"importance", Int(0, 10), false},
};
constexpr AttrSpec kChannelAttrs[] = {
    {"audioChannelFormatID", Id("AC_hhhhhhhh"), true},
    {"audioChannelFormatName", kAny, true},
    {"typeLabel", Id("hhhh"), true},
    {"typeDefinition", Enum(kTypeDefs), true},
};
constexpr AttrSpec kBlockAttrs[] = {
    {"audioBlockFormatID", Id("AB_hhhhhhhh_hhhhhhhh"), true},
    {"rtime", kTime, true},
    {"duration", kTime, true},
};
constexpr AttrSpec kFrequencyAttrs[] = {
    {"typeDefinition", Enum("lowPass|highPass"), true},
};
constexpr AttrSpec kDsPositionAttrs[] = {
    {"coordinate", Enum(kCoords), true},
    {"bound", Enum("min|max"), false},
    {"screenEdgeLock", Enum("left|right|top|bottom"), false},
};
constexpr AttrSpec kObjPositionAttrs[] = {
    {"coordinate", Enum(kCoords), true},
    {"screenEdgeLock", Enum("left|right|top|bottom"), false},
};
constexpr AttrSpec kGainAttrs[] = {
    {"gainUnit", Enum(kGainUnits), true},
};
constexpr AttrSpec kJumpPositionAttrs[] = {
    {"interpolationLength", kTime, true},
};
constexpr AttrSpec kHeadphoneVirtualiseAttrs[] = {
    {"bypass", kBool, false},
    {"DRR", Float(-130, 130), false},  // §9.5.
};
constexpr AttrSpec kChannelLockAttrs[] = {
    // A1-19 says 0.0 to 2*sqrt(3); §10.2 says 0..2. Accept the wider table
    // value.
    {"maxDistance", Float(0, 3.4641016151), false},
};
constexpr AttrSpec kObjectDivergenceAttrs[] = {
    {"azimuthRange", Float(0, 180), false},
    {"positionRange", Float(0, 1), false},
};
constexpr AttrSpec kZoneAttrs[] = {
    {"minAzimuth", Float(-180, 180), false},
    {"maxAzimuth", Float(-180, 180), false},
    {"minElevation", Float(-90, 90), false},
    {"maxElevation", Float(-90, 90), false},
    {"minX", Float(-1, 1), false},
    {"maxX", Float(-1, 1), false},
    {"minY", Float(-1, 1), false},
    {"maxY", Float(-1, 1), false},
    {"minZ", Float(-1, 1), false},
    {"maxZ", Float(-1, 1), false},
};
constexpr AttrSpec kCoefficientAttrs[] = {
    {"gainUnit", Enum(kGainUnits), false},
    {"gain", Float(), false},
    {"gainVar", kAny, false},
    {"phase", Float(), false},
    {"phaseVar", kAny, false},
    {"delay", Float(), false},
    {"delayVar", kAny, false},
};
constexpr AttrSpec kLoudnessMetadataAttrs[] = {
    // A1-37: all three are free strings ("ITU-R BS.1770", "EBU R128", ...).
    {"loudnessMethod", kAny, false},
    {"loudnessRecType", kAny, false},
    {"loudnessCorrectionType", kAny, false},
};
constexpr AttrSpec kRendererAttrs[] = {
    {"uri", kAny, false},
    {"name", kAny, false},
    {"version", kAny, false},
    {"coordinateMode", Enum("polar|cartesian"), false},
};
constexpr AttrSpec kLanguageAttrs[] = {
    {"language", kAny, false},  // ISO 639-1/-2 code (A1-28).
};
constexpr AttrSpec kReferenceScreenAttrs[] = {
    {"aspectRatio", Float(0, kInf), false},
};
constexpr AttrSpec kScreenCentreAttrs[] = {
    {"coordinate", Enum(kCoords), false},
};
constexpr AttrSpec kScreenWidthAttrs[] = {
    {"coordinate", Enum("azimuth|X"), false},
};
constexpr AttrSpec kObjectInteractionAttrs[] = {
    {"onOffInteract", kBool, false},
    {"gainInteract", kBool, false},
    {"positionInteract", kBool, false},
};
constexpr AttrSpec kGainInteractionRangeAttrs[] = {
    {"bound", Enum("min|max"), false},
    {"gainUnit", Enum(kGainUnits), false},
};
constexpr AttrSpec kPositionInteractionRangeAttrs[] = {
    {"coordinate", Enum(kCoords), false},
    {"bound", Enum("min|max"), false},
};
constexpr AttrSpec kPositionOffsetAttrs[] = {
    {"coordinate", Enum(kCoords), false},
};
constexpr AttrSpec kAlternativeValueSetAttrs[] = {
    {"alternativeValueSetID", Id("AVS_hhhh_hhhh"), false},
};
constexpr AttrSpec kDialogueAttrs[] = {
    {"nonDialogueContentKind", Int(0, 3), false},  // A1-36.
    {"dialogueContentKind", Int(0, 6), false},
    {"mixedContentKind", Int(0, 4), false},
};
constexpr AttrSpec kStreamFormatAttrs[] = {
    {"audioStreamFormatID", Id("AS_hhhhhhhh"), false},
    {"audioStreamFormatName", kAny, false},
    {"formatLabel", Id("hhhh"), false},
    {"formatDefinition", kAny, false},
};
constexpr AttrSpec kTrackFormatAttrs[] = {
    {"audioTrackFormatID", Id("AT_hhhhhhhh_hh"), false},
    {"audioTrackFormatName", kAny, false},
    {"formatLabel", Id("hhhh"), false},
    {"formatDefinition", kAny, false},
};
constexpr AttrSpec kTrackUidAttrs[] = {
    {"UID", Id("ATU_hhhhhhhh"), false},
    {"sampleRate", Float(0, kInf), false},
    {"bitDepth", Int(1, 64), false},
};
constexpr AttrSpec kProfileAttrs[] = {
    {"profileName", kAny, false},
    {"profileVersion", kAny, false},
    {"profileLevel", kAny, false},
};
constexpr AttrSpec kTagAttrs[] = {
    {"class", kAny, false},
};

// ── Child-name tables ────────────────────────────────────────────────────────

constexpr const char* kFormatExtendedChildren[] = {
    "audioProgramme",   "audioContent",       "audioObject",
    "audioPackFormat",  "audioChannelFormat", "audioStreamFormat",
    "audioTrackFormat", "audioTrackUID",      "profileList",
    "tagList",
};
constexpr const char* kProgrammeChildren[] = {
    "audioProgrammeLabel",  "audioContentIDRef",
    "loudnessMetadata",     "audioProgrammeReferenceScreen",
    "authoringInformation", "alternativeValueSetIDRef",
};
constexpr const char* kContentChildren[] = {
    "audioContentLabel", "audioObjectIDRef",         "loudnessMetadata",
    "dialogue",          "alternativeValueSetIDRef",
};
constexpr const char* kObjectChildren[] = {
    "audioPackFormatIDRef",
    "audioObjectIDRef",
    "audioObjectLabel",
    "audioComplementaryObjectGroupLabel",
    "audioComplementaryObjectIDRef",
    "audioTrackUIDRef",
    "audioObjectInteraction",
    "gain",
    "headLocked",
    "positionOffset",
    "mute",
    "alternativeValueSet",
};
// Union across pack types (A1-23 core + A1-24 Matrix + A1-25 HOA). The audit
// does not yet narrow pack children by typeDefinition.
constexpr const char* kPackChildren[] = {
    "audioChannelFormatIDRef",
    "audioPackFormatIDRef",
    "absoluteDistance",
    "encodePackFormatIDRef",
    "decodePackFormatIDRef",
    "inputPackFormatIDRef",
    "outputPackFormatIDRef",
    "normalization",
    "nfcRefDist",
    "screenRef",
};
constexpr const char* kChannelChildren[] = {"audioBlockFormat", "frequency"};

constexpr const char* kBlockCommon0[] = {"gain", "importance", "jumpPosition"};
constexpr const char* kDsBlockChildren[] = {
    "gain",       "importance",          "jumpPosition",
    "headLocked", "headphoneVirtualise", "speakerLabel",
    "position",   "cartesian",
};
constexpr const char* kMtxBlockChildren[] = {
    "gain",
    "importance",
    "jumpPosition",
    "outputChannelFormatIDRef",
    // Legacy name; spec says parsers should read both (A1-15 fn 1).
    "outputChannelIDRef",
    "matrix",
};
constexpr const char* kObjBlockChildren[] = {
    "gain",
    "importance",
    "jumpPosition",
    "headLocked",
    "headphoneVirtualise",
    "position",
    "cartesian",
    "width",
    "height",
    "depth",
    "diffuse",
    "channelLock",
    "objectDivergence",
    "zoneExclusion",
    "screenRef",
};
constexpr const char* kHoaBlockChildren[] = {
    "gain",
    "importance",
    "jumpPosition",
    "headLocked",
    "headphoneVirtualise",
    "equation",
    "order",
    "degree",
    "normalization",
    "nfcRefDist",
    "screenRef",
};
// Fallback for channels whose typeDefinition could not be resolved: union.
constexpr const char* kAnyBlockChildren[] = {
    "gain",
    "importance",
    "jumpPosition",
    "headLocked",
    "headphoneVirtualise",
    "speakerLabel",
    "position",
    "cartesian",
    "width",
    "height",
    "depth",
    "diffuse",
    "channelLock",
    "objectDivergence",
    "zoneExclusion",
    "screenRef",
    "outputChannelFormatIDRef",
    "outputChannelIDRef",
    "matrix",
    "equation",
    "order",
    "degree",
    "normalization",
    "nfcRefDist",
};
constexpr const char* kZoneExclusionChildren[] = {"zone"};
constexpr const char* kMatrixChildren[] = {"coefficient"};
constexpr const char* kLoudnessChildren[] = {
    "integratedLoudness", "loudnessRange",    "maxTruePeak", "maxMomentary",
    "maxShortTerm",       "dialogueLoudness", "renderer",
};
constexpr const char* kRendererChildren[] = {"audioPackFormatIDRef",
                                             "audioObjectIDRef"};
constexpr const char* kReferenceScreenChildren[] = {"screenCentrePosition",
                                                    "screenWidth"};
constexpr const char* kAuthoringChildren[] = {"referenceLayout", "renderer"};
constexpr const char* kReferenceLayoutChildren[] = {"audioPackFormatIDRef"};
constexpr const char* kObjectInteractionChildren[] = {
    "gainInteractionRange", "positionInteractionRange"};
constexpr const char* kAlternativeValueSetChildren[] = {
    "audioObjectLabel", "audioObjectInteraction", "gain",
    "headLocked",       "positionOffset",         "mute",
};
constexpr const char* kStreamFormatChildren[] = {
    "audioChannelFormatIDRef", "audioPackFormatIDRef", "audioTrackFormatIDRef"};
constexpr const char* kTrackFormatChildren[] = {"audioStreamFormatIDRef"};
constexpr const char* kTrackUidChildren[] = {
    "audioMXFLookUp", "audioTrackFormatIDRef", "audioChannelFormatIDRef",
    "audioPackFormatIDRef"};
constexpr const char* kProfileListChildren[] = {"profile"};
constexpr const char* kTagListChildren[] = {"tagGroup"};
constexpr const char* kTagGroupChildren[] = {
    "tag", "audioProgrammeIDRef", "audioContentIDRef", "audioObjectIDRef"};

// ── Element table ────────────────────────────────────────────────────────────

constexpr ElementSpec kElements[] = {
    {"audioFormatExtended", true, kAny, kFormatExtendedAttrs,
     kFormatExtendedChildren, "BS.2076-3 §5.12"},
    {"audioProgramme", true, kAny, kProgrammeAttrs, kProgrammeChildren,
     "BS.2076-3 §5.8"},
    {"audioContent", true, kAny, kContentAttrs, kContentChildren,
     "BS.2076-3 §5.7"},
    {"audioObject", true, kAny, kObjectAttrs, kObjectChildren,
     "BS.2076-3 §5.6"},
    {"audioPackFormat", true, kAny, kPackAttrs, kPackChildren,
     "BS.2076-3 §5.5"},
    {"audioChannelFormat", true, kAny, kChannelAttrs, kChannelChildren,
     "BS.2076-3 §5.3"},
    {"frequency",
     true,
     Float(0, kInf),
     kFrequencyAttrs,
     {},
     "BS.2076-3 §5.3.2"},

    // audioBlockFormat by channel typeDefinition context.
    {"ds/audioBlockFormat", true, kAny, kBlockAttrs, kDsBlockChildren,
     "BS.2076-3 §5.4.3.1"},
    {"mtx/audioBlockFormat", true, kAny, kBlockAttrs, kMtxBlockChildren,
     "BS.2076-3 §5.4.3.2"},
    {"obj/audioBlockFormat", true, kAny, kBlockAttrs, kObjBlockChildren,
     "BS.2076-3 §5.4.3.3"},
    {"hoa/audioBlockFormat", true, kAny, kBlockAttrs, kHoaBlockChildren,
     "BS.2076-3 §5.4.3.4"},
    {"bin/audioBlockFormat", true, kAny, kBlockAttrs, kBlockCommon0,
     "BS.2076-3 §5.4.3.5"},
    {"audioBlockFormat", true, kAny, kBlockAttrs, kAnyBlockChildren,
     "BS.2076-3 §5.4"},

    // Block sub-elements. Position text ranges are refined per the
    // coordinate attribute by the audit walker.
    {"ds/position",
     true,
     Float(),
     kDsPositionAttrs,
     {},
     "BS.2076-3 Tables A1-13/A1-14"},
    {"obj/position",
     true,
     Float(),
     kObjPositionAttrs,
     {},
     "BS.2076-3 Tables A1-17/A1-18"},
    {"position", true, Float(), kDsPositionAttrs, {}, "BS.2076-3 §5.4.3"},
    {"gain", true, Float(), kGainAttrs, {}, "BS.2076-3 §9.1"},
    {"importance", false, Int(0, 10), {}, {}, "BS.2076-3 §9.2"},
    {"jumpPosition", true, kBool, kJumpPositionAttrs, {}, "BS.2076-3 §9.3"},
    {"headLocked", false, kBool, {}, {}, "BS.2076-3 §9.4"},
    {"headphoneVirtualise",
     false,
     kAny,
     kHeadphoneVirtualiseAttrs,
     {},
     "BS.2076-3 §9.5"},
    {"speakerLabel", true, kLabel, {}, {}, "BS.2076-3 §5.4.3.1 + BS.2051/2094"},
    {"cartesian", true, kBool, {}, {}, "BS.2076-3 Table A1-19"},
    {"width", true, Float(0, 360), {}, {}, "BS.2076-3 Tables A1-17/A1-18"},
    {"height", true, Float(0, 360), {}, {}, "BS.2076-3 Tables A1-17/A1-18"},
    {"depth", true, Float(0, 1), {}, {}, "BS.2076-3 Tables A1-17/A1-18"},
    {"diffuse", false, Float(0, 1), {}, {}, "BS.2076-3 §10.1"},
    {"channelLock", false, kBool, kChannelLockAttrs, {}, "BS.2076-3 §10.2"},
    {"objectDivergence",
     false,
     Float(0, 1),
     kObjectDivergenceAttrs,
     {},
     "BS.2076-3 §10.4"},
    {"zoneExclusion",
     false,
     kAny,
     {},
     kZoneExclusionChildren,
     "BS.2076-3 §10.3"},
    {"zone", false, kAny, kZoneAttrs, {}, "BS.2076-3 §10.3"},
    {"screenRef", false, kBool, {}, {}, "BS.2076-3 §10.5"},
    {"equation", false, kAny, {}, {}, "BS.2076-3 §5.4.3.4"},
    {"order", false, Int(0, 1e9), {}, {}, "BS.2076-3 §11"},
    {"degree", false, Int(-1e9, 1e9), {}, {}, "BS.2076-3 §11"},
    {"normalization", false, Enum("N3D|SN3D|FuMa"), {}, {}, "BS.2076-3 §11"},
    {"nfcRefDist", false, Float(0, kInf), {}, {}, "BS.2076-3 §11"},
    {"absoluteDistance", false, Float(), {}, {}, "BS.2076-3 §5.5.2"},
    {"matrix", false, kAny, {}, kMatrixChildren, "BS.2076-3 Table A1-16"},
    {"coefficient",
     false,
     Id("AC_hhhhhhhh"),
     kCoefficientAttrs,
     {},
     "BS.2076-3 Table A1-16"},
    {"outputChannelFormatIDRef",
     false,
     Id("AC_hhhhhhhh"),
     {},
     {},
     "BS.2076-3 Table A1-15"},
    {"outputChannelIDRef",
     false,
     Id("AC_hhhhhhhh"),
     {},
     {},
     "BS.2076-3 Table A1-15 fn 1 (legacy name)"},

    // ID references.
    {"audioContentIDRef", true, Id("ACO_hhhh"), {}, {}, "BS.2076-3 §5.8"},
    {"audioObjectIDRef", true, Id("AO_hhhh"), {}, {}, "BS.2076-3 §5.7"},
    {"audioPackFormatIDRef", true, Id("AP_hhhhhhhh"), {}, {}, "BS.2076-3 §5.6"},
    {"audioChannelFormatIDRef",
     true,
     Id("AC_hhhhhhhh"),
     {},
     {},
     "BS.2076-3 §5.5"},
    {"audioTrackUIDRef", true, Id("ATU_hhhhhhhh"), {}, {}, "BS.2076-3 §5.6"},
    {"audioTrackFormatIDRef",
     false,
     Id("AT_hhhhhhhh_hh"),
     {},
     {},
     "BS.2076-3 §5.9"},
    {"audioStreamFormatIDRef",
     false,
     Id("AS_hhhhhhhh"),
     {},
     {},
     "BS.2076-3 §5.1"},
    {"audioProgrammeIDRef", false, Id("APR_hhhh"), {}, {}, "BS.2076-3 §5.11"},
    // Matrix pack references (allowed audioPackFormat children; the importer
    // does not read Matrix packs, so none is consumed).
    {"encodePackFormatIDRef",
     false,
     Id("AP_hhhhhhhh"),
     {},
     {},
     "BS.2076-3 Table A1-24"},
    {"decodePackFormatIDRef",
     false,
     Id("AP_hhhhhhhh"),
     {},
     {},
     "BS.2076-3 Table A1-24"},
    {"inputPackFormatIDRef",
     false,
     Id("AP_hhhhhhhh"),
     {},
     {},
     "BS.2076-3 Table A1-24"},
    {"outputPackFormatIDRef",
     false,
     Id("AP_hhhhhhhh"),
     {},
     {},
     "BS.2076-3 Table A1-24"},
    // Context-narrowed entries: the parser reads these elements only under
    // one parent; under the other allowed parent the same element is
    // spec-valid but ignored, and reporting it "ok" would claim a read
    // that never happens. ResolveChild tries "parent/name" before "name".
    {"audioContent/loudnessMetadata", false, kAny, kLoudnessMetadataAttrs,
     kLoudnessChildren, "BS.2076-3 §5.7"},
    {"audioObject/audioObjectIDRef",
     false,
     Id("AO_hhhh"),
     {},
     {},
     "BS.2076-3 §5.6.3"},
    {"audioComplementaryObjectIDRef",
     false,
     Id("AO_hhhh"),
     {},
     {},
     "BS.2076-3 §5.6.3"},
    {"alternativeValueSetIDRef",
     false,
     Id("AVS_hhhh_hhhh"),
     {},
     {},
     "BS.2076-3 §5.6.5"},

    // Loudness / labels / programme extras.
    {"loudnessMetadata", true, kAny, kLoudnessMetadataAttrs, kLoudnessChildren,
     "BS.2076-3 §5.7.4"},
    {"integratedLoudness", true, Float(), {}, {}, "BS.2076-3 Table A1-38"},
    {"loudnessRange", false, Float(0, kInf), {}, {}, "BS.2076-3 Table A1-38"},
    {"maxTruePeak", true, Float(), {}, {}, "BS.2076-3 Table A1-38"},
    {"maxMomentary", false, Float(), {}, {}, "BS.2076-3 Table A1-38"},
    {"maxShortTerm", false, Float(), {}, {}, "BS.2076-3 Table A1-38"},
    {"dialogueLoudness", true, Float(), {}, {}, "BS.2076-3 Table A1-38"},
    {"renderer", false, kAny, kRendererAttrs, kRendererChildren,
     "BS.2076-3 §5.7.4/§5.8.6"},
    {"audioProgrammeLabel",
     false,
     kAny,
     kLanguageAttrs,
     {},
     "BS.2076-3 Table A1-42"},
    {"audioContentLabel",
     false,
     kAny,
     kLanguageAttrs,
     {},
     "BS.2076-3 Table A1-34"},
    {"audioObjectLabel",
     false,
     kAny,
     kLanguageAttrs,
     {},
     "BS.2076-3 Table A1-28"},
    {"audioComplementaryObjectGroupLabel",
     false,
     kAny,
     kLanguageAttrs,
     {},
     "BS.2076-3 Table A1-29"},
    {"audioProgrammeReferenceScreen", false, kAny, kReferenceScreenAttrs,
     kReferenceScreenChildren, "BS.2076-3 §5.8.3"},
    {"screenCentrePosition",
     false,
     Float(),
     kScreenCentreAttrs,
     {},
     "BS.2076-3 Tables A1-44/A1-45"},
    {"screenWidth",
     false,
     Float(),
     kScreenWidthAttrs,
     {},
     "BS.2076-3 Tables A1-44/A1-45"},
    {"authoringInformation",
     false,
     kAny,
     {},
     kAuthoringChildren,
     "BS.2076-3 §5.8.6"},
    {"referenceLayout",
     false,
     kAny,
     {},
     kReferenceLayoutChildren,
     "BS.2076-3 Table A1-51"},

    // Interaction / alternative sets / dialogue.
    {"audioObjectInteraction", false, kAny, kObjectInteractionAttrs,
     kObjectInteractionChildren, "BS.2076-3 §5.6.4"},
    {"gainInteractionRange",
     false,
     Float(),
     kGainInteractionRangeAttrs,
     {},
     "BS.2076-3 Table A1-31"},
    {"positionInteractionRange",
     false,
     Float(),
     kPositionInteractionRangeAttrs,
     {},
     "BS.2076-3 Table A1-31"},
    {"positionOffset",
     false,
     Float(),
     kPositionOffsetAttrs,
     {},
     "BS.2076-3 Table A1-27"},
    {"mute", false, kBool, {}, {}, "BS.2076-3 Table A1-27"},
    {"alternativeValueSet", false, kAny, kAlternativeValueSetAttrs,
     kAlternativeValueSetChildren, "BS.2076-3 §5.6.5"},
    {"dialogue", false, Int(0, 2), kDialogueAttrs, {}, "BS.2076-3 §5.7.3"},

    // Stream/track plumbing (deprecated for PCM by BS.2076-2; not read).
    {"audioStreamFormat", false, kAny, kStreamFormatAttrs,
     kStreamFormatChildren, "BS.2076-3 §5.2"},
    {"audioTrackFormat", false, kAny, kTrackFormatAttrs, kTrackFormatChildren,
     "BS.2076-3 §5.1"},
    {"audioTrackUID", false, kAny, kTrackUidAttrs, kTrackUidChildren,
     "BS.2076-3 §5.9"},
    {"audioMXFLookUp",
     false,
     kAny,
     {},
     {},
     "BS.2076-3 §5.9.2 (deprecated in -3)"},

    // New in BS.2076-3.
    {"profileList", false, kAny, {}, kProfileListChildren, "BS.2076-3 §5.10"},
    {"profile", false, kAny, kProfileAttrs, {}, "BS.2076-3 Table A1-57"},
    {"tagList", false, kAny, {}, kTagListChildren, "BS.2076-3 §5.11"},
    {"tagGroup", false, kAny, {}, kTagGroupChildren, "BS.2076-3 Table A1-59"},
    {"tag", false, kAny, kTagAttrs, {}, "BS.2076-3 Table A1-59"},
};

// ── Speaker labels (BS.2051-3 Table 1 ∪ BS.2094-2 Tables 1A/1B) ─────────────

constexpr const char* kSpeakerLabels[] = {
    // Middle layer (elevation 0).
    "M+000",
    "M+022",
    "M-022",
    "M+SC",
    "M-SC",
    "M+030",
    "M-030",
    "M+045",
    "M-045",
    "M+060",
    "M-060",
    "M+090",
    "M-090",
    "M+110",
    "M-110",
    "M+135",
    "M-135",
    "M+150",
    "M-150",
    "M+180",
    // Upper layer (elevation +30) and specials.
    "U+000",
    "U+022",
    "U-022",
    "U+030",
    "U-030",
    "U+045",
    "U-045",
    "U+060",
    "U-060",
    "U+090",
    "U-090",
    "U+110",
    "U-110",
    "U+135",
    "U-135",
    "U+180",
    "UH+180",
    "T+000",
    // Bottom layer (elevation −30).
    "B+000",
    "B+022",
    "B-022",
    "B+030",
    "B-030",
    "B+045",
    "B-045",
    "B+060",
    "B-060",
    "B+090",
    "B-090",
    "B+110",
    "B-110",
    "B+135",
    "B-135",
    "B+180",
    // LFE (BS.2094-2: bare LFE is AC_00010004's label; LFE1/2 are the
    // positioned pair).
    "LFE",
    "LFE1",
    "LFE2",
    // BS.2094-2 Table 1B Cartesian cube labels.
    "M_FL",
    "M_FR",
    "M_FC",
    "M_BL",
    "M_BR",
    "M_FL50",
    "M_FR50",
    "M_BC",
    "M_SL",
    "M_SR",
    "U_TC",
    "U_FL",
    "U_FC",
    "U_FR",
    "U_BL",
    "U_BC",
    "U_BR",
    "U_SL",
    "U_SR",
    "B_FC",
    "B_FL",
    "B_FR",
    "M_FSL67",
    "M_FSR67",
    "M_FLSc",
    "M_FRSc",
    "U_BC67",
    "M_BL50",
    "M_BR50",
};

// ── Value checking ───────────────────────────────────────────────────────────

bool AllDigits(absl::string_view s) {
  if (s.empty()) return false;
  for (char c : s) {
    if (!absl::ascii_isdigit(c)) return false;
  }
  return true;
}

bool AllZeros(absl::string_view s) {
  for (char c : s) {
    if (c != '0') return false;
  }
  return true;
}

// Spec timecode forms (BS.2076-3 §5.13):
//   1. decimal:    "ss.zzzzz" or "hh:mm:ss.zzzzz"  (>= 5 decimal places)
//   2. long-form:  "hh:mm:ss.zzzzzSfffff"          (z-count == f-count)
//   3. shortform:  "zzzzzSfffff"                   (variable digit counts)
// Lenient (importer accepts, spec does not define): fewer than 5 decimal
// places, no fractional part, or MM:SS.
ValueCheck CheckTimecode(absl::string_view v) {
  if (v.empty()) return ValueCheck::kInvalid;

  const size_t s_pos = v.find('S');
  if (s_pos != absl::string_view::npos) {
    const absl::string_view num = v.substr(0, s_pos);
    const absl::string_view den = v.substr(s_pos + 1);
    if (!AllDigits(den) || AllZeros(den)) return ValueCheck::kInvalid;
    if (num.find(':') == absl::string_view::npos) {
      // Shortform: zzzzzSfffff.
      return AllDigits(num) ? ValueCheck::kValid : ValueCheck::kInvalid;
    }
    // Long form: hh:mm:ss.zzzzzSfffff with matching digit counts.
    const size_t dot = num.find('.');
    if (dot == absl::string_view::npos) return ValueCheck::kInvalid;
    const absl::string_view frac = num.substr(dot + 1);
    if (!AllDigits(frac)) return ValueCheck::kInvalid;
    const std::vector<absl::string_view> hms =
        absl::StrSplit(num.substr(0, dot), ':');
    if (hms.size() != 3) return ValueCheck::kInvalid;
    for (absl::string_view f : hms) {
      if (!AllDigits(f)) return ValueCheck::kInvalid;
    }
    // The spec pads the sample count to the sample rate's digit count.
    // ParseTimecode reads it either way, so a mismatch is a leniency the
    // importer honors rather than a value it discards.
    return frac.size() == den.size() ? ValueCheck::kValid
                                     : ValueCheck::kLenient;
  }

  const std::vector<absl::string_view> fields = absl::StrSplit(v, ':');
  if (fields.empty() || fields.size() > 3) return ValueCheck::kInvalid;
  // Every field must be numeric (digits with at most one dot in the last).
  for (size_t i = 0; i < fields.size(); ++i) {
    const absl::string_view f = fields[i];
    const size_t dot = f.find('.');
    const bool last = i + 1 == fields.size();
    if (dot != absl::string_view::npos) {
      if (!last) return ValueCheck::kInvalid;
      if (!AllDigits(f.substr(0, dot)) || !AllDigits(f.substr(dot + 1))) {
        return ValueCheck::kInvalid;
      }
    } else if (!AllDigits(f)) {
      return ValueCheck::kInvalid;
    }
  }
  const absl::string_view last = fields.back();
  const size_t dot = last.find('.');
  const size_t frac_digits =
      dot == absl::string_view::npos ? 0 : last.size() - dot - 1;
  if (fields.size() == 2) return ValueCheck::kLenient;  // MM:SS.
  return frac_digits >= 5 ? ValueCheck::kValid : ValueCheck::kLenient;
}

bool MatchIdPattern(absl::string_view pattern, absl::string_view v) {
  if (pattern.size() != v.size()) return false;
  for (size_t i = 0; i < pattern.size(); ++i) {
    if (pattern[i] == 'h') {
      // Hex digits are case-insensitive (BS.2076-3 §6).
      if (!absl::ascii_isxdigit(v[i])) return false;
    } else if (pattern[i] != v[i]) {
      return false;
    }
  }
  return true;
}

bool EnumMatch(absl::string_view enums, absl::string_view v,
               bool case_sensitive) {
  for (absl::string_view e : absl::StrSplit(enums, '|')) {
    if (case_sensitive ? e == v : absl::EqualsIgnoreCase(e, v)) return true;
  }
  return false;
}

}  // namespace

ValueCheck CheckValue(const ValueDomain& domain, absl::string_view value) {
  const ValueDomain& d = domain;
  const absl::string_view v = value;
  switch (d.kind) {
    case Kind::kAny:
      return ValueCheck::kValid;
    case Kind::kBool:
      if (v == "0" || v == "1") return ValueCheck::kValid;
      // Spec tables say "1/0 flag"; the importer also accepts true/false.
      if (absl::EqualsIgnoreCase(v, "true") ||
          absl::EqualsIgnoreCase(v, "false")) {
        return ValueCheck::kLenient;
      }
      return ValueCheck::kInvalid;
    case Kind::kEnum:
      if (EnumMatch(d.enums, v, /*case_sensitive=*/true)) {
        return ValueCheck::kValid;
      }
      if (EnumMatch(d.enums, v, /*case_sensitive=*/false)) {
        return ValueCheck::kLenient;  // e.g. "db" for "dB", "Left" for "left".
      }
      return ValueCheck::kInvalid;
    case Kind::kFloat: {
      double x = 0;
      if (!absl::SimpleAtod(v, &x) || !std::isfinite(x)) {
        return ValueCheck::kInvalid;
      }
      return (x >= d.min && x <= d.max) ? ValueCheck::kValid
                                        : ValueCheck::kInvalid;
    }
    case Kind::kInt: {
      int64_t n = 0;
      if (absl::SimpleAtoi(v, &n)) {
        return (n >= d.min && n <= d.max) ? ValueCheck::kValid
                                          : ValueCheck::kInvalid;
      }
      double x = 0;  // "10.0" for an integer field: importer truncates.
      if (absl::SimpleAtod(v, &x) && std::isfinite(x) && x >= d.min &&
          x <= d.max) {
        return ValueCheck::kLenient;
      }
      return ValueCheck::kInvalid;
    }
    case Kind::kId:
      return MatchIdPattern(d.pattern, v) ? ValueCheck::kValid
                                          : ValueCheck::kInvalid;
    case Kind::kTimecode:
      return CheckTimecode(v);
    case Kind::kSpeakerLabel:
      if (IsSpecSpeakerLabel(v)) return ValueCheck::kValid;
      // A label the specs do not enumerate but whose shape the importer's
      // structural parser accepts (e.g. "M+023") is *used*, not replaced —
      // grading it invalid would claim a fallback that never happened.
      return ParseSpeakerLabelGrammar(v).has_value() ? ValueCheck::kLenient
                                                     : ValueCheck::kInvalid;
  }
  return ValueCheck::kInvalid;
}

const ElementSpec* FindElement(absl::string_view key) {
  static const absl::NoDestructor<
      absl::flat_hash_map<absl::string_view, const ElementSpec*>>
      kIndex([] {
        absl::flat_hash_map<absl::string_view, const ElementSpec*> m;
        for (const ElementSpec& e : kElements) m.emplace(e.key, &e);
        return m;
      }());
  auto it = kIndex->find(key);
  return it == kIndex->end() ? nullptr : it->second;
}

absl::Span<const ElementSpec> AllElements() { return kElements; }

bool IsKnownElementName(absl::string_view name) {
  for (const ElementSpec& e : kElements) {
    absl::string_view key = e.key;
    const size_t slash = key.find('/');
    if (slash != absl::string_view::npos) key = key.substr(slash + 1);
    if (key == name) return true;
  }
  return false;
}

absl::string_view StripSpeakerLabelUrn(absl::string_view label) {
  // BS.2094-2 §4.1.1 carries labels as URNs in the XML:
  // "urn:itu:bs:2051:<version>:speaker:M+030". Accept both spellings.
  constexpr absl::string_view kUrnPrefix = "urn:itu:bs:2051:";
  constexpr absl::string_view kSpeakerInfix = ":speaker:";
  if (!absl::StartsWith(label, kUrnPrefix)) return label;
  absl::string_view rest = label.substr(kUrnPrefix.size());
  const size_t infix = rest.find(kSpeakerInfix);
  if (infix == absl::string_view::npos || !AllDigits(rest.substr(0, infix))) {
    return label;  // Malformed URN: leave verbatim so it fails label lookup.
  }
  return rest.substr(infix + kSpeakerInfix.size());
}

bool IsSpecSpeakerLabel(absl::string_view label) {
  static const absl::NoDestructor<absl::flat_hash_set<absl::string_view>> kSet(
      [] {
        absl::flat_hash_set<absl::string_view> s;
        for (const char* l : kSpeakerLabels) s.insert(l);
        return s;
      }());
  return kSet->contains(StripSpeakerLabelUrn(label));
}

std::optional<SpeakerLabelParts> ParseSpeakerLabelGrammar(
    absl::string_view label) {
  const absl::string_view bare = StripSpeakerLabelUrn(label);
  if (bare.size() < 2) return std::nullopt;

  SpeakerLabelParts parts;
  absl::string_view rest;
  // "UH" before "U": the longer prefix wins.
  if (absl::StartsWith(bare, "UH")) {
    parts.layer = "UH";
    rest = bare.substr(2);
  } else if (bare[0] == 'M' || bare[0] == 'U' || bare[0] == 'B' ||
             bare[0] == 'T') {
    parts.layer = bare.substr(0, 1);
    rest = bare.substr(1);
  } else {
    return std::nullopt;
  }

  if (rest.empty() || (rest[0] != '+' && rest[0] != '-')) return std::nullopt;
  parts.sign = rest[0] == '+' ? 1 : -1;
  const absl::string_view magnitude = rest.substr(1);

  // The screen-edge pair carries "SC" where the azimuth would be, and only
  // on the middle layer.
  if (magnitude == "SC") {
    if (parts.layer != "M") return std::nullopt;
    parts.screen = true;
    return parts;
  }
  if (!AllDigits(magnitude)) return std::nullopt;
  int azimuth = 0;
  if (!absl::SimpleAtoi(magnitude, &azimuth) || azimuth > 180) {
    return std::nullopt;
  }
  parts.azimuth = azimuth;
  return parts;
}

}  // namespace vocab
}  // namespace adm
}  // namespace adm2iamf
