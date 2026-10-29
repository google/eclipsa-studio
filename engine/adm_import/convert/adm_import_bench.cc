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

// Times the ADM import render of one ADM-BWF file:
//   adm_import_bench [--stages] <in.wav> [out.wav]
// By default it runs ConvertAdmFileToChannelBed, the path the app's render
// job takes, and reports the time to the first progress report. With
// --stages it times open + parse + scene, a whole-file PCM read and
// RenderChannelBed separately. The 24-bit WAV write runs only with an output
// path.

#if !defined(_WIN32)
#include <sys/resource.h>
#endif

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "absl/status/status.h"
#include "absl/types/span.h"
#include "adm_import/adm/adm_parser.h"
#include "adm_import/adm/common_definitions.h"
#include "adm_import/convert/convert.h"
#include "adm_import/render/channel_renderer.h"
#include "adm_import/render/render_progress.h"
#include "adm_import/scene/adm_adapter.h"
#include "adm_import/scene/layouts.h"
#include "adm_import/wav/bw64_reader.h"
#include "adm_import/wav/wav_writer.h"

namespace {

using Clock = std::chrono::steady_clock;

double Seconds(Clock::time_point a, Clock::time_point b) {
  return std::chrono::duration<double>(b - a).count();
}

void PrintPeakRss() {
#if !defined(_WIN32)
  rusage u{};
  getrusage(RUSAGE_SELF, &u);
#if defined(__APPLE__)
  const double bytes = static_cast<double>(u.ru_maxrss);  // Bytes on macOS.
#else
  const double bytes = static_cast<double>(u.ru_maxrss) * 1024.0;  // KiB.
#endif
  std::printf("peak rss     %8.2f GiB\n", bytes / (1024.0 * 1024.0 * 1024.0));
#endif
}

void PrintError(const absl::Status& s) {
  std::fprintf(stderr, "%s\n", std::string(s.message()).c_str());
}

// The app's path: ConvertAdmFileToChannelBed, then the WAV write.
int RunConvert(const char* in, const char* out) {
  const auto t0 = Clock::now();
  Clock::time_point first_progress{};
  adm2iamf::RenderProgress progress;
  progress.report = [&](uint64_t done, uint64_t) {
    if (done > 0 && first_progress == Clock::time_point{}) {
      first_progress = Clock::now();
    }
  };
  auto r = adm2iamf::ConvertAdmFileToChannelBed(in, 0, &progress);
  if (!r.ok()) {
    PrintError(r.status());
    return 1;
  }
  const auto t1 = Clock::now();
  double write_s = 0.0;
  if (out != nullptr) {
    absl::Status s = adm2iamf::WriteWavPlanar(out, r->channels, r->sample_rate,
                                              adm2iamf::WavEncoding::kPcm24);
    if (!s.ok()) {
      PrintError(s);
      return 1;
    }
    write_s = Seconds(t1, Clock::now());
  }
  if (first_progress != Clock::time_point{}) {
    std::printf("first progress %6.2f s\n", Seconds(t0, first_progress));
  }
  std::printf("convert      %8.2f s\n", Seconds(t0, t1));
  if (out != nullptr) std::printf("wav write    %8.2f s\n", write_s);
  PrintPeakRss();
  return 0;
}

// Stage by stage, with the whole master read into memory first.
int RunStages(const char* in, const char* out) {
  const auto t0 = Clock::now();
  auto reader = adm2iamf::Bw64Reader::Open(in);
  if (!reader.ok()) {
    PrintError(reader.status());
    return 1;
  }
  if ((*reader)->axml().empty()) {
    std::fprintf(stderr, "Input has no `axml` chunk; not an ADM-BWF file.\n");
    return 1;
  }
  auto model = adm2iamf::adm::ParseAxml((*reader)->axml());
  if (!model.ok()) {
    PrintError(model.status());
    return 1;
  }
  if (!(*reader)->chna().empty()) {
    auto chna =
        adm2iamf::adm::ParseChna(absl::MakeConstSpan((*reader)->chna()));
    if (!chna.ok()) {
      PrintError(chna.status());
      return 1;
    }
    model->chna = *chna;
  }
  adm2iamf::adm::ResolveCommonDefinitions(*model);
  auto scene = adm2iamf::BuildSceneFromAdm(*model);
  if (!scene.ok()) {
    PrintError(scene.status());
    return 1;
  }
  const auto t1 = Clock::now();

  std::vector<std::vector<float>> tracks;
  const uint32_t rate = (*reader)->format().sample_rate;
  auto frames = (*reader)->ReadPlanarFloat(0, (*reader)->num_frames(), tracks);
  if (!frames.ok()) {
    PrintError(frames.status());
    return 1;
  }
  const auto t2 = Clock::now();

  adm2iamf::RenderStats stats;
  auto bed = adm2iamf::RenderChannelBed(*scene, adm2iamf::ImportLayout(),
                                        tracks, rate, 0, &stats);
  if (!bed.ok()) {
    PrintError(bed.status());
    return 1;
  }
  const auto t3 = Clock::now();

  double write_s = 0.0;
  if (out != nullptr) {
    absl::Status s = adm2iamf::WriteWavPlanar(out, *bed, rate,
                                              adm2iamf::WavEncoding::kPcm24);
    if (!s.ok()) {
      PrintError(s);
      return 1;
    }
    write_s = Seconds(t3, Clock::now());
  }

  std::printf("tracks=%zu frames=%llu rate=%u duration=%.1fs\n", tracks.size(),
              static_cast<unsigned long long>(*frames), rate,
              static_cast<double>(*frames) / rate);
  std::printf("bed sources: passthrough=%d lfe=%d olr=%d objects=%d\n",
              stats.passthrough, stats.lfe, stats.olr, stats.objects);
  std::printf("parse+scene  %8.2f s\n", Seconds(t0, t1));
  std::printf("pcm read     %8.2f s\n", Seconds(t1, t2));
  std::printf("render       %8.2f s\n", Seconds(t2, t3));
  if (out != nullptr) std::printf("wav write    %8.2f s\n", write_s);
  PrintPeakRss();
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  int arg = 1;
  const bool stages = argc > 1 && std::strcmp(argv[1], "--stages") == 0;
  if (stages) ++arg;
  if (arg >= argc) {
    std::fprintf(stderr, "usage: %s [--stages] <in.wav> [out.wav]\n", argv[0]);
    return 2;
  }
  const char* in = argv[arg];
  const char* out = arg + 1 < argc ? argv[arg + 1] : nullptr;
  return stages ? RunStages(in, out) : RunConvert(in, out);
}
