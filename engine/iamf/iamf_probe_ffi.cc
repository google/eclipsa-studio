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

#include "iamf/iamf_probe_ffi.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <optional>
#include <string>
#include <vector>

#include "absl/types/span.h"
#include "engine_log.h"
#include "iamf/cli/probe.h"
#include "iamf/cli/probe_json.h"
#include "iamf/iamf_demuxer.h"
#include "iamf/include/iamf_tools/iamf_stream_interface.h"
#include "iamf/read_only_file_map.h"
#include "renderer/oar_capability.h"

namespace {

// Heap-duplicate a std::string. std::string's buffer is NUL-terminated
// as of C++11 but we copy explicitly to avoid depending on that.
// Returns nullptr on allocation failure or when `s` is empty (the
// caller treats empty strings as "absent" and the Dart side turns a
// NULL pointer into a null Dart string).
char* DupStr(const std::string& s) {
  if (s.empty()) return nullptr;
  char* out = static_cast<char*>(std::malloc(s.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, s.data(), s.size());
  out[s.size()] = '\0';
  return out;
}

EclipsaStudioIamfProbeResult* MakeErrorResult(int32_t status,
                                              const std::string& msg) {
  auto* result = static_cast<EclipsaStudioIamfProbeResult*>(
      std::calloc(1, sizeof(EclipsaStudioIamfProbeResult)));
  if (result == nullptr) return nullptr;
  result->status = status;
  result->error_message = DupStr(msg);
  return result;
}

int32_t MapAeType(const std::string& type) {
  if (type == "channel_based") return 0;
  if (type == "scene_based") return 1;
  if (type == "object_based") return 2;
  return -1;
}

// Picks the human-readable layout label the source tab should show.
// For channel-based AEs with an "Expanded" top-level layout the
// expanded layout name is more informative; for everything else the
// top-level label is what users recognise.
std::string DeriveLayoutLabel(const iamf_tools::AudioElementReport& ae) {
  if (!ae.scalable_layers.empty()) {
    const auto& top = ae.scalable_layers.front();
    if (top.loudspeaker_layout == "Expanded" &&
        top.expanded_loudspeaker_layout.has_value()) {
      return *top.expanded_loudspeaker_layout;
    }
    return top.loudspeaker_layout;
  }
  if (ae.ambisonics.has_value() && ae.ambisonics->order.has_value()) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "Ambisonics Order %d",
                  *ae.ambisonics->order);
    return buf;
  }
  return {};
}

// Mapping a probe input via iamf/read_only_file_map.h (instead of
// slurping it into a vector) avoids double-buffering the entire IAMF in
// process memory: a 543 MB Opus file took ~3.4 s to slurp via ifstream
// and another 3.1 s on the inspector pass. The kernel keeps the same
// pages cached across successive `eclipsa_studio_iamf_probe`,
// `eclipsa_studio_playback_open`, and `eclipsa_studio_iamf_probe_json` calls,
// so the first call pays the page-in once and subsequent calls hit the cache.
// ReadOnlyFileMap carries the Windows backend (CreateFileMapping /
// MapViewOfFile) the POSIX-only io/file_mapping.h lacks.
absl::Span<const uint8_t> MappedSpan(const eclipsa_studio::ReadOnlyFileMap& m) {
  return absl::MakeConstSpan(m.data(), m.size());
}

// Resolves the bytes iamf_tools::Probe should read for `path`. A raw .iamf
// is probed straight from the mmap. An IAMF-in-ISOBMFF .mp4 is demuxed —
// the `iamf` track is extracted into `*scratch` (which the caller must keep
// alive across the Probe call) and a span over it is returned. Returns
// false and sets `*err` for an MP4 with no usable IAMF track.
bool ResolveProbeSpan(const char* path,
                      const eclipsa_studio::ReadOnlyFileMap& mapped,
                      std::vector<uint8_t>* scratch,
                      absl::Span<const uint8_t>* out_span, std::string* err) {
  if (!eclipsa_studio::IamfDemuxer::IsIsoBmff(mapped.data(), mapped.size())) {
    *out_span = MappedSpan(mapped);
    return true;
  }
  eclipsa_studio::IamfDemuxer demuxer;
  if (!demuxer.DemuxToBytes(path, scratch)) {
    *err = demuxer.last_error();
    return false;
  }
  // Hand the just-demuxed bitstream to the engine session that QC open runs
  // moments later, so it doesn't re-parse the same container (ES-215).
  eclipsa_studio::StashIamfDemux(path, *scratch);
  *out_span = absl::MakeConstSpan(scratch->data(), scratch->size());
  return true;
}

char* DupStringHeap(const std::string& s) {
  char* out = static_cast<char*>(std::malloc(s.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, s.data(), s.size());
  out[s.size()] = '\0';
  return out;
}

// Minimal RFC 8259 string escaper for the error path. The success path
// delegates JSON serialisation entirely to iamf_tools::ProbeReportToJson;
// only error reasons (IO messages, probe status text) are serialised
// here, so the mandatory escape set is enough.
std::string EscapeJson(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 2);
  for (const unsigned char c : s) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (c < 0x20) {
          char esc[8];
          std::snprintf(esc, sizeof(esc), "\\u%04x", c);
          out += esc;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out;
}

char* MakeJsonError(const std::string& reason) {
  return DupStringHeap("{\"ok\":false,\"error\":\"" + EscapeJson(reason) +
                       "\"}");
}

}  // namespace

extern "C" {

EclipsaStudioIamfProbeResult* eclipsa_studio_iamf_probe(const char* path) {
  if (path == nullptr) {
    return MakeErrorResult(-1, "eclipsa_studio_iamf_probe: null path");
  }

  using clock = std::chrono::steady_clock;
  const auto t0 = clock::now();

  std::string io_err;
  eclipsa_studio::ReadOnlyFileMap mapped;
  if (!mapped.open(path, &io_err)) {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf_probe", io_err.c_str());
    return MakeErrorResult(-2, io_err);
  }
  mapped.hint_sequential();
  const auto t_slurp = clock::now();

  // Descriptors only — no temporal-unit scan. A full scan walks every TU
  // (minutes on large files) just to sum total_samples, which the engine
  // session then re-derives authoritatively from
  // IamfStreamInterface::GetTotalSamples() a moment later. We still take
  // the descriptors-only `total_samples` the probe can derive without a
  // scan (currently FLAC, from STREAMINFO); it stays 0 for Opus/LPCM,
  // where the Playback UI shows the engine's value once the lazy scan
  // finishes.
  // .mp4 deliverables: demux the embedded `iamf` track first; raw .iamf is
  // probed straight from the mmap. `demux_scratch` backs the span below.
  std::vector<uint8_t> demux_scratch;
  absl::Span<const uint8_t> probe_span;
  std::string demux_err;
  if (!ResolveProbeSpan(path, mapped, &demux_scratch, &probe_span,
                        &demux_err)) {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf_probe", demux_err.c_str());
    // -5: MP4 demux failed (distinct from -2, which is mmap-open failure).
    return MakeErrorResult(-5, demux_err);
  }

  iamf_tools::ProbeOptions options;
  options.scan_mode = iamf_tools::ScanMode::kDescriptorsOnly;
  auto probe = iamf_tools::Probe(probe_span, options);
  const auto t_probe = clock::now();
  if (!probe.ok()) {
    std::string msg = std::string("iamf_tools::Probe: ") +
                      std::string(probe.status().message());
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf_probe", msg.c_str());
    return MakeErrorResult(-3, msg);
  }
  const iamf_tools::ProbeReport& report = *probe;

  auto* result = static_cast<EclipsaStudioIamfProbeResult*>(
      std::calloc(1, sizeof(EclipsaStudioIamfProbeResult)));
  if (result == nullptr) return nullptr;

  if (!report.codec_configs.empty()) {
    result->sample_rate = report.codec_configs.front().output_sample_rate;
  }
  if (report.descriptor_total_samples.has_value()) {
    result->total_samples = *report.descriptor_total_samples;
  }

  result->num_audio_elements =
      static_cast<uint32_t>(report.audio_elements.size());
  if (result->num_audio_elements > 0) {
    auto* aes = static_cast<EclipsaStudioIamfAe*>(
        std::calloc(result->num_audio_elements, sizeof(EclipsaStudioIamfAe)));
    if (aes == nullptr) {
      result->num_audio_elements = 0;
      eclipsa_studio_iamf_probe_free(result);
      return MakeErrorResult(-4, "out of memory allocating audio_elements");
    }
    for (uint32_t i = 0; i < result->num_audio_elements; ++i) {
      const auto& src = report.audio_elements[i];
      aes[i].audio_element_id = src.id;
      aes[i].type = MapAeType(src.type);
      const bool has_order =
          src.ambisonics.has_value() && src.ambisonics->order.has_value();
      aes[i].ambisonics_order = has_order ? *src.ambisonics->order : -1;
      aes[i].layout_label = DupStr(DeriveLayoutLabel(src));

      // Renderability = upstream's decode judgement AND the OAR
      // capability mapping — the same pair `eclipsa_studio_playback_open`
      // gates registration on (see the header note).
      const iamf_tools::api::AudioElementDescriptor d =
          iamf_tools::api::DescriptorFromProbeReport(src);
      aes[i].num_channels = d.num_channels;
      const bool oar_renderable =
          OarSubTypeForElement(aes[i].type, d.loudspeaker_layout_raw,
                               d.expanded_loudspeaker_layout_raw,
                               has_order ? *src.ambisonics->order : -1)
              .has_value();
      aes[i].renderable = (d.supported && oar_renderable) ? 1 : 0;
      if (aes[i].renderable != 0) {
        aes[i].skip_reason = ECLIPSA_STUDIO_AE_RENDERABLE;
      } else if (aes[i].type == 2) {
        aes[i].skip_reason = ECLIPSA_STUDIO_AE_SKIP_OBJECT_BASED;
      } else if (aes[i].type == -1) {
        aes[i].skip_reason = ECLIPSA_STUDIO_AE_SKIP_UNKNOWN_TYPE;
      } else if (!d.supported) {
        aes[i].skip_reason = ECLIPSA_STUDIO_AE_SKIP_NOT_DECODABLE;
      } else {
        aes[i].skip_reason = ECLIPSA_STUDIO_AE_SKIP_LAYOUT_NOT_RENDERABLE;
      }
    }
    result->audio_elements = aes;
  }

  result->num_mix_presentations =
      static_cast<uint32_t>(report.mix_presentations.size());
  if (result->num_mix_presentations > 0) {
    auto* mps = static_cast<EclipsaStudioIamfMixPresentation*>(
        std::calloc(result->num_mix_presentations,
                    sizeof(EclipsaStudioIamfMixPresentation)));
    if (mps == nullptr) {
      result->num_mix_presentations = 0;
      eclipsa_studio_iamf_probe_free(result);
      return MakeErrorResult(-4, "out of memory allocating mix_presentations");
    }
    for (uint32_t i = 0; i < result->num_mix_presentations; ++i) {
      const auto& src = report.mix_presentations[i];
      mps[i].mix_presentation_id = src.id;
      if (!src.annotations.empty()) {
        mps[i].language = DupStr(src.annotations.front().first);
        mps[i].name = DupStr(src.annotations.front().second);
      }
      mps[i].loudness_lufs =
          src.integrated_loudness_lkfs.has_value()
              ? static_cast<double>(*src.integrated_loudness_lkfs)
              : std::numeric_limits<double>::quiet_NaN();
      mps[i].true_peak_dbtp = src.true_peak_dbfs.has_value()
                                  ? static_cast<double>(*src.true_peak_dbfs)
                                  : std::numeric_limits<double>::quiet_NaN();

      // Derive layout + per-AE default gains from the first sub-mix.
      if (!src.sub_mixes.empty()) {
        const auto& sub = src.sub_mixes.front();
        const uint32_t n = static_cast<uint32_t>(sub.audio_elements.size());
        if (n > 0) {
          auto* els = static_cast<EclipsaStudioIamfMixElement*>(
              std::calloc(n, sizeof(EclipsaStudioIamfMixElement)));
          if (els != nullptr) {
            for (uint32_t j = 0; j < n; ++j) {
              els[j].audio_element_id = sub.audio_elements[j].audio_element_id;
              els[j].default_mix_gain_db =
                  sub.audio_elements[j].element_mix_gain.default_mix_gain;
            }
            mps[i].num_elements = n;
            mps[i].elements = els;
          }
        }
        if (!sub.layouts.empty()) {
          const auto& lay = sub.layouts.front().loudness_layout;
          mps[i].layout_type = DupStr(lay.layout_type);
          if (lay.sound_system.has_value()) {
            mps[i].sound_system = DupStr(*lay.sound_system);
          }
        }
      }
    }
    result->mix_presentations = mps;
  }

  {
    using ms = std::chrono::duration<double, std::milli>;
    const double d_slurp = ms(t_slurp - t0).count();
    const double d_probe = ms(t_probe - t_slurp).count();
    const double d_total = ms(clock::now() - t0).count();
    char buf[192];
    std::snprintf(buf, sizeof(buf),
                  "probe ok: %.1f MB in %.1f ms (mmap=%.1f, probe=%.1f)",
                  static_cast<double>(mapped.size()) / (1024.0 * 1024.0),
                  d_total, d_slurp, d_probe);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "iamf_probe", buf);
  }

  return result;
}

void eclipsa_studio_iamf_probe_free(EclipsaStudioIamfProbeResult* result) {
  if (result == nullptr) return;
  std::free(const_cast<char*>(result->error_message));
  if (result->audio_elements != nullptr) {
    for (uint32_t i = 0; i < result->num_audio_elements; ++i) {
      std::free(const_cast<char*>(result->audio_elements[i].layout_label));
    }
    std::free(const_cast<EclipsaStudioIamfAe*>(result->audio_elements));
  }
  if (result->mix_presentations != nullptr) {
    for (uint32_t i = 0; i < result->num_mix_presentations; ++i) {
      const auto& mp = result->mix_presentations[i];
      std::free(const_cast<char*>(mp.name));
      std::free(const_cast<char*>(mp.language));
      std::free(const_cast<char*>(mp.layout_type));
      std::free(const_cast<char*>(mp.sound_system));
      std::free(const_cast<EclipsaStudioIamfMixElement*>(mp.elements));
    }
    std::free(const_cast<EclipsaStudioIamfMixPresentation*>(
        result->mix_presentations));
  }
  std::free(result);
}

char* eclipsa_studio_iamf_probe_json(const char* path) {
  if (path == nullptr) {
    return MakeJsonError("eclipsa_studio_iamf_probe_json: null path");
  }
  using clock = std::chrono::steady_clock;
  const auto t0 = clock::now();

  std::string io_err;
  eclipsa_studio::ReadOnlyFileMap mapped;
  if (!mapped.open(path, &io_err)) {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf_probe", io_err.c_str());
    return MakeJsonError(io_err);
  }
  mapped.hint_sequential();
  const auto t_slurp = clock::now();

  // .mp4 deliverables: demux the embedded `iamf` track first; raw .iamf is
  // probed straight from the mmap. `demux_scratch` backs the span below.
  std::vector<uint8_t> demux_scratch;
  absl::Span<const uint8_t> probe_span;
  std::string demux_err;
  if (!ResolveProbeSpan(path, mapped, &demux_scratch, &probe_span,
                        &demux_err)) {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf_probe", demux_err.c_str());
    return MakeJsonError(demux_err);
  }

  iamf_tools::ProbeOptions options;
  options.scan_mode = iamf_tools::ScanMode::kDescriptorsOnly;
  auto probe_or = iamf_tools::Probe(probe_span, options);
  const auto t_probe = clock::now();
  if (!probe_or.ok()) {
    const std::string msg = std::string("iamf_tools::Probe: ") +
                            std::string(probe_or.status().message());
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf_probe", msg.c_str());
    return MakeJsonError(msg);
  }

  // The Inspector's JSON shape is owned by iamf_tools (ProbeReportToJson),
  // so it evolves in lockstep with ProbeReport and we no longer hand-roll
  // it. We only add the {ok, report} envelope the Dart parser keys off —
  // matching MakeJsonError's ok=false form on the failure paths above.
  std::string json = "{\"ok\":true,\"report\":";
  json += iamf_tools::ProbeReportToJson(*probe_or);
  json += "}";

  using ms = std::chrono::duration<double, std::milli>;
  char log[224];
  std::snprintf(
      log, sizeof(log),
      "probe_json ok: %.1f MB in %.1f ms (mmap=%.1f, probe=%.1f, json=%zu B)",
      static_cast<double>(mapped.size()) / (1024.0 * 1024.0),
      ms(clock::now() - t0).count(), ms(t_slurp - t0).count(),
      ms(t_probe - t_slurp).count(), json.size());
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "iamf_probe", log);

  return DupStringHeap(json);
}

void eclipsa_studio_iamf_probe_json_free(char* json) {
  if (json != nullptr) std::free(json);
}

}  // extern "C"
