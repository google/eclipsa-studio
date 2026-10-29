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

#include "tools/cli_commands.h"

#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include "engine_log.h"
#include "graph/audio_buffer.h"
#include "gtest/gtest.h"
#include "iamf/gpac_system.h"
#include "iamf/iamf_stream_reader.h"
#include "io/wav_reader.h"
#include "mix_renderer/offline_iamf_measurer.h"
#include "test/iamf_test_mux.h"
#include "test/test_wav_helper.h"

// gpac last: its headers poison strcpy/strcat with #error macros, which
// breaks any standard header included after them.
#include <gpac/isomedia.h>

namespace {

using eclipsa_studio::cli::DetectInputKind;
using eclipsa_studio::cli::InputKind;
using eclipsa_studio::cli::RunBounce;
using eclipsa_studio::cli::RunCatchingExceptions;
using eclipsa_studio::cli::RunCli;
using eclipsa_studio::cli::RunEncode;
using eclipsa_studio::cli::RunMeasure;
using eclipsa_studio::cli::RunProbe;

std::string FixturePath(const char* name) {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir == nullptr) srcdir = ".";
  const std::string candidates[] = {
      std::string(srcdir) + "/_main/test/fixtures/" + name,
      std::string(srcdir) + "/_main/engine/test/fixtures/" + name,
      std::string("test/fixtures/") + name,
  };
  for (const auto& c : candidates) {
    std::ifstream probe(c, std::ios::binary);
    if (probe) return c;
  }
  return {};
}

struct CliRun {
  int rc;
  std::string out;
  std::string err;
};

CliRun RunCmd(int (*cmd)(const std::vector<std::string>&, std::ostream&,
                         std::ostream&),
              const std::vector<std::string>& args) {
  std::ostringstream out, err;
  const int rc = cmd(args, out, err);
  return {rc, out.str(), err.str()};
}

// Runs the top-level dispatcher on `args` (argv after the program name).
CliRun RunCliArgs(const std::vector<std::string>& args) {
  std::vector<const char*> argv = {"eclipsa_studio_cli"};
  for (const std::string& a : args) argv.push_back(a.c_str());
  std::ostringstream out, err;
  const int rc = RunCli(static_cast<int>(argv.size()), argv.data(), out, err);
  return {rc, out.str(), err.str()};
}

// A fresh directory named after the running test plus `suffix`.
std::string TestDir(const std::string& suffix) {
  const std::string dir =
      test_wav::temp_dir() + "/" +
      ::testing::UnitTest::GetInstance()->current_test_info()->name() + "_" +
      suffix;
  std::filesystem::remove_all(dir);
  std::filesystem::create_directories(dir);
  return dir;
}

// Sorted names of the entries in `dir`, hidden ones included.
std::vector<std::string> DirEntries(const std::string& dir) {
  std::vector<std::string> names;
  for (const auto& entry : std::filesystem::directory_iterator(dir)) {
    names.push_back(entry.path().filename().string());
  }
  std::sort(names.begin(), names.end());
  return names;
}

std::string ReadFile(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(f),
                     std::istreambuf_iterator<char>());
}

void WriteFile(const std::string& path, const std::string& bytes) {
  std::ofstream(path, std::ios::binary) << bytes;
}

// ── dispatch / usage ──────────────────────────────────────────────────────

TEST(CliDispatch, NoArgsPrintsUsage) {
  std::ostringstream out, err;
  const char* argv[] = {"eclipsa_studio_cli"};
  EXPECT_EQ(RunCli(1, argv, out, err), 1);
  EXPECT_NE(err.str().find("usage:"), std::string::npos);
  EXPECT_TRUE(out.str().empty());
}

TEST(CliDispatch, HelpPrintsUsageToStdout) {
  for (const char* flag : {"--help", "-h", "help"}) {
    SCOPED_TRACE(flag);
    const CliRun r = RunCliArgs({flag});
    EXPECT_EQ(r.rc, 0);
    EXPECT_TRUE(r.err.empty()) << r.err;
    EXPECT_EQ(r.out.rfind("usage: eclipsa_studio_cli", 0), 0u) << r.out;
    EXPECT_NE(r.out.find("measure  <file> --layout <name>"), std::string::npos);
    EXPECT_NE(r.out.find("--out <file.iamf|file.mp4>"), std::string::npos);
    EXPECT_NE(r.out.find("[--video V.mp4|V.mov]"), std::string::npos);
    EXPECT_NE(r.out.find("--out-dir O"), std::string::npos);
    EXPECT_NE(r.out.find("probe    <file.iamf|file.mp4> [--json]"),
              std::string::npos);
    EXPECT_NE(r.out.find("measure-iamf is an old name of measure."),
              std::string::npos);
  }
}

TEST(CliDispatch, UnknownSubcommandFails) {
  std::ostringstream out, err;
  const char* argv[] = {"eclipsa_studio_cli", "frobnicate"};
  EXPECT_EQ(RunCli(2, argv, out, err), 1);
  EXPECT_NE(err.str().find("unknown subcommand"), std::string::npos);
}

// The engine log ring is process-wide, so it can hold entries from
// before the command, here from the test itself. RunCli prints only the
// entries its command logged: bounce of a missing file logs one.
TEST(CliDispatch, PrintsOnlyTheEngineLogOfTheCommand) {
  engine_log(ECLIPSA_STUDIO_LOG_ERROR, "test", "staged before the command");
  const std::string dir = TestDir("out");
  const CliRun r =
      RunCliArgs({"bounce", dir + "/missing.wav", dir + "/out.wav"});
  EXPECT_EQ(r.rc, 2);
  EXPECT_EQ(r.err.find("staged before the command"), std::string::npos)
      << r.err;
  EXPECT_NE(r.err.find("engine error [bounce]: "), std::string::npos) << r.err;
}

// --help or -h after a subcommand prints that subcommand's usage to
// stdout, wherever it stands among the arguments; measure-iamf prints the
// usage of measure.
TEST(CliDispatch, SubcommandHelpPrintsItsUsage) {
  const std::pair<const char*, const char*> cases[] = {
      {"bounce", "usage: eclipsa_studio_cli bounce <in.wav>"},
      {"measure", "usage: eclipsa_studio_cli measure <file>"},
      {"measure-iamf", "usage: eclipsa_studio_cli measure <file>"},
      {"encode", "usage: eclipsa_studio_cli encode <config.textproto>"},
      {"probe", "usage: eclipsa_studio_cli probe <file.iamf|file.mp4>"},
  };
  for (const auto& [cmd, usage] : cases) {
    for (const std::vector<std::string>& args :
         {std::vector<std::string>{cmd, "--help"},
          std::vector<std::string>{cmd, "-h"},
          std::vector<std::string>{cmd, "some.file", "--help"}}) {
      SCOPED_TRACE(args[0] + " " + args.back());
      const CliRun r = RunCliArgs(args);
      EXPECT_EQ(r.rc, 0);
      EXPECT_TRUE(r.err.empty()) << r.err;
      EXPECT_EQ(r.out.rfind(usage, 0), 0u) << r.out;
    }
  }
}

// An exception thrown out of a subcommand is reported with exit code 2
// after the stack unwinds, so a scratch directory's destructor runs. No
// subcommand input throws on every platform (a Windows path conversion
// does), so the guard is driven directly.
TEST(CliDispatch, ExceptionIsReportedAfterUnwinding) {
  struct SetOnDestruction {
    bool* flag;
    ~SetOnDestruction() { *flag = true; }
  };
  bool destroyed = false;
  std::ostringstream err;
  const int rc = RunCatchingExceptions(
      [&destroyed]() -> int {
        const SetOnDestruction guard{&destroyed};
        throw std::system_error(
            std::make_error_code(std::errc::illegal_byte_sequence),
            "path conversion");
      },
      err);
  EXPECT_EQ(rc, 2);
  EXPECT_TRUE(destroyed);
  EXPECT_EQ(err.str().rfind("error: path conversion", 0), 0u) << err.str();

  std::ostringstream quiet;
  EXPECT_EQ(RunCatchingExceptions([] { return 1; }, quiet), 1);
  EXPECT_TRUE(quiet.str().empty());
}

// ── input kind ────────────────────────────────────────────────────────────

// The kind comes from the first 12 bytes, never the extension: a WAV
// named .iamf is a WAV, and a RIFF file of another form type is not.
TEST(CliInputKind, DetectsWavByContent) {
  const std::string dir = TestDir("files");
  const std::string wav_named_iamf = dir + "/mix.iamf";
  ASSERT_TRUE(test_wav::write_sine(wav_named_iamf, 2, 48000, 16, 440.f, 0.1f));
  EXPECT_EQ(DetectInputKind(wav_named_iamf), InputKind::kWav);

  const std::string size_and_pad("\xff\xff\xff\xff", 4);
  WriteFile(dir + "/rf64.bin", "RF64" + size_and_pad + "WAVEds64");
  WriteFile(dir + "/bw64.bin", "BW64" + size_and_pad + "WAVEds64");
  WriteFile(dir + "/avi.wav", "RIFF" + size_and_pad + "AVI LIST");
  WriteFile(dir + "/short.wav", "RIFF");
  EXPECT_EQ(DetectInputKind(dir + "/rf64.bin"), InputKind::kWav);
  EXPECT_EQ(DetectInputKind(dir + "/bw64.bin"), InputKind::kWav);
  EXPECT_EQ(DetectInputKind(dir + "/avi.wav"), InputKind::kOther);
  EXPECT_EQ(DetectInputKind(dir + "/short.wav"), InputKind::kOther);

  const std::string iamf = FixturePath("noise_3s_stereo_opus.iamf");
  ASSERT_FALSE(iamf.empty()) << "fixture missing";
  EXPECT_EQ(DetectInputKind(iamf), InputKind::kOther);
}

TEST(CliInputKind, MissingFileAndDirectoryAreUnreadable) {
  const std::string dir = TestDir("files");
  EXPECT_EQ(DetectInputKind(dir + "/missing.wav"), InputKind::kUnreadable);
  EXPECT_EQ(DetectInputKind(dir), InputKind::kUnreadable);
}

// ── bounce ────────────────────────────────────────────────────────────────

TEST(CliBounce, PassthroughBounceWritesOutput) {
  const std::string dir = test_wav::temp_dir();
  const std::string in = dir + "/cli_in.wav";
  const std::string out_wav = dir + "/cli_out.wav";
  ASSERT_TRUE(test_wav::write_sine(in, 2, 48000, 16, 440.f, 0.25f));

  const CliRun r = RunCmd(RunBounce, {in, out_wav});
  EXPECT_EQ(r.rc, 0) << r.err;
  EXPECT_EQ(r.out, "ok\n");

  WavReader reader;
  ASSERT_TRUE(reader.open(out_wav.c_str()));
  EXPECT_EQ(reader.channels(), 2u);
  EXPECT_EQ(reader.total_frames(), 12000u);
}

TEST(CliBounce, RoutingMinusOneSilencesChannel) {
  const std::string dir = test_wav::temp_dir();
  const std::string in = dir + "/cli_route_in.wav";
  const std::string out_wav = dir + "/cli_route_out.wav";
  ASSERT_TRUE(test_wav::write_sine(in, 2, 48000, 16, 440.f, 0.1f));

  const CliRun r = RunCmd(RunBounce, {in, out_wav, "--routing", "-1,1"});
  ASSERT_EQ(r.rc, 0) << r.err;

  WavReader reader;
  ASSERT_TRUE(reader.open(out_wav.c_str()));
  constexpr uint32_t kCap = 1024;
  float storage[2 * kCap] = {};
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = 2;
  buf.capacity_frames = kCap;
  ASSERT_GT(reader.read(buf, kCap), 0u);
  // Channel 0 silenced by routing -1; channel 1 carries the sine.
  bool ch1_nonzero = false;
  for (uint32_t i = 0; i < buf.frames; ++i) {
    EXPECT_EQ(buf.channel(0)[i], 0.0f);
    ch1_nonzero |= buf.channel(1)[i] != 0.0f;
  }
  EXPECT_TRUE(ch1_nonzero);
}

// An output that is the input file would replace the source WAV (ES-850).
// A hard link or a symlink to the input is the same file under another
// name.
TEST(CliBounce, OutputThatIsTheInputIsRejected) {
  const std::string dir = TestDir("files");
  const std::string in = dir + "/in.wav";
  ASSERT_TRUE(test_wav::write_sine(in, 2, 48000, 16, 440.f, 0.25f));
  std::vector<std::string> names = {"in.wav", "link.wav"};
  std::vector<std::string> outputs = {in, dir + "/link.wav"};
  std::error_code ec;
  std::filesystem::create_hard_link(in, outputs[1], ec);
  ASSERT_FALSE(ec) << ec.message();
#ifndef _WIN32
  // Creating a symlink on Windows needs a privilege the test cannot count
  // on.
  outputs.push_back(dir + "/symlink.wav");
  names.push_back("symlink.wav");
  std::filesystem::create_symlink(in, outputs.back(), ec);
  ASSERT_FALSE(ec) << ec.message();
#endif
  const std::string original = ReadFile(in);

  for (const std::string& out_wav : outputs) {
    SCOPED_TRACE(out_wav);
    const CliRun r = RunCmd(RunBounce, {in, out_wav});
    EXPECT_EQ(r.rc, 1);
    EXPECT_NE(r.err.find("error: the output must not be the input file"),
              std::string::npos)
        << r.err;
    EXPECT_TRUE(r.out.empty()) << r.out;
  }
  EXPECT_EQ(ReadFile(in), original);
  EXPECT_EQ(DirEntries(dir), names);
}

TEST(CliBounce, OutputThatIsADirectoryIsRejected) {
  const std::string dir = TestDir("files");
  const std::string in = dir + "/in.wav";
  ASSERT_TRUE(test_wav::write_sine(in, 2, 48000, 16, 440.f, 0.25f));
  const CliRun r = RunCmd(RunBounce, {in, dir});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("error: the output is a directory"), std::string::npos)
      << r.err;
  EXPECT_EQ(DirEntries(dir), (std::vector<std::string>{"in.wav"}));
}

// The bounce writes into a scratch directory and renames the result onto
// the output. The test covers a failed bounce, whose input is missing,
// and a successful one: an existing output is kept by the first and
// replaced by the second, and no scratch directory remains after either.
TEST(CliBounce, ReplacesTheOutputOnlyOnSuccess) {
  const std::string dir = TestDir("files");
  const std::string in = dir + "/in.wav";
  const std::string out_wav = dir + "/out.wav";
  ASSERT_TRUE(test_wav::write_sine(in, 2, 48000, 16, 440.f, 0.25f));
  WriteFile(out_wav, "earlier output");

  const CliRun failed = RunCmd(RunBounce, {dir + "/missing.wav", out_wav});
  EXPECT_EQ(failed.rc, 2);
  EXPECT_EQ(ReadFile(out_wav), "earlier output");
  EXPECT_EQ(DirEntries(dir), (std::vector<std::string>{"in.wav", "out.wav"}));

  const CliRun ok = RunCmd(RunBounce, {in, out_wav});
  ASSERT_EQ(ok.rc, 0) << ok.err;
  WavReader reader;
  ASSERT_TRUE(reader.open(out_wav.c_str()));
  EXPECT_EQ(reader.total_frames(), 12000u);
  EXPECT_EQ(DirEntries(dir), (std::vector<std::string>{"in.wav", "out.wav"}));
}

TEST(CliBounce, MissingInputFails) {
  const CliRun r =
      RunCmd(RunBounce, {"/no/such/input.wav", "/tmp/never_written.wav"});
  EXPECT_EQ(r.rc, 2);
  EXPECT_NE(r.err.find("failed to open input"), std::string::npos);
}

TEST(CliBounce, BadFlagValueFails) {
  const CliRun r = RunCmd(RunBounce, {"a.wav", "b.wav", "--gain-db", "loud"});
  EXPECT_EQ(r.rc, 1);
}

// A numeric flag value must be a number in full: a gain must be finite,
// and an unsigned value must not carry a sign that std::stoull would
// wrap, or exceed the field it fills. Every case names a missing input,
// which returns 2 when the open runs first.
TEST(CliBounce, MalformedNumericFlagsFail) {
  const std::pair<const char*, const char*> bad_flags[] = {
      {"--gain-db", "3dB"},
      {"--gain-db", "nan"},
      {"--gain-db", "-inf"},
      {"--gain-db", " -6"},
      {"--gain-db", ""},
      {"--pad-frames", "-1"},
      {"--pad-frames", "+5"},
      {"--pad-frames", "10x"},
      {"--pad-frames", " 10"},
      {"--pad-frames", ""},
      {"--pad-frames", "18446744073709551616"},
      {"--rate", "-48000"},
      {"--rate", "48k"},
      {"--rate", "4294967296"},
  };
  for (const auto& [flag, value] : bad_flags) {
    SCOPED_TRACE(std::string(flag) + " '" + value + "'");
    const CliRun r = RunCmd(RunBounce, {"/no/such/input.wav",
                                        "/tmp/never_written.wav", flag, value});
    EXPECT_EQ(r.rc, 1);
    EXPECT_NE(r.err.find(std::string("bad ") + flag + " value"),
              std::string::npos)
        << r.err;
  }
}

// Well-formed values reach the bounce, which then fails on the missing
// input.
TEST(CliBounce, WellFormedNumericFlagsAreAccepted) {
  const CliRun r =
      RunCmd(RunBounce, {"/no/such/input.wav", "/tmp/never_written.wav",
                         "--gain-db", "-6.5", "--pad-frames",
                         "18446744073709551615", "--rate", "4294967295"});
  EXPECT_EQ(r.rc, 2) << r.err;
  EXPECT_NE(r.err.find("failed to open input"), std::string::npos) << r.err;
}

// Typo'd flags must be rejected, not silently swallow the next token.
TEST(CliBounce, UnknownFlagFails) {
  const CliRun r = RunCmd(RunBounce, {"a.wav", "b.wav", "--gaindb", "-6"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("unknown flag --gaindb"), std::string::npos);
}

// A value flag followed by another flag has no value. The next flag
// must not become its value, which for --render-wav would write a file
// named --no-limiter and measure with the limiter on.
TEST(CliBounce, ValueFlagFollowedByAFlagFails) {
  const CliRun r =
      RunCmd(RunBounce, {"/no/such/input.wav", "/tmp/never_written.wav",
                         "--rate", "--gain-db", "-6"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("--rate expects a value"), std::string::npos) << r.err;
}

TEST(CliMeasure, ValueFlagFollowedByAFlagFails) {
  const CliRun r =
      RunCmd(RunMeasure, {"/no/such/input.iamf", "--layout", "stereo",
                          "--render-wav", "--no-limiter"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("--render-wav expects a value"), std::string::npos)
      << r.err;
}

TEST(CliProbe, UnknownFlagDoesNotSwallowPositional) {
  const CliRun r = RunCmd(RunProbe, {"--bogus", "file.iamf"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("unknown flag --bogus"), std::string::npos);
}

// ── measure ───────────────────────────────────────────────────────────────

// The value of the `key=` line in measure output, NAN when it is absent.
float OutputValue(const std::string& out, const std::string& key) {
  std::istringstream lines(out);
  std::string line;
  const std::string prefix = key + "=";
  while (std::getline(lines, line)) {
    if (line.rfind(prefix, 0) == 0) {
      return std::strtof(line.c_str() + prefix.size(), nullptr);
    }
  }
  return NAN;
}

// The keys of the `key=value` lines in measure output, in order.
std::vector<std::string> OutputKeys(const std::string& out) {
  std::vector<std::string> keys;
  std::istringstream lines(out);
  std::string line;
  while (std::getline(lines, line)) {
    keys.push_back(line.substr(0, line.find('=')));
  }
  return keys;
}

// A full-scale 440 Hz sine on both stereo channels: BS.1770 channel
// powers sum, K-weighting at 440 Hz is within ~1 dB of unity, so the
// integrated loudness lands near 0 LUFS (one channel alone would be
// ~-3 LUFS). True/digital peak sit at full scale. Wide tolerances —
// this guards the wiring, not the meter (loudness_meter_test does).
TEST(CliMeasure, FullScaleStereoSineNearZeroLufs) {
  const std::string dir = test_wav::temp_dir();
  const std::string wav = dir + "/cli_measure.wav";
  ASSERT_TRUE(test_wav::write_sine(wav, 2, 48000, 16, 440.f, 1.0f));

  const CliRun r = RunCmd(RunMeasure, {wav, "--layout", "stereo"});
  ASSERT_EQ(r.rc, 0) << r.err;

  float lufs = -999, true_peak = -999, digital_peak = -999;
  std::istringstream lines(r.out);
  std::string line;
  while (std::getline(lines, line)) {
    sscanf(line.c_str(), "integrated_lufs=%f", &lufs);
    sscanf(line.c_str(), "true_peak_dbtp=%f", &true_peak);
    sscanf(line.c_str(), "digital_peak_dbfs=%f", &digital_peak);
  }
  // ±2 dB on all three: OAR's stereo passthrough applies ~-1 dB, so
  // the measured values sit near -1, not 0 — the tolerance covers
  // that plus any small future liboar gain drift.
  EXPECT_NEAR(lufs, 0.0f, 2.0f);
  EXPECT_NEAR(true_peak, 0.0f, 2.0f);
  EXPECT_NEAR(digital_peak, 0.0f, 2.0f);
}

// A WAV input prints the three keys it printed before measure took IAMF
// input, and the old name measure-iamf routes a WAV the same way.
TEST(CliMeasure, WavOutputIsUnchangedUnderBothNames) {
  const std::string dir = TestDir("files");
  const std::string wav = dir + "/mix.wav";
  ASSERT_TRUE(test_wav::write_sine(wav, 2, 48000, 16, 440.f, 1.0f));

  const CliRun r = RunCliArgs({"measure", wav, "--layout", "stereo"});
  ASSERT_EQ(r.rc, 0) << r.err;
  // The measure logs INFO entries, which RunCli does not print.
  EXPECT_TRUE(r.err.empty()) << r.err;
  EXPECT_EQ(OutputKeys(r.out),
            (std::vector<std::string>{"integrated_lufs", "true_peak_dbtp",
                                      "digital_peak_dbfs"}));

  const CliRun old_name =
      RunCliArgs({"measure-iamf", wav, "--layout", "stereo"});
  ASSERT_EQ(old_name.rc, 0) << old_name.err;
  EXPECT_EQ(old_name.out, r.out);

  // The same WAV bytes under an .iamf name take the WAV path.
  const std::string wav_named_iamf = dir + "/mix.iamf";
  std::filesystem::copy_file(wav, wav_named_iamf);
  const CliRun renamed =
      RunCmd(RunMeasure, {wav_named_iamf, "--layout", "stereo"});
  ASSERT_EQ(renamed.rc, 0) << renamed.err;
  EXPECT_EQ(renamed.out, r.out);
}

TEST(CliMeasure, IamfFlagsWithWavAreUsageErrors) {
  const std::string dir = TestDir("files");
  const std::string wav = dir + "/mix.wav";
  ASSERT_TRUE(test_wav::write_sine(wav, 2, 48000, 16, 440.f, 0.1f));

  const CliRun elements =
      RunCmd(RunMeasure, {wav, "--layout", "stereo", "--elements", "300"});
  EXPECT_EQ(elements.rc, 1);
  EXPECT_NE(elements.err.find("--elements applies to IAMF input only"),
            std::string::npos)
      << elements.err;
  EXPECT_TRUE(elements.out.empty());

  const CliRun gain = RunCmd(
      RunMeasure, {wav, "--layout", "stereo", "--output-gain-db", "-1.5"});
  EXPECT_EQ(gain.rc, 1);
  EXPECT_NE(gain.err.find("--output-gain-db applies to IAMF input only"),
            std::string::npos)
      << gain.err;
  EXPECT_TRUE(gain.out.empty());

  const std::vector<std::vector<std::string>> outputs = {
      {"--trace-json", dir + "/trace.json"},
      {"--render-wav", dir + "/render.wav"}};
  for (const auto& extra : outputs) {
    std::vector<std::string> args = {wav, "--layout", "stereo"};
    args.insert(args.end(), extra.begin(), extra.end());
    const CliRun r = RunCmd(RunMeasure, args);
    EXPECT_EQ(r.rc, 1) << extra[0];
    EXPECT_NE(r.err.find(extra[0] + " applies to IAMF input only"),
              std::string::npos)
        << r.err;
    EXPECT_TRUE(r.out.empty());
  }
  EXPECT_FALSE(std::filesystem::exists(dir + "/trace.json"));
  EXPECT_FALSE(std::filesystem::exists(dir + "/render.wav"));
}

// --no-limiter measures a WAV without OAR's -1 dBFS limiter. A 997 Hz
// float sine peaking at 1.8 (+5.11 dBFS) on both channels reports its
// own sample peak, and its loudness reads 20 dB above the same sine at
// 0.18, which peaks at -14.89 dBFS and leaves the limiter idle. The
// quiet sine measures the same with and without the flag, so the
// limiter delay the flag removes does not change the figures. Without
// the flag the limiter holds the hot sine's peak at -1 dBFS and lowers
// its loudness. The output keeps the three keys of a WAV measure.
TEST(CliMeasure, NoLimiterMeasuresTheUnlimitedWav) {
  constexpr int kRate = 48000;
  constexpr int kFrames = 2 * kRate;
  constexpr double kPi = 3.14159265358979323846;
  const auto sine = [](float amplitude) {
    std::vector<float> samples(kFrames);
    for (int i = 0; i < kFrames; ++i) {
      samples[i] =
          amplitude *
          static_cast<float>(std::sin(2.0 * kPi * 997.0 * i / double{kRate}));
    }
    return samples;
  };
  const auto peak_dbfs = [](const std::vector<float>& samples) {
    float peak = 0.0f;
    for (const float s : samples) peak = std::max(peak, std::fabs(s));
    return 20.0f * std::log10(peak);
  };
  const std::vector<float> hot_samples = sine(1.8f);
  const std::vector<float> quiet_samples = sine(0.18f);
  const std::string dir = TestDir("wavs");
  const std::string hot = dir + "/hot.wav";
  const std::string quiet = dir + "/quiet.wav";
  ASSERT_TRUE(test_wav::write_float32_frames(hot, 2, kRate, hot_samples));
  ASSERT_TRUE(test_wav::write_float32_frames(quiet, 2, kRate, quiet_samples));

  const CliRun unlimited =
      RunCmd(RunMeasure, {hot, "--layout", "stereo", "--no-limiter"});
  ASSERT_EQ(unlimited.rc, 0) << unlimited.err;
  const CliRun limited = RunCmd(RunMeasure, {hot, "--layout", "stereo"});
  ASSERT_EQ(limited.rc, 0) << limited.err;
  const CliRun quiet_on = RunCmd(RunMeasure, {quiet, "--layout", "stereo"});
  ASSERT_EQ(quiet_on.rc, 0) << quiet_on.err;
  const CliRun quiet_off =
      RunCmd(RunMeasure, {quiet, "--layout", "stereo", "--no-limiter"});
  ASSERT_EQ(quiet_off.rc, 0) << quiet_off.err;

  EXPECT_EQ(OutputKeys(unlimited.out),
            (std::vector<std::string>{"integrated_lufs", "true_peak_dbtp",
                                      "digital_peak_dbfs"}));
  // The output prints two decimals.
  EXPECT_NEAR(OutputValue(unlimited.out, "digital_peak_dbfs"),
              peak_dbfs(hot_samples), 0.011f)
      << unlimited.out;
  EXPECT_NEAR(OutputValue(unlimited.out, "integrated_lufs"),
              OutputValue(quiet_on.out, "integrated_lufs") + 20.0f, 0.03f)
      << unlimited.out << quiet_on.out;
  EXPECT_NEAR(OutputValue(quiet_on.out, "digital_peak_dbfs"),
              peak_dbfs(quiet_samples), 0.011f)
      << quiet_on.out;
  for (const char* key :
       {"integrated_lufs", "true_peak_dbtp", "digital_peak_dbfs"}) {
    EXPECT_NEAR(OutputValue(quiet_off.out, key), OutputValue(quiet_on.out, key),
                0.011f)
        << key;
  }

  EXPECT_LE(OutputValue(limited.out, "digital_peak_dbfs"), -0.99f)
      << limited.out;
  EXPECT_GT(OutputValue(limited.out, "digital_peak_dbfs"), -3.0f)
      << limited.out;
  EXPECT_LT(OutputValue(limited.out, "integrated_lufs"),
            OutputValue(unlimited.out, "integrated_lufs") - 1.0f)
      << limited.out << unlimited.out;
}

// A file that is neither a WAV nor readable as IAMF names both attempts.
TEST(CliMeasure, NeitherWavNorIamfFails) {
  const std::string path = TestDir("files") + "/notes.txt";
  WriteFile(path, "not audio of any kind");
  const CliRun r = RunCmd(RunMeasure, {path, "--layout", "stereo"});
  EXPECT_EQ(r.rc, 2);
  EXPECT_NE(r.err.find(path + " is not a WAV file, and reading it as IAMF "
                              "failed: "),
            std::string::npos)
      << r.err;
}

TEST(CliMeasure, UnreadableInputFails) {
  const std::string dir = TestDir("files");
  const CliRun r = RunCmd(RunMeasure, {dir, "--layout", "stereo"});
  EXPECT_EQ(r.rc, 2);
  EXPECT_NE(r.err.find("cannot read input file"), std::string::npos) << r.err;
}

TEST(CliMeasure, ChannelCountMismatchFails) {
  const std::string dir = test_wav::temp_dir();
  const std::string wav = dir + "/cli_measure_mono.wav";
  ASSERT_TRUE(test_wav::write_sine(wav, 1, 48000, 16, 440.f, 0.1f));

  const CliRun r = RunCmd(RunMeasure, {wav, "--layout", "5.1"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("channels"), std::string::npos);
}

// A 9.1.6 WAV is read in the alt order unless --channel-order iamf
// names the bitstream order (ES-960). A tone on WAV channel 0 is FLc in
// the alt order (BS.1770 weight 1.0) and FL in the IAMF order (weight
// 1.41), so the two readings sit 1.49 LU apart, as in
// mix_renderer_ffi_test.cc.
TEST(CliMeasure, ChannelOrderSelectsThe916WavOrder) {
  constexpr int kCh = 16;
  constexpr int kFrames = 2 * 48000;
  std::vector<int16_t> pcm(static_cast<size_t>(kFrames) * kCh, 0);
  for (int i = 0; i < kFrames; ++i) {
    const float t = static_cast<float>(i) / 48000.0f;
    pcm[static_cast<size_t>(i) * kCh] = static_cast<int16_t>(
        std::sin(2.0f * 3.14159265f * 997.0f * t) * 0.25f * 32767.0f);
  }
  const std::string wav = TestDir("wavs") + "/tone916.wav";
  ASSERT_TRUE(test_wav::write_frames_s16(wav, kCh, 48000, pcm));

  const auto lufs = [](const CliRun& r) {
    float value = -999.0f;
    std::istringstream lines(r.out);
    std::string line;
    while (std::getline(lines, line)) {
      sscanf(line.c_str(), "integrated_lufs=%f", &value);
    }
    return value;
  };
  const CliRun by_default = RunCmd(RunMeasure, {wav, "--layout", "9.1.6"});
  ASSERT_EQ(by_default.rc, 0) << by_default.err;
  const CliRun alt =
      RunCmd(RunMeasure, {wav, "--layout", "9.1.6", "--channel-order", "alt"});
  ASSERT_EQ(alt.rc, 0) << alt.err;
  const CliRun iamf =
      RunCmd(RunMeasure, {wav, "--layout", "9.1.6", "--channel-order", "iamf"});
  ASSERT_EQ(iamf.rc, 0) << iamf.err;
  EXPECT_EQ(by_default.out, alt.out);
  EXPECT_GT(lufs(alt), -40.0f);
  EXPECT_NEAR(lufs(iamf) - lufs(alt), 1.49f, 0.1f);

  const CliRun bad =
      RunCmd(RunMeasure, {wav, "--layout", "9.1.6", "--channel-order", "olr"});
  EXPECT_EQ(bad.rc, 1);
  EXPECT_NE(bad.err.find("bad --channel-order value"), std::string::npos);
  const CliRun other =
      RunCmd(RunMeasure, {wav, "--layout", "7.1.4", "--channel-order", "alt"});
  EXPECT_EQ(other.rc, 1);
  EXPECT_NE(other.err.find("9.1.6 layout only"), std::string::npos);
}

TEST(CliMeasure, UnknownLayoutFails) {
  const CliRun r = RunCmd(RunMeasure, {"x.wav", "--layout", "22.2"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("unknown layout"), std::string::npos);
}

// ── probe ─────────────────────────────────────────────────────────────────

TEST(CliProbe, SummarizesFixture) {
  const std::string fixture = FixturePath("tones_100ms_3OA_stereo_opus.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  const CliRun r = RunCmd(RunProbe, {fixture});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_NE(r.out.find("sample_rate=48000"), std::string::npos);
  EXPECT_NE(r.out.find("audio_elements=2"), std::string::npos);
  EXPECT_NE(r.out.find("mix_presentations="), std::string::npos);
}

TEST(CliProbe, JsonOutputIsWellFormedish) {
  const std::string fixture = FixturePath("tones_100ms_3OA_stereo_opus.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  const CliRun r = RunCmd(RunProbe, {fixture, "--json"});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_EQ(r.out.front(), '{');
}

// FLAC carries a usable sample total in its STREAMINFO, so the
// descriptors-only probe can report a duration without a temporal-unit
// scan (unlike Opus, which reports total_samples=0 here).
TEST(CliProbe, FlacStructReportsDescriptorDuration) {
  const std::string fixture = FixturePath("noise_1024samp_stereo_flac.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  const CliRun r = RunCmd(RunProbe, {fixture});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_NE(r.out.find("sample_rate=48000"), std::string::npos);
  EXPECT_NE(r.out.find("total_samples=1024"), std::string::npos);
}

// The FLAC codec config the Dart Inspector parser depends on: it keys
// StreamInfo off block_type_raw == 0 (upstream drops a dedicated
// is_stream_info flag) and reads the descriptors-only total.
TEST(CliProbe, FlacJsonExposesStreamInfo) {
  const std::string fixture = FixturePath("noise_1024samp_stereo_flac.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  const CliRun r = RunCmd(RunProbe, {fixture, "--json"});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_NE(r.out.find("\"codec_id\": \"FLAC\""), std::string::npos);
  EXPECT_NE(r.out.find("\"block_type_raw\": 0"), std::string::npos);
  EXPECT_NE(r.out.find("\"total_samples_in_stream\": 1024"), std::string::npos);
  EXPECT_NE(r.out.find("\"descriptor_total_samples\": 1024"),
            std::string::npos);
}

// An MP4 with an IAMF track, muxed at test time, gives the same text and
// JSON reports as the raw .iamf it was muxed from.
TEST(CliProbe, Mp4MatchesRawIamf) {
  const std::string iamf = FixturePath("tones_100ms_3OA_stereo_opus.iamf");
  ASSERT_FALSE(iamf.empty()) << "fixture missing";
  const std::string mp4 = TestDir("files") + "/tones.mp4";
  ASSERT_TRUE(iamf_test_mux::MuxIamfToMp4(iamf, mp4));

  const CliRun raw_text = RunCmd(RunProbe, {iamf});
  const CliRun mp4_text = RunCmd(RunProbe, {mp4});
  ASSERT_EQ(raw_text.rc, 0) << raw_text.err;
  ASSERT_EQ(mp4_text.rc, 0) << mp4_text.err;
  EXPECT_EQ(mp4_text.out, raw_text.out);

  const CliRun raw_json = RunCmd(RunProbe, {iamf, "--json"});
  const CliRun mp4_json = RunCmd(RunProbe, {mp4, "--json"});
  ASSERT_EQ(raw_json.rc, 0) << raw_json.err;
  ASSERT_EQ(mp4_json.rc, 0) << mp4_json.err;
  EXPECT_EQ(mp4_json.out, raw_json.out);
}

TEST(CliProbe, MissingFileFails) {
  const CliRun r = RunCmd(RunProbe, {"/no/such/file.iamf"});
  EXPECT_EQ(r.rc, 2);
  EXPECT_FALSE(r.err.empty());
}

// ── encode ────────────────────────────────────────────────────────────────

TEST(CliEncode, MissingConfigFails) {
  const CliRun r = RunCmd(RunEncode, {"/no/such/config.textproto", "--wav-dir",
                                      "/tmp", "--out-dir", "/tmp"});
  EXPECT_EQ(r.rc, 2);
  EXPECT_NE(r.err.find("cannot read config"), std::string::npos);
}

TEST(CliEncode, GarbageConfigFailsParse) {
  const std::string dir = test_wav::temp_dir();
  const std::string cfg = dir + "/bad.textproto";
  {
    std::ofstream(cfg) << "this is { not a UserMetadata";
  }
  const CliRun r = RunCmd(RunEncode, {cfg, "--wav-dir", dir, "--out-dir", dir});
  EXPECT_EQ(r.rc, 2);
  EXPECT_NE(r.err.find("rc=-10"), std::string::npos);
}

// A parse error that quotes a 2000-character field name is longer than a
// log ring slot. RunCli prints it in slot-sized engine entries, and the
// entries together hold the whole name (ES-937).
TEST(CliEncode, LongParseErrorIsPrintedWhole) {
  const std::string dir = TestDir("in");
  const std::string field(2000, 'q');
  const std::string cfg = dir + "/long.textproto";
  WriteFile(cfg, field + ": 1\n");
  const CliRun r =
      RunCliArgs({"encode", cfg, "--wav-dir", dir, "--out-dir", dir});
  EXPECT_EQ(r.rc, 2);
  const std::string prefix = "engine error [iamf]: ";
  std::string joined;
  std::istringstream lines(r.err);
  for (std::string line; std::getline(lines, line);) {
    if (line.rfind(prefix, 0) == 0) joined += line.substr(prefix.size());
  }
  EXPECT_NE(joined.find(field), std::string::npos) << r.err;
}

// ── encode round trip (golden textprotos) ────────────────────────────────
//
// The goldens under fixtures/golden/ are produced by the app's
// UserMetadataBuilder (pinned byte-for-byte by
// app/test/export/user_metadata_golden_test.dart). Encoding them through
// the real iamf-tools encoder and probing the result guards the
// app-to-encoder contract: a proto field rename in an iamf-tools pin
// bump, or a builder emitting a field the encoder rejects, fails here
// instead of at user export time.

struct GoldenRoundTrip {
  std::string json;       // probe --json output; empty on failure
  std::string iamf_path;  // encoded file path
};

// Encode a golden config against WAVs staged in a fresh directory and
// probe the encoded file (json empty on any failure, with a gtest
// failure already recorded). Each WAV is `source_frames` long; the
// default, 24576, is 24 LPCM frames of 1024.
GoldenRoundTrip EncodeGoldenAndProbe(
    const char* golden_name, const char* output_name,
    const std::vector<std::pair<std::string, int>>& wavs,
    int source_frames = 24576) {
  const std::string cfg = FixturePath(golden_name);
  EXPECT_FALSE(cfg.empty()) << golden_name << " missing";
  if (cfg.empty()) return {};

  const std::string base =
      test_wav::temp_dir() + "/" +
      ::testing::UnitTest::GetInstance()->current_test_info()->name();
  const std::string wav_dir = base + "_wavs";
  const std::string out_dir = base + "_out";
  std::filesystem::create_directories(wav_dir);
  std::filesystem::create_directories(out_dir);
  for (const auto& [name, channels] : wavs) {
    EXPECT_TRUE(test_wav::write_sine_frames(wav_dir + "/" + name, channels,
                                            48000, 16, 440.f, source_frames));
  }

  const CliRun enc =
      RunCmd(RunEncode, {cfg, "--wav-dir", wav_dir, "--out-dir", out_dir});
  EXPECT_EQ(enc.rc, 0) << enc.err;
  if (enc.rc != 0) return {};

  const std::string iamf = out_dir + "/" + output_name;
  const CliRun probe = RunCmd(RunProbe, {iamf, "--json"});
  EXPECT_EQ(probe.rc, 0) << probe.err;
  if (probe.rc != 0) return {};
  return {probe.out, iamf};
}

// Parse "descriptor_bytes_consumed" out of the probe JSON so the
// position byte search below can stay inside the descriptor OBUs
// (audio-frame PCM could otherwise false-positive a short pattern).
size_t DescriptorBytes(const std::string& json) {
  const char* key = "\"descriptor_bytes_consumed\": ";
  const size_t pos = json.find(key);
  if (pos == std::string::npos) return 0;
  return static_cast<size_t>(
      std::strtoul(json.c_str() + pos + std::strlen(key), nullptr, 10));
}

// Substring of `json` from `from` to `to` (empty `to` = to the end).
// Empty when `from` is missing — assertions on the window then fail
// loudly rather than match the whole document.
std::string Window(const std::string& json, const std::string& from,
                   const std::string& to = {}) {
  const size_t a = json.find(from);
  if (a == std::string::npos) return {};
  if (to.empty()) return json.substr(a);
  const size_t b = json.find(to, a + from.size());
  return json.substr(a, b == std::string::npos ? std::string::npos : b - a);
}

// The first default_mix_gain_q7_8 value after `anchor` inside `window`
// — the probe emits each element's element_mix_gain right after its
// localized annotation, so this ties a gain to a specific element (or,
// with an "output_mix_gain" anchor, to the sub-mix). INT_MIN when
// either is missing.
int GainQ78After(const std::string& window, const std::string& anchor) {
  const size_t a = window.find(anchor);
  if (a == std::string::npos) return INT_MIN;
  const char* key = "\"default_mix_gain_q7_8\": ";
  const size_t g = window.find(key, a);
  if (g == std::string::npos) return INT_MIN;
  return std::atoi(window.c_str() + g + std::strlen(key));
}

// Decodes the first `frames` frames of `iamf_path` with IamfStreamReader
// and returns each channel's absolute peak. Empty, with a gtest failure
// recorded, when the file does not open, decodes to a channel count
// other than `channels`, or holds fewer than `frames` frames.
std::vector<float> DecodedPeaks(const std::string& iamf_path, uint32_t channels,
                                uint32_t frames) {
  IamfStreamReader reader;
  if (!reader.open(iamf_path.c_str())) {
    ADD_FAILURE() << reader.last_error();
    return {};
  }
  if (reader.channels() != channels) {
    ADD_FAILURE() << "decoded " << reader.channels() << " channels, expected "
                  << channels;
    return {};
  }
  std::vector<float> storage(static_cast<size_t>(channels) * frames, 0.0f);
  AudioBuffer buf;
  buf.data = storage.data();
  buf.channels = channels;
  buf.capacity_frames = frames;
  buf.frames = 0;
  if (reader.read(buf, frames) != frames) {
    ADD_FAILURE() << "decoded fewer than " << frames << " frames";
    return {};
  }
  std::vector<float> peaks(channels, 0.0f);
  for (uint32_t c = 0; c < channels; ++c) {
    for (uint32_t f = 0; f < frames; ++f) {
      peaks[c] = std::max(peaks[c], std::fabs(buf.channel(c)[f]));
    }
  }
  return peaks;
}

// ── measure with an IAMF input ────────────────────────────────────────────

// The fixtures under test/fixtures/ are all shorter than the 400 ms
// momentary window, which leaves the integrated value undefined, so the
// positive case encodes the multi_mix golden (24576 frames = 512 ms)
// and measures its "Main" presentation: AE 300 at -3 dB and AE 301 at
// 0 dB, output -1.5 dB.
TEST(CliMeasureIamf, MeasuresEncodedGolden) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.iamf_path.empty());

  const CliRun r =
      RunCmd(RunMeasure, {rt.iamf_path, "--layout", "stereo", "--elements",
                          "300:-3,301", "--output-gain-db", "-1.5"});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_NE(r.out.find("sample_rate=48000"), std::string::npos);
  EXPECT_NE(r.out.find("total_frames=24576"), std::string::npos);

  float lufs = -999, true_peak = -999, digital_peak = -999;
  std::istringstream lines(r.out);
  std::string line;
  while (std::getline(lines, line)) {
    sscanf(line.c_str(), "integrated_lufs=%f", &lufs);
    sscanf(line.c_str(), "true_peak_dbtp=%f", &true_peak);
    sscanf(line.c_str(), "digital_peak_dbfs=%f", &digital_peak);
  }
  // Two full-scale 440 Hz sines summed at -3 dB and 0 dB, output
  // -1.5 dB: hot enough to engage the limiter, so the peaks sit at the
  // -1 dBFS ceiling and the program is far above the silence floor.
  EXPECT_GT(lufs, -20.0f);
  EXPECT_LT(lufs, 0.0f);
  EXPECT_NEAR(digital_peak, -1.0f, 0.2f);
  EXPECT_GE(true_peak, digital_peak - 0.01f);
}

// A WAV read whole into planar channels.
struct PlanarWav {
  uint32_t sample_rate = 0;
  uint32_t bit_depth = 0;
  std::vector<std::vector<float>> channels;
};

// Reads `path` whole; empty channels, with a gtest failure recorded, when
// it does not open or reads short.
PlanarWav ReadPlanarWav(const std::string& path) {
  WavReader reader;
  if (!reader.open(path.c_str())) {
    ADD_FAILURE() << "cannot open " << path;
    return {};
  }
  const uint32_t channels = reader.channels();
  const auto frames = static_cast<uint32_t>(reader.total_frames());
  std::vector<float> storage(static_cast<size_t>(channels) * frames, 0.0f);
  AudioBuffer buf;
  buf.data = storage.data();
  buf.channels = channels;
  buf.capacity_frames = frames;
  buf.frames = 0;
  if (reader.read(buf, frames) != frames) {
    ADD_FAILURE() << "read fewer than " << frames << " frames of " << path;
    return {};
  }
  PlanarWav wav;
  wav.sample_rate = reader.sample_rate();
  wav.bit_depth = reader.bit_depth();
  for (uint32_t c = 0; c < channels; ++c) {
    wav.channels.emplace_back(buf.channel(c), buf.channel(c) + frames);
  }
  return wav;
}

float PeakDbfs(const PlanarWav& wav) {
  float peak = 0.0f;
  for (const auto& channel : wav.channels) {
    for (const float s : channel) peak = std::max(peak, std::fabs(s));
  }
  return 20.0f * std::log10(peak);
}

// The multi_mix golden's "Main" presentation (see MeasuresEncodedGolden)
// at an output gain of -1.5 dB engages the limiter; 20 dB lower, the
// render peaks near -17 dBFS and the limiter stays idle.
using MainFlags = std::array<const char*, 6>;
constexpr MainFlags kHotMain = {"--layout",   "stereo",           "--elements",
                                "300:-3,301", "--output-gain-db", "-1.5"};
constexpr MainFlags kQuietMain = {"--layout",         "stereo",
                                  "--elements",       "300:-3,301",
                                  "--output-gain-db", "-21.5"};

CliRun MeasureWith(const std::string& file, const MainFlags& flags,
                   const std::vector<std::string>& extra = {}) {
  std::vector<std::string> args = {file};
  args.insert(args.end(), flags.begin(), flags.end());
  args.insert(args.end(), extra.begin(), extra.end());
  return RunCmd(RunMeasure, args);
}

// limiter_gr_max_db is positive when the limiter acts and 0 when it
// stays idle.
TEST(CliMeasureIamf, ReportsLimiterGainReduction) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.iamf_path.empty());

  const CliRun hot = MeasureWith(rt.iamf_path, kHotMain);
  ASSERT_EQ(hot.rc, 0) << hot.err;
  EXPECT_NE(hot.out.find("limiter=on\n"), std::string::npos) << hot.out;
  EXPECT_GT(OutputValue(hot.out, "limiter_gr_max_db"), 1.0f) << hot.out;

  const CliRun quiet = MeasureWith(rt.iamf_path, kQuietMain);
  ASSERT_EQ(quiet.rc, 0) << quiet.err;
  EXPECT_NE(quiet.out.find("limiter_gr_max_db=0.00\n"), std::string::npos)
      << quiet.out;
}

// --no-limiter measures the unlimited render: the peaks the limited
// render holds at -1 dBFS go above full scale, and no gain reduction is
// reported.
TEST(CliMeasureIamf, NoLimiterMeasuresTheUnlimitedRender) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.iamf_path.empty());

  const CliRun limited = MeasureWith(rt.iamf_path, kHotMain);
  ASSERT_EQ(limited.rc, 0) << limited.err;
  EXPECT_LE(OutputValue(limited.out, "digital_peak_dbfs"), -0.99f);

  const CliRun unlimited =
      MeasureWith(rt.iamf_path, kHotMain, {"--no-limiter"});
  ASSERT_EQ(unlimited.rc, 0) << unlimited.err;
  EXPECT_NE(unlimited.out.find("limiter=off\n"), std::string::npos)
      << unlimited.out;
  EXPECT_NE(unlimited.out.find("limiter_gr_max_db=0.00\n"), std::string::npos)
      << unlimited.out;
  EXPECT_GT(OutputValue(unlimited.out, "digital_peak_dbfs"), 0.0f)
      << unlimited.out;
  EXPECT_GT(OutputValue(unlimited.out, "integrated_lufs"),
            OutputValue(limited.out, "integrated_lufs"));
  EXPECT_NE(unlimited.out.find("total_frames=24576\n"), std::string::npos);
}

// --render-wav writes one float frame per program frame. With the
// limiter idle the limited and unlimited renders match sample for
// sample, which holds only when the limiter's look-ahead delay is
// removed from the limited one; with the limiter acting, the files carry
// the peaks measure prints.
TEST(CliMeasureIamf, RenderWavHoldsTheProgramFrames) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.iamf_path.empty());
  const std::string dir = TestDir("render");

  const std::string quiet_on = dir + "/quiet_on.wav";
  const std::string quiet_off = dir + "/quiet_off.wav";
  ASSERT_EQ(
      MeasureWith(rt.iamf_path, kQuietMain, {"--render-wav", quiet_on}).rc, 0);
  ASSERT_EQ(MeasureWith(rt.iamf_path, kQuietMain,
                        {"--no-limiter", "--render-wav", quiet_off})
                .rc,
            0);
  const PlanarWav on = ReadPlanarWav(quiet_on);
  const PlanarWav off = ReadPlanarWav(quiet_off);
  ASSERT_EQ(on.channels.size(), 2u);
  ASSERT_EQ(off.channels.size(), 2u);
  EXPECT_EQ(on.sample_rate, 48000u);
  EXPECT_EQ(on.bit_depth, 32u);
  for (size_t c = 0; c < 2; ++c) {
    ASSERT_EQ(on.channels[c].size(), 24576u);
    ASSERT_EQ(off.channels[c].size(), 24576u);
    float max_diff = 0.0f;
    for (size_t f = 0; f < on.channels[c].size(); ++f) {
      max_diff =
          std::max(max_diff, std::fabs(on.channels[c][f] - off.channels[c][f]));
    }
    EXPECT_LT(max_diff, 1e-6f) << "channel " << c;
  }
  EXPECT_NEAR(PeakDbfs(on), -16.8f, 1.0f);

  const std::string hot_on = dir + "/hot_on.wav";
  const std::string hot_off = dir + "/hot_off.wav";
  const CliRun limited =
      MeasureWith(rt.iamf_path, kHotMain, {"--render-wav", hot_on});
  const CliRun unlimited = MeasureWith(
      rt.iamf_path, kHotMain, {"--no-limiter", "--render-wav", hot_off});
  ASSERT_EQ(limited.rc, 0) << limited.err;
  ASSERT_EQ(unlimited.rc, 0) << unlimited.err;
  EXPECT_NEAR(PeakDbfs(ReadPlanarWav(hot_on)),
              OutputValue(limited.out, "digital_peak_dbfs"), 0.01f);
  EXPECT_NEAR(PeakDbfs(ReadPlanarWav(hot_off)),
              OutputValue(unlimited.out, "digital_peak_dbfs"), 0.01f);
  EXPECT_GT(PeakDbfs(ReadPlanarWav(hot_off)), 0.0f);
}

// --trace-json writes the pass's figures and its 100 ms traces; the GR
// series has one entry per started 100 ms step and its largest entry is
// the printed limiter_gr_max_db.
TEST(CliMeasureIamf, TraceJsonWritesTheSeries) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.iamf_path.empty());
  const std::string json_path = TestDir("trace") + "/trace.json";

  const CliRun r =
      MeasureWith(rt.iamf_path, kHotMain, {"--trace-json", json_path});
  ASSERT_EQ(r.rc, 0) << r.err;
  const std::string json = ReadFile(json_path);
  for (const char* key :
       {"\"layout\": \"stereo\"", "\"limiter\": true", "\"step_ms\": 100",
        "\"total_frames\": 24576", "\"momentary_lufs\": [",
        "\"short_term_lufs\": [", "\"short_term_peak_dbfs\": ["}) {
    EXPECT_NE(json.find(key), std::string::npos) << key << "\n" << json;
  }

  // 24576 frames at 48 kHz is 512 ms: six 100 ms steps.
  const std::string gr = Window(json, "\"limiter_gr_db\": [", "]");
  ASSERT_FALSE(gr.empty()) << json;
  std::istringstream values(gr.substr(std::strlen("\"limiter_gr_db\": [")));
  std::vector<float> entries;
  std::string item;
  while (std::getline(values, item, ',')) {
    entries.push_back(std::strtof(item.c_str(), nullptr));
  }
  ASSERT_EQ(entries.size(), 6u) << gr;
  EXPECT_NEAR(*std::max_element(entries.begin(), entries.end()),
              OutputValue(r.out, "limiter_gr_max_db"), 0.005f);
}

// An output path that names the input would truncate the file the pass
// reads.
TEST(CliMeasureIamf, OutputThatIsTheInputIsRejected) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.iamf_path.empty());
  const std::string before = ReadFile(rt.iamf_path);
  for (const char* flag : {"--render-wav", "--trace-json"}) {
    const CliRun r = MeasureWith(rt.iamf_path, kHotMain, {flag, rt.iamf_path});
    EXPECT_EQ(r.rc, 1) << flag;
    EXPECT_NE(r.err.find("names the input file"), std::string::npos) << r.err;
  }
  EXPECT_EQ(ReadFile(rt.iamf_path), before);
}

// An empty path, a directory, and one file named by both outputs are
// usage errors that write nothing.
TEST(CliMeasureIamf, UnusableOutputPathsAreUsageErrors) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.iamf_path.empty());
  const std::string dir = TestDir("outputs");

  for (const char* flag : {"--render-wav", "--trace-json"}) {
    const CliRun empty = MeasureWith(rt.iamf_path, kHotMain, {flag, ""});
    EXPECT_EQ(empty.rc, 1) << flag;
    EXPECT_NE(empty.err.find(std::string(flag) + " expects a file path"),
              std::string::npos)
        << empty.err;

    const CliRun directory = MeasureWith(rt.iamf_path, kHotMain, {flag, dir});
    EXPECT_EQ(directory.rc, 1) << flag;
    EXPECT_NE(directory.err.find(std::string(flag) + " names a directory"),
              std::string::npos)
        << directory.err;
  }

  const CliRun same = MeasureWith(
      rt.iamf_path, kHotMain,
      {"--render-wav", dir + "/out", "--trace-json", dir + "/./sub/../out"});
  EXPECT_EQ(same.rc, 1);
  EXPECT_NE(same.err.find("name the same file"), std::string::npos) << same.err;
  EXPECT_TRUE(DirEntries(dir).empty());
}

// A path whose directory does not exist fails before the pass, with no
// output written.
TEST(CliMeasureIamf, MissingOutputDirectoryFails) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.iamf_path.empty());
  const std::string dir = TestDir("outputs");
  const std::string missing = dir + "/missing/out";

  for (const char* flag : {"--render-wav", "--trace-json"}) {
    const CliRun r = MeasureWith(rt.iamf_path, kHotMain, {flag, missing});
    EXPECT_EQ(r.rc, 2) << flag;
    EXPECT_NE(r.err.find("cannot create a scratch directory beside " + missing),
              std::string::npos)
        << r.err;
    EXPECT_TRUE(r.out.empty()) << r.out;
  }
  EXPECT_TRUE(DirEntries(dir).empty());
}

// The outputs replace earlier files only when the whole pass succeeds;
// a failed pass leaves them as they were and no scratch directory
// behind.
TEST(CliMeasureIamf, ReplacesTheOutputsOnlyOnSuccess) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.iamf_path.empty());
  const std::string dir = TestDir("outputs");
  const std::string wav = dir + "/render.wav";
  const std::string json = dir + "/trace.json";
  WriteFile(wav, "earlier render");
  WriteFile(json, "earlier trace");
  const std::vector<std::string> both = {"--render-wav", wav, "--trace-json",
                                         json};
  const std::vector<std::string> entries = {"render.wav", "trace.json"};

  // An element the file does not have fails after the scratch
  // directories exist.
  std::vector<std::string> unknown_element = {rt.iamf_path, "--layout",
                                              "stereo", "--elements", "999"};
  unknown_element.insert(unknown_element.end(), both.begin(), both.end());
  const CliRun failed = RunCmd(RunMeasure, unknown_element);
  EXPECT_EQ(failed.rc, 1);
  EXPECT_EQ(ReadFile(wav), "earlier render");
  EXPECT_EQ(ReadFile(json), "earlier trace");
  EXPECT_EQ(DirEntries(dir), entries);

  // One output with a missing directory stops the other one too.
  const CliRun half = MeasureWith(
      rt.iamf_path, kHotMain,
      {"--render-wav", wav, "--trace-json", dir + "/missing/trace.json"});
  EXPECT_EQ(half.rc, 2);
  EXPECT_EQ(ReadFile(wav), "earlier render");
  EXPECT_EQ(DirEntries(dir), entries);

  const CliRun ok = MeasureWith(rt.iamf_path, kHotMain, both);
  ASSERT_EQ(ok.rc, 0) << ok.err;
  EXPECT_EQ(ReadPlanarWav(wav).channels.size(), 2u);
  EXPECT_NE(ReadFile(json).find("\"limiter\": true"), std::string::npos);
  EXPECT_EQ(DirEntries(dir), entries);
}

// A program that ends partway through a 1024-frame render block (25000
// frames: 24 blocks plus 424), measured without the limiter: the render
// holds exactly the program frames and the trace says the limiter was
// off.
TEST(CliMeasureIamf, UnlimitedPartialFinalBlock) {
  const GoldenRoundTrip rt = EncodeGoldenAndProbe(
      "golden/multi_mix.textproto", "multi_mix.iamf",
      {{"bed.wav", 2}, {"vocal.wav", 2}}, /*source_frames=*/25000);
  ASSERT_FALSE(rt.iamf_path.empty());
  const std::string dir = TestDir("outputs");
  const std::string wav = dir + "/render.wav";
  const std::string json = dir + "/trace.json";

  const CliRun r =
      MeasureWith(rt.iamf_path, kHotMain,
                  {"--no-limiter", "--render-wav", wav, "--trace-json", json});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_NE(r.out.find("total_frames=25000\n"), std::string::npos) << r.out;
  EXPECT_NE(r.out.find("limiter=off\n"), std::string::npos) << r.out;

  const PlanarWav render = ReadPlanarWav(wav);
  ASSERT_EQ(render.channels.size(), 2u);
  EXPECT_EQ(render.channels[0].size(), 25000u);
  EXPECT_NEAR(PeakDbfs(render), OutputValue(r.out, "digital_peak_dbfs"), 0.01f);
  // The sines run to the last input frame, so the render's final frames
  // carry program audio, not the zero padding of the last block.
  float tail_peak = 0.0f;
  for (size_t f = 25000 - 100; f < 25000; ++f) {
    tail_peak = std::max(tail_peak, std::fabs(render.channels[0][f]));
  }
  EXPECT_GT(tail_peak, 0.5f);

  const std::string trace = ReadFile(json);
  EXPECT_NE(trace.find("\"limiter\": false"), std::string::npos) << trace;
  EXPECT_NE(trace.find("\"total_frames\": 25000"), std::string::npos);
}

// measure reads an MP4 with an IAMF track by content and prints the same
// measurement as for the raw .iamf; measure-iamf, its old name, does too.
TEST(CliMeasureIamf, Mp4MatchesRawIamfUnderBothNames) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.iamf_path.empty());
  const std::string mp4 = TestDir("files") + "/multi_mix.mp4";
  ASSERT_TRUE(iamf_test_mux::MuxIamfToMp4(rt.iamf_path, mp4));

  const std::vector<std::string> flags = {"--layout",         "stereo",
                                          "--elements",       "300:-3,301",
                                          "--output-gain-db", "-1.5"};
  const auto measure = [&flags](const char* cmd, const std::string& file) {
    std::vector<std::string> args = {cmd, file};
    args.insert(args.end(), flags.begin(), flags.end());
    return RunCliArgs(args);
  };
  const CliRun raw = measure("measure", rt.iamf_path);
  ASSERT_EQ(raw.rc, 0) << raw.err;
  EXPECT_NE(raw.out.find("total_frames=24576"), std::string::npos) << raw.out;
  EXPECT_NE(raw.out.find("integrated_lufs="), std::string::npos);

  const CliRun from_mp4 = measure("measure", mp4);
  ASSERT_EQ(from_mp4.rc, 0) << from_mp4.err;
  EXPECT_EQ(from_mp4.out, raw.out);

  const CliRun old_raw = measure("measure-iamf", rt.iamf_path);
  const CliRun old_mp4 = measure("measure-iamf", mp4);
  ASSERT_EQ(old_raw.rc, 0) << old_raw.err;
  ASSERT_EQ(old_mp4.rc, 0) << old_mp4.err;
  EXPECT_EQ(old_raw.out, raw.out);
  EXPECT_EQ(old_mp4.out, raw.out);
}

TEST(CliMeasureIamf, UnknownElementFails) {
  const std::string fixture = FixturePath("noise_3s_stereo_opus.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  const CliRun r =
      RunCmd(RunMeasure, {fixture, "--layout", "stereo", "--elements", "999"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("invalid_argument"), std::string::npos) << r.err;
}

TEST(CliMeasureIamf, UnknownLayoutFails) {
  const CliRun r = RunCmd(RunMeasure, {"x.iamf", "--layout", "22.2"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("unknown layout"), std::string::npos);
}

TEST(CliMeasureIamf, MissingFileFails) {
  const CliRun r =
      RunCmd(RunMeasure, {"/no/such/file.iamf", "--layout", "stereo"});
  EXPECT_EQ(r.rc, 2);
  EXPECT_FALSE(r.err.empty());
}

// A malformed --elements list is a usage error (rc 1) that is reported
// before the file is opened: every case names a missing file, which
// returns 2 when the open runs first. "301x:0dB" has trailing text in
// the id and in the gain. 4294967597 is 2^32 + 301 and must not wrap to
// id 301.
TEST(CliMeasureIamf, MalformedElementListFails) {
  const char* const bad_lists[] = {
      "301x:0dB",    // trailing text in the id and the gain
      "4294967597",  // above UINT32_MAX
      "301x",        // trailing text in the id
      "301:0dB",     // trailing text in the gain
      "-301",        // signed id
      "301:",        // empty gain
      ":3",          // empty id
      "300,301x",    // a bad entry after a good one
      "301:nan",     // non-finite gain
      "301:inf",     // non-finite gain
      "301: -3",     // leading whitespace in the gain
  };
  for (const char* list : bad_lists) {
    SCOPED_TRACE(list);
    const CliRun r = RunCmd(RunMeasure, {"/no/such/file.iamf", "--layout",
                                         "stereo", "--elements", list});
    EXPECT_EQ(r.rc, 1);
    EXPECT_NE(r.err.find("bad --elements entry"), std::string::npos) << r.err;
  }
}

// UINT32_MAX is the largest id the list accepts: it reaches the
// measurer, which reports that the file has no such element.
TEST(CliMeasureIamf, LargestElementIdIsParsed) {
  const std::string fixture = FixturePath("noise_3s_stereo_opus.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  const CliRun r = RunCmd(
      RunMeasure, {fixture, "--layout", "stereo", "--elements", "4294967295"});
  EXPECT_EQ(r.rc, 1);
  EXPECT_NE(r.err.find("no audio element id=4294967295"), std::string::npos)
      << r.err;
}

TEST(CliMeasureIamf, MalformedOutputGainFails) {
  for (const char* gain : {"-1.5x", "nan", "-inf", " -6", ""}) {
    SCOPED_TRACE(gain);
    const CliRun r = RunCmd(RunMeasure, {"/no/such/file.iamf", "--layout",
                                         "stereo", "--output-gain-db", gain});
    EXPECT_EQ(r.rc, 1);
    EXPECT_NE(r.err.find("bad --output-gain-db value"), std::string::npos)
        << r.err;
  }
}

TEST(CliEncode, GoldenObjectsBinauralRoundTrip) {
  const GoldenRoundTrip rt = EncodeGoldenAndProbe(
      "golden/objects_binaural.textproto", "objects_binaural.iamf",
      {{"obj_mono.wav", 1}, {"obj_dual.wav", 2}});
  ASSERT_FALSE(rt.json.empty());

  // The binaural filter profile round-trips: direct on the mono object,
  // the ambient default on the dual.
  EXPECT_NE(rt.json.find("\"binaural_filter_profile\": \"direct\""),
            std::string::npos);
  EXPECT_NE(rt.json.find("\"binaural_filter_profile\": \"ambient\""),
            std::string::npos);
  // Both elements survive as object-based with exactly one substream
  // (iamf-tools rejects any other count — the dual is one coupled pair).
  EXPECT_NE(rt.json.find("\"type\": \"object_based\""), std::string::npos);
  EXPECT_NE(rt.json.find("\"num_substreams\": 1"), std::string::npos);
  EXPECT_EQ(rt.json.find("\"num_substreams\": 2"), std::string::npos);

  // The probe does not (yet) surface the rendering-config position
  // defaults, so assert them in the descriptor bytes. The polar
  // defaults start byte-aligned (the preceding param_definition ends
  // on a mode bit + 7 reserved bits) and pack as azimuth:9 elevation:8
  // distance:7.
  const size_t descriptor_bytes = DescriptorBytes(rt.json);
  ASSERT_GT(descriptor_bytes, 0u);
  std::ifstream f(rt.iamf_path, std::ios::binary);
  ASSERT_TRUE(f.good());
  std::string descriptors(descriptor_bytes, '\0');
  f.read(descriptors.data(), static_cast<std::streamsize>(descriptor_bytes));
  descriptors.resize(static_cast<size_t>(f.gcount()));

  // Each pattern is anchored on its full param_definition tail —
  // uleb128 parameter_rate 48000 (0x80 0xF7 0x02) + mode bit 1 with 7
  // reserved bits (0x80) — so a short position triple can't match
  // coincidental descriptor bytes. The mono pattern additionally leads
  // with its uleb128 parameter_id (100 = 0x64, fixed by the golden).
  //
  // Mono object az=30 el=10 dist=64 (0.5 * 127 rounded):
  // 000011110 00001010 1000000 -> 0x0F 0x05 0x40.
  const std::string mono_polar = "\x64\x80\xf7\x02\x80\x0f\x05\x40";
  EXPECT_NE(descriptors.find(mono_polar), std::string::npos);
  // Dual object center az=10 spread=60 el=-5 dist=127: first (channel
  // 0 = L) az=40, second az=-20 -> two 9/8/7-bit triples pack to
  // 0x14 0x7D 0xFF 0xF6 0x7D 0xFF.
  const std::string dual_polar = "\x80\xf7\x02\x80\x14\x7d\xff\xf6\x7d\xff";
  EXPECT_NE(descriptors.find(dual_polar), std::string::npos);
}

TEST(CliEncode, GoldenMultiMixRoundTrip) {
  const GoldenRoundTrip rt =
      EncodeGoldenAndProbe("golden/multi_mix.textproto", "multi_mix.iamf",
                           {{"bed.wav", 2}, {"vocal.wav", 2}});
  ASSERT_FALSE(rt.json.empty());

  // Slice the report per presentation so every gain assertion below is
  // tied to the right presentation AND element — a gain landing on the
  // wrong element would otherwise still satisfy a whole-document
  // substring search.
  const std::string main_mix =
      Window(rt.json, "\"label\": \"Main\"", "\"label\": \"Vocal Only\"");
  const std::string vocal_only = Window(rt.json, "\"label\": \"Vocal Only\"");
  ASSERT_FALSE(main_mix.empty());
  ASSERT_FALSE(vocal_only.empty());

  // "Main": Bed -3 dB (-768), Vocal 0 dB, output -1.5 dB (-384).
  EXPECT_EQ(GainQ78After(main_mix, "\"Bed\""), -768);
  EXPECT_EQ(GainQ78After(main_mix, "\"Vocal\""), 0);
  EXPECT_EQ(GainQ78After(main_mix, "\"output_mix_gain\""), -384);

  // "Vocal Only": the Bed is excluded entirely; Vocal +2 dB (512),
  // output 0 dB.
  EXPECT_EQ(vocal_only.find("\"Bed\""), std::string::npos);
  EXPECT_EQ(GainQ78After(vocal_only, "\"Vocal\""), 512);
  EXPECT_EQ(GainQ78After(vocal_only, "\"output_mix_gain\""), 0);
}

TEST(CliEncode, GoldenMultiMixOpusRoundTrip) {
  // The Opus leg of the export contract (ES-382): the app builder's Opus
  // codec config (960-sample frames, per-channel bitrate metadata)
  // drives the real libopus encode. Sources are 24000 frames, 25 Opus
  // frames of 960.
  const GoldenRoundTrip rt = EncodeGoldenAndProbe(
      "golden/multi_mix_opus.textproto", "multi_mix_opus.iamf",
      {{"bed.wav", 2}, {"vocal.wav", 2}}, /*source_frames=*/24000);
  ASSERT_FALSE(rt.json.empty());

  // The encoded stream is genuinely Opus, with exactly one codec
  // config shared by both elements.
  const char* codec_key = "\"codec_id\": \"Opus\"";
  size_t codec_count = 0;
  for (size_t pos = rt.json.find(codec_key); pos != std::string::npos;
       pos = rt.json.find(codec_key, pos + 1)) {
    ++codec_count;
  }
  EXPECT_EQ(codec_count, 1u);
  EXPECT_EQ(rt.json.find("\"codec_id\": \"LPCM\""), std::string::npos);

  // Both presentations survive the transcode, with the same gain
  // contract as the LPCM multi-mix golden.
  const std::string main_mix =
      Window(rt.json, "\"label\": \"Main\"", "\"label\": \"Vocal Only\"");
  const std::string vocal_only = Window(rt.json, "\"label\": \"Vocal Only\"");
  ASSERT_FALSE(main_mix.empty());
  ASSERT_FALSE(vocal_only.empty());

  // "Main": Bed -3 dB (-768), Vocal 0 dB, output -1.5 dB (-384).
  EXPECT_EQ(GainQ78After(main_mix, "\"Bed\""), -768);
  EXPECT_EQ(GainQ78After(main_mix, "\"Vocal\""), 0);
  EXPECT_EQ(GainQ78After(main_mix, "\"output_mix_gain\""), -384);

  // "Vocal Only": the Bed is excluded entirely; Vocal +2 dB (512),
  // output 0 dB.
  EXPECT_EQ(vocal_only.find("\"Bed\""), std::string::npos);
  EXPECT_EQ(GainQ78After(vocal_only, "\"Vocal\""), 512);
  EXPECT_EQ(GainQ78After(vocal_only, "\"output_mix_gain\""), 0);
}

// The 9.1.6 bed golden (ES-940, ES-960): the app lists a 9.1.6 element's
// channel labels in OBR's alt order, FLc first, with channel_id the WAV
// index. iamf-tools keys each WAV channel by its label, so the encode
// takes the labels in that order and the decoded element comes out in
// the bitstream's canonical 9.1.6 order (FL FR FC LFE BL BR FLc FRc SiL
// SiR TpFL TpFR TpBL TpBR TpSiL TpSiR): a tone on WAV channel 0 decodes
// on channel 6, and nowhere else.
TEST(CliEncode, Golden916AltRoundTrip) {
  const std::string cfg = FixturePath("golden/bed916.textproto");
  ASSERT_FALSE(cfg.empty()) << "bed916 golden fixture missing";

  constexpr int kCh = 16;
  constexpr int kFrames = 24576;
  std::vector<int16_t> pcm(static_cast<size_t>(kFrames) * kCh, 0);
  for (int i = 0; i < kFrames; ++i) {
    const float t = static_cast<float>(i) / 48000.0f;
    pcm[static_cast<size_t>(i) * kCh] = static_cast<int16_t>(
        std::sin(2.0f * 3.14159265f * 440.0f * t) * 0.25f * 32767.0f);
  }
  const std::string wav_dir = TestDir("wavs");
  const std::string out_dir = TestDir("out");
  ASSERT_TRUE(
      test_wav::write_frames_s16(wav_dir + "/bed916.wav", kCh, 48000, pcm));

  const CliRun enc =
      RunCmd(RunEncode, {cfg, "--wav-dir", wav_dir, "--out-dir", out_dir});
  ASSERT_EQ(enc.rc, 0) << enc.err;
  const std::string iamf = out_dir + "/bed916.iamf";
  const CliRun probe = RunCmd(RunProbe, {iamf, "--json"});
  ASSERT_EQ(probe.rc, 0) << probe.err;
  EXPECT_NE(probe.out.find("\"num_channels\": 16"), std::string::npos)
      << probe.out;

  const std::vector<float> peaks = DecodedPeaks(iamf, kCh, 4096);
  ASSERT_EQ(peaks.size(), size_t{kCh});
  for (uint32_t c = 0; c < kCh; ++c) {
    if (c == 6) {
      EXPECT_GT(peaks[c], 0.2f) << "decoded channel " << c << " (FLc)";
    } else {
      EXPECT_LT(peaks[c], 0.001f) << "decoded channel " << c;
    }
  }
}

// The third-order scene golden (ES-940): the app writes a Scene element
// as an ambisonics_mono_config with one substream per channel, an
// identity channel_mapping and the labels A_0 to A_15, and iamf-tools
// takes the ambisonics mode from the config that is set. The encode
// must accept that config, and the probe must report a mono-mode order-3
// scene with 16 substreams and the identity channel_mapping. The decoder
// undoes channel_mapping, so the decode check cannot see it; the probe
// check does. Each WAV channel carries a 440 Hz tone at its own peak,
// 0.02 * (channel + 1), and must decode at that peak on the same ACN
// channel, so a swap of any two A_n labels fails.
TEST(CliEncode, GoldenScene3oaRoundTrip) {
  const std::string cfg = FixturePath("golden/scene3oa.textproto");
  ASSERT_FALSE(cfg.empty()) << "scene3oa golden fixture missing";

  constexpr int kCh = 16;
  constexpr int kFrames = 24576;
  std::array<float, kCh> tone_peak = {};
  for (int c = 0; c < kCh; ++c)
    tone_peak[c] = 0.02f * static_cast<float>(c + 1);
  std::vector<int16_t> pcm(static_cast<size_t>(kFrames) * kCh, 0);
  for (int i = 0; i < kFrames; ++i) {
    const float t = static_cast<float>(i) / 48000.0f;
    const float s = std::sin(2.0f * 3.14159265f * 440.0f * t);
    for (int c = 0; c < kCh; ++c) {
      pcm[static_cast<size_t>(i) * kCh + c] =
          static_cast<int16_t>(s * tone_peak[c] * 32767.0f);
    }
  }
  const std::string wav_dir = TestDir("wavs");
  const std::string out_dir = TestDir("out");
  ASSERT_TRUE(
      test_wav::write_frames_s16(wav_dir + "/scene3oa.wav", kCh, 48000, pcm));

  const CliRun enc =
      RunCmd(RunEncode, {cfg, "--wav-dir", wav_dir, "--out-dir", out_dir});
  ASSERT_EQ(enc.rc, 0) << enc.err;
  const std::string iamf = out_dir + "/scene3oa.iamf";
  const CliRun probe = RunCmd(RunProbe, {iamf, "--json"});
  ASSERT_EQ(probe.rc, 0) << probe.err;
  EXPECT_NE(probe.out.find("\"type\": \"scene_based\""), std::string::npos)
      << probe.out;
  EXPECT_NE(probe.out.find("\"num_channels\": 16"), std::string::npos)
      << probe.out;
  // From the ambisonics object to the close of its nested mono object.
  const std::string ambisonics = Window(probe.out, "\"ambisonics\": {", "}");
  for (const char* expected :
       {"\"mode\": \"mono\"", "\"order\": 3,", "\"substream_count\": 16",
        "\"channel_mapping\": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, "
        "14, 15]"}) {
    EXPECT_NE(ambisonics.find(expected), std::string::npos)
        << expected << " missing from " << ambisonics;
  }

  const std::vector<float> peaks = DecodedPeaks(iamf, kCh, 4096);
  ASSERT_EQ(peaks.size(), size_t{kCh});
  for (int c = 0; c < kCh; ++c) {
    EXPECT_NEAR(peaks[c], tone_peak[c], 0.005f) << "decoded channel " << c;
  }
}

// Program length of an encoded file after the start and end trims, from
// the temporal-unit scan the QC Loudness Report runs when it opens a
// file. 0, with a gtest failure recorded, when the file does not open.
uint64_t ScannedProgramFrames(const std::string& iamf_path) {
  constexpr uint32_t kOarStereo = 2;
  eclipsa_studio::OfflineIamfMeasurer measurer;
  if (!measurer.Open(iamf_path, /*buffer_size=*/1024, kOarStereo)) {
    ADD_FAILURE() << measurer.last_error();
    return 0;
  }
  return measurer.total_frames();
}

// Inputs that end partway through a coded frame (ES-935): 25000 frames is
// 24 LPCM frames of 1024 plus 424, and 26 Opus frames of 960 plus 40.
// iamf-tools pads the final frame and adds the pad to the end trim, so
// the file decodes to the input length.
TEST(CliEncode, GoldenMultiMixPartialFinalFrame) {
  const GoldenRoundTrip rt = EncodeGoldenAndProbe(
      "golden/multi_mix.textproto", "multi_mix.iamf",
      {{"bed.wav", 2}, {"vocal.wav", 2}}, /*source_frames=*/25000);
  ASSERT_FALSE(rt.json.empty());
  EXPECT_EQ(ScannedProgramFrames(rt.iamf_path), 25000u);
}

TEST(CliEncode, GoldenMultiMixOpusPartialFinalFrame) {
  const GoldenRoundTrip rt = EncodeGoldenAndProbe(
      "golden/multi_mix_opus.textproto", "multi_mix_opus.iamf",
      {{"bed.wav", 2}, {"vocal.wav", 2}}, /*source_frames=*/25000);
  ASSERT_FALSE(rt.json.empty());
  EXPECT_EQ(ScannedProgramFrames(rt.iamf_path), 25000u);
}

// A failed encode prints the exporter's engine log entries after the
// failure code. The config drops the golden's includes_* fields, so
// samples_to_trim_at_end_includes_padding falls back to its default,
// true, and a trim of 0 cannot cover the pad that a 25000-frame input
// needs.
TEST(CliEncode, FailedEncodePrintsTheEngineReason) {
  const std::string golden = FixturePath("golden/multi_mix.textproto");
  ASSERT_FALSE(golden.empty());
  std::istringstream lines(ReadFile(golden));
  std::string config;
  for (std::string line; std::getline(lines, line);) {
    if (line.find("_includes_") == std::string::npos) config += line + "\n";
  }
  const std::string dir = TestDir("in");
  WriteFile(dir + "/config.textproto", config);
  for (const char* name : {"bed.wav", "vocal.wav"}) {
    ASSERT_TRUE(test_wav::write_sine_frames(dir + "/" + name, 2, 48000, 16,
                                            440.f, 25000));
  }

  const CliRun r = RunCliArgs({"encode", dir + "/config.textproto", "--wav-dir",
                               dir, "--out", dir + "/out.iamf"});
  EXPECT_EQ(r.rc, 2);
  const size_t summary = r.err.find("error: encode failed (rc=-23)\n");
  const size_t detail =
      r.err.find("engine error [iamf]: EncodePush: OutputTemporalUnit failed:");
  ASSERT_NE(summary, std::string::npos) << r.err;
  ASSERT_NE(detail, std::string::npos) << r.err;
  EXPECT_LT(summary, detail);
  // The iamf-tools status follows on its own line.
  EXPECT_NE(r.err.find("engine error [iamf]: ", detail + 1), std::string::npos)
      << r.err;
}

// ── encode --out ──────────────────────────────────────────────────────────

// The multi_mix golden and its two stereo WAVs (24576 frames each), staged
// in a fresh directory, for the encode --out tests.
struct EncodeInputs {
  std::string config;
  std::string wav_dir;
};
EncodeInputs StageMultiMix() {
  EncodeInputs inputs;
  inputs.config = FixturePath("golden/multi_mix.textproto");
  EXPECT_FALSE(inputs.config.empty()) << "golden/multi_mix.textproto missing";
  inputs.wav_dir = TestDir("wavs");
  for (const char* name : {"bed.wav", "vocal.wav"}) {
    EXPECT_TRUE(test_wav::write_sine_frames(inputs.wav_dir + "/" + name, 2,
                                            48000, 16, 440.f, 24576));
  }
  return inputs;
}

// Track counts of the MP4 at `path`, read with GPAC's ISO-media reader.
struct Mp4Tracks {
  uint32_t total = 0;
  uint32_t audio = 0;
  uint32_t visual = 0;
  uint32_t visual_samples = 0;
};
Mp4Tracks ReadMp4Tracks(const std::string& path) {
  Mp4Tracks tracks;
  eclipsa_studio::GpacSystem gpac;
  if (!gpac.ok()) return tracks;
  GF_ISOFile* file = gf_isom_open(path.c_str(), GF_ISOM_OPEN_READ, nullptr);
  if (file == nullptr) return tracks;
  tracks.total = gf_isom_get_track_count(file);
  for (uint32_t i = 1; i <= tracks.total; ++i) {
    const uint32_t type = gf_isom_get_media_type(file, i);
    if (type == GF_ISOM_MEDIA_AUDIO) ++tracks.audio;
    if (type == GF_ISOM_MEDIA_VISUAL) {
      ++tracks.visual;
      tracks.visual_samples = gf_isom_get_sample_count(file, i);
    }
  }
  gf_isom_close(file);
  return tracks;
}

// --out x.iamf writes exactly that path, with the bytes --out-dir writes
// under the config's file_name_prefix, and leaves no scratch files.
TEST(CliEncodeOut, IamfMatchesOutDirBytes) {
  const EncodeInputs in = StageMultiMix();
  const std::string out_dir = TestDir("out_dir");
  const std::string out_file_dir = TestDir("out_file");
  const std::string out = out_file_dir + "/custom_name.iamf";

  const CliRun by_dir = RunCmd(
      RunEncode, {in.config, "--wav-dir", in.wav_dir, "--out-dir", out_dir});
  ASSERT_EQ(by_dir.rc, 0) << by_dir.err;
  const CliRun by_file =
      RunCmd(RunEncode, {in.config, "--wav-dir", in.wav_dir, "--out", out});
  ASSERT_EQ(by_file.rc, 0) << by_file.err;
  EXPECT_EQ(by_file.out, "ok\n");

  EXPECT_EQ(DirEntries(out_file_dir),
            (std::vector<std::string>{"custom_name.iamf"}));
  const std::string expected = ReadFile(out_dir + "/multi_mix.iamf");
  ASSERT_FALSE(expected.empty());
  EXPECT_EQ(ReadFile(out), expected);
}

// --out x.mp4 writes an IAMF-in-MP4 that probe and measure read with the
// same reports as the .iamf encoded from the same inputs.
TEST(CliEncodeOut, Mp4ProbesAndMeasuresLikeIamf) {
  const EncodeInputs in = StageMultiMix();
  const std::string dir = TestDir("out");
  const std::string iamf = dir + "/mix.iamf";
  const std::string mp4 = dir + "/mix.mp4";
  const CliRun enc_iamf =
      RunCmd(RunEncode, {in.config, "--wav-dir", in.wav_dir, "--out", iamf});
  ASSERT_EQ(enc_iamf.rc, 0) << enc_iamf.err;
  const CliRun enc_mp4 =
      RunCmd(RunEncode, {in.config, "--wav-dir", in.wav_dir, "--out", mp4});
  ASSERT_EQ(enc_mp4.rc, 0) << enc_mp4.err;
  EXPECT_EQ(DirEntries(dir), (std::vector<std::string>{"mix.iamf", "mix.mp4"}));

  // An ISOBMFF file with the IAMF track and no video.
  EXPECT_EQ(ReadFile(mp4).substr(4, 4), "ftyp");
  const Mp4Tracks tracks = ReadMp4Tracks(mp4);
  EXPECT_EQ(tracks.total, 1u);
  EXPECT_EQ(tracks.audio, 1u);

  const CliRun probe_iamf = RunCmd(RunProbe, {iamf, "--json"});
  const CliRun probe_mp4 = RunCmd(RunProbe, {mp4, "--json"});
  ASSERT_EQ(probe_iamf.rc, 0) << probe_iamf.err;
  ASSERT_EQ(probe_mp4.rc, 0) << probe_mp4.err;
  EXPECT_EQ(probe_mp4.out, probe_iamf.out);

  const CliRun measure_iamf = RunCmd(RunMeasure, {iamf, "--layout", "stereo"});
  const CliRun measure_mp4 = RunCmd(RunMeasure, {mp4, "--layout", "stereo"});
  ASSERT_EQ(measure_iamf.rc, 0) << measure_iamf.err;
  ASSERT_EQ(measure_mp4.rc, 0) << measure_mp4.err;
  EXPECT_NE(measure_iamf.out.find("total_frames=24576"), std::string::npos);
  EXPECT_EQ(measure_mp4.out, measure_iamf.out);
}

// --video adds the video track, stream-copied: all 12 frames of the
// fixture (FRAMES in engine/tools/generate_stts_fixture.py).
TEST(CliEncodeOut, Mp4WithVideoHasVideoTrack) {
  const EncodeInputs in = StageMultiMix();
  const std::string video = FixturePath("stts_zero_tail_h264.mp4");
  ASSERT_FALSE(video.empty()) << "fixture missing";
  const std::string dir = TestDir("out");
  const std::string iamf = dir + "/mix.iamf";
  const std::string mp4 = dir + "/film.mp4";
  ASSERT_EQ(
      RunCmd(RunEncode, {in.config, "--wav-dir", in.wav_dir, "--out", iamf}).rc,
      0);
  const CliRun r = RunCmd(RunEncode, {in.config, "--wav-dir", in.wav_dir,
                                      "--out", mp4, "--video", video});
  ASSERT_EQ(r.rc, 0) << r.err;
  EXPECT_EQ(DirEntries(dir),
            (std::vector<std::string>{"film.mp4", "mix.iamf"}));

  const Mp4Tracks tracks = ReadMp4Tracks(mp4);
  EXPECT_EQ(tracks.total, 2u);
  EXPECT_EQ(tracks.audio, 1u);
  EXPECT_EQ(tracks.visual, 1u);
  EXPECT_EQ(tracks.visual_samples, 12u);

  const CliRun probe_iamf = RunCmd(RunProbe, {iamf, "--json"});
  const CliRun probe_mp4 = RunCmd(RunProbe, {mp4, "--json"});
  ASSERT_EQ(probe_mp4.rc, 0) << probe_mp4.err;
  EXPECT_EQ(probe_mp4.out, probe_iamf.out);
}

// Every case is rejected before the config is read, and writes nothing.
TEST(CliEncodeOut, BadOutputArgumentsAreUsageErrors) {
  const std::string dir = TestDir("out");
  const std::string video_fixture = FixturePath("stts_zero_tail_h264.mp4");
  ASSERT_FALSE(video_fixture.empty()) << "fixture missing";
  const std::string video_copy = dir + "/film.mp4";
  std::filesystem::copy_file(video_fixture, video_copy);
  const std::string video_bytes = ReadFile(video_copy);

  struct Case {
    std::vector<std::string> flags;
    const char* message;
  };
  const Case cases[] = {
      {{"--out", dir + "/x.iamf", "--video", video_fixture},
       "--video needs an --out ending in .mp4"},
      {{"--out-dir", dir, "--video", video_fixture},
       "--video needs an --out ending in .mp4"},
      {{"--out", dir + "/x.iamf", "--out-dir", dir},
       "--out and --out-dir cannot be used together"},
      {{}, "usage: eclipsa_studio_cli encode"},
      {{"--out", dir + "/x.wav"},
       "--out needs a file name ending in .iamf or .mp4"},
      {{"--out", dir + "/x"},
       "--out needs a file name ending in .iamf or .mp4"},
      {{"--out", dir + "/.iamf"},
       "--out needs a file name ending in .iamf or .mp4"},
      {{"--out", video_copy, "--video", video_copy},
       "--out must not be the --video file"},
      {{"--out", dir + "/x.mp4", "--video", ""}, "--video expects a file path"},
  };
  for (const Case& c : cases) {
    std::vector<std::string> args = {"/no/such/config.textproto", "--wav-dir",
                                     dir};
    args.insert(args.end(), c.flags.begin(), c.flags.end());
    std::string joined;
    for (const std::string& a : c.flags) joined += a + " ";
    SCOPED_TRACE(joined);
    const CliRun r = RunCmd(RunEncode, args);
    EXPECT_EQ(r.rc, 1);
    EXPECT_NE(r.err.find(c.message), std::string::npos) << r.err;
  }
  EXPECT_EQ(DirEntries(dir), (std::vector<std::string>{"film.mp4"}));
  EXPECT_EQ(ReadFile(video_copy), video_bytes);
}

// A failed encode or video check writes nothing at --out, leaves an
// earlier file there as it was, and removes its scratch directory.
TEST(CliEncodeOut, FailureLeavesNoOutput) {
  const EncodeInputs in = StageMultiMix();
  const std::string empty_wav_dir = TestDir("no_wavs");
  const std::string dir = TestDir("out");

  // The WAVs are missing: the encode fails for each container.
  for (const char* name : {"/x.iamf", "/x.mp4"}) {
    SCOPED_TRACE(name);
    const CliRun r = RunCmd(RunEncode, {in.config, "--wav-dir", empty_wav_dir,
                                        "--out", dir + name});
    EXPECT_EQ(r.rc, 2);
    EXPECT_NE(r.err.find("cannot open an input WAV"), std::string::npos)
        << r.err;
  }
  EXPECT_TRUE(DirEntries(dir).empty());

  // The video is not an ISOBMFF file: rejected before the encode.
  const std::string not_video = FixturePath("noise_3s_stereo_opus.iamf");
  ASSERT_FALSE(not_video.empty()) << "fixture missing";
  const CliRun bad_video =
      RunCmd(RunEncode, {in.config, "--wav-dir", in.wav_dir, "--out",
                         dir + "/y.mp4", "--video", not_video});
  EXPECT_EQ(bad_video.rc, 2);
  EXPECT_NE(bad_video.err.find("--video is not an MP4 or MOV file"),
            std::string::npos)
      << bad_video.err;
  const CliRun missing_video =
      RunCmd(RunEncode, {in.config, "--wav-dir", in.wav_dir, "--out",
                         dir + "/y.mp4", "--video", dir + "/missing.mp4"});
  EXPECT_EQ(missing_video.rc, 2);
  EXPECT_NE(missing_video.err.find("cannot read --video file"),
            std::string::npos)
      << missing_video.err;
  EXPECT_TRUE(DirEntries(dir).empty());

  // An earlier file at --out survives a failed encode unchanged.
  const std::string earlier = dir + "/keep.iamf";
  WriteFile(earlier, "earlier export");
  const CliRun r = RunCmd(
      RunEncode, {in.config, "--wav-dir", empty_wav_dir, "--out", earlier});
  EXPECT_EQ(r.rc, 2);
  EXPECT_EQ(ReadFile(earlier), "earlier export");
  EXPECT_EQ(DirEntries(dir), (std::vector<std::string>{"keep.iamf"}));
}

// A directory at --out is rejected before the encode. A mux that fails
// after a successful encode keeps an earlier file at --out and removes the
// scratch directory: GPAC's IAMF writer rejects the Base-Advanced profile
// of the objects_binaural golden.
TEST(CliEncodeOut, OutDirectoryAndLateMuxFailure) {
  const std::string config = FixturePath("golden/objects_binaural.textproto");
  ASSERT_FALSE(config.empty()) << "golden/objects_binaural.textproto missing";
  const std::string wav_dir = TestDir("wavs");
  ASSERT_TRUE(test_wav::write_sine_frames(wav_dir + "/obj_mono.wav", 1, 48000,
                                          16, 440.f, 24576));
  ASSERT_TRUE(test_wav::write_sine_frames(wav_dir + "/obj_dual.wav", 2, 48000,
                                          16, 440.f, 24576));
  const std::string dir = TestDir("out");

  const std::string folder = dir + "/folder.iamf";
  std::filesystem::create_directory(folder);
  const CliRun to_folder =
      RunCmd(RunEncode, {config, "--wav-dir", wav_dir, "--out", folder});
  EXPECT_EQ(to_folder.rc, 1);
  EXPECT_NE(to_folder.err.find("--out is a directory"), std::string::npos)
      << to_folder.err;
  EXPECT_TRUE(std::filesystem::is_empty(folder));

  // The same inputs encode to a raw .iamf.
  const CliRun raw = RunCmd(
      RunEncode, {config, "--wav-dir", wav_dir, "--out", dir + "/x.iamf"});
  ASSERT_EQ(raw.rc, 0) << raw.err;

  const std::string earlier = dir + "/x.mp4";
  WriteFile(earlier, "earlier export");
  const CliRun mux =
      RunCmd(RunEncode, {config, "--wav-dir", wav_dir, "--out", earlier});
  EXPECT_EQ(mux.rc, 2);
  EXPECT_NE(mux.err.find("writing the IAMF track into the MP4 failed"),
            std::string::npos)
      << mux.err;
  EXPECT_EQ(ReadFile(earlier), "earlier export");
  EXPECT_EQ(DirEntries(dir),
            (std::vector<std::string>{"folder.iamf", "x.iamf", "x.mp4"}));
}

TEST(CliEncodeOut, MissingOutputDirectoryFails) {
  const EncodeInputs in = StageMultiMix();
  const std::string out = TestDir("parent") + "/no/such/dir/x.iamf";
  const CliRun r =
      RunCmd(RunEncode, {in.config, "--wav-dir", in.wav_dir, "--out", out});
  EXPECT_EQ(r.rc, 2);
  EXPECT_NE(r.err.find("cannot create a scratch directory"), std::string::npos)
      << r.err;
}

}  // namespace
