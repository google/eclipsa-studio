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

// Tests for the log ring: engine_log() and engine_log_rt() stage
// messages lock-free; eclipsa_studio_rt_log_drain() forwards them through the
// registered callback — the same pipeline that feeds the JSONL log
// file in the app. The drain is the only place the callback fires:
// invoking it from the logging thread aborts the process when that
// thread belongs to another isolate group (the video pop-out crash).

#include "engine_log.h"

#include <cstdlib>
#include <cstring>
#include <string>

#ifndef _WIN32
#include <unistd.h>
#endif
#include <vector>

#include "gtest/gtest.h"

namespace {

struct Captured {
  EclipsaStudioLogLevel level;
  std::string category;
  std::string message;
};

// The callback contract mirrors the Dart side: the strings are
// heap-allocated by the drain and owned by the callee.
std::vector<Captured>& captured() {
  static std::vector<Captured> entries;
  return entries;
}

void capture_callback(EclipsaStudioLogLevel level, const char* category,
                      const char* message) {
  captured().push_back({level, category, message});
  free(const_cast<char*>(category));
  free(const_cast<char*>(message));
}

// Must match kLogRingCapacity in engine_log.cc.
constexpr int kRingCapacity = 512;

class RtLogRingTest : public ::testing::Test {
 protected:
  void SetUp() override {
    // Flush anything staged by a previous test, then start clean.
    eclipsa_studio_set_log_callback(capture_callback);
    eclipsa_studio_rt_log_drain();
    captured().clear();
  }
  void TearDown() override { eclipsa_studio_set_log_callback(nullptr); }
};

TEST_F(RtLogRingTest, DrainForwardsStagedMessagesInOrder) {
  engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "oar", "first");
  engine_log_rt(ECLIPSA_STUDIO_LOG_DEBUG, "audio", "second");
  engine_log_rt(ECLIPSA_STUDIO_LOG_ERROR, "oar", "third");
  EXPECT_TRUE(captured().empty());  // nothing forwarded before drain

  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 3u);
  EXPECT_EQ(captured()[0].level, ECLIPSA_STUDIO_LOG_WARN);
  EXPECT_EQ(captured()[0].category, "oar");
  EXPECT_EQ(captured()[0].message, "first");
  EXPECT_EQ(captured()[1].level, ECLIPSA_STUDIO_LOG_DEBUG);
  EXPECT_EQ(captured()[1].category, "audio");
  EXPECT_EQ(captured()[1].message, "second");
  EXPECT_EQ(captured()[2].level, ECLIPSA_STUDIO_LOG_ERROR);
  EXPECT_EQ(captured()[2].message, "third");
}

TEST_F(RtLogRingTest, EngineLogIsStagedUntilDrainNotDeliveredInline) {
  // engine_log() must never invoke the callback on the logging thread —
  // it stages to the ring like engine_log_rt() and the drain delivers.
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "video", "staged control-plane message");
  EXPECT_TRUE(captured().empty());

  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 1u);
  EXPECT_EQ(captured()[0].level, ECLIPSA_STUDIO_LOG_INFO);
  EXPECT_EQ(captured()[0].category, "video");
  EXPECT_EQ(captured()[0].message, "staged control-plane message");
}

TEST_F(RtLogRingTest, EngineLogAndRtVariantShareOneOrderedRing) {
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", "first");
  engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "audio", "second");
  engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "engine", "third");

  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 3u);
  EXPECT_EQ(captured()[0].message, "first");
  EXPECT_EQ(captured()[1].message, "second");
  EXPECT_EQ(captured()[2].message, "third");
}

TEST_F(RtLogRingTest, DrainIsIdempotentWhenEmpty) {
  eclipsa_studio_rt_log_drain();
  eclipsa_studio_rt_log_drain();
  EXPECT_TRUE(captured().empty());
}

TEST_F(RtLogRingTest, MessagesSurviveUntilCallbackRegisters) {
  // Early-startup messages must not be lost: drain is a no-op while no
  // callback is registered, so entries stay staged.
  eclipsa_studio_set_log_callback(nullptr);
  engine_log_rt(ECLIPSA_STUDIO_LOG_INFO, "audio", "early message");
  eclipsa_studio_rt_log_drain();
  EXPECT_TRUE(captured().empty());

  eclipsa_studio_set_log_callback(capture_callback);
  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 1u);
  EXPECT_EQ(captured()[0].message, "early message");
}

TEST_F(RtLogRingTest, OverflowDropsNewestAndReportsCount) {
  for (int i = 0; i < kRingCapacity + 10; ++i) {
    char msg[32];
    snprintf(msg, sizeof(msg), "msg %d", i);
    engine_log_rt(ECLIPSA_STUDIO_LOG_DEBUG, "audio", msg);
  }
  eclipsa_studio_rt_log_drain();

  // Capacity entries survive, plus one synthesized overflow warning.
  ASSERT_EQ(captured().size(), static_cast<size_t>(kRingCapacity) + 1);
  EXPECT_EQ(captured().front().message, "msg 0");
  const Captured& report = captured().back();
  EXPECT_EQ(report.level, ECLIPSA_STUDIO_LOG_WARN);
  EXPECT_NE(report.message.find("10 message(s) dropped"), std::string::npos)
      << report.message;

  // The drop counter resets on drain: the ring works normally again.
  captured().clear();
  engine_log_rt(ECLIPSA_STUDIO_LOG_INFO, "audio", "after overflow");
  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 1u);
  EXPECT_EQ(captured()[0].message, "after overflow");
}

#ifndef _WIN32
// Captures what is written to fd 2 while `fn` runs: the fallback path
// uses write(STDERR_FILENO), so a pipe spliced in as fd 2 sees it.
template <typename Fn>
std::string CaptureStderr(Fn&& fn) {
  int fds[2];
  if (pipe(fds) != 0) return "pipe() failed";
  const int saved = dup(STDERR_FILENO);
  dup2(fds[1], STDERR_FILENO);
  close(fds[1]);
  fn();
  dup2(saved, STDERR_FILENO);
  close(saved);
  std::string out;
  char buf[4096];
  for (;;) {
    const ssize_t n = read(fds[0], buf, sizeof(buf));
    if (n <= 0) break;
    out.append(buf, static_cast<size_t>(n));
  }
  close(fds[0]);
  return out;
}

TEST_F(RtLogRingTest, DroppedWarningsAndErrorsFallBackToStderr) {
  // A control-thread storm: engine_log() has no stderr path of its own,
  // so once the ring is full the WARN and ERROR entries it drops go to
  // stderr, and the DEBUG and INFO ones are counted only (ES-270).
  const std::string err = CaptureStderr([] {
    for (int i = 0; i < kRingCapacity; ++i) {
      engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "graph", "fill");
    }
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "graph", "dropped debug");
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "graph", "dropped info");
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "graph", "dropped warn");
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "graph", "dropped error");
  });
  EXPECT_EQ(err.find("dropped debug"), std::string::npos) << err;
  EXPECT_EQ(err.find("dropped info"), std::string::npos) << err;
  EXPECT_NE(err.find("[WARN] [graph] dropped warn"), std::string::npos) << err;
  EXPECT_NE(err.find("[ERROR] [graph] dropped error"), std::string::npos)
      << err;

  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), static_cast<size_t>(kRingCapacity) + 1);
  EXPECT_NE(captured().back().message.find("4 message(s) dropped"),
            std::string::npos)
      << captured().back().message;

  // Within capacity nothing reaches stderr from engine_log().
  captured().clear();
  const std::string quiet = CaptureStderr(
      [] { engine_log(ECLIPSA_STUDIO_LOG_ERROR, "graph", "staged error"); });
  EXPECT_TRUE(quiet.empty()) << quiet;
  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 1u);
  EXPECT_EQ(captured()[0].message, "staged error");
}
#endif  // _WIN32

TEST_F(RtLogRingTest, LongMessagesAreTruncatedNotDropped) {
  // Longer than the 512-byte ring slot.
  const std::string long_msg(600, 'x');
  engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "a-category-name-longer-than-the-slot",
                long_msg.c_str());
  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 1u);
  EXPECT_GT(captured()[0].message.size(), 0u);
  EXPECT_LT(captured()[0].message.size(), long_msg.size());
  EXPECT_EQ(captured()[0].message.find_first_not_of('x'), std::string::npos);
  EXPECT_LT(captured()[0].category.size(), 16u);
}

// ── engine_log_lines ────────────────────────────────────────────────

// The messages of all captured entries, joined without a separator.
std::string JoinedMessages() {
  std::string joined;
  for (const Captured& entry : captured()) joined += entry.message;
  return joined;
}

TEST_F(RtLogRingTest, LinesAreStagedOneEntryEachWithoutEmptyLines) {
  engine_log_lines(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
                   "first\nsecond\r\n\r\n\nthird\n");
  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 3u);
  EXPECT_EQ(captured()[0].message, "first");
  EXPECT_EQ(captured()[1].message, "second");
  EXPECT_EQ(captured()[2].message, "third");
  for (const Captured& entry : captured()) {
    EXPECT_EQ(entry.level, ECLIPSA_STUDIO_LOG_ERROR);
    EXPECT_EQ(entry.category, "iamf");
  }
}

TEST_F(RtLogRingTest, LongLineIsStagedWholeInSlotSizedChunks) {
  std::string line;
  for (int i = 0; i < 1200; ++i) line += static_cast<char>('a' + i % 26);
  engine_log_lines(ECLIPSA_STUDIO_LOG_ERROR, "iamf", line);
  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 3u);
  EXPECT_EQ(captured()[0].message.size(), 511u);
  EXPECT_EQ(captured()[1].message.size(), 511u);
  EXPECT_EQ(captured()[2].message.size(), 178u);
  EXPECT_EQ(JoinedMessages(), line);
}

// A cut at 511 bytes that falls on any continuation byte of a 2-byte or
// a 4-byte UTF-8 character moves back to the start of that character, so
// every entry is valid UTF-8 (the Dart side decodes each one on its own).
TEST_F(RtLogRingTest, LongLineIsCutAtUtf8CharacterBoundaries) {
  const std::string two_byte = "\xC3\xA9";           // U+00E9
  const std::string four_byte = "\xF0\x9F\x8E\xB5";  // U+1F3B5
  const struct {
    size_t prefix;
    std::string character;
  } cases[] = {
      {510, two_byte}, {510, four_byte}, {509, four_byte}, {508, four_byte}};
  for (const auto& c : cases) {
    SCOPED_TRACE(testing::Message() << c.prefix << " + " << c.character.size());
    captured().clear();
    const std::string line = std::string(c.prefix, 'x') + c.character + "yz";
    engine_log_lines(ECLIPSA_STUDIO_LOG_WARN, "iamf", line);
    eclipsa_studio_rt_log_drain();
    ASSERT_EQ(captured().size(), 2u);
    EXPECT_EQ(captured()[0].message, std::string(c.prefix, 'x'));
    EXPECT_EQ(captured()[1].message, c.character + "yz");
  }
}

// Continuation bytes with no lead byte are not UTF-8. The cut moves back
// at most 3 bytes, so each entry still holds at least 508 of them and no
// byte is lost.
TEST_F(RtLogRingTest, LineOfContinuationBytesIsStagedWhole) {
  const std::string line(600, '\x80');
  engine_log_lines(ECLIPSA_STUDIO_LOG_WARN, "iamf", line);
  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 2u);
  EXPECT_EQ(captured()[0].message.size(), 508u);
  EXPECT_EQ(captured()[1].message.size(), 92u);
  EXPECT_EQ(JoinedMessages(), line);
}

TEST_F(RtLogRingTest, NullStringsAreSafe) {
  engine_log_rt(ECLIPSA_STUDIO_LOG_INFO, nullptr, nullptr);
  eclipsa_studio_rt_log_drain();
  ASSERT_EQ(captured().size(), 1u);
  EXPECT_EQ(captured()[0].category, "");
  EXPECT_EQ(captured()[0].message, "");
}

}  // namespace
