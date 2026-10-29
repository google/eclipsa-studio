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
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iterator>
#include <map>
#include <optional>
#include <sstream>
#include <system_error>
#include <utility>

#include "bounce/element_bouncer.h"
#include "bounce/element_stream.h"
#include "engine_log.h"
#include "iamf/iamf_exporter.h"
#include "iamf/iamf_muxer.h"
#include "iamf/iamf_probe_ffi.h"
#include "io/wav_reader.h"
#include "mix_renderer/offline_iamf_measurer.h"
#include "mix_renderer/offline_mix_renderer.h"
#include "renderer/channel_order.h"
#include "wav/writer.h"

namespace eclipsa_studio::cli {
namespace {

// Output layouts the measure subcommand accepts. The oar value is the
// oar_layout_t enum constant (liboar's oar.h); channel counts follow
// the IAMF sound-system definitions. Kept numeric so the CLI does not
// need a direct liboar dependency. meters/bs1770_weights.cc mirrors
// the same constants — if the upstream enum ever changes, both tables
// need the update.
struct LayoutSpec {
  const char* name;
  uint32_t oar_value;
  uint32_t channels;
};
// Render block size of the measure subcommands, the app's offline
// measurement block.
constexpr uint32_t kMeasureBlockSize = 1024;

constexpr LayoutSpec kLayouts[] = {
    {"mono", 1, 1},    {"stereo", 2, 2},      {"5.1", 3, 6},
    {"5.1.2", 4, 8},   {"5.1.4", 5, 10},      {"7.1", 6, 8},
    {"7.1.2", 7, 10},  {"7.1.4", 8, 12},      {"3.1.2", 9, 6},
    {"9.1.6", 10, 16}, {"binaural", 0xFF, 2},
};

const LayoutSpec* FindLayout(const std::string& name) {
  for (const auto& l : kLayouts) {
    if (name == l.name) return &l;
  }
  return nullptr;
}

// Split args into positionals and --flag value pairs. Each subcommand
// passes its known flags: `value_flags` take one value, `bool_flags`
// take none. Returns false on an unknown --flag or a value flag
// missing its value — typos must not silently swallow the next token.
struct ParsedArgs {
  std::vector<std::string> positional;
  std::map<std::string, std::string> flags;
};
bool ParseArgs(const std::vector<std::string>& args,
               const std::vector<std::string>& value_flags,
               const std::vector<std::string>& bool_flags, ParsedArgs* parsed,
               std::ostream& err) {
  const auto contains = [](const std::vector<std::string>& v,
                           const std::string& s) {
    return std::find(v.begin(), v.end(), s) != v.end();
  };
  for (size_t i = 0; i < args.size(); ++i) {
    const std::string& a = args[i];
    if (a.rfind("--", 0) != 0) {
      parsed->positional.push_back(a);
      continue;
    }
    if (contains(bool_flags, a)) {
      parsed->flags[a] = "1";
      continue;
    }
    if (!contains(value_flags, a)) {
      err << "error: unknown flag " << a << "\n";
      return false;
    }
    // A flag in the value position is the next flag, not a value:
    // `--render-wav --no-limiter` must not write a file named
    // --no-limiter.
    if (i + 1 >= args.size() || args[i + 1].rfind("--", 0) == 0) {
      err << "error: " << a << " expects a value\n";
      return false;
    }
    parsed->flags[a] = args[++i];
  }
  return true;
}

// Parse "1,0,-1" into a routing vector. Returns false on junk.
bool ParseRouting(const std::string& spec, std::vector<int>* routing,
                  std::ostream& err) {
  std::stringstream ss(spec);
  std::string item;
  while (std::getline(ss, item, ',')) {
    try {
      size_t used = 0;
      const int v = std::stoi(item, &used);
      if (used != item.size()) throw std::invalid_argument(item);
      routing->push_back(v);
    } catch (const std::exception&) {
      err << "error: bad --routing entry '" << item << "'\n";
      return false;
    }
  }
  return true;
}

// Parse a gain in dB. The whole string must be a finite number with no
// leading whitespace (std::stof skips it). Returns false on junk,
// including nan and inf.
bool ParseGainDb(const std::string& text, float* gain_db) {
  if (text.empty() || std::isspace(static_cast<unsigned char>(text[0]))) {
    return false;
  }
  try {
    size_t used = 0;
    const float v = std::stof(text, &used);
    if (used != text.size() || !std::isfinite(v)) return false;
    *gain_db = v;
    return true;
  } catch (const std::exception&) {
    return false;
  }
}

// Parse a decimal unsigned integer no greater than `max`. The text must
// start with a digit, which rejects the sign and leading whitespace
// std::stoull would accept (it wraps "-1" to UINT64_MAX), and must be a
// number in full. Returns false on junk.
bool ParseUnsigned(const std::string& text, uint64_t max, uint64_t* value) {
  if (text.empty() || !std::isdigit(static_cast<unsigned char>(text[0]))) {
    return false;
  }
  try {
    size_t used = 0;
    const uint64_t v = std::stoull(text, &used);
    if (used != text.size() || v > max) return false;
    *value = v;
    return true;
  } catch (const std::exception&) {
    return false;
  }
}

// One entry of the measure --elements list.
struct ElementSpec {
  uint32_t audio_element_id = 0;
  float mix_gain_db = 0.0f;
};

// Parse "300:-3,301" into element specs: a decimal audio element id and
// an optional mix gain in dB per entry, 0 dB when omitted. The whole of
// each id and gain must be a number, and an id must not exceed
// UINT32_MAX. Empty entries are skipped. Returns false on junk.
bool ParseElements(const std::string& spec, std::vector<ElementSpec>* elements,
                   std::ostream& err) {
  std::stringstream ss(spec);
  std::string item;
  while (std::getline(ss, item, ',')) {
    if (item.empty()) continue;
    const size_t colon = item.find(':');
    const std::string id_text = item.substr(0, colon);
    ElementSpec element;
    uint64_t id = 0;
    bool ok = ParseUnsigned(id_text, UINT32_MAX, &id);
    element.audio_element_id = static_cast<uint32_t>(id);
    if (ok && colon != std::string::npos) {
      ok = ParseGainDb(item.substr(colon + 1), &element.mix_gain_db);
    }
    if (!ok) {
      err << "error: bad --elements entry '" << item << "'\n";
      return false;
    }
    elements->push_back(element);
  }
  return true;
}

std::string LayoutNames() {
  std::string names;
  for (const auto& l : kLayouts) {
    if (!names.empty()) names += "|";
    names += l.name;
  }
  return names;
}

constexpr char kUsage[] =
    "usage: eclipsa_studio_cli <bounce|measure|encode|probe> ...\n"
    "  bounce   <in.wav> <out.wav> [--gain-db G] [--routing 1,0,-1]\n"
    "           [--pad-frames N] [--rate R]\n"
    "  measure  <file> --layout <name> [--elements ID[:GAIN_DB],...]\n"
    "           [--output-gain-db G] [--channel-order alt|iamf]\n"
    "           [--no-limiter] [--trace-json T.json] [--render-wav R.wav]\n"
    "           file: a mix WAV, or a .iamf or an MP4 with an IAMF track\n"
    "  encode   <config.textproto> --wav-dir D --out <file.iamf|file.mp4>\n"
    "           [--video V.mp4|V.mov]\n"
    "  encode   <config.textproto> --wav-dir D --out-dir O\n"
    "  probe    <file.iamf|file.mp4> [--json]\n"
    "  measure-iamf is an old name of measure.\n"
    "  --help after a subcommand prints the usage of that subcommand.\n";

constexpr char kBounceUsage[] =
    "usage: eclipsa_studio_cli bounce <in.wav> <out.wav> [--gain-db G]\n"
    "         [--routing 1,0,-1] [--pad-frames N] [--rate R]\n";

constexpr char kProbeUsage[] =
    "usage: eclipsa_studio_cli probe <file.iamf|file.mp4> [--json]\n";

std::string MeasureUsage() {
  return "usage: eclipsa_studio_cli measure <file> --layout <" + LayoutNames() +
         ">\n"
         "         [--elements ID[:GAIN_DB],...] [--output-gain-db G]\n"
         "         [--channel-order alt|iamf]\n"
         "         [--no-limiter] [--trace-json T.json] [--render-wav R.wav]\n"
         "  file: a mix WAV, or a .iamf or an MP4 with an IAMF track.\n"
         "  --elements, --output-gain-db, --trace-json and --render-wav\n"
         "  apply to IAMF input only.\n"
         "  IAMF input also prints limiter=on or limiter=off and\n"
         "  limiter_gr_max_db, the largest entry of the 100 ms limiter gain\n"
         "  reduction trace, the value the Loudness Report shows. The trace\n"
         "  samples the limiter envelope once per 1024-frame render block,\n"
         "  so isolated transients read low.\n"
         "  --no-limiter turns OAR's -1 dBFS limiter off for this\n"
         "  measurement, of a WAV or an IAMF input, and for the render\n"
         "  --render-wav writes.\n"
         "  --trace-json writes the 100 ms traces (limiter_gr_db,\n"
         "  momentary_lufs, short_term_lufs, short_term_peak_dbfs) as JSON.\n"
         "  momentary_lufs starts once its 400 ms window fills,\n"
         "  short_term_lufs and short_term_peak_dbfs once their 3 s\n"
         "  window fills; limiter_gr_db starts at 0 s.\n"
         "  --render-wav writes the measured render as a 32-bit float WAV\n"
         "  in OAR's output channel order for the layout, one frame per\n"
         "  program frame, with the limiter delay removed; a file larger\n"
         "  than 4 GiB is written as RF64. With --layout binaural only\n"
         "  the limiter delay is removed; the latency of OBR's binaural\n"
         "  filters stays in the file.\n"
         "  Both files are written into a scratch directory beside each\n"
         "  path and moved onto the path once the pass succeeds; a failed\n"
         "  pass leaves existing files at the paths unchanged.\n"
         "  With --layout binaural, every IAMF element renders binaural\n"
         "  world-locked with the ambient filter profile. The app's\n"
         "  Loudness Report uses each element's headphones rendering mode\n"
         "  and binaural filter profile from the mix presentation, so the\n"
         "  two can differ for a file that sets them.\n"
         "  --channel-order applies to a 9.1.6 WAV only: alt (the default)\n"
         "  reads it in OBR's alternative order (FLc FRc FC LFE FL FR SiL\n"
         "  SiR BL BR, then the tops), iamf in the IAMF bitstream order.\n";
}

constexpr char kEncodeUsage[] =
    "usage: eclipsa_studio_cli encode <config.textproto> --wav-dir D\n"
    "         --out <file.iamf|file.mp4> [--video V.mp4|V.mov]\n"
    "       eclipsa_studio_cli encode <config.textproto> --wav-dir D "
    "--out-dir O\n"
    "  --out-dir writes O/<file_name_prefix>.iamf.\n"
    "  --video needs an --out ending in .mp4.\n";

// True when `args` holds --help or -h, which print the subcommand's usage
// to stdout.
bool WantsHelp(const std::vector<std::string>& args) {
  return std::any_of(args.begin(), args.end(), [](const std::string& a) {
    return a == "--help" || a == "-h";
  });
}

// Renders the mix WAV at `wav_path` as a channel-bed element at its own
// layout into the same target layout and measures the render, the app's
// export-time loudness measurement path. `limiter` false renders without
// OAR's -1 dBFS limiter (--no-limiter).
int MeasureWav(const std::string& wav_path, const LayoutSpec& layout,
               uint32_t channel_order, bool limiter, std::ostream& out,
               std::ostream& err) {
  WavReader reader;
  if (!reader.open(wav_path.c_str())) {
    err << "error: failed to open WAV: " << wav_path << "\n";
    return 2;
  }
  const uint32_t channels = reader.channels();
  const uint32_t sample_rate = reader.sample_rate();
  reader.close();
  if (channels != layout.channels) {
    err << "error: " << wav_path << " has " << channels << " channels but "
        << layout.name << " expects " << layout.channels << "\n";
    return 1;
  }

  OfflineMixRenderer renderer;
  // Set before Init() builds OAR, as the IAMF path does before Open().
  // With the limiter off OAR adds no look-ahead delay, and the
  // measurement sink reads that delay from the renderer, so the pass
  // measures the same program frames either way.
  if (!renderer.SetLimiterEnabled(limiter)) {
    err << "error: the renderer refused to turn the limiter "
        << (limiter ? "on" : "off") << "\n";
    return 2;
  }
  if (!renderer.Init(sample_rate, kMeasureBlockSize, layout.oar_value)) {
    err << "error: renderer init failed (layout " << layout.name << ")\n";
    return 2;
  }
  MixElementConfig element;
  element.element_id = 1;
  // Identity stream: no gain/routing/pad/rate — reads the file as-is.
  element.stream.input_wav_path = wav_path;
  element.element_type = 0;  // channel-based
  element.element_sub_type = static_cast<int>(layout.oar_value);
  element.channels = channels;
  // A 9.1.6 WAV is read in the order --channel-order names; the default
  // is the app's channel order, OBR's alt order (FLc FRc FC LFE FL FR
  // SiL SiR BL BR TpFL TpFR TpSiL TpSiR TpBL TpBR), the order a 9.1.6
  // element carries in a session.
  element.channel_order = channel_order;
  // No gain flag: to measure a WAV at another gain, bounce it with
  // `bounce --gain-db` first.
  if (!renderer.AddElement(element)) {
    err << "error: failed to add element\n";
    return 2;
  }
  const std::optional<LoudnessResult> result = renderer.RenderAndMeasure();
  if (!result.has_value()) {
    err << "error: render/measure failed\n";
    return 2;
  }

  out << std::fixed << std::setprecision(2)
      << "integrated_lufs=" << result->integrated_lufs << "\n"
      << "true_peak_dbtp=" << result->true_peak_dbtp << "\n"
      << "digital_peak_dbfs=" << result->digital_peak_dbfs << "\n";
  return 0;
}

// A new directory `eclipsa_studio_cli.partial-<hex>` in the directory of
// `target` for the intermediate files of one encode, bounce or measure, removed
// with its contents on destruction. It sits beside the target so the
// final rename stays on one file system. The name is ASCII whatever
// `target` is called, and has no leading dot, so a directory left by an
// interrupted run is visible.
class ScratchDir {
 public:
  explicit ScratchDir(const std::filesystem::path& target) {
    std::filesystem::path parent = target.parent_path();
    if (parent.empty()) parent = ".";
    // Tries up to 100 names, counting up from a clock value, and takes the
    // first one create_directory makes; it returns false without an error
    // for a name that exists.
    const auto seed = static_cast<uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count());
    for (uint64_t attempt = 0; attempt < 100; ++attempt) {
      char name[48];
      std::snprintf(name, sizeof(name), "eclipsa_studio_cli.partial-%016llx",
                    static_cast<unsigned long long>(seed + attempt));
      const std::filesystem::path candidate = parent / name;
      std::error_code ec;
      if (std::filesystem::create_directory(candidate, ec)) {
        path_ = candidate;
        return;
      }
      if (ec) {
        error_ = ec.message();
        return;
      }
    }
    error_ = "every candidate name is in use";
  }
  ~ScratchDir() {
    if (path_.empty()) return;
    std::error_code ignore;
    std::filesystem::remove_all(path_, ignore);
  }
  ScratchDir(const ScratchDir&) = delete;
  ScratchDir& operator=(const ScratchDir&) = delete;

  bool ok() const { return !path_.empty(); }
  const std::filesystem::path& path() const { return path_; }
  const std::string& error() const { return error_; }

 private:
  std::filesystem::path path_;
  std::string error_;
};

// `path` made absolute, with the links of its existing part resolved and
// `.` and `..` removed, so two spellings of one file compare equal
// whether or not the file exists yet.
std::filesystem::path NormalPath(const std::string& path) {
  std::error_code ec;
  std::filesystem::path normal = std::filesystem::weakly_canonical(path, ec);
  if (ec) normal = std::filesystem::absolute(path, ec).lexically_normal();
  return normal;
}

// Options of an IAMF measure pass beyond the element selection.
struct IamfMeasureOptions {
  bool limiter = true;
  std::string trace_json_path;  // empty: no trace file
  std::string render_wav_path;  // empty: no render file
};

// The trace series --trace-json writes, by JSON key.
struct JsonTrace {
  const char* key;
  uint32_t series;
};
constexpr JsonTrace kJsonTraces[] = {
    {"limiter_gr_db", kTraceLimiterGrDb},
    {"momentary_lufs", kTraceMomentaryLufs},
    {"short_term_lufs", kTraceShortTermLufs},
    {"short_term_peak_dbfs", kTraceShortTermPeakDbfs},
};

std::vector<float> CopySeries(const OfflineIamfMeasurer& measurer,
                              uint32_t series) {
  std::vector<float> values(measurer.TraceLength(series));
  values.resize(measurer.CopyTrace(series, values.data(),
                                   static_cast<uint32_t>(values.size())));
  return values;
}

// Writes the --trace-json file for a finished pass. JSON has no
// infinity, so a non-finite value is written as null. Returns false when
// the file cannot be written.
bool WriteTraceJson(const std::filesystem::path& json_path,
                    const LayoutSpec& layout, bool limiter,
                    const OfflineIamfMeasurer& measurer,
                    const LoudnessResult& result, float gr_max_db) {
  std::ofstream f(json_path, std::ios::binary | std::ios::trunc);
  if (!f) return false;
  const auto number = [&f](float v) {
    if (std::isfinite(v)) {
      f << v;
    } else {
      f << "null";
    }
  };
  f << std::fixed << std::setprecision(2) << "{\n"
    << "  \"layout\": \"" << layout.name << "\",\n"
    << "  \"limiter\": " << (limiter ? "true" : "false") << ",\n"
    << "  \"sample_rate\": " << measurer.sample_rate() << ",\n"
    << "  \"total_frames\": " << measurer.total_frames() << ",\n"
    << "  \"step_ms\": " << OfflineIamfMeasurer::kTraceStepMs << ",\n"
    << "  \"integrated_lufs\": ";
  number(result.integrated_lufs);
  f << ",\n  \"true_peak_dbtp\": ";
  number(result.true_peak_dbtp);
  f << ",\n  \"digital_peak_dbfs\": ";
  number(result.digital_peak_dbfs);
  f << ",\n  \"limiter_gr_max_db\": ";
  number(gr_max_db);
  f << ",\n  \"series\": {\n";
  for (size_t i = 0; i < std::size(kJsonTraces); ++i) {
    f << "    \"" << kJsonTraces[i].key << "\": [";
    const std::vector<float> values =
        CopySeries(measurer, kJsonTraces[i].series);
    for (size_t j = 0; j < values.size(); ++j) {
      if (j > 0) f << ", ";
      number(values[j]);
    }
    f << "]" << (i + 1 < std::size(kJsonTraces) ? ",\n" : "\n");
  }
  f << "  }\n}\n";
  f.close();
  return !f.fail();
}

// Writes the program frames of a measure pass into a 32-bit float WAV.
// Tap() goes to OfflineIamfMeasurer::SetProgramTap(), and the writer must
// outlive the pass. A write error stops the appending; Finish() reports
// it.
class RenderWavWriter {
 public:
  // Creates `path` for `channels` channels at `sample_rate`. Returns
  // false with `error` set when the file cannot be created.
  bool Open(const std::filesystem::path& path, uint32_t channels,
            uint32_t sample_rate, std::string* error) {
    wav::WriterOptions options;
    options.channels = static_cast<uint16_t>(channels);
    options.sample_rate = sample_rate;
    options.format = wav::WriteFormat::kFloat32;
    wav::Result<wav::Writer> created =
        wav::Writer::Create(path.string(), options);
    if (!created.ok()) {
      *error = created.error();
      return false;
    }
    writer_.emplace(std::move(created.value()));
    channels_.assign(channels, nullptr);
    return true;
  }

  LoudnessAnalysisSink::ProgramTap Tap() {
    return [this](const float* rendered, uint32_t stride, uint32_t first,
                  uint32_t count) { Append(rendered, stride, first, count); };
  }

  // Finalizes the file after the pass. Returns false with `error` set
  // when a write or the finalize failed.
  bool Finish(std::string* error) {
    if (error_.empty()) {
      const wav::Status status = writer_->Finalize();
      if (!status.ok()) error_ = status.message();
    }
    *error = error_;
    return error_.empty();
  }

 private:
  void Append(const float* rendered, uint32_t stride, uint32_t first,
              uint32_t count) {
    if (!error_.empty()) return;
    for (size_t c = 0; c < channels_.size(); ++c) {
      channels_[c] = rendered + c * stride + first;
    }
    const wav::Status status =
        writer_->PushPlanarFloat(channels_.data(), count);
    if (!status.ok()) error_ = status.message();
  }

  std::optional<wav::Writer> writer_;
  std::vector<const float*> channels_;
  std::string error_;
};

// Decodes the IAMF file at `path` (.iamf or IAMF-in-MP4), renders audio
// elements at `layout` and measures the render, the QC Loudness Report's
// path (ES-520). `listed` names the elements and their static mix gains;
// when it is null, every renderable element renders at 0 dB.
int MeasureIamf(const std::string& path, const LayoutSpec& layout,
                const std::vector<ElementSpec>* listed, float output_gain_db,
                const IamfMeasureOptions& options, std::ostream& out,
                std::ostream& err) {
  // The output files are written into scratch directories beside their
  // paths and moved onto them only once the pass and both writes have
  // succeeded, so a failure leaves earlier files at the paths as they
  // were. Creating the directories first also stops a path whose
  // directory does not exist before the pass runs.
  std::optional<ScratchDir> wav_scratch;
  std::optional<ScratchDir> json_scratch;
  const auto make_scratch = [&err](const std::string& target,
                                   std::optional<ScratchDir>* scratch) {
    if (target.empty()) return true;
    scratch->emplace(std::filesystem::path(target));
    if ((*scratch)->ok()) return true;
    err << "error: cannot create a scratch directory beside " << target << ": "
        << (*scratch)->error() << "\n";
    return false;
  };
  if (!make_scratch(options.render_wav_path, &wav_scratch) ||
      !make_scratch(options.trace_json_path, &json_scratch)) {
    return 2;
  }

  OfflineIamfMeasurer measurer;
  if (!measurer.SetLimiterEnabled(options.limiter)) {
    err << "error: the renderer refused to turn the limiter "
        << (options.limiter ? "on" : "off") << "\n";
    return 2;
  }
  if (!measurer.Open(path, kMeasureBlockSize, layout.oar_value)) {
    err << "error: " << path
        << " is not a WAV file, and reading it as IAMF failed: "
        << measurer.last_error() << "\n";
    return 2;
  }

  if (listed != nullptr) {
    for (const ElementSpec& element : *listed) {
      if (!measurer.IncludeElement(element.audio_element_id,
                                   element.mix_gain_db, 1, 0)) {
        // An id the file does not have or cannot render is an argument
        // that does not fit the input; anything else is a failure.
        const std::string& error = measurer.last_error();
        err << "error: " << error << "\n";
        const bool argument_error = error.rfind("invalid_argument:", 0) == 0 ||
                                    error.rfind("unsupported:", 0) == 0;
        return argument_error ? 1 : 2;
      }
    }
  } else {
    for (uint32_t i = 0; i < measurer.num_elements(); ++i) {
      const OfflineIamfMeasurer::ElementInfo info = measurer.element(i);
      if (!info.renderable) {
        err << "note: skipping audio element " << info.audio_element_id
            << " (not renderable)\n";
        continue;
      }
      if (!measurer.IncludeElement(info.audio_element_id, 0.0f, 1, 0)) {
        err << "error: " << measurer.last_error() << "\n";
        return 2;
      }
    }
  }
  measurer.SetOutputMixGain(output_gain_db);

  // --render-wav: the sink hands each block's program frames to the
  // writer's tap. Declared after the scratch directories, so the writer
  // closes its file before a failed pass removes them.
  RenderWavWriter render_wav;
  std::filesystem::path staged_wav;
  if (wav_scratch.has_value()) {
    staged_wav = wav_scratch->path() / "render.wav";
    std::string error;
    if (!render_wav.Open(staged_wav, measurer.output_channels(),
                         measurer.sample_rate(), &error)) {
      err << "error: cannot write " << options.render_wav_path << ": " << error
          << "\n";
      return 2;
    }
    measurer.SetProgramTap(render_wav.Tap());
  }

  const std::optional<LoudnessResult> result = measurer.Measure();
  measurer.SetProgramTap({});
  if (!result.has_value()) {
    err << "error: " << measurer.last_error() << "\n";
    return 2;
  }
  if (wav_scratch.has_value()) {
    std::string error;
    if (!render_wav.Finish(&error)) {
      err << "error: cannot write " << options.render_wav_path << ": " << error
          << "\n";
      return 2;
    }
  }

  const std::vector<float> gr = CopySeries(measurer, kTraceLimiterGrDb);
  const float gr_max_db =
      gr.empty() ? 0.0f : *std::max_element(gr.begin(), gr.end());
  std::filesystem::path staged_json;
  if (json_scratch.has_value()) {
    staged_json = json_scratch->path() / "trace.json";
    if (!WriteTraceJson(staged_json, layout, options.limiter, measurer, *result,
                        gr_max_db)) {
      err << "error: cannot write " << options.trace_json_path << "\n";
      return 2;
    }
  }

  // Both outputs are complete; move them onto their paths.
  const auto move_onto = [&err](const std::filesystem::path& staged,
                                const std::string& target) {
    if (staged.empty()) return true;
    std::error_code ec;
    std::filesystem::rename(staged, std::filesystem::path(target), ec);
    if (!ec) return true;
    err << "error: cannot move the output to " << target << ": " << ec.message()
        << "\n";
    return false;
  };
  if (!move_onto(staged_wav, options.render_wav_path) ||
      !move_onto(staged_json, options.trace_json_path)) {
    return 2;
  }

  float lra = 0.0f;
  bool lra_stable = false;
  const bool has_lra = measurer.GetLoudnessRange(&lra, &lra_stable);
  out << std::fixed << std::setprecision(2)
      << "sample_rate=" << measurer.sample_rate() << "\n"
      << "total_frames=" << measurer.total_frames() << "\n"
      << "integrated_lufs=" << result->integrated_lufs << "\n"
      << "true_peak_dbtp=" << result->true_peak_dbtp << "\n"
      << "digital_peak_dbfs=" << result->digital_peak_dbfs << "\n";
  if (has_lra) out << "loudness_range_lu=" << lra << "\n";
  out << "limiter=" << (options.limiter ? "on" : "off") << "\n"
      << "limiter_gr_max_db=" << gr_max_db << "\n";
  return 0;
}

// The container an encode --out path names by its extension, compared
// without regard to case. nullopt for any other extension.
enum class OutputContainer : uint8_t { kIamf, kMp4 };
std::optional<OutputContainer> OutputContainerFor(const std::string& path) {
  std::string ext = std::filesystem::path(path).extension().string();
  std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  if (ext == ".iamf") return OutputContainer::kIamf;
  if (ext == ".mp4") return OutputContainer::kMp4;
  return std::nullopt;
}

// Reports an IamfExporter::EncodePush failure code with a short reason
// that covers every condition the exporter returns the code for. The
// exporter writes the details, such as the iamf-tools status, to the
// engine log, which RunCli prints after this line.
void ReportEncodeError(int32_t rc, std::ostream& err) {
  std::string reason;
  switch (rc) {
    case -10:
      reason = "textproto parse failure";
      break;
    case -11:
      reason =
          "num_samples_per_frame in the codec config is missing, zero or "
          "larger than " +
          std::to_string(ElementStream::kMaxPullFrames);
      break;
    case -12:
      reason =
          "the config's audio_frame_metadata does not match the input WAVs "
          "or is inconsistent";
      break;
    case -13:
      reason = "cannot open an input WAV";
      break;
    case -14:
      reason =
          "the input WAVs are empty, differ in length, or end before their "
          "declared length";
      break;
    default:
      break;
  }
  err << "error: encode failed (rc=" << rc << ")";
  if (!reason.empty()) err << ": " << reason;
  err << "\n";
}

// Reports an IamfMuxer::ProbeVideo failure for the --video file `video`.
void ReportVideoProbeError(int32_t rc, const std::string& video,
                           std::ostream& err) {
  switch (rc) {
    case -3:
      err << "error: cannot read --video file: " << video << "\n";
      break;
    case -10:
      err << "error: GPAC system init failed\n";
      break;
    case -12:
      err << "error: --video is not an MP4 or MOV file that GPAC can open: "
          << video << "\n";
      break;
    case -13:
      err << "error: --video has no video track: " << video << "\n";
      break;
    default:
      err << "error: --video check failed (rc=" << rc << "): " << video << "\n";
      break;
  }
}

// Reports an IamfMuxer::Mux or MuxAudioOnly failure.
void ReportMuxError(int32_t rc, const std::string& video, std::ostream& err) {
  switch (rc) {
    case -3:
      err << "error: cannot read --video file: " << video << "\n";
      break;
    case -10:
      err << "error: GPAC system init failed\n";
      break;
    case -11:
      err << "error: writing the IAMF track into the MP4 failed (one cause: "
             "GPAC's MP4 writer accepts the Simple, Base and Base-Enhanced "
             "profiles only)\n";
      break;
    case -12:
      err << "error: copying the video track into the MP4 failed\n";
      break;
    default:
      err << "error: MP4 mux failed (rc=" << rc << ")\n";
      break;
  }
}

// Encodes `config` into the file `out`, whose extension selects a raw
// .iamf or an IAMF-in-MP4, with the video track of `video` stream-copied
// into the MP4 when `video` is non-empty. The encode and the mux write
// into a scratch directory beside `out`, and the result is renamed onto
// `out` only after every step succeeded, so a failure leaves any earlier
// file at `out` as it was.
int EncodeToFile(const std::string& config, const std::string& wav_dir,
                 const std::string& out_path, OutputContainer container,
                 const std::string& video, std::ostream& out,
                 std::ostream& err) {
  IamfMuxer muxer;
  if (!video.empty()) {
    // Checked before the encode, as the app's export does (ES-742), so an
    // unusable video fails in seconds instead of after the encode.
    const int32_t rc = muxer.ProbeVideo(video);
    if (rc != 0) {
      ReportVideoProbeError(rc, video, err);
      return 2;
    }
  }

  const ScratchDir scratch{std::filesystem::path(out_path)};
  if (!scratch.ok()) {
    err << "error: cannot create a scratch directory beside " << out_path
        << ": " << scratch.error() << "\n";
    return 2;
  }
  const std::filesystem::path encoded = scratch.path() / "encoded.iamf";
  IamfExporter exporter;
  const int32_t rc =
      exporter.EncodePushFromWavDirToFile(config, wav_dir, encoded.string());
  if (rc != 0) {
    ReportEncodeError(rc, err);
    return 2;
  }

  std::filesystem::path result = encoded;
  if (container == OutputContainer::kMp4) {
    result = scratch.path() / "muxed.mp4";
    const int32_t mux_rc =
        video.empty() ? muxer.MuxAudioOnly(encoded.string(), result.string())
                      : muxer.Mux(encoded.string(), video, result.string());
    if (mux_rc != 0) {
      ReportMuxError(mux_rc, video, err);
      return 2;
    }
  }

  std::error_code ec;
  std::filesystem::rename(result, std::filesystem::path(out_path), ec);
  if (ec) {
    err << "error: cannot move the output to " << out_path << ": "
        << ec.message() << "\n";
    return 2;
  }
  out << "ok\n";
  return 0;
}

// Where PrintEngineLog writes: the running command's error stream, or
// null, which discards the entry. A file-static because the log
// callback type has no context argument.
std::ostream* g_engine_log_err = nullptr;

// Engine log callback: prints a WARN or ERROR entry to the command's
// error stream. The drain hands over malloc'd copies of both strings,
// which this frees on every path.
void PrintEngineLog(EclipsaStudioLogLevel level, const char* category,
                    const char* message) noexcept {
  if (g_engine_log_err != nullptr && level >= ECLIPSA_STUDIO_LOG_WARN) {
    *g_engine_log_err << "engine "
                      << (level == ECLIPSA_STUDIO_LOG_ERROR ? "error"
                                                            : "warning")
                      << " [" << category << "]: " << message << "\n";
  }
  std::free(const_cast<char*>(category));
  std::free(const_cast<char*>(message));
}

// Routes the engine log to `err` for the lifetime of the object: the
// constructor discards entries staged before it, and the destructor
// prints the WARN and ERROR entries the command logged. The engine
// stages every log message in a ring that only a drain delivers, so
// without this the CLI would print a failure code but not its reason.
class EngineLogToStream {
 public:
  explicit EngineLogToStream(std::ostream& err) {
    eclipsa_studio_set_log_callback(PrintEngineLog);
    eclipsa_studio_rt_log_drain();
    g_engine_log_err = &err;
  }
  ~EngineLogToStream() {
    eclipsa_studio_rt_log_drain();
    g_engine_log_err = nullptr;
    eclipsa_studio_set_log_callback(nullptr);
  }
  EngineLogToStream(const EngineLogToStream&) = delete;
  EngineLogToStream& operator=(const EngineLogToStream&) = delete;
};

}  // namespace

InputKind DetectInputKind(const std::string& path) {
  std::error_code ec;
  if (!std::filesystem::is_regular_file(std::filesystem::path(path), ec)) {
    return InputKind::kUnreadable;
  }
  std::ifstream file(path, std::ios::binary);
  if (!file) return InputKind::kUnreadable;
  // The header engine/wav accepts: RIFF, RF64 or BW64, a 4-byte size,
  // then the WAVE form type.
  char header[12] = {};
  file.read(header, sizeof(header));
  if (file.gcount() != static_cast<std::streamsize>(sizeof(header))) {
    return InputKind::kOther;
  }
  const bool riff = std::memcmp(header, "RIFF", 4) == 0 ||
                    std::memcmp(header, "RF64", 4) == 0 ||
                    std::memcmp(header, "BW64", 4) == 0;
  return riff && std::memcmp(header + 8, "WAVE", 4) == 0 ? InputKind::kWav
                                                         : InputKind::kOther;
}

int RunBounce(const std::vector<std::string>& args, std::ostream& out,
              std::ostream& err) {
  if (WantsHelp(args)) {
    out << kBounceUsage;
    return 0;
  }
  ParsedArgs p;
  if (!ParseArgs(args, {"--gain-db", "--routing", "--pad-frames", "--rate"}, {},
                 &p, err)) {
    return 1;
  }
  if (p.positional.size() != 2) {
    err << kBounceUsage;
    return 1;
  }

  const std::string& in_path = p.positional[0];
  const std::string& out_path = p.positional[1];
  ElementBouncer::Config cfg;
  cfg.input_wav_path = in_path;
  if (p.flags.count("--gain-db") &&
      !ParseGainDb(p.flags["--gain-db"], &cfg.gain_db)) {
    err << "error: bad --gain-db value '" << p.flags["--gain-db"] << "'\n";
    return 1;
  }
  if (p.flags.count("--pad-frames") &&
      !ParseUnsigned(p.flags["--pad-frames"], UINT64_MAX, &cfg.pad_to_frames)) {
    err << "error: bad --pad-frames value '" << p.flags["--pad-frames"]
        << "'\n";
    return 1;
  }
  if (p.flags.count("--rate")) {
    uint64_t rate = 0;
    if (!ParseUnsigned(p.flags["--rate"], UINT32_MAX, &rate)) {
      err << "error: bad --rate value '" << p.flags["--rate"] << "'\n";
      return 1;
    }
    cfg.output_sample_rate = static_cast<uint32_t>(rate);
  }
  if (p.flags.count("--routing") &&
      !ParseRouting(p.flags["--routing"], &cfg.routing, err)) {
    return 1;
  }

  // The bounce reads the whole input before the rename onto the output,
  // so the same file would work, but it would replace the source WAV
  // (ES-850).
  std::error_code dir_ec;
  if (std::filesystem::is_directory(std::filesystem::path(out_path), dir_ec)) {
    err << "error: the output is a directory: " << out_path << "\n";
    return 1;
  }
  std::error_code same_file_ec;
  if (std::filesystem::equivalent(std::filesystem::path(in_path),
                                  std::filesystem::path(out_path),
                                  same_file_ec)) {
    err << "error: the output must not be the input file: " << out_path << "\n";
    return 1;
  }

  // The bounce writes into a scratch directory beside the output, and the
  // result is renamed onto it only on success, so a failure leaves any
  // earlier file at the output as it was.
  const ScratchDir scratch{std::filesystem::path(out_path)};
  if (!scratch.ok()) {
    err << "error: cannot create a scratch directory beside " << out_path
        << ": " << scratch.error() << "\n";
    return 2;
  }
  const std::filesystem::path bounced = scratch.path() / "bounced.wav";
  cfg.output_wav_path = bounced.string();

  const int32_t rc = ElementBouncer::Bounce(cfg);
  switch (rc) {
    case 0:
      break;
    case -1:
      err << "error: failed to open input WAV: " << in_path << "\n";
      return 2;
    case -2:
      err << "error: failed to open the output WAV in a scratch directory "
             "beside "
          << out_path << "\n";
      return 2;
    default:
      err << "error: bounce failed (rc=" << rc << ")\n";
      return 2;
  }

  std::error_code ec;
  std::filesystem::rename(bounced, std::filesystem::path(out_path), ec);
  if (ec) {
    err << "error: cannot move the output to " << out_path << ": "
        << ec.message() << "\n";
    return 2;
  }
  out << "ok\n";
  return 0;
}

// measure: routes by content. A WAV file is measured as a rendered mix;
// anything else goes to the IAMF measurer, which reads a raw IA sequence
// or an MP4 with an IAMF track and reports its own errors. `--elements`
// lists audio element ids with an optional static mix gain each
// (`300:-3,301`); without it every renderable element renders at 0 dB.
int RunMeasure(const std::vector<std::string>& args, std::ostream& out,
               std::ostream& err) {
  if (WantsHelp(args)) {
    out << MeasureUsage();
    return 0;
  }
  ParsedArgs p;
  if (!ParseArgs(args,
                 {"--layout", "--elements", "--output-gain-db",
                  "--channel-order", "--trace-json", "--render-wav"},
                 {"--no-limiter"}, &p, err)) {
    return 1;
  }
  if (p.positional.size() != 1 || !p.flags.count("--layout")) {
    err << MeasureUsage();
    return 1;
  }
  const LayoutSpec* layout = FindLayout(p.flags["--layout"]);
  if (layout == nullptr) {
    err << "error: unknown layout '" << p.flags["--layout"] << "' ("
        << LayoutNames() << ")\n";
    return 1;
  }

  // `--elements` and `--output-gain-db` are parsed before the file is
  // opened, so a value that does not parse is a usage error whether or
  // not the file can be read.
  std::vector<ElementSpec> listed;
  const bool has_elements = p.flags.count("--elements") != 0;
  if (has_elements && !ParseElements(p.flags["--elements"], &listed, err)) {
    return 1;
  }
  float output_gain_db = 0.0f;
  if (p.flags.count("--output-gain-db") &&
      !ParseGainDb(p.flags["--output-gain-db"], &output_gain_db)) {
    err << "error: bad --output-gain-db value '" << p.flags["--output-gain-db"]
        << "'\n";
    return 1;
  }
  // --channel-order names the order of a 9.1.6 WAV's channels; a 9.1.6
  // WAV without it is read in the alt order.
  uint32_t channel_order = layout->oar_value == kOarLayout916
                               ? kChannelOrder916Alt
                               : kChannelOrderOar;
  if (p.flags.count("--channel-order")) {
    const std::string& value = p.flags["--channel-order"];
    if (layout->oar_value != kOarLayout916) {
      err << "error: --channel-order applies to the 9.1.6 layout only\n";
      return 1;
    }
    if (value == "alt") {
      channel_order = kChannelOrder916Alt;
    } else if (value == "iamf") {
      channel_order = kChannelOrderOar;
    } else {
      err << "error: bad --channel-order value '" << value
          << "' (alt or iamf)\n";
      return 1;
    }
  }

  const std::string& path = p.positional[0];
  const InputKind kind = DetectInputKind(path);
  if (kind == InputKind::kUnreadable) {
    err << "error: cannot read input file: " << path << "\n";
    return 2;
  }
  const bool limiter = p.flags.count("--no-limiter") == 0;
  if (kind == InputKind::kWav) {
    for (const char* flag :
         {"--elements", "--output-gain-db", "--trace-json", "--render-wav"}) {
      if (p.flags.count(flag)) {
        err << "error: " << flag << " applies to IAMF input only; " << path
            << " is a WAV file\n";
        return 1;
      }
    }
    return MeasureWav(path, *layout, channel_order, limiter, out, err);
  }
  if (p.flags.count("--channel-order")) {
    err << "error: --channel-order applies to WAV input only; " << path
        << " is an IAMF file\n";
    return 1;
  }
  // Each output names a file that is neither a directory, the input
  // (the move after the pass would replace it) nor the other output.
  for (const char* flag : {"--trace-json", "--render-wav"}) {
    if (!p.flags.count(flag)) continue;
    const std::string& target = p.flags[flag];
    if (target.empty()) {
      err << "error: " << flag << " expects a file path\n";
      return 1;
    }
    std::error_code ec;
    if (std::filesystem::is_directory(std::filesystem::path(target), ec)) {
      err << "error: " << flag << " names a directory: " << target << "\n";
      return 1;
    }
    if (std::filesystem::equivalent(std::filesystem::path(path),
                                    std::filesystem::path(target), ec)) {
      err << "error: " << flag << " names the input file " << path << "\n";
      return 1;
    }
  }
  if (p.flags.count("--trace-json") && p.flags.count("--render-wav") &&
      NormalPath(p.flags["--trace-json"]) ==
          NormalPath(p.flags["--render-wav"])) {
    err << "error: --trace-json and --render-wav name the same file\n";
    return 1;
  }
  IamfMeasureOptions options;
  options.limiter = limiter;
  if (p.flags.count("--trace-json")) {
    options.trace_json_path = p.flags["--trace-json"];
  }
  if (p.flags.count("--render-wav")) {
    options.render_wav_path = p.flags["--render-wav"];
  }
  return MeasureIamf(path, *layout, has_elements ? &listed : nullptr,
                     output_gain_db, options, out, err);
}

int RunMeasureIamf(const std::vector<std::string>& args, std::ostream& out,
                   std::ostream& err) {
  return RunMeasure(args, out, err);
}

int RunEncode(const std::vector<std::string>& args, std::ostream& out,
              std::ostream& err) {
  if (WantsHelp(args)) {
    out << kEncodeUsage;
    return 0;
  }
  ParsedArgs p;
  if (!ParseArgs(args, {"--wav-dir", "--out", "--out-dir", "--video"}, {}, &p,
                 err)) {
    return 1;
  }
  const bool has_out = p.flags.count("--out") != 0;
  const bool has_out_dir = p.flags.count("--out-dir") != 0;
  if (has_out && has_out_dir) {
    err << "error: --out and --out-dir cannot be used together\n"
        << kEncodeUsage;
    return 1;
  }
  if (p.positional.size() != 1 || !p.flags.count("--wav-dir") ||
      (!has_out && !has_out_dir)) {
    err << kEncodeUsage;
    return 1;
  }
  std::optional<OutputContainer> container;
  if (has_out) {
    container = OutputContainerFor(p.flags["--out"]);
    if (!container.has_value()) {
      err << "error: --out needs a file name ending in .iamf or .mp4: "
          << p.flags["--out"] << "\n";
      return 1;
    }
    std::error_code dir_ec;
    if (std::filesystem::is_directory(std::filesystem::path(p.flags["--out"]),
                                      dir_ec)) {
      err << "error: --out is a directory: " << p.flags["--out"] << "\n";
      return 1;
    }
  }
  const bool has_video = p.flags.count("--video") != 0;
  const std::string video = has_video ? p.flags["--video"] : "";
  if (has_video && container != OutputContainer::kMp4) {
    err << "error: --video needs an --out ending in .mp4\n";
    return 1;
  }
  if (has_video && video.empty()) {
    err << "error: --video expects a file path\n";
    return 1;
  }
  // The mux reads the whole video before the rename onto --out, so the
  // same path would work, but it would replace the source video.
  std::error_code same_file_ec;
  if (!video.empty() &&
      std::filesystem::equivalent(std::filesystem::path(p.flags["--out"]),
                                  std::filesystem::path(video), same_file_ec)) {
    err << "error: --out must not be the --video file: " << video << "\n";
    return 1;
  }

  std::ifstream config_file(p.positional[0]);
  if (!config_file) {
    err << "error: cannot read config: " << p.positional[0] << "\n";
    return 2;
  }
  std::stringstream config;
  config << config_file.rdbuf();

  if (has_out) {
    return EncodeToFile(config.str(), p.flags["--wav-dir"], p.flags["--out"],
                        *container, video, out, err);
  }
  IamfExporter exporter;
  const int32_t rc = exporter.EncodePushFromWavDir(
      config.str(), p.flags["--wav-dir"], p.flags["--out-dir"]);
  if (rc != 0) {
    ReportEncodeError(rc, err);
    return 2;
  }
  out << "ok\n";
  return 0;
}

int RunProbe(const std::vector<std::string>& args, std::ostream& out,
             std::ostream& err) {
  if (WantsHelp(args)) {
    out << kProbeUsage;
    return 0;
  }
  ParsedArgs p;
  if (!ParseArgs(args, {}, {"--json"}, &p, err)) return 1;
  if (p.positional.size() != 1) {
    err << kProbeUsage;
    return 1;
  }
  const std::string& path = p.positional[0];

  if (p.flags.count("--json")) {
    char* json = eclipsa_studio_iamf_probe_json(path.c_str());
    if (json == nullptr) {
      err << "error: probe allocation failed\n";
      return 2;
    }
    const bool failed = std::strstr(json, "\"ok\":false") != nullptr;
    out << json << "\n";
    eclipsa_studio_iamf_probe_json_free(json);
    return failed ? 2 : 0;
  }

  EclipsaStudioIamfProbeResult* r = eclipsa_studio_iamf_probe(path.c_str());
  if (r == nullptr) {
    err << "error: probe allocation failed\n";
    return 2;
  }
  if (r->status != 0) {
    err << "error: "
        << (r->error_message != nullptr ? r->error_message : "probe failed")
        << "\n";
    eclipsa_studio_iamf_probe_free(r);
    return 2;
  }

  out << "sample_rate=" << r->sample_rate << "\n"
      << "total_samples=" << r->total_samples << "\n";
  if (r->sample_rate > 0) {
    out << std::fixed << std::setprecision(3) << "duration_sec="
        << static_cast<double>(r->total_samples) / r->sample_rate << "\n";
  }
  out << "audio_elements=" << r->num_audio_elements << "\n";
  for (uint32_t i = 0; i < r->num_audio_elements; ++i) {
    const EclipsaStudioIamfAe& ae = r->audio_elements[i];
    out << "ae[" << i << "] id=" << ae.audio_element_id << " type=" << ae.type
        << " channels=" << ae.num_channels
        << " ambisonics_order=" << ae.ambisonics_order
        << " layout=" << (ae.layout_label != nullptr ? ae.layout_label : "-")
        << " renderable=" << ae.renderable << " skip_reason=" << ae.skip_reason
        << "\n";
  }
  out << "mix_presentations=" << r->num_mix_presentations << "\n";
  for (uint32_t i = 0; i < r->num_mix_presentations; ++i) {
    const EclipsaStudioIamfMixPresentation& mp = r->mix_presentations[i];
    out << "mp[" << i << "] id=" << mp.mix_presentation_id
        << " name=" << (mp.name != nullptr ? mp.name : "-")
        << " elements=" << mp.num_elements
        << " loudness_lufs=" << mp.loudness_lufs
        << " true_peak_dbtp=" << mp.true_peak_dbtp << "\n";
  }
  eclipsa_studio_iamf_probe_free(r);
  return 0;
}

int RunCatchingExceptions(const std::function<int()>& subcommand,
                          std::ostream& err) {
  try {
    return subcommand();
  } catch (const std::exception& e) {
    err << "error: " << e.what() << "\n";
    return 2;
  }
}

int RunCli(int argc, const char* const* argv, std::ostream& out,
           std::ostream& err) {
  if (argc < 2) {
    err << kUsage;
    return 1;
  }
  const std::string cmd = argv[1];
  if (cmd == "--help" || cmd == "-h" || cmd == "help") {
    out << kUsage;
    return 0;
  }
  const std::vector<std::string> args(argv + 2, argv + argc);
  const EngineLogToStream engine_log_to_err(err);
  return RunCatchingExceptions(
      [&]() {
        if (cmd == "bounce") return RunBounce(args, out, err);
        if (cmd == "measure") return RunMeasure(args, out, err);
        if (cmd == "measure-iamf") return RunMeasureIamf(args, out, err);
        if (cmd == "encode") return RunEncode(args, out, err);
        if (cmd == "probe") return RunProbe(args, out, err);
        err << "error: unknown subcommand '" << cmd << "'\n" << kUsage;
        return 1;
      },
      err);
}

}  // namespace eclipsa_studio::cli
