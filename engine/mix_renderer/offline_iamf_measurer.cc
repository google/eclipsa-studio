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

#include "mix_renderer/offline_iamf_measurer.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "engine_log.h"
#include "iamf/iamf_demuxer.h"
#include "iamf/include/iamf_tools/iamf_stream_factory.h"
#include "iamf/include/iamf_tools/iamf_stream_interface.h"
#include "iamf/include/iamf_tools/iamf_stream_settings.h"
#include "iamf/include/iamf_tools/iamf_tools_api_types.h"
#include "iamf/read_only_file_map.h"
#include "renderer/oar_capability.h"
#include "renderer/oar_renderer.h"

namespace eclipsa_studio {

using iamf_tools::api::AudioElementDescriptor;
using iamf_tools::api::IamfByteRange;
using iamf_tools::api::IamfStatus;
using iamf_tools::api::IamfStreamFactory;
using iamf_tools::api::IamfStreamInterface;
using iamf_tools::api::IamfStreamSettings;
using iamf_tools::api::TemporalUnitOutput;

namespace {

constexpr const char* kLogCategory = "iamf_measure";

}  // namespace

struct OfflineIamfMeasurer::Impl {
  // An included element: its index into the stream's AE list (which is
  // also the index into TemporalUnitOutput::samples_per_ae) and the
  // static gain pushed before every block.
  struct Included {
    uint32_t stream_index = 0;
    uint32_t audio_element_id = 0;
    uint32_t channels = 0;
    float mix_gain_db = 0.0f;
    // Planar staging for one render block, `channels * buffer_size`.
    std::vector<float> block;
  };

  // The stream reads from one of these for its whole life: the mapping
  // (raw IAMF), the MP4 source (in-place track ranges), or the owned
  // bytes (a track demuxed into memory).
  ReadOnlyFileMap map;
  std::unique_ptr<IamfMp4Source> mp4_source;
  std::vector<uint8_t> owned_bytes;
  std::unique_ptr<IamfStreamInterface> stream;

  std::string path;
  uint32_t sample_rate = 0;
  uint64_t total_frames = 0;
  uint32_t buffer_size = 1024;
  uint32_t layout = 2;
  float output_mix_gain_db = 0.0f;
  std::vector<ElementInfo> elements;
  // OAR sub-type per element, parallel to `elements`; nullopt where
  // OAR has no sub-renderer for the coded layout.
  std::vector<std::optional<int>> sub_types;
  std::vector<Included> included;
  OarRenderer oar;
  LoudnessAnalysisSink sink;
  bool measured_once = false;  // Measure() has run on this instance
  std::string last_error;

  void Fail(const std::string& message) {
    last_error = message;
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, kLogCategory,
               ("measure: " + message).c_str());
  }

  void ReleaseStream() {
    // The stream is reset before the bytes it reads go away.
    stream.reset();
    mp4_source.reset();
    owned_bytes.clear();
    map.close();
  }

  bool OpenStream();
  bool OpenStreamFromBytes(const uint8_t* bytes, size_t len);
  bool ConfigureFromStream();
};

// ── Open ────────────────────────────────────────────────────────────────

bool OfflineIamfMeasurer::Impl::OpenStreamFromBytes(const uint8_t* bytes,
                                                    size_t len) {
  // Eager scan: the pass needs the program length up front, and the
  // caller is already off the UI thread.
  const IamfStreamSettings settings;
  const IamfStatus status =
      IamfStreamFactory::OpenFromBytes(bytes, len, settings, stream);
  if (!status.ok()) {
    Fail(status.error_message);
    stream.reset();
    return false;
  }
  return true;
}

bool OfflineIamfMeasurer::Impl::OpenStream() {
  std::string map_err;
  if (!map.open(path.c_str(), &map_err)) {
    Fail(map_err);
    return false;
  }
  map.hint_sequential();

  if (!IamfDemuxer::IsIsoBmff(map.data(), map.size())) {
    return OpenStreamFromBytes(map.data(), map.size());
  }

  // IAMF-in-ISOBMFF: read the `iamf` track's samples in place from the
  // source's own mapping, as the playback session and the probe do. The
  // sniffing map is not needed after this point.
  map.close();
  auto source = std::make_unique<IamfMp4Source>();
  std::string source_err;
  bool sample_data_external = false;
  if (source->open(path, &source_err, &sample_data_external)) {
    std::vector<IamfByteRange> ranges;
    ranges.reserve(source->segments().size());
    for (const auto& segment : source->segments()) {
      ranges.push_back({segment.data(), segment.size()});
    }
    const IamfStreamSettings settings;
    const IamfStatus status = IamfStreamFactory::OpenFromSegments(
        ranges.data(), ranges.size(), settings, stream);
    if (!status.ok()) {
      Fail(status.error_message);
      stream.reset();
      return false;
    }
    mp4_source = std::move(source);
    return true;
  }
  if (!sample_data_external) {
    Fail(source_err);
    return false;
  }
  // A track whose sample data is stored in another file: demux it into
  // memory, the one path that still copies the track.
  IamfDemuxer demuxer;
  if (!demuxer.DemuxToBytes(path, &owned_bytes)) {
    Fail(demuxer.last_error());
    return false;
  }
  return OpenStreamFromBytes(owned_bytes.data(), owned_bytes.size());
}

bool OfflineIamfMeasurer::Impl::ConfigureFromStream() {
  sample_rate = stream->GetSampleRate();
  total_frames = stream->GetTotalSamples();
  // Below 10 Hz the sink's GR-trace step truncates to zero frames; the
  // same guard OfflineMixRenderer::Init applies.
  if (sample_rate < 8000) {
    char buf[96];
    snprintf(buf, sizeof(buf), "unsupported: sample rate %u (< 8000 Hz)",
             sample_rate);
    Fail(buf);
    return false;
  }
  if (total_frames == 0) {
    Fail("malformed: the file has no audio frames");
    return false;
  }

  const uint32_t num_ae = stream->GetNumAudioElements();
  elements.clear();
  elements.reserve(num_ae);
  sub_types.clear();
  sub_types.reserve(num_ae);
  for (uint32_t i = 0; i < num_ae; ++i) {
    const AudioElementDescriptor d = stream->GetAudioElement(i);
    ElementInfo info;
    info.audio_element_id = d.audio_element_id;
    info.kind = static_cast<int32_t>(d.kind);
    info.num_channels = d.num_channels;
    info.layout_info = d.layout_info;
    info.loudspeaker_layout_raw = d.loudspeaker_layout_raw;
    info.expanded_loudspeaker_layout_raw = d.expanded_loudspeaker_layout_raw;
    info.supported = d.supported;
    // The same renderer-capability narrowing as
    // eclipsa_studio_playback_open: OAR needs a sub-renderer for the
    // coded layout (or ambisonics order).
    const std::optional<int> sub_type =
        OarSubTypeForElement(info.kind, info.loudspeaker_layout_raw,
                             info.expanded_loudspeaker_layout_raw,
                             info.kind == 1 ? info.layout_info : -1);
    info.renderable = info.supported && sub_type.has_value();
    elements.push_back(info);
    sub_types.push_back(sub_type);
  }

  if (!oar.init(sample_rate, buffer_size, layout)) {
    Fail("internal: OAR init failed for the offline render");
    return false;
  }
  return true;
}

// ── Lifecycle ───────────────────────────────────────────────────────────

OfflineIamfMeasurer::OfflineIamfMeasurer() : impl_(std::make_unique<Impl>()) {
  // Offline instance: no audio thread will ever drive it, so OAR's
  // fade/ack waits must short-circuit (ES-515). Marked here rather than in
  // Open(): SetLimiterEnabled() may come first, and the renderer accepts
  // the switch only on an instance marked so.
  impl_->oar.set_no_audio_thread();
}

// Impl declares the stream after the bytes it reads (the mapping, the
// MP4 source and the owned buffer), so the default destruction order
// resets the stream first.
OfflineIamfMeasurer::~OfflineIamfMeasurer() = default;

bool OfflineIamfMeasurer::Open(const std::string& path, uint32_t buffer_size,
                               uint32_t layout) {
  impl_->ReleaseStream();
  impl_->last_error.clear();
  impl_->elements.clear();
  impl_->sub_types.clear();
  impl_->included.clear();
  impl_->measured_once = false;
  // A tap set for the previous pass may hold state that pass owned.
  impl_->sink.SetProgramTap({});
  if (path.empty()) {
    impl_->Fail("invalid_argument: empty path");
    return false;
  }
  if (buffer_size == 0) {
    impl_->Fail("invalid_argument: buffer_size is 0");
    return false;
  }
  impl_->path = path;
  impl_->buffer_size = buffer_size;
  impl_->layout = layout;

  using clock = std::chrono::steady_clock;
  const auto t0 = clock::now();
  if (!impl_->OpenStream()) {
    impl_->ReleaseStream();
    return false;
  }
  if (!impl_->ConfigureFromStream()) {
    impl_->ReleaseStream();
    return false;
  }

  using ms = std::chrono::duration<double, std::milli>;
  char buf[224];
  snprintf(buf, sizeof(buf),
           "open: %u Hz, %llu frames, %zu AEs, layout=%u, in %.1f ms (%s)",
           impl_->sample_rate,
           static_cast<unsigned long long>(impl_->total_frames),
           impl_->elements.size(), layout, ms(clock::now() - t0).count(),
           impl_->mp4_source      ? "mp4, in place"
           : impl_->map.is_open() ? "iamf, in place"
                                  : "mp4, demuxed into memory");
  engine_log(ECLIPSA_STUDIO_LOG_INFO, kLogCategory, buf);
  return true;
}

uint32_t OfflineIamfMeasurer::sample_rate() const { return impl_->sample_rate; }

uint64_t OfflineIamfMeasurer::total_frames() const {
  return impl_->total_frames;
}

uint32_t OfflineIamfMeasurer::num_elements() const {
  return static_cast<uint32_t>(impl_->elements.size());
}

OfflineIamfMeasurer::ElementInfo OfflineIamfMeasurer::element(
    uint32_t index) const {
  if (index >= impl_->elements.size()) return ElementInfo{};
  return impl_->elements[index];
}

bool OfflineIamfMeasurer::IncludeElement(uint32_t audio_element_id,
                                         float mix_gain_db,
                                         uint32_t headphones_mode,
                                         uint32_t binaural_profile) {
  impl_->last_error.clear();
  if (impl_->stream == nullptr) {
    impl_->Fail("invalid_argument: no file is open");
    return false;
  }
  const auto it = std::find_if(impl_->elements.begin(), impl_->elements.end(),
                               [&](const ElementInfo& e) {
                                 return e.audio_element_id == audio_element_id;
                               });
  if (it == impl_->elements.end()) {
    char buf[96];
    snprintf(buf, sizeof(buf), "invalid_argument: no audio element id=%u",
             audio_element_id);
    impl_->Fail(buf);
    return false;
  }
  if (!it->renderable) {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "unsupported: audio element id=%u (kind=%d layout=%d/%d) "
             "cannot be rendered",
             audio_element_id, it->kind, it->loudspeaker_layout_raw,
             it->expanded_loudspeaker_layout_raw);
    impl_->Fail(buf);
    return false;
  }
  const std::optional<int> sub_type =
      impl_->sub_types[static_cast<size_t>(it - impl_->elements.begin())];
  if (!impl_->oar.add_element(audio_element_id, it->kind, *sub_type,
                              it->num_channels)) {
    char buf[96];
    snprintf(buf, sizeof(buf), "internal: OAR add_element failed for id=%u",
             audio_element_id);
    impl_->Fail(buf);
    return false;
  }
  impl_->oar.set_element_rendering_config(audio_element_id, headphones_mode,
                                          binaural_profile);
  impl_->oar.commit_rendering_config();

  // Replace on duplicate id, as OfflineMixRenderer::AddElement does.
  Impl::Included inc;
  inc.stream_index = static_cast<uint32_t>(it - impl_->elements.begin());
  inc.audio_element_id = audio_element_id;
  inc.channels = it->num_channels;
  inc.mix_gain_db = mix_gain_db;
  inc.block.assign(static_cast<size_t>(inc.channels) * impl_->buffer_size,
                   0.0f);
  const auto dup = std::find_if(impl_->included.begin(), impl_->included.end(),
                                [&](const Impl::Included& e) {
                                  return e.audio_element_id == audio_element_id;
                                });
  if (dup != impl_->included.end()) {
    *dup = std::move(inc);
  } else {
    impl_->included.push_back(std::move(inc));
  }
  return true;
}

void OfflineIamfMeasurer::SetOutputMixGain(float gain_db) {
  impl_->output_mix_gain_db = gain_db;
}

bool OfflineIamfMeasurer::SetLimiterEnabled(bool enabled) {
  // The renderer keeps the setting across init(), so it holds for an
  // Open() that follows, and the constructor marked it
  // set_no_audio_thread(), so it accepts the change at any point.
  return impl_->oar.set_limiter_enabled(enabled);
}

void OfflineIamfMeasurer::SetProgramTap(LoudnessAnalysisSink::ProgramTap tap) {
  impl_->sink.SetProgramTap(std::move(tap));
}

uint32_t OfflineIamfMeasurer::output_channels() const {
  return impl_->stream != nullptr ? impl_->oar.channel_count() : 0;
}

// ── Decode + render + measure ───────────────────────────────────────────

std::optional<LoudnessResult> OfflineIamfMeasurer::Measure() {
  Impl& im = *impl_;
  im.last_error.clear();
  // A failed run leaves nothing of a previous one readable.
  im.sink.Reset();
  if (im.stream == nullptr) {
    im.Fail("invalid_argument: no file is open");
    return std::nullopt;
  }
  if (im.included.empty()) {
    im.Fail("invalid_argument: no audio elements included");
    return std::nullopt;
  }
  // The renderer keeps its limiter and rendering state across calls, so
  // a second pass would start on the first pass's tail. One pass per
  // instance; a new pass opens the file again.
  if (im.measured_once) {
    im.Fail(
        "invalid_argument: Measure() was already called on this "
        "instance; open the file again for another pass");
    return std::nullopt;
  }
  im.measured_once = true;

  const uint32_t bs = im.buffer_size;
  if (!im.sink.Begin(&im.oar, im.sample_rate, bs, im.layout, im.total_frames)) {
    im.Fail("internal: OAR reports 0 output channels");
    return std::nullopt;
  }

  const auto render_start = std::chrono::steady_clock::now();
  TemporalUnitOutput tu;
  uint32_t tu_pos = 0;  // frames of `tu` already moved into blocks
  bool eof = false;
  bool partial_tu_logged = false;
  uint64_t frames_fed = 0;

  while (im.sink.has_more()) {
    // ── Assemble one render block from the decoded temporal units ────
    // Temporal units are `frames_produced` frames of interleaved float
    // per AE and do not line up with the render block, so this loop
    // deinterleaves as many frames as the block still needs and keeps
    // the rest of the unit for the next block. Past the end of the
    // stream the block stays zero, which drains the limiter delay.
    for (auto& inc : im.included) {
      std::fill(inc.block.begin(), inc.block.end(), 0.0f);
    }
    uint32_t filled = 0;
    while (filled < bs && !eof) {
      if (tu_pos >= tu.frames_produced) {
        const IamfStatus status = im.stream->NextTemporalUnit(tu);
        if (!status.ok()) {
          im.Fail(status.error_message);
          return std::nullopt;
        }
        tu_pos = 0;
        if (tu.frames_produced == 0) {
          eof = true;
          break;
        }
        // Channel-width contract, as the playback session's io_loop
        // checks it: a non-empty buffer holds exactly frames_produced
        // frames of the element's channels. An empty buffer is a
        // partial temporal unit; that element is silent for the unit.
        for (const auto& inc : im.included) {
          if (inc.stream_index >= tu.samples_per_ae.size()) {
            im.Fail(
                "internal: temporal unit has fewer elements than the "
                "descriptors");
            return std::nullopt;
          }
          const std::vector<float>& src = tu.samples_per_ae[inc.stream_index];
          const uint64_t expected =
              static_cast<uint64_t>(tu.frames_produced) * inc.channels;
          if (!src.empty() && src.size() != expected) {
            char msg[224];
            snprintf(msg, sizeof(msg),
                     "internal: AE %u delivered %zu samples for %u frames * "
                     "%u channels (expected %llu)",
                     inc.audio_element_id, src.size(), tu.frames_produced,
                     inc.channels, static_cast<unsigned long long>(expected));
            im.Fail(msg);
            return std::nullopt;
          }
          if (src.empty() && !partial_tu_logged) {
            char msg[160];
            snprintf(msg, sizeof(msg),
                     "measure: AE %u carried no frames in a temporal unit "
                     "at frame %llu; it is silent for that unit",
                     inc.audio_element_id,
                     static_cast<unsigned long long>(frames_fed));
            engine_log(ECLIPSA_STUDIO_LOG_WARN, kLogCategory, msg);
            partial_tu_logged = true;
          }
        }
      }
      const uint32_t n = std::min(bs - filled, tu.frames_produced - tu_pos);
      for (auto& inc : im.included) {
        const std::vector<float>& src = tu.samples_per_ae[inc.stream_index];
        if (src.empty()) continue;
        const uint32_t ch = inc.channels;
        const float* in = src.data() + static_cast<size_t>(tu_pos) * ch;
        for (uint32_t c = 0; c < ch; ++c) {
          float* out = inc.block.data() + static_cast<size_t>(c) * bs + filled;
          for (uint32_t f = 0; f < n; ++f) {
            out[f] = in[static_cast<size_t>(f) * ch + c];
          }
        }
      }
      filled += n;
      tu_pos += n;
      frames_fed += n;
    }

    // ── Feed OAR and render ──────────────────────────────────────────
    for (auto& inc : im.included) {
      // Static gain re-pushed before every block: OAR's gain metadata
      // covers `frames` and then reverts to 0 dB (see
      // OfflineMixRenderer::RenderAndMeasure).
      im.oar.set_element_mix_gain(inc.audio_element_id, inc.mix_gain_db,
                                  inc.mix_gain_db, bs);
      im.oar.update_element_data(inc.audio_element_id, inc.block.data(),
                                 inc.channels, bs, bs);
    }
    im.oar.set_output_mix_gain(im.output_mix_gain_db, im.output_mix_gain_db,
                               bs);
    const float* rendered = im.oar.render(bs);
    if (rendered == nullptr) {
      im.Fail("internal: OAR render returned null");
      return std::nullopt;
    }
    im.sink.Consume(rendered);
  }

  const LoudnessResult result = im.sink.Finish();

  if (frames_fed != im.total_frames) {
    char msg[160];
    snprintf(msg, sizeof(msg),
             "measure: fed %llu frames from the stream against a scanned "
             "total of %llu",
             static_cast<unsigned long long>(frames_fed),
             static_cast<unsigned long long>(im.total_frames));
    engine_log(ECLIPSA_STUDIO_LOG_WARN, kLogCategory, msg);
  }

  const auto render_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now() - render_start)
                             .count();
  char buf[320];
  snprintf(buf, sizeof(buf),
           "measured: integrated=%.1f LUFS, true_peak=%.1f dBTP, "
           "digital_peak=%.1f dBFS (layout=%u elements=%zu frames=%llu "
           "render_ms=%lld)",
           result.integrated_lufs, result.true_peak_dbtp,
           result.digital_peak_dbfs, im.layout, im.included.size(),
           static_cast<unsigned long long>(frames_fed),
           static_cast<long long>(render_ms));
  engine_log(ECLIPSA_STUDIO_LOG_INFO, kLogCategory, buf);
  return result;
}

// ── Post-measurement queries ────────────────────────────────────────────

uint32_t OfflineIamfMeasurer::TraceLength(uint32_t series) const {
  return impl_->sink.TraceLength(series);
}

uint32_t OfflineIamfMeasurer::CopyTrace(uint32_t series, float* out,
                                        uint32_t cap) const {
  return impl_->sink.CopyTrace(series, out, cap);
}

bool OfflineIamfMeasurer::GetLoudnessRange(float* lra_lu,
                                           bool* is_stable) const {
  return impl_->sink.GetLoudnessRange(lra_lu, is_stable);
}

const std::string& OfflineIamfMeasurer::last_error() const {
  return impl_->last_error;
}

}  // namespace eclipsa_studio
