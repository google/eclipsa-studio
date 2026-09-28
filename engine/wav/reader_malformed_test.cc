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

//
// Malformed-input hardening: in the strict default mode every corrupt
// fixture must fail closed with an error — no crash, no silent partial
// success. The trailing ReaderLenient section pins OpenMode::kLenient's
// recovery of the same fixtures (clamped/floored `data`, ignored tails)
// for the playback/waveform/probe consumers. These tests run under the
// asan/ubsan CI configs, which is where this class of test pays off.

#include <cstdint>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "wav/reader.h"
#include "wav/testing/fixture.h"
#include "wav/types.h"

namespace wav {
namespace {

namespace wt = wav::testing;
namespace wtf = wav::testing::fixture_internal;

// Writes `bytes` to a temp file and expects Open() to fail with an error
// containing `substring`.
void ExpectOpenFails(const std::vector<uint8_t>& bytes, const std::string& name,
                     const std::string& substring) {
  const std::string path = wt::TempDir() + "/" + name + ".wav";
  ASSERT_TRUE(wt::WriteBytes(path, bytes));
  auto r = Reader::Open(path);
  ASSERT_FALSE(r.ok()) << name << ": unexpectedly accepted";
  EXPECT_NE(r.error().find(substring), std::string::npos)
      << name << ": error was: " << r.error();
}

// Appends a whole chunk (id + size32 + payload + pad) to raw file bytes.
void AppendChunk(std::vector<uint8_t>& v, const char* id,
                 const std::vector<uint8_t>& payload) {
  wtf::AppendId(v, id);
  wtf::AppendU32(v, static_cast<uint32_t>(payload.size()));
  v.insert(v.end(), payload.begin(), payload.end());
  if (payload.size() & 1) v.push_back(0);
}

wt::FixtureSpec DefaultSpec() {
  wt::FixtureSpec spec;
  spec.format = SampleFormat::kInt16;
  spec.channels = 2;
  spec.num_frames = 48;
  return spec;
}

TEST(ReaderMalformed, EmptyAndTinyFiles) {
  ExpectOpenFails({}, "empty", "too small");
  auto f = wt::BuildFixture(DefaultSpec());
  f.bytes.resize(8);
  ExpectOpenFails(f.bytes, "eight_bytes", "too small");
}

TEST(ReaderMalformed, HeaderOnlyFileMissesFmt) {
  auto f = wt::BuildFixture(DefaultSpec());
  f.bytes.resize(12);
  ExpectOpenFails(f.bytes, "header_only", "Missing `fmt `");
}

TEST(ReaderMalformed, BadMagicAndFormType) {
  auto f = wt::BuildFixture(DefaultSpec());
  auto bytes = f.bytes;
  bytes[3] = 'X';  // "RIFX"
  ExpectOpenFails(bytes, "bad_magic", "magic");
  bytes = f.bytes;
  bytes[11] = '0';  // "WAV0"
  ExpectOpenFails(bytes, "bad_wave", "WAVE");
}

TEST(ReaderMalformed, TruncatedDataPayload) {
  auto f = wt::BuildFixture(DefaultSpec());
  // Chop the file mid-`data`: the declared size now exceeds the file.
  f.bytes.resize(f.data_payload_offset + 10);
  ExpectOpenFails(f.bytes, "truncated_data", "remain in the file");
}

TEST(ReaderMalformed, ChunkSizeExceedingFileSize) {
  auto spec = DefaultSpec();
  spec.include_extra_chunk = true;
  auto f = wt::BuildFixture(spec);
  wtf::PutU32At(f.bytes, f.extra_size_field_offset, 0x7FFFFFFFu);
  ExpectOpenFails(f.bytes, "oversized_extra", "remain in the file");

  f = wt::BuildFixture(DefaultSpec());
  wtf::PutU32At(f.bytes, f.data_size_field_offset, 0x10000u);
  ExpectOpenFails(f.bytes, "oversized_data", "remain in the file");
}

TEST(ReaderMalformed, FmtAfterDataIsRejected) {
  auto spec = DefaultSpec();
  spec.fmt_after_data = true;
  ExpectOpenFails(wt::BuildFixture(spec).bytes, "fmt_after_data",
                  "must precede");
}

TEST(ReaderMalformed, UnknownSizeDataInPlainRiff) {
  auto f = wt::BuildFixture(DefaultSpec());
  wtf::PutU32At(f.bytes, f.data_size_field_offset, 0xFFFFFFFFu);
  ExpectOpenFails(f.bytes, "riff_unknown_size", "unknown size");
}

TEST(ReaderMalformed, Rf64WithoutDs64) {
  auto spec = DefaultSpec();
  spec.container = Container::kRf64;
  spec.ds64 = wt::FixtureSpec::Ds64Mode::kNone;
  auto f = wt::BuildFixture(spec);
  wtf::PutU32At(f.bytes, f.data_size_field_offset, 0xFFFFFFFFu);
  ExpectOpenFails(f.bytes, "rf64_no_ds64", "ds64");
}

TEST(ReaderMalformed, Ds64AfterDataIsTooLate) {
  auto spec = DefaultSpec();
  spec.container = Container::kRf64;
  spec.ds64 = wt::FixtureSpec::Ds64Mode::kAfterData;
  ExpectOpenFails(wt::BuildFixture(spec).bytes, "ds64_after_data", "ds64");
}

TEST(ReaderMalformed, TruncatedDs64) {
  auto spec = DefaultSpec();
  spec.container = Container::kRf64;
  auto f = wt::BuildFixture(spec);
  wtf::PutU32At(f.bytes, f.ds64_size_field_offset, 8);
  ExpectOpenFails(f.bytes, "truncated_ds64", "Truncated `ds64`");
}

TEST(ReaderMalformed, TruncatedAndInvalidFmt) {
  auto f = wt::BuildFixture(DefaultSpec());
  wtf::PutU32At(f.bytes, f.fmt_size_field_offset, 8);
  ExpectOpenFails(f.bytes, "short_fmt", "Truncated `fmt `");

  // WAVE_FORMAT_EXTENSIBLE must be >= 40 bytes.
  auto spec = DefaultSpec();
  spec.extensible = true;
  f = wt::BuildFixture(spec);
  wtf::PutU32At(f.bytes, f.fmt_size_field_offset, 24);
  ExpectOpenFails(f.bytes, "short_ext_fmt", "EXTENSIBLE");
}

TEST(ReaderMalformed, InvalidFmtFields) {
  const size_t kChannelsOff = 2, kRateOff = 4, kBitsOff = 14, kTagOff = 0;
  auto f = wt::BuildFixture(DefaultSpec());
  const size_t payload = f.fmt_size_field_offset + 4;

  auto bytes = f.bytes;
  wtf::PutU16At(bytes, payload + kChannelsOff, 0);
  ExpectOpenFails(bytes, "zero_channels", "zero channels");

  bytes = f.bytes;
  wtf::PutU32At(bytes, payload + kRateOff, 0);
  ExpectOpenFails(bytes, "zero_rate", "zero sample rate");

  bytes = f.bytes;
  wtf::PutU16At(bytes, payload + kBitsOff, 12);
  ExpectOpenFails(bytes, "pcm12", "Unsupported PCM bit depth");

  bytes = f.bytes;
  wtf::PutU16At(bytes, payload + kTagOff, 0x55);  // MPEG-layer-3.
  ExpectOpenFails(bytes, "mp3_tag", "Unsupported format tag");

  // IEEE float must be 32- or 64-bit.
  auto spec = DefaultSpec();
  spec.format = SampleFormat::kFloat32;
  f = wt::BuildFixture(spec);
  bytes = f.bytes;
  wtf::PutU16At(bytes, f.fmt_size_field_offset + 4 + kBitsOff, 16);
  ExpectOpenFails(bytes, "float16", "Unsupported IEEE-float bit depth");
}

TEST(ReaderMalformed, PartialTrailingFrameIsRejected) {
  auto f = wt::BuildFixture(DefaultSpec());
  // 16-bit stereo frames are 4 bytes; declare a size 2 bytes short and
  // truncate the file to match, leaving a dangling half frame.
  wtf::PutU32At(f.bytes, f.data_size_field_offset, 48 * 4 - 2);
  f.bytes.resize(f.data_payload_offset + 48 * 4 - 2);
  ExpectOpenFails(f.bytes, "partial_frame", "whole number of frames");
}

TEST(ReaderMalformed, TrailingGarbageBytes) {
  auto f = wt::BuildFixture(DefaultSpec());
  f.bytes.push_back(0xDE);
  f.bytes.push_back(0xAD);
  f.bytes.push_back(0x11);
  ExpectOpenFails(f.bytes, "trailing_garbage", "Trailing bytes");
}

TEST(ReaderMalformed, DuplicateStructuralChunks) {
  auto f = wt::BuildFixture(DefaultSpec());
  auto bytes = f.bytes;
  AppendChunk(bytes, "fmt ", std::vector<uint8_t>(16, 0));
  ExpectOpenFails(bytes, "dup_fmt", "Duplicate `fmt `");

  bytes = f.bytes;
  AppendChunk(bytes, "data", {});
  ExpectOpenFails(bytes, "dup_data", "Duplicate `data`");

  auto spec = DefaultSpec();
  spec.container = Container::kRf64;
  bytes = wt::BuildFixture(spec).bytes;
  AppendChunk(bytes, "ds64", std::vector<uint8_t>(28, 0));
  ExpectOpenFails(bytes, "dup_ds64", "Duplicate `ds64`");
}

TEST(ReaderMalformed, GarbageChunkIdsAreSanitizedInErrors) {
  auto spec = DefaultSpec();
  spec.include_extra_chunk = true;
  auto f = wt::BuildFixture(spec);
  // Corrupt the extra chunk's id with non-printable bytes and oversize it;
  // the error must not leak raw bytes.
  f.bytes[f.extra_size_field_offset - 4] = 0x01;
  f.bytes[f.extra_size_field_offset - 3] = 0xFF;
  wtf::PutU32At(f.bytes, f.extra_size_field_offset, 0x40000000u);
  const std::string path = wt::TempDir() + "/garbage_id.wav";
  ASSERT_TRUE(wt::WriteBytes(path, f.bytes));
  auto r = Reader::Open(path);
  ASSERT_FALSE(r.ok());
  EXPECT_NE(r.error().find("'??md'"), std::string::npos) << r.error();
}

TEST(ReaderMalformed, NonexistentFile) {
  auto r = Reader::Open(wt::TempDir() + "/does_not_exist.wav");
  ASSERT_FALSE(r.ok());
  EXPECT_NE(r.error().find("Cannot open"), std::string::npos);
}

// ── OpenMode::kLenient ──────────────────────────────────────────────────
// Playback, the waveform scan and the UI probe open user files leniently:
// the same damage patterns the strict tests above reject must open, read
// their intact prefix, and report recovered(). Structural damage before
// `data` fails in both modes.

// Writes `bytes`, opens leniently, and returns the Result for the caller
// to assert on.
Result<Reader> OpenLenient(const std::vector<uint8_t>& bytes,
                           const std::string& name) {
  const std::string path = wt::TempDir() + "/" + name + ".wav";
  EXPECT_TRUE(wt::WriteBytes(path, bytes));
  return Reader::Open(path, OpenMode::kLenient);
}

uint64_t CountReadableFrames(Reader& r) {
  std::vector<std::vector<float>> out;
  auto n = r.ReadPlanarFloat(0, r.info().num_frames + 16, out);
  EXPECT_TRUE(n.ok()) << n.error();
  return n.ok() ? *n : 0;
}

TEST(ReaderLenient, IntactFileDoesNotReportRecovery) {
  auto r = OpenLenient(wt::BuildFixture(DefaultSpec()).bytes, "lenient_clean");
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_FALSE(r->recovered());
  EXPECT_EQ(r->info().num_frames, 48u);
  EXPECT_EQ(CountReadableFrames(*r), 48u);
}

TEST(ReaderLenient, TruncatedDataPayloadClampsToWholeFrames) {
  // Interrupted recording / partial copy: 48 frames declared, 2.5 frames
  // (10 bytes of 4-byte frames) on disk. The prefix reads; the dangling
  // half frame is dropped.
  auto f = wt::BuildFixture(DefaultSpec());
  f.bytes.resize(f.data_payload_offset + 10);
  auto r = OpenLenient(f.bytes, "lenient_truncated_data");
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_TRUE(r->recovered());
  EXPECT_EQ(r->info().num_frames, 2u);
  EXPECT_EQ(CountReadableFrames(*r), 2u);
}

TEST(ReaderLenient, PartialTrailingFrameIsFloored) {
  // Declared size 2 bytes short of a whole frame: 47 whole frames stay.
  auto f = wt::BuildFixture(DefaultSpec());
  wtf::PutU32At(f.bytes, f.data_size_field_offset, 48 * 4 - 2);
  f.bytes.resize(f.data_payload_offset + 48 * 4 - 2);
  auto r = OpenLenient(f.bytes, "lenient_partial_frame");
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_TRUE(r->recovered());
  EXPECT_EQ(r->info().num_frames, 47u);
  EXPECT_EQ(CountReadableFrames(*r), 47u);
}

TEST(ReaderLenient, TrailingGarbageBytesAreIgnored) {
  auto f = wt::BuildFixture(DefaultSpec());
  f.bytes.push_back(0xDE);
  f.bytes.push_back(0xAD);
  f.bytes.push_back(0x11);
  auto r = OpenLenient(f.bytes, "lenient_trailing_garbage");
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_TRUE(r->recovered());
  EXPECT_EQ(r->info().num_frames, 48u);
  EXPECT_EQ(CountReadableFrames(*r), 48u);
}

TEST(ReaderLenient, MalformedTailChunkEndsWalk) {
  // A tail chunk declaring 4096 bytes with 4 present (truncated final
  // metadata chunk): the walk stops, `data` and the inventory before the
  // bad chunk survive.
  auto f = wt::BuildFixture(DefaultSpec());
  wtf::AppendId(f.bytes, "LIST");
  wtf::AppendU32(f.bytes, 4096);
  wtf::AppendU32(f.bytes, 0);  // 4 of 4096 payload bytes present
  auto r = OpenLenient(f.bytes, "lenient_bad_tail_chunk");
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_TRUE(r->recovered());
  EXPECT_EQ(r->info().num_frames, 48u);
  EXPECT_EQ(CountReadableFrames(*r), 48u);
}

TEST(ReaderLenient, RiffUnknownSizeDataReadsToEof) {
  // Non-seekable streaming writers leave the 0xFFFFFFFF placeholder
  // unpatched; the payload is the rest of the file.
  auto f = wt::BuildFixture(DefaultSpec());
  wtf::PutU32At(f.bytes, f.data_size_field_offset, 0xFFFFFFFFu);
  auto r = OpenLenient(f.bytes, "lenient_riff_unknown_size");
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_TRUE(r->recovered());
  EXPECT_EQ(r->info().num_frames, 48u);
  EXPECT_EQ(CountReadableFrames(*r), 48u);
}

TEST(ReaderLenient, DataHeaderAtExactEofIsZeroFrames) {
  // The degenerate clamp: the `data` header is the last thing in the
  // file, so 0 bytes remain. A 0-frame recovered open, not a crash and
  // not an error — downstream consumers handle 0-frame files.
  auto f = wt::BuildFixture(DefaultSpec());
  f.bytes.resize(f.data_payload_offset);
  auto r = OpenLenient(f.bytes, "lenient_data_at_eof");
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_TRUE(r->recovered());
  EXPECT_EQ(r->info().num_frames, 0u);
  EXPECT_EQ(CountReadableFrames(*r), 0u);
}

TEST(ReaderLenient, SizeRecoveryIsRiffOnly) {
  // Truncated `data` and unknown-size `data` do NOT recover in the
  // 64-bit containers: absorbing "the rest of the file" there would
  // swallow trailing ADM metadata and return it as audio. A damaged
  // BW64/RF64 master must fail loudly, not import as a longer plain
  // WAV.
  for (const Container c : {Container::kRf64, Container::kBw64}) {
    auto spec = DefaultSpec();
    spec.container = c;
    auto f = wt::BuildFixture(spec);
    f.bytes.resize(f.data_payload_offset + 10);  // truncated payload
    EXPECT_FALSE(OpenLenient(f.bytes, "lenient_64_truncated").ok());
  }

  // A ds64-declared size larger than the file fails too (the ds64
  // lied; there is no trustworthy payload length). The ds64 payload
  // starts 4 bytes past its size field; dataSize is 8 bytes in.
  auto spec = DefaultSpec();
  spec.container = Container::kRf64;
  auto f = wt::BuildFixture(spec);
  wtf::PutU64At(f.bytes, f.ds64_size_field_offset + 4 + 8, uint64_t{1} << 40);
  wtf::PutU32At(f.bytes, f.data_size_field_offset, 0xFFFFFFFFu);
  EXPECT_FALSE(OpenLenient(f.bytes, "lenient_ds64_lies").ok());
}

TEST(ReaderLenient, DroppedAdmChunkIsFlagged) {
  // A BW64 whose `axml` sits after `data` (the streaming-writer layout)
  // and is truncated: the lenient walk-stop keeps the audio but must
  // flag the metadata loss, so ADM detection can refuse to treat the
  // file as a plain WAV.
  auto spec = DefaultSpec();
  spec.container = Container::kBw64;
  auto f = wt::BuildFixture(spec);
  wtf::AppendId(f.bytes, "axml");
  wtf::AppendU32(f.bytes, 64);  // declares 64 bytes...
  f.bytes.push_back('<');       // ...one present
  auto r = OpenLenient(f.bytes, "lenient_dropped_axml");
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_TRUE(r->recovered());
  EXPECT_TRUE(r->metadata_dropped());
  EXPECT_TRUE(r->axml().empty());  // no zero-padded partial payload
  EXPECT_EQ(r->info().num_frames, 48u);
  EXPECT_EQ(CountReadableFrames(*r), 48u);

  // A non-metadata tail chunk does not raise the flag.
  f = wt::BuildFixture(DefaultSpec());
  wtf::AppendId(f.bytes, "LIST");
  wtf::AppendU32(f.bytes, 4096);
  wtf::AppendU32(f.bytes, 0);
  auto r2 = OpenLenient(f.bytes, "lenient_dropped_list");
  ASSERT_TRUE(r2.ok()) << r2.error();
  EXPECT_TRUE(r2->recovered());
  EXPECT_FALSE(r2->metadata_dropped());
}

TEST(ReaderLenient, PreDataDamageStillFails) {
  // Leniency covers the payload and the tail, never the header: without
  // a trustworthy `fmt ` there is nothing to salvage.
  auto f = wt::BuildFixture(DefaultSpec());
  auto bytes = f.bytes;
  const size_t payload = f.fmt_size_field_offset + 4;
  wtf::PutU16At(bytes, payload + 2, 0);  // zero channels
  EXPECT_FALSE(OpenLenient(bytes, "lenient_zero_channels").ok());

  bytes = f.bytes;
  wtf::PutU32At(bytes, f.fmt_size_field_offset, 8);  // truncated fmt
  EXPECT_FALSE(OpenLenient(bytes, "lenient_short_fmt").ok());

  bytes = f.bytes;
  bytes.resize(12);  // header only, no fmt/data at all
  EXPECT_FALSE(OpenLenient(bytes, "lenient_header_only").ok());
}

}  // namespace
}  // namespace wav
