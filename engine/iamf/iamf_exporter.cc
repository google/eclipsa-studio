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

#include "iamf/iamf_exporter.h"

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "absl/types/span.h"
#include "bounce/element_stream.h"
#include "engine_log.h"
#include "google/protobuf/io/tokenizer.h"
#include "google/protobuf/text_format.h"
#include "graph/audio_buffer.h"
#include "iamf/cli/proto/audio_frame.pb.h"
#include "iamf/cli/proto/user_metadata.pb.h"
#include "iamf/include/iamf_tools/iamf_encoder_factory.h"
#include "iamf/include/iamf_tools/iamf_encoder_interface.h"
#include "iamf/include/iamf_tools/iamf_tools_encoder_api_types.h"

namespace eclipsa_studio {

namespace {

// Chunk-log a possibly multi-line, possibly long message line by line so
// nothing is silently truncated at the log ring's slot size.
void LogChunkedLines(EclipsaStudioLogLevel level, const std::string& text) {
  size_t pos = 0;
  while (pos < text.size()) {
    const size_t nl = text.find('\n', pos);
    const size_t end = (nl == std::string::npos) ? text.size() : nl;
    const size_t len = end - pos;
    char line_buf[320];
    const size_t n = std::min<size_t>(len, sizeof(line_buf) - 1);
    std::memcpy(line_buf, text.data() + pos, n);
    line_buf[n] = '\0';
    engine_log(level, "iamf", line_buf);
    if (nl == std::string::npos) break;
    pos = nl + 1;
  }
}

// Parses a UserMetadata textproto, logging detailed per-line errors on
// failure.
bool ParseUserMetadataOrLog(const std::string& config_textproto,
                            iamf_tools_cli_proto::UserMetadata* out) {
  // Capture detailed parse errors so we can actually diagnose them.
  class CollectingErrorCollector : public google::protobuf::io::ErrorCollector {
   public:
    std::string errors;
    void RecordError(int line, google::protobuf::io::ColumnNumber col,
                     absl::string_view msg) override {
      // %.*s uses `int` for the length; cap via size_t min to stay
      // safely within INT_MAX before narrowing. The chunked log below
      // re-reads `errors` so nothing is truncated silently.
      const size_t msg_len = std::min<size_t>(msg.size(), 1024);
      char b[1280];
      snprintf(b, sizeof(b), "line %d col %d: %.*s\n", line + 1,
               static_cast<int>(col) + 1, static_cast<int>(msg_len),
               msg.data());
      errors += b;
    }
    void RecordWarning(int, google::protobuf::io::ColumnNumber,
                       absl::string_view) override {}
  };
  CollectingErrorCollector collector;
  google::protobuf::TextFormat::Parser parser;
  parser.RecordErrorsTo(&collector);
  if (parser.ParseFromString(config_textproto, out)) return true;
  engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
             "failed to parse UserMetadata textproto");
  LogChunkedLines(ECLIPSA_STUDIO_LOG_ERROR, collector.errors);
  return false;
}

}  // namespace

IamfExporter::IamfExporter() = default;
IamfExporter::~IamfExporter() = default;

int32_t IamfExporter::EncodePushFromWavDir(const std::string& config_textproto,
                                           const std::string& input_wav_dir,
                                           const std::string& output_dir) {
  // No begin/run split on this path — arming the request here is it.
  ResetForNewRequest();

  if (config_textproto.empty()) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", "EncodePush: empty config");
    return -1;
  }
  iamf_tools_cli_proto::UserMetadata user_metadata;
  if (!ParseUserMetadataOrLog(config_textproto, &user_metadata)) {
    return -10;
  }
  std::vector<PushElement> elements;
  elements.reserve(
      static_cast<size_t>(user_metadata.audio_frame_metadata_size()));
  for (const auto& afm : user_metadata.audio_frame_metadata()) {
    PushElement element;
    element.wav_basename = afm.wav_filename();
    element.stream.input_wav_path = input_wav_dir + "/" + afm.wav_filename();
    elements.push_back(std::move(element));
  }
  const std::string output_path =
      output_dir + "/" +
      user_metadata.test_vector_metadata().file_name_prefix() + ".iamf";
  return EncodePushParsed(user_metadata, output_path, elements);
}

int32_t IamfExporter::EncodePush(const std::string& config_textproto,
                                 const std::string& output_iamf_path,
                                 const std::vector<PushElement>& elements) {
  // Progress restarts here, but the cancel flag is NOT cleared: it is
  // armed by ResetForNewRequest() at begin, and a cancel raised in the
  // begin→run window must abort this encode (see ResetForNewRequest).
  progress_.store(0.0f, std::memory_order_relaxed);
  // Stats too: a run that fails before its streams open must read as
  // "no stats" (GetElementClipStats -> false), not as the previous
  // run's numbers. The FFI path already gets this from begin's
  // ResetForNewRequest; direct EncodePush callers get it here.
  {
    std::lock_guard<std::mutex> lock(stats_mutex_);
    element_stats_.clear();
  }

  if (config_textproto.empty()) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", "EncodePush: empty config");
    return -1;
  }
  iamf_tools_cli_proto::UserMetadata user_metadata;
  if (!ParseUserMetadataOrLog(config_textproto, &user_metadata)) {
    return -10;
  }
  return EncodePushParsed(user_metadata, output_iamf_path, elements);
}

int32_t IamfExporter::EncodePushParsed(
    const iamf_tools_cli_proto::UserMetadata& user_metadata,
    const std::string& output_iamf_path,
    const std::vector<PushElement>& elements) {
  if (output_iamf_path.empty()) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "EncodePush: empty output path");
    return -2;
  }
  if (elements.empty()) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", "EncodePush: no elements");
    return -3;
  }

  if (user_metadata.codec_config_metadata_size() == 0 ||
      user_metadata.codec_config_metadata(0)
              .codec_config()
              .num_samples_per_frame() == 0) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "EncodePush: missing/zero num_samples_per_frame");
    return -11;
  }
  const uint32_t frame_size = user_metadata.codec_config_metadata(0)
                                  .codec_config()
                                  .num_samples_per_frame();
  if (frame_size > ElementStream::kMaxPullFrames) {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "EncodePush: num_samples_per_frame %u exceeds pull cap %u",
             frame_size, ElementStream::kMaxPullFrames);
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
    return -11;
  }

  // ── Resolve each element against audio_frame_metadata ─────────────
  // The UserMetadata is the single source of truth for the element →
  // audio_element_id mapping and the per-channel IAMF labels; the
  // wav_filename field (unused by the push API) is the join key.
  struct ResolvedElement {
    uint32_t audio_element_id = 0;
    // Serialized ChannelLabelMessage keys, indexed by source channel.
    std::vector<std::string> channel_keys;
  };
  std::vector<ResolvedElement> resolved(elements.size());
  for (size_t e = 0; e < elements.size(); ++e) {
    const iamf_tools_cli_proto::AudioFrameObuMetadata* afm = nullptr;
    for (const auto& candidate : user_metadata.audio_frame_metadata()) {
      if (candidate.wav_filename() == elements[e].wav_basename) {
        afm = &candidate;
        break;
      }
    }
    if (afm == nullptr) {
      char buf[256];
      snprintf(buf, sizeof(buf),
               "EncodePush: no audio_frame_metadata for \"%s\"",
               elements[e].wav_basename.c_str());
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
      return -12;
    }
    resolved[e].audio_element_id = afm->audio_element_id();
    // The basename join takes the first metadata match, so two elements
    // sharing a source WAV resolve to the same id — build_spans would
    // then feed one element's PCM twice and starve the other, which
    // surfaces as an opaque encoder error. Reject it here by name.
    for (size_t prev = 0; prev < e; ++prev) {
      if (resolved[prev].audio_element_id == resolved[e].audio_element_id) {
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "EncodePush: \"%s\" and \"%s\" resolve to the same "
                 "audio_element_id %u — elements must resolve to "
                 "distinct audio_element_ids",
                 elements[prev].wav_basename.c_str(),
                 elements[e].wav_basename.c_str(),
                 resolved[e].audio_element_id);
        engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
        return -12;
      }
    }
    const int num_labels = afm->channel_metadatas_size();
    if (num_labels == 0) {
      char buf[256];
      snprintf(buf, sizeof(buf), "EncodePush: \"%s\" has no channel labels",
               elements[e].wav_basename.c_str());
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
      return -12;
    }
    resolved[e].channel_keys.resize(static_cast<size_t>(num_labels));
    // Count-matched + in-range + no-duplicate ids together guarantee
    // every slot of channel_keys is filled — a duplicate would leave
    // another slot as an empty label that only fails deep inside
    // iamf-tools.
    std::vector<bool> seen_channel(static_cast<size_t>(num_labels), false);
    for (const auto& cm : afm->channel_metadatas()) {
      if (cm.channel_id() >= static_cast<uint32_t>(num_labels)) {
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "EncodePush: \"%s\" channel_id %u out of range (%d labels)",
                 elements[e].wav_basename.c_str(), cm.channel_id(), num_labels);
        engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
        return -12;
      }
      if (seen_channel[cm.channel_id()]) {
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "EncodePush: \"%s\" has a duplicate channel_id %u",
                 elements[e].wav_basename.c_str(), cm.channel_id());
        engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
        return -12;
      }
      seen_channel[cm.channel_id()] = true;
      iamf_tools_cli_proto::ChannelLabelMessage label;
      label.set_channel_label(cm.channel_label());
      resolved[e].channel_keys[cm.channel_id()] = label.SerializeAsString();
    }
  }

  // ── Open the element streams ──────────────────────────────────────
  std::vector<std::unique_ptr<ElementStream>> streams;
  streams.reserve(elements.size());
  for (size_t e = 0; e < elements.size(); ++e) {
    auto stream = std::make_unique<ElementStream>();
    if (!stream->Open(elements[e].stream)) {
      char buf[256];
      snprintf(buf, sizeof(buf), "EncodePush: cannot open \"%s\"",
               elements[e].stream.input_wav_path.c_str());
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
      return -13;
    }
    if (stream->channels() != resolved[e].channel_keys.size()) {
      char buf[256];
      snprintf(buf, sizeof(buf),
               "EncodePush: \"%s\" delivers %u channels, UserMetadata "
               "labels %zu",
               elements[e].wav_basename.c_str(), stream->channels(),
               resolved[e].channel_keys.size());
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
      return -12;
    }
    streams.push_back(std::move(stream));
  }

  // From here on every exit — success, failure, or -99 cancel —
  // snapshots the per-element overload stats from what each stream
  // actually delivered, so the caller can report clipping even on a
  // partial run. Cleared again by the next ResetForNewRequest().
  //
  // Pre-reserve now so the destructor never allocates: destructors are
  // implicitly noexcept, and this guard also runs while unwinding
  // toward the FFI exception firewall — a bad_alloc there would
  // terminate instead of returning -5. clear() keeps capacity, so the
  // push_backs below stay allocation-free.
  {
    std::lock_guard<std::mutex> lock(stats_mutex_);
    element_stats_.reserve(streams.size());
  }
  // Declared after `streams` so it destructs first and the pointer it
  // holds is always valid — do not reorder above the open loop.
  struct StatsCapture {
    IamfExporter* self;
    const std::vector<std::unique_ptr<ElementStream>>* streams;
    ~StatsCapture() {
      std::lock_guard<std::mutex> lock(self->stats_mutex_);
      self->element_stats_.clear();
      for (const auto& s : *streams) {
        self->element_stats_.push_back(
            {s->clipped_samples(), s->peak_linear()});
      }
    }
  } stats_capture{this, &streams};

  // Every stream must deliver the same length — the dialog pads all
  // elements to a common frame count, and iamf-tools requires equal
  // substream durations.
  const uint64_t total_frames = streams[0]->total_frames();
  for (size_t e = 1; e < streams.size(); ++e) {
    if (streams[e]->total_frames() != total_frames) {
      char buf[256];
      snprintf(buf, sizeof(buf),
               "EncodePush: length mismatch: \"%s\" %" PRIu64
               " frames vs %" PRIu64,
               elements[e].wav_basename.c_str(), streams[e]->total_frames(),
               total_frames);
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
      return -14;
    }
  }
  if (total_frames == 0) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "EncodePush: zero-length input");
    return -14;
  }
  const uint64_t total_units = (total_frames + frame_size - 1) / frame_size;

  // ── Create the file-generating encoder ────────────────────────────
  // The factory's ObuSequencerIamf writes the standalone .iamf itself,
  // including the descriptor-OBU rewrite with measured loudness after
  // FinalizeEncode — no manual OBU assembly here.
  std::string serialized;
  if (!user_metadata.SerializeToString(&serialized)) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "EncodePush: UserMetadata reserialization failed");
    return -21;
  }
  auto encoder_or =
      iamf_tools::api::IamfEncoderFactory::CreateFileGeneratingIamfEncoder(
          serialized, output_iamf_path);
  if (!encoder_or.ok()) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "EncodePush: encoder create failed:");
    LogChunkedLines(ECLIPSA_STUDIO_LOG_ERROR,
                    std::string(encoder_or.status().message()));
    return -21;
  }
  std::unique_ptr<iamf_tools::api::IamfEncoderInterface> encoder =
      std::move(*encoder_or);

  {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "EncodePush: %zu elements, %" PRIu64 " frames, %" PRIu64
             " units of %u, delay=%u -> %s",
             elements.size(), total_frames, total_units, frame_size,
             encoder->GetEncoderDelay(), output_iamf_path.c_str());
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "iamf", buf);
  }
  progress_.store(0.05f, std::memory_order_relaxed);

  // Destroy the encoder (closing its file handle) and best-effort
  // remove the partial output.
  auto abort_encode = [&encoder, &output_iamf_path]() {
    encoder.reset();
    std::remove(output_iamf_path.c_str());
  };

  // ── Per-element scratch: float pull target + double widen target ──
  // Spans in the temporal-unit map point at the double storage, which
  // never moves — the map is built once and refilled in place. Only a
  // short final unit needs the spans rebuilt (shorter length).
  const size_t num_elements = elements.size();
  std::vector<std::vector<float>> float_storage(num_elements);
  std::vector<AudioBuffer> float_bufs(num_elements);
  std::vector<std::vector<double>> double_storage(num_elements);
  for (size_t e = 0; e < num_elements; ++e) {
    const uint32_t ch = streams[e]->channels();
    float_storage[e].assign(static_cast<size_t>(ch) * frame_size, 0.0f);
    float_bufs[e].data = float_storage[e].data();
    float_bufs[e].channels = ch;
    float_bufs[e].frames = 0;
    float_bufs[e].capacity_frames = frame_size;
    double_storage[e].assign(static_cast<size_t>(ch) * frame_size, 0.0);
  }

  iamf_tools::api::IamfTemporalUnitData unit_data;
  auto build_spans = [&](uint32_t span_frames) {
    unit_data.audio_element_id_to_data.clear();
    for (size_t e = 0; e < num_elements; ++e) {
      auto& element_data =
          unit_data.audio_element_id_to_data[resolved[e].audio_element_id];
      for (size_t ch = 0; ch < resolved[e].channel_keys.size(); ++ch) {
        element_data[resolved[e].channel_keys[ch]] = absl::MakeConstSpan(
            double_storage[e].data() + ch * frame_size, span_frames);
      }
    }
  };
  build_spans(frame_size);

  // ── Push temporal units, then drain ───────────────────────────────
  // Loop shape follows the interface's documented control flow: feed a
  // unit, FinalizeEncode after the last one, flush via
  // OutputTemporalUnit until GeneratingTemporalUnits flips false.
  uint64_t units_pushed = 0;
  bool finalized = false;
  uint64_t idle_iterations = 0;
  std::vector<uint8_t> tu_obus;
  while (encoder->GeneratingTemporalUnits()) {
    if (cancel_.load(std::memory_order_relaxed)) {
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "iamf", "EncodePush cancelled");
      abort_encode();
      return -99;
    }

    if (units_pushed < total_units) {
      const uint64_t start = units_pushed * frame_size;
      const auto unit_frames = static_cast<uint32_t>(
          std::min<uint64_t>(frame_size, total_frames - start));
      for (size_t e = 0; e < num_elements; ++e) {
        const uint32_t pulled = streams[e]->Pull(float_bufs[e], unit_frames);
        if (pulled != unit_frames) {
          char buf[192];
          snprintf(buf, sizeof(buf),
                   "EncodePush: \"%s\" delivered %u of %u frames at unit "
                   "%" PRIu64,
                   elements[e].wav_basename.c_str(), pulled, unit_frames,
                   units_pushed);
          engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
          abort_encode();
          return -14;
        }
        // Widen float -> double at the API seam.
        const uint32_t ch_count = float_bufs[e].channels;
        for (uint32_t ch = 0; ch < ch_count; ++ch) {
          const float* src = float_bufs[e].channel(ch);
          double* dst =
              double_storage[e].data() + static_cast<size_t>(ch) * frame_size;
          for (uint32_t f = 0; f < unit_frames; ++f) {
            dst[f] = static_cast<double>(src[f]);
          }
        }
      }
      if (unit_frames < frame_size) build_spans(unit_frames);

      const absl::Status status = encoder->Encode(unit_data);
      if (!status.ok()) {
        engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
                   "EncodePush: Encode failed:");
        LogChunkedLines(ECLIPSA_STUDIO_LOG_ERROR,
                        std::string(status.message()));
        abort_encode();
        return -22;
      }
      ++units_pushed;

      if (units_pushed == total_units) {
        const absl::Status fin = encoder->FinalizeEncode();
        if (!fin.ok()) {
          engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
                     "EncodePush: FinalizeEncode failed:");
          LogChunkedLines(ECLIPSA_STUDIO_LOG_ERROR, std::string(fin.message()));
          abort_encode();
          return -24;
        }
        finalized = true;
      }
    } else {
      // All audio pushed and finalized; only draining remains. Guard
      // against an encoder that never flips GeneratingTemporalUnits.
      if (++idle_iterations > 100000) {
        engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
                   "EncodePush: encoder never finished draining");
        abort_encode();
        return -23;
      }
    }

    const absl::Status out = encoder->OutputTemporalUnit(tu_obus);
    if (!out.ok()) {
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
                 "EncodePush: OutputTemporalUnit failed:");
      LogChunkedLines(ECLIPSA_STUDIO_LOG_ERROR, std::string(out.message()));
      abort_encode();
      return -23;
    }

    progress_.store(0.05f + 0.90f * (static_cast<float>(units_pushed) /
                                     static_cast<float>(total_units)),
                    std::memory_order_relaxed);
  }

  if (!finalized) {
    // The encoder stopped generating before all audio was pushed —
    // never expected with a correctly sized unit count.
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "EncodePush: encoder stopped before the last unit");
    abort_encode();
    return -22;
  }

  // Destruction closes and finalizes the output file.
  encoder.reset();

  progress_.store(1.0f, std::memory_order_relaxed);
  {
    char buf[192];
    snprintf(buf, sizeof(buf), "EncodePush complete: %" PRIu64 " units -> %s",
             units_pushed, output_iamf_path.c_str());
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "iamf", buf);
  }
  return 0;
}

bool IamfExporter::GetElementClipStats(uint32_t index,
                                       uint64_t* out_clipped_samples,
                                       float* out_peak_linear) const {
  std::lock_guard<std::mutex> lock(stats_mutex_);
  if (index >= element_stats_.size()) return false;
  const ElementClipStats& s = element_stats_[index];
  if (out_clipped_samples) *out_clipped_samples = s.clipped_samples;
  if (out_peak_linear) *out_peak_linear = s.peak_linear;
  return true;
}

}  // namespace eclipsa_studio
