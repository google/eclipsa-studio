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
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <map>
#include <optional>
#include <sstream>

#include "bounce/element_bouncer.h"
#include "iamf/iamf_exporter.h"
#include "iamf/iamf_probe_ffi.h"
#include "io/wav_reader.h"
#include "mix_renderer/offline_mix_renderer.h"

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
    if (i + 1 >= args.size()) {
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

std::string LayoutNames() {
  std::string names;
  for (const auto& l : kLayouts) {
    if (!names.empty()) names += "|";
    names += l.name;
  }
  return names;
}

}  // namespace

int RunBounce(const std::vector<std::string>& args, std::ostream& out,
              std::ostream& err) {
  ParsedArgs p;
  if (!ParseArgs(args, {"--gain-db", "--routing", "--pad-frames", "--rate"}, {},
                 &p, err)) {
    return 1;
  }
  if (p.positional.size() != 2) {
    err << "usage: eclipsa_studio_cli bounce <in.wav> <out.wav> [--gain-db G]\n"
        << "         [--routing 1,0,-1] [--pad-frames N] [--rate R]\n";
    return 1;
  }

  ElementBouncer::Config cfg;
  cfg.input_wav_path = p.positional[0];
  cfg.output_wav_path = p.positional[1];
  try {
    if (p.flags.count("--gain-db")) {
      cfg.gain_db = std::stof(p.flags["--gain-db"]);
    }
    if (p.flags.count("--pad-frames")) {
      cfg.pad_to_frames = std::stoull(p.flags["--pad-frames"]);
    }
    if (p.flags.count("--rate")) {
      cfg.output_sample_rate =
          static_cast<uint32_t>(std::stoul(p.flags["--rate"]));
    }
  } catch (const std::exception&) {
    err << "error: bad numeric flag value\n";
    return 1;
  }
  if (p.flags.count("--routing") &&
      !ParseRouting(p.flags["--routing"], &cfg.routing, err)) {
    return 1;
  }

  const int32_t rc = ElementBouncer::Bounce(cfg);
  switch (rc) {
    case 0:
      out << "ok\n";
      return 0;
    case -1:
      err << "error: failed to open input WAV: " << cfg.input_wav_path << "\n";
      return 2;
    case -2:
      err << "error: failed to open output WAV: " << cfg.output_wav_path
          << "\n";
      return 2;
    default:
      err << "error: bounce failed (rc=" << rc << ")\n";
      return 2;
  }
}

int RunMeasure(const std::vector<std::string>& args, std::ostream& out,
               std::ostream& err) {
  ParsedArgs p;
  if (!ParseArgs(args, {"--layout"}, {}, &p, err)) return 1;
  if (p.positional.size() != 1 || !p.flags.count("--layout")) {
    err << "usage: eclipsa_studio_cli measure <mix.wav> --layout <"
        << LayoutNames() << ">\n";
    return 1;
  }
  const LayoutSpec* layout = FindLayout(p.flags["--layout"]);
  if (layout == nullptr) {
    err << "error: unknown layout '" << p.flags["--layout"] << "' ("
        << LayoutNames() << ")\n";
    return 1;
  }

  const std::string& wav_path = p.positional[0];
  WavReader reader;
  if (!reader.open(wav_path.c_str())) {
    err << "error: failed to open WAV: " << wav_path << "\n";
    return 2;
  }
  const uint32_t channels = reader.channels();
  const uint32_t sample_rate = reader.sample_rate();
  reader.close();
  if (channels != layout->channels) {
    err << "error: " << wav_path << " has " << channels << " channels but "
        << layout->name << " expects " << layout->channels << "\n";
    return 1;
  }

  // Render the WAV as a channel-bed element at its own layout into the
  // same target layout (≈ passthrough) and measure — identical to the
  // app's export-time loudness measurement path.
  OfflineMixRenderer renderer;
  if (!renderer.Init(sample_rate, 1024, layout->oar_value)) {
    err << "error: renderer init failed (layout " << layout->name << ")\n";
    return 2;
  }
  MixElementConfig element;
  element.element_id = 1;
  // Identity stream: no gain/routing/pad/rate — reads the file as-is.
  element.stream.input_wav_path = wav_path;
  element.element_type = 0;  // channel-based
  element.element_sub_type = static_cast<int>(layout->oar_value);
  element.channels = channels;
  // No gain flag: mix_gain_db does not propagate through the offline
  // renderer's measurement path (verified empirically) — apply gain
  // with `bounce --gain-db` first if a scaled measurement is needed.
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

int RunEncode(const std::vector<std::string>& args, std::ostream& out,
              std::ostream& err) {
  ParsedArgs p;
  if (!ParseArgs(args, {"--wav-dir", "--out-dir"}, {}, &p, err)) return 1;
  if (p.positional.size() != 1 || !p.flags.count("--wav-dir") ||
      !p.flags.count("--out-dir")) {
    err << "usage: eclipsa_studio_cli encode <config.textproto> --wav-dir D "
           "--out-dir O\n";
    return 1;
  }

  std::ifstream config_file(p.positional[0]);
  if (!config_file) {
    err << "error: cannot read config: " << p.positional[0] << "\n";
    return 2;
  }
  std::stringstream config;
  config << config_file.rdbuf();

  IamfExporter exporter;
  const int32_t rc = exporter.EncodePushFromWavDir(
      config.str(), p.flags["--wav-dir"], p.flags["--out-dir"]);
  if (rc != 0) {
    err << "error: encode failed (rc=" << rc << ")"
        << (rc == -10 ? " — textproto parse failure" : "") << "\n";
    return 2;
  }
  out << "ok\n";
  return 0;
}

int RunProbe(const std::vector<std::string>& args, std::ostream& out,
             std::ostream& err) {
  ParsedArgs p;
  if (!ParseArgs(args, {}, {"--json"}, &p, err)) return 1;
  if (p.positional.size() != 1) {
    err << "usage: eclipsa_studio_cli probe <file.iamf> [--json]\n";
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

int RunCli(int argc, const char* const* argv, std::ostream& out,
           std::ostream& err) {
  const std::string usage =
      "usage: eclipsa_studio_cli <bounce|measure|encode|probe> ...\n"
      "  bounce  <in.wav> <out.wav> [--gain-db G] [--routing 1,0,-1]\n"
      "          [--pad-frames N] [--rate R]\n"
      "  measure <mix.wav> --layout <name>\n"
      "  encode  <config.textproto> --wav-dir D --out-dir O\n"
      "  probe   <file.iamf> [--json]\n";
  if (argc < 2) {
    err << usage;
    return 1;
  }
  const std::string cmd = argv[1];
  std::vector<std::string> args(argv + 2, argv + argc);
  if (cmd == "bounce") return RunBounce(args, out, err);
  if (cmd == "measure") return RunMeasure(args, out, err);
  if (cmd == "encode") return RunEncode(args, out, err);
  if (cmd == "probe") return RunProbe(args, out, err);
  err << "error: unknown subcommand '" << cmd << "'\n" << usage;
  return 1;
}

}  // namespace eclipsa_studio::cli
