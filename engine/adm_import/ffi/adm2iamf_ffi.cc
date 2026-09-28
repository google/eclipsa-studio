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

#include "adm_import/ffi/adm2iamf_ffi.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <queue>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

#include "absl/container/flat_hash_set.h"
#include "absl/status/status.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"
#include "absl/types/span.h"
#include "adm_import/adm/adm_audit.h"
#include "adm_import/adm/adm_model.h"
#include "adm_import/adm/adm_parser.h"
#include "adm_import/adm/common_definitions.h"
#include "adm_import/adm/json_escape.h"
#include "adm_import/adm/xml.h"
#include "adm_import/convert/convert.h"
#include "adm_import/render/channel_renderer.h"
#include "adm_import/render/image_spread.h"
#include "adm_import/render/object_motion.h"
#include "adm_import/render/render_progress.h"
#include "adm_import/scene/adm_adapter.h"
#include "adm_import/scene/layouts.h"
#include "adm_import/scene/scene.h"
#include "adm_import/wav/bw64_reader.h"
#include "adm_import/wav/wav_writer.h"
#include "wav/types.h"

// ABI pin: the Dart mirror (app/lib/import/adm_import_bridge.dart) and its
// hermetic test (adm_import_bridge_test.dart) assume this exact layout. Catch
// any drift at compile time on the C side too.
static_assert(sizeof(Adm2iamfRenderConfig) == 24,
              "Adm2iamfRenderConfig size drift vs the Dart ABI mirror.");
static_assert(offsetof(Adm2iamfRenderConfig, in_path) == 8,
              "Adm2iamfRenderConfig::in_path offset drift.");
static_assert(offsetof(Adm2iamfRenderConfig, out_path) == 16,
              "Adm2iamfRenderConfig::out_path offset drift.");

namespace adm2iamf {
namespace {

// ── Minimal JSON building (the repo stays dependency-light; no JSON dep)
// ──────

// The shared emitter also sanitizes: file-derived bytes that are not
// well-formed UTF-8 become U+FFFD, so the Dart-side decoder cannot throw.
using adm::AppendJsonString;

std::string JsonString(absl::string_view s) {
  std::string out;
  AppendJsonString(out, s);
  return out;
}

std::string JsonBool(bool b) { return b ? "true" : "false"; }

// {"ok":false,"error":"..."} -- the shared error/cancel envelope.
char* DupCStr(absl::string_view s) {
  char* p = static_cast<char*>(std::malloc(s.size() + 1));
  if (p == nullptr) return nullptr;
  std::memcpy(p, s.data(), s.size());
  p[s.size()] = '\0';
  return p;
}

std::string ErrorJsonString(absl::string_view message) {
  std::string out = "{\"ok\":false,\"error\":";
  AppendJsonString(out, message);
  out.push_back('}');
  return out;
}

char* ErrorJson(absl::string_view message) {
  return DupCStr(ErrorJsonString(message));
}

// ── Probe ────────────────────────────────────────────────────────────────────

// One import warning surfaced to the app. Severity is "info" or "warning".
struct ImportWarning {
  const char* severity;
  const char* code;
  std::string message;
};

// Builds the deduped, capped warnings list from the per-channel resolution
// records, the audit roll-ups, extra chunks and common-definition misses.
//
// Every input here is file-controlled and only loosely bounded (one record
// per declared bed channel), so both the output and the dedup set are capped
// at the producer rather than trimmed afterwards -- the previous shape held
// every distinct message in memory and rescanned them linearly per add.
std::vector<ImportWarning> BuildWarnings(
    const Scene* scene, const adm::AuditReport& audit,
    const std::vector<Bw64Reader::ExtraChunk>& extra_chunks,
    uint64_t extra_chunks_seen,
    const std::vector<std::string>& commondef_unresolved) {
  constexpr size_t kMaxWarnings = 50;
  std::vector<ImportWarning> out;
  absl::flat_hash_set<std::string> seen;
  size_t dropped = 0;
  const auto add = [&](const char* severity, const char* code,
                       std::string message) {
    if (out.size() >= kMaxWarnings) {
      // Past the cap, stop tracking distinct messages too; `dropped` then
      // counts occurrences, which is all the summary row claims.
      ++dropped;
      return;
    }
    // Key on (code, message): two codes may legitimately share wording.
    if (!seen.insert(absl::StrCat(code, "\x1f", message)).second) return;
    out.push_back(ImportWarning{severity, code, std::move(message)});
  };

  if (scene != nullptr) {
    for (const ChannelResolution& r : scene->resolutions) {
      absl::string_view who =
          r.channel_name.empty() ? r.channel_id : r.channel_name;
      if (who.empty()) who = "(unnamed)";
      if (r.method == ResolutionMethod::kUnsupportedPack) {
        // "We do not render this content" is a different class of notice
        // from "this channel is malformed" (ES-623, ES-553); HOA support (ES-441)
        // retires it.
        add("warning", "pack_type_unsupported",
            absl::StrCat("Channel ", who, " ", r.note,
                         " and will not be rendered."));
        continue;
      }
      if (!r.resolved) {
        add("warning", "channel_unresolved",
            absl::StrCat("Channel ", who, " could not be resolved (", r.note,
                         "); it will not be rendered."));
        continue;
      }
      // Severity is the dialog's triage (ES-553): "warning" for anything that
      // changes what gets rendered (a dropped, unsupported or misrouted
      // channel, a clamped object), "info" for the routine notices a vendor
      // master produces by the dozen (a documented fallback that resolved,
      // a label the authored position overrode, discarded non-spec
      // metadata). Every entry still reaches the JSONL log with its code.
      if (r.divergence) {
        add("info", "label_position_divergence",
            absl::StrCat("Channel ", who, ": ", r.note, "."));
      }
      if (r.lfe_ambiguous) {
        add("warning", "lfe_ambiguous",
            absl::StrCat("Channel ", who,
                         ": position coincides with an LFE slot but nothing "
                         "marks it as LFE; treated as a speaker."));
      }
      if (r.fallback) {
        add("info", "channel_fallback",
            absl::StrCat("Channel ", who, ": ",
                         r.note.empty() ? "resolved via fallback" : r.note,
                         "."));
      }
    }
  }

  if (scene != nullptr && scene->clamped_object_values > 0) {
    add("warning", "object_position_clamped",
        absl::StrCat(scene->clamped_object_values,
                     " object position values outside the room cube were "
                     "clamped to it, changing those objects' authored "
                     "directions."));
  }

  if (audit.counts.unknown > 0) {
    add("info", "audit_unknown",
        absl::StrCat(audit.counts.unknown,
                     " non-spec (unknown) elements/attributes in the ADM "
                     "metadata were discarded."));
  }
  if (audit.counts.invalid_value > 0) {
    add("info", "audit_invalid",
        absl::StrCat(audit.counts.invalid_value,
                     " ADM values outside their spec domain; fallbacks "
                     "substituted."));
  }

  for (const auto& c : extra_chunks) {
    add("info", "extra_chunk",
        absl::StrCat("Non-ADM chunk '", c.id, "' (", c.bytes,
                     " bytes) was ignored."));
  }
  if (extra_chunks_seen > extra_chunks.size()) {
    add("info", "extra_chunk",
        absl::StrCat("+", extra_chunks_seen - extra_chunks.size(),
                     " further non-ADM chunks were ignored."));
  }
  for (const std::string& id : commondef_unresolved) {
    add("warning", "commondef_unresolved",
        absl::StrCat("Common-definition channel ", id,
                     " is not in the built-in table; channel dropped."));
  }

  if (dropped > 0) {
    // Replace the last kept entry with the summary so the list is exactly
    // kMaxWarnings long and the count stays truthful.
    out.back() =
        ImportWarning{"info", "truncated",
                      absl::StrCat("+", dropped + 1,
                                   " more warnings not shown; the audit "
                                   "counts above cover them.")};
  }
  return out;
}

void AppendWarningsJson(std::string& out,
                        const std::vector<ImportWarning>& warnings) {
  absl::StrAppend(&out, ",\"warnings\":[");
  bool first = true;
  for (const ImportWarning& w : warnings) {
    if (!first) out.push_back(',');
    first = false;
    absl::StrAppend(&out, "{\"severity\":\"", w.severity, "\",\"code\":\"",
                    w.code, "\",\"message\":", JsonString(w.message), "}");
  }
  out.push_back(']');
}

// Trajectory downsampling caps: the probe is a preview, not a data export.
// The total bounds the probe JSON against a pathological master (hundreds of
// moving objects); the per-object ceiling bounds the polyline any one object
// hands the inspector to draw.
//
// The budget is split between the movers rather than handed out first-come.
// A first-come split starves the tail of the list, and 64 points each — what
// shipped before ES-608 — is not enough for an object that orbits: one measured
// master turns an object through 55 degrees a second for 196 s, where 64
// vertices sit 3.6 s apart, further than half a revolution, and the drawn
// path takes the short way round and travels backwards.
//
// The two figures come from what that file's paths cost to draw correctly.
// Its densest orbiting object asks for 654 points to stay inside the
// tolerance below; 8192 divided among its 26 movers reaches 634 of them,
// which draws the object's four-lobed orbit with a median position error of
// 0.4 degrees against a near-exact reference. 4096 gave it 216 points and a
// featureless ring at 2.4 degrees; 16384 gives it the last 20 points and
// changes nothing visible. The cost of 8192 is a 435 KB probe JSON and about
// 46000 drawn chords on that file, against 221 KB and 27700 at 4096. The
// ceiling of 1024 is what the six objects that teleport rather than travel
// are held to — they ask for 10000 to 22000 each and no polyline describes
// them.
constexpr size_t kMaxTrajectoryPointsPerObject = 1024;
constexpr size_t kMaxTrajectoryPointsTotal = 8192;

// How far the drawn polyline is allowed to sit from the evaluated motion
// before a vertex has to be kept (ES-608). Cartesian ADM exports write
// jitter-sized keyframes in 0.01 cube steps, worth about 0.6 degrees at the
// edge of the cube, so this discards the jitter; authored corners are larger
// and survive.
constexpr double kTrajectoryToleranceDeg = 2.0;

// What a full-range change of `distance` costs against that tolerance. The
// inspector lerps distance between vertices exactly as it lerps direction, so
// motion that only changes distance has to register as an error too or it
// would decimate away to its two ends. 0 -> 1 costs as much as a 90-degree
// turn.
constexpr double kTrajectoryDistanceDeg = 90.0;

// Instants evaluated for one object before decimation, at most two per
// keyframe. Bounds the memory and the O(candidates * cap) decimation a
// pathological timeline (a million keyframes) can ask for. The densest
// objects measured on real masters want 6504 and 19068 candidates, both
// inside this; past it the candidate instants are thinned uniformly before
// the decimation runs. The bound is not a speed limit worth tightening:
// decimating a 337 s master with twelve 9534-keyframe movers costs 130 ms of
// the probe's 3.9 s.
constexpr size_t kMaxTrajectoryCandidates = 32768;

constexpr double kPi = 3.14159265358979323846;

// A direction as a unit vector, for the angular error below. Same axis
// convention as image_spread.cc, though only angles between two of these are
// ever taken, so any consistent one would do.
struct TrajectoryDir {
  double x = 0.0, y = 0.0, z = 0.0;
};

TrajectoryDir DirectionOf(const Polar& p) {
  const double az = p.azimuth * kPi / 180.0;
  const double el = p.elevation * kPi / 180.0;
  const double ce = std::cos(el);
  return {ce * std::cos(az), ce * std::sin(az), std::sin(el)};
}

double AngleBetweenDeg(const TrajectoryDir& a, const TrajectoryDir& b) {
  const double dot = std::clamp(a.x * b.x + a.y * b.y + a.z * b.z, -1.0, 1.0);
  return std::acos(dot) * 180.0 / kPi;
}

// One evaluated instant of an object's path: the converted position, its time
// in seconds, and the direction the error metric compares.
struct TrajectorySample {
  Polar p;
  double t = 0.0;
  TrajectoryDir dir;
};

// How far `c` sits from where a polyline through `a` and `b` alone would put
// it, in degrees. Reconstructs the position the same way the inspector does
// (azimuth the short way round, elevation and distance linear, by time), so
// the number bounds the error a viewer sees, in the drawn mark and in the
// scrubber's readout alike.
double TrajectoryErrorDeg(const TrajectorySample& a, const TrajectorySample& b,
                          const TrajectorySample& c) {
  const double span = b.t - a.t;
  const double u = span > 0.0 ? (c.t - a.t) / span : 0.0;
  double step = static_cast<double>(b.p.azimuth) - a.p.azimuth;
  if (step > 180.0) {
    step -= 360.0;
  } else if (step < -180.0) {
    step += 360.0;
  }
  Polar mid;
  mid.azimuth = static_cast<float>(a.p.azimuth + step * u);
  mid.elevation =
      static_cast<float>(a.p.elevation + (b.p.elevation - a.p.elevation) * u);
  mid.distance =
      static_cast<float>(a.p.distance + (b.p.distance - a.p.distance) * u);
  const double angle = AngleBetweenDeg(DirectionOf(mid), c.dir);
  const double radial = std::abs(static_cast<double>(mid.distance) -
                                 static_cast<double>(c.p.distance)) *
                        kTrajectoryDistanceDeg;
  return std::max(angle, radial);
}

// Chooses which of `pts` to draw: always its two ends, then the interior
// vertices whose absence would push the reconstructed path past
// kTrajectoryToleranceDeg, at most `cap` in all. Douglas-Peucker, run
// best-first from a heap rather than depth-first, so hitting the cap keeps
// the `cap` most load-bearing corners of the path instead of every corner in
// its first half. Returns ascending indices into `pts`.
std::vector<size_t> DecimateTrajectory(const std::vector<TrajectorySample>& pts,
                                       size_t cap) {
  std::vector<size_t> kept;
  if (pts.size() < 2 || cap < 2) return kept;
  // A segment of the path with the interior vertex that is furthest off it.
  struct Split {
    size_t a = 0, b = 0, worst = 0;
    double err = 0.0;
    // std::priority_queue pops the largest, which is the split to take next.
    bool operator<(const Split& o) const { return err < o.err; }
  };
  std::vector<bool> keep(pts.size(), false);
  keep[0] = true;
  keep[pts.size() - 1] = true;
  size_t n_kept = 2;
  std::priority_queue<Split> queue;
  const auto consider = [&](size_t a, size_t b) {
    if (b <= a + 1) return;  // No interior vertex to judge.
    Split s{a, b, a + 1, -1.0};
    for (size_t i = a + 1; i < b; ++i) {
      const double e = TrajectoryErrorDeg(pts[a], pts[b], pts[i]);
      if (e > s.err) {
        s.err = e;
        s.worst = i;
      }
    }
    if (s.err > kTrajectoryToleranceDeg) queue.push(s);
  };
  consider(0, pts.size() - 1);
  while (!queue.empty() && n_kept < cap) {
    const Split s = queue.top();
    queue.pop();
    keep[s.worst] = true;
    ++n_kept;
    consider(s.a, s.worst);
    consider(s.worst, s.b);
  }
  kept.reserve(n_kept);
  for (size_t i = 0; i < pts.size(); ++i) {
    if (keep[i]) kept.push_back(i);
  }
  return kept;
}

// Appends `"start_s":<s>,"end_s":<s>,"trajectory":[[az,el,dist,t,rms_deg,
// ratio,tilt_deg,focus],...]` members for a moving object.
//
// The vertices are the corners of the *interpolated* motion, evaluated
// through the same object_motion.h path the renderer bakes in, so the preview
// matches the bake (jumpPosition snaps, interpolationLength ramps), and each
// one converts through ConvertObjectPosition with the render's `anchors`.
// Motion between keyframes is linear, so the path is exactly the polyline
// through every keyframe start and ramp end; those instants are evaluated and
// then decimated to the ones the drawn path cannot do without (ES-608). Vertices
// are neither uniform in time nor a subset of any grid, so the inspector
// places each one by its `t`.
//
// `t` is the vertex's time in seconds from the start of the file; the four
// values after it are the ImageSpread fields `meter` reports for the vertex,
// in declaration order (all four are omitted when `meter` is null); `start_s`
// and `end_s` are the motion span the vertices cover (first keyframe start to
// the end of the last keyframe's ramp).
//
// `share` is this object's slice of the probe-wide budget, from which the
// vertex count is capped; the caller divides `budget` between the movers so
// no object is starved by the ones ahead of it in the list.
//
// Emits nothing for static objects (single keyframe), an unusable sample
// rate, when fewer than two points of `budget` remain (two is the minimum
// useful polyline), or when the whole path sits at one position (a
// multi-block object that never moves). `budget` is decremented by the points
// actually kept, and `dropped_objects` counts moving objects that got no
// trajectory purely because the probe-wide budget ran out — surfaced in the
// JSON so the probe stays honest about truncation, as the audit section does.
void AppendTrajectoryJson(std::string& out, const ObjectSource& o,
                          uint32_t sample_rate,
                          const oar_position_anchors_t* anchors,
                          ImageSpreadMeter* meter, size_t share, size_t& budget,
                          size_t& dropped_objects) {
  if (o.timeline.size() < 2 || sample_rate == 0) return;
  if (budget < 2) {
    ++dropped_objects;
    return;
  }
  const std::vector<uint64_t> start =
      KeyframeStartFrames(o.timeline, sample_rate);
  // Motion ends once the last keyframe's ramp completes (interpolationLength,
  // else the block duration); the position holds constant afterwards. The
  // timeline is document-ordered, so front()/back() being the extremes is a
  // file-derived assumption — a reversed timeline lands in the degenerate
  // branch below rather than sampling a bogus span.
  const ObjectKeyframe& last = o.timeline.back();
  const double tail_s = last.interp_length_s.has_value() ? *last.interp_length_s
                        : last.has_duration              ? last.duration_s
                                                         : 0.0;
  const uint64_t begin = start.front();
  const uint64_t end =
      start.back() + static_cast<uint64_t>(std::llround(tail_s * sample_rate));
  const double begin_s = begin / static_cast<double>(sample_rate);
  const double end_s = end / static_cast<double>(sample_rate);

  std::vector<TrajectorySample> pts;
  if (end <= begin) {
    // Degenerate span (all keyframes snap at one instant, e.g. blocks with no
    // usable rtime): the interpolated path is a single point, so fall back to
    // the keyframe positions, every vertex stamped with that one instant. The
    // decimation still runs and still caps them.
    pts.reserve(o.timeline.size());
    for (const ObjectKeyframe& k : o.timeline) {
      const Polar p = ConvertObjectPosition(k.position, anchors);
      pts.push_back({p, begin_s, DirectionOf(p)});
    }
  } else {
    // The corners of the path. A keyframe either ramps into its position over
    // `ramp` frames from its own start, or snaps to it there (the first one,
    // jumpPosition, or no ramp length at all) — in which case the instant
    // before the snap is a corner too, and holds the previous position, so
    // the drawn path steps rather than sliding into the snap.
    std::vector<uint64_t> frames;
    frames.reserve(o.timeline.size() * 2 + 2);
    for (size_t i = 0; i < o.timeline.size(); ++i) {
      const ObjectKeyframe& k = o.timeline[i];
      const double ramp_s = k.interp_length_s.has_value() ? *k.interp_length_s
                            : k.has_duration              ? k.duration_s
                                                          : 0.0;
      const uint64_t ramp =
          static_cast<uint64_t>(std::llround(ramp_s * sample_rate));
      if (i > 0) {
        if (k.jump || ramp == 0) {
          if (start[i] > begin) frames.push_back(start[i] - 1);
        } else {
          frames.push_back(start[i] + ramp);
        }
      }
      frames.push_back(start[i]);
    }
    frames.push_back(begin);
    frames.push_back(end);
    std::sort(frames.begin(), frames.end());
    frames.erase(
        std::remove_if(frames.begin(), frames.end(),
                       [&](uint64_t f) { return f < begin || f > end; }),
        frames.end());
    frames.erase(std::unique(frames.begin(), frames.end()), frames.end());
    if (frames.size() > kMaxTrajectoryCandidates) {
      // Uniform thinning of the corner list, keeping both ends. Only a
      // timeline denser than any real master reaches this.
      std::vector<uint64_t> thinned;
      thinned.reserve(kMaxTrajectoryCandidates);
      const size_t span = frames.size() - 1;
      for (size_t i = 0; i < kMaxTrajectoryCandidates; ++i) {
        thinned.push_back(frames[(span * i) / (kMaxTrajectoryCandidates - 1)]);
      }
      thinned.erase(std::unique(thinned.begin(), thinned.end()), thinned.end());
      frames.swap(thinned);
    }
    pts.reserve(frames.size());
    for (const uint64_t f : frames) {
      const size_t cur = ActiveKeyframe(start, f);
      const Polar p = ConvertObjectPosition(
          EvalObjectTimeline(o.timeline, start, cur, f, sample_rate).position,
          anchors);
      pts.push_back({p, f / static_cast<double>(sample_rate), DirectionOf(p)});
    }
  }

  const std::vector<size_t> kept = DecimateTrajectory(
      pts, std::min({kMaxTrajectoryPointsPerObject, share, budget}));
  if (kept.size() < 2) return;
  // Every kept vertex at one position means the object never moved: a
  // stationary multi-block object, not a path. Emit nothing and leave the
  // budget untouched. Exact comparison is right here — a hold re-evaluates to
  // bit-identical floats, while a real ramp never repeats a value.
  const Polar& first = pts[kept.front()].p;
  const bool still = std::all_of(kept.begin(), kept.end(), [&](size_t i) {
    return pts[i].p.azimuth == first.azimuth &&
           pts[i].p.elevation == first.elevation &&
           pts[i].p.distance == first.distance;
  });
  if (still) return;

  std::string body;
  for (size_t i = 0; i < kept.size(); ++i) {
    const TrajectorySample& s = pts[kept[i]];
    absl::StrAppend(&body, i ? "," : "", "[", s.p.azimuth, ",", s.p.elevation,
                    ",", s.p.distance, ",", s.t);
    if (meter != nullptr) {
      const ImageSpread sp = meter->Measure(s.p);
      absl::StrAppend(&body, ",", sp.rms_deg, ",", sp.ratio, ",", sp.tilt_deg,
                      ",", sp.focus);
    }
    body.push_back(']');
  }
  absl::StrAppend(&out, ",\"start_s\":", begin_s, ",\"end_s\":", end_s,
                  ",\"trajectory\":[", body, "]");
  budget -= kept.size();
}

std::string BuildProbeJson(const std::string& path) {
  auto reader = Bw64Reader::Open(path);
  if (!reader.ok()) {
    std::string out = "{\"ok\":false,\"error\":";
    AppendJsonString(out, reader.status().message());
    out.push_back('}');
    return out;
  }
  const auto& fmt = (*reader)->format();
  const uint64_t num_frames = (*reader)->num_frames();
  const double duration =
      fmt.sample_rate ? static_cast<double>(num_frames) / fmt.sample_rate : 0.0;

  // The render's anchors (7.1.4), derived once per probe and used for every
  // object position and trajectory sample below, so the preview shows the
  // bake's positions. RenderChannelBed derives the same handle and fails the
  // same way when it cannot (ES-607).
  const AnchorsHandle anchors = MakeAnchors(ImportLayout());
  if (anchors == nullptr) {
    return ErrorJsonString(
        "position conversion anchors unavailable for 7.1.4.");
  }

  // Measures how wide the render images each position the probe reports
  // (ES-640), created once for the whole probe. Unlike the anchors this is not
  // load-bearing: without it every `spread` field is simply absent and the
  // preview draws marks without halos, which beats refusing to describe a
  // file over a drawing detail.
  const std::unique_ptr<ImageSpreadMeter> meter =
      ImageSpreadMeter::Create(ImportLayout());

  std::string out = "{\"ok\":true,\"format\":{";
  absl::StrAppend(
      &out, "\"channels\":", fmt.channels, ",\"sample_rate\":", fmt.sample_rate,
      ",\"bits_per_sample\":", fmt.bits_per_sample(),
      ",\"is_float\":", JsonBool(wav::IsFloatFormat(fmt.format)),
      ",\"num_frames\":", num_frames, ",\"duration_s\":", duration,
      ",\"axml_bytes\":", (*reader)->axml().size(),
      ",\"chna_bytes\":", (*reader)->chna().size(), ",\"extra_chunks\":[");
  {
    bool first = true;
    for (const Bw64Reader::ExtraChunk& c : (*reader)->extra_chunks()) {
      if (!first) out.push_back(',');
      first = false;
      absl::StrAppend(&out, "{\"id\":", JsonString(c.id),
                      ",\"bytes\":", c.bytes, "}");
    }
  }
  absl::StrAppend(&out, "]}");

  if ((*reader)->axml().empty()) {
    // Not ADM: report format only, with an empty scene.
    absl::StrAppend(&out,
                    ",\"adm\":null,\"scene\":{\"sources\":[],\"objects\":[]},"
                    "\"unresolved\":[],\"warnings\":[]}");
    return out;
  }

  // One XML parse feeds both the model builder and the audit walker.
  auto root = ParseXml((*reader)->axml());
  if (!root.ok()) {
    std::string err = "{\"ok\":false,\"error\":";
    AppendJsonString(
        err, absl::StrCat("axml parse failed: ", root.status().message()));
    err.push_back('}');
    return err;
  }
  adm::Model model = adm::BuildModel(*root);
  adm::AuditReport audit = adm::AuditAxml(*root);

  if (!(*reader)->chna().empty()) {
    auto chna = adm::ParseChna(absl::MakeConstSpan((*reader)->chna()));
    // Same outcome as the import (convert.cc LoadAdm): a malformed table
    // is an error, not "no table" — previewing a sequentially numbered scene
    // that the render then rejects would mislead (ES-626).
    if (!chna.ok()) return ErrorJsonString(chna.status().message());
    model.chna = *chna;
  }
  const std::vector<std::string> unresolved =
      adm::ResolveCommonDefinitions(model);

  absl::StrAppend(&out, ",\"adm\":{\"programmes\":", model.programmes.size(),
                  ",\"contents\":", model.contents.size(),
                  ",\"objects\":", model.objects.size(),
                  ",\"packs\":", model.packs.size(),
                  ",\"channels\":", model.channels.size(),
                  ",\"chna_rows\":", model.chna.size(), "}");

  auto scene = BuildSceneFromAdm(model);
  if (!scene.ok()) {
    // Format + ADM parsed, but no renderable scene: surface the reason and an
    // empty scene rather than failing the whole probe.
    absl::StrAppend(&out,
                    ",\"scene\":{\"sources\":[],\"objects\":[],\"error\":");
    AppendJsonString(out, scene.status().message());
    out.push_back('}');
  } else {
    absl::StrAppend(&out, ",\"scene\":{\"sources\":[");
    // Each record names the source it produced, so the annotation follows
    // the adapter's own bookkeeping rather than assuming the two vectors
    // advance in lockstep.
    std::vector<const ChannelResolution*> source_records(scene->sources.size(),
                                                         nullptr);
    for (const ChannelResolution& r : scene->resolutions) {
      if (r.source_index >= 0 &&
          static_cast<size_t>(r.source_index) < source_records.size()) {
        source_records[r.source_index] = &r;
      }
    }
    bool first = true;
    for (size_t i = 0; i < scene->sources.size(); ++i) {
      const Source& s = scene->sources[i];
      if (!first) out.push_back(',');
      first = false;
      absl::StrAppend(&out, "{\"label\":", JsonString(s.label),
                      ",\"lfe\":", JsonBool(s.is_lfe),
                      ",\"azimuth\":", s.position.azimuth,
                      ",\"elevation\":", s.position.elevation,
                      ",\"distance\":", s.position.distance,
                      ",\"gain\":", s.gain, ",\"track\":", s.track_index);
      // How wide the render images this channel (degrees). An LFE channel
      // routes rather than pans, so it has no direction and no width.
      if (meter != nullptr && !s.is_lfe) {
        const ImageSpread sp = meter->Measure(s.position);
        absl::StrAppend(
            &out, ",\"spread\":", sp.rms_deg, ",\"spread_ratio\":", sp.ratio,
            ",\"spread_tilt\":", sp.tilt_deg, ",\"spread_focus\":", sp.focus);
      }
      if (source_records[i] != nullptr) {
        const ChannelResolution& r = *source_records[i];
        absl::StrAppend(&out, ",\"resolution\":{\"method\":\"",
                        ResolutionMethodName(r.method),
                        "\",\"resolved\":", JsonBool(r.resolved),
                        ",\"fallback\":", JsonBool(r.fallback),
                        ",\"note\":", JsonString(r.note), "}");
      }
      out.push_back('}');
    }
    absl::StrAppend(&out, "],\"objects\":[");
    first = true;
    size_t trajectory_budget = kMaxTrajectoryPointsTotal;
    size_t trajectory_dropped = 0;
    // Movers still to come, so each one's share of what is left of the budget
    // can be worked out as the list is walked. Objects that need fewer points
    // than their share leave the rest to the movers behind them.
    size_t movers_left = 0;
    for (const ObjectSource& o : scene->objects) {
      if (o.timeline.size() >= 2) ++movers_left;
    }
    for (const ObjectSource& o : scene->objects) {
      if (!first) out.push_back(',');
      first = false;
      const ObjectPosition& pos0 = o.timeline.front().position;
      const Polar p0 = ConvertObjectPosition(pos0, anchors.get());
      absl::StrAppend(
          &out, "{\"label\":", JsonString(o.label),
          ",\"track\":", o.track_index, ",\"importance\":", o.importance,
          ",\"blocks\":", o.timeline.size(), ",\"azimuth\":", p0.azimuth,
          ",\"elevation\":", p0.elevation, ",\"distance\":", p0.distance,
          ",\"cartesian\":", JsonBool(pos0.cartesian));
      if (meter != nullptr) {
        const ImageSpread sp = meter->Measure(p0);
        absl::StrAppend(
            &out, ",\"spread\":", sp.rms_deg, ",\"spread_ratio\":", sp.ratio,
            ",\"spread_tilt\":", sp.tilt_deg, ",\"spread_focus\":", sp.focus);
      }
      // The authored cube, for the inspector: after the anchored conversion
      // `distance` is r_xy or |z|, not a radius, so the numbers above cannot
      // be read back as a room position (ES-635). Emitted only when the object
      // is cartesian-authored — a polar object has no cube, and zeros would
      // assert one. Describes the first keyframe only: a timeline that mixes
      // coordinate systems (out of spec, see render/object_motion.h) gets a
      // flag that does not hold for its whole path.
      if (pos0.cartesian) {
        absl::StrAppend(&out, ",\"x\":", pos0.cube.x, ",\"y\":", pos0.cube.y,
                        ",\"z\":", pos0.cube.z);
      }
      size_t share = 0;
      if (o.timeline.size() >= 2 && movers_left > 0) {
        share = std::max<size_t>(2, trajectory_budget / movers_left);
        --movers_left;
      }
      AppendTrajectoryJson(out, o, fmt.sample_rate, anchors.get(), meter.get(),
                           share, trajectory_budget, trajectory_dropped);
      out.push_back('}');
    }
    out.push_back(']');
    if (trajectory_dropped > 0) {
      // Truthfulness marker: this many moving objects have no trajectory only
      // because the probe-wide point budget ran out, not because they are
      // static.
      absl::StrAppend(&out,
                      ",\"trajectory_objects_dropped\":", trajectory_dropped);
    }
    absl::StrAppend(&out, ",\"unresolved_channels\":[");
    first = true;
    for (const ChannelResolution& r : scene->resolutions) {
      if (r.resolved) continue;
      if (!first) out.push_back(',');
      first = false;
      absl::StrAppend(&out, "{\"id\":", JsonString(r.channel_id),
                      ",\"name\":", JsonString(r.channel_name),
                      ",\"reason\":", JsonString(r.note), "}");
    }
    out.push_back(']');
    out.push_back('}');
  }

  absl::StrAppend(&out, ",\"unresolved\":[");
  for (size_t i = 0; i < unresolved.size(); ++i) {
    if (i != 0) out.push_back(',');
    AppendJsonString(out, unresolved[i]);
  }
  out.push_back(']');

  // Audit report: findings capped (full detail lives in external tooling).
  // The shortfall lands in counts.findings_dropped so the report stays
  // honest about truncation.
  constexpr size_t kMaxAuditFindings = 100;
  if (audit.findings.size() > kMaxAuditFindings) {
    audit.counts.findings_dropped +=
        static_cast<int>(audit.findings.size() - kMaxAuditFindings);
    audit.findings.resize(kMaxAuditFindings);
  }
  absl::StrAppend(&out, ",\"audit\":", audit.ToJson());

  AppendWarningsJson(out,
                     BuildWarnings(scene.ok() ? &*scene : nullptr, audit,
                                   (*reader)->extra_chunks(),
                                   (*reader)->extra_chunks_seen(), unresolved));
  out.push_back('}');
  return out;
}

// ── Render job table ─────────────────────────────────────────────────────────

struct Job {
  std::atomic<float> progress{0.0f};
  std::atomic<int> state{kAdm2iamfRenderRunning};
  std::atomic<bool> cancel{false};
  // Written by the worker before `state` becomes terminal (release), so it is
  // safe to read once a reader observes a terminal state (acquire).
  std::string result_json;
};

// Table entry: the shared job state plus the worker thread handle. The thread
// is kept joinable (not detached) so adm2iamf_shutdown() can drain all
// in-flight work before the host unloads this library.
struct JobEntry {
  std::shared_ptr<Job> job;
  std::thread worker;
};

// All three statics are intentionally leaked (never destroyed) to avoid a
// static-destruction-order race with a worker that is still finishing; the
// process reclaims the memory on exit. NextJobId() is mutated only under
// JobsMutex.
std::mutex& JobsMutex() {
  static std::mutex* m = new std::mutex();
  return *m;
}
std::map<int, JobEntry>& Jobs() {
  static auto* jobs = new std::map<int, JobEntry>();
  return *jobs;
}
int& NextJobId() {
  static int id = 0;
  return id;
}

std::shared_ptr<Job> FindJob(int id) {
  std::lock_guard<std::mutex> lock(JobsMutex());
  auto it = Jobs().find(id);
  return it == Jobs().end() ? nullptr : it->second.job;
}

// Routes an extern "C" body through a catch-all so a C++ exception can never
// cross the C ABI (which is undefined behavior). On any throw, returns
// `fallback`; the catch only returns that trivial value, so it cannot throw.
template <typename Fn>
std::invoke_result_t<Fn> GuardAbi(Fn&& fn, std::invoke_result_t<Fn> fallback) {
  // Returning `fallback` must not itself throw, or an exception could still
  // escape the catch. The C ABI only ever returns trivially-copyable scalars
  // (char*, int, float), so lock that invariant in.
  static_assert(std::is_trivially_copyable_v<std::invoke_result_t<Fn>>,
                "GuardAbi fallback must be trivially copyable.");
  try {
    return std::forward<Fn>(fn)();
  } catch (...) {
    return fallback;
  }
}

// Runs one render to completion on the worker thread, writing the WAV and a
// result-JSON summary, then publishing the terminal state. `in_path`/`out_path`
// are owned copies (made on the calling thread) so this worker never touches
// the caller's freed `cfg.in_path`/`out_path` pointers; `cfg` carries only the
// inline scalars, which copy by value.
void RunRenderImpl(std::shared_ptr<Job> job, Adm2iamfRenderConfig cfg,
                   std::string in_path, std::string out_path) {
  RenderProgress progress;
  progress.report = [job](uint64_t done, uint64_t total) {
    job->progress.store(total ? static_cast<float>(static_cast<double>(done) /
                                                   static_cast<double>(total))
                              : 0.0f,
                        std::memory_order_relaxed);
  };
  progress.should_cancel = [job] {
    return job->cancel.load(std::memory_order_relaxed);
  };

  // The bed is always 24-bit PCM (the app offers no encoding choice; extend
  // the config if one is ever needed).
  const WavEncoding enc = WavEncoding::kPcm24;

  std::string result;
  absl::Status status = absl::OkStatus();
  int channels_written = 0;
  uint32_t sample_rate = 0;
  std::string stats_json;

  auto r = ConvertAdmFileToChannelBed(in_path, cfg.min_importance, &progress);
  if (r.ok()) {
    status = WriteWavPlanar(out_path, r->channels, r->sample_rate, enc);
    channels_written = static_cast<int>(r->channels.size());
    sample_rate = r->sample_rate;
    const auto& s = r->stats;
    stats_json =
        absl::StrCat("{\"passthrough\":", s.passthrough, ",\"lfe\":", s.lfe,
                     ",\"olr\":", s.olr, ",\"objects\":", s.objects,
                     ",\"objects_dropped\":", s.objects_dropped, "}");
  } else {
    status = r.status();
  }

  int terminal;
  if (absl::IsCancelled(status)) {
    job->result_json = ErrorJsonString("render cancelled");
    terminal = kAdm2iamfRenderCancelled;
  } else if (!status.ok()) {
    job->result_json = ErrorJsonString(status.message());
    terminal = kAdm2iamfRenderError;
  } else {
    std::string ok = "{\"ok\":true,\"out_path\":";
    AppendJsonString(ok, out_path);
    absl::StrAppend(&ok, ",\"sample_rate\":", sample_rate,
                    ",\"channels\":", channels_written,
                    ",\"stats\":", stats_json.empty() ? "null" : stats_json,
                    "}");
    job->result_json = std::move(ok);
    job->progress.store(1.0f, std::memory_order_relaxed);
    terminal = kAdm2iamfRenderDone;
  }
  job->state.store(terminal, std::memory_order_release);
}

// Worker thread entry point. Wraps RunRenderImpl so no exception escapes the
// thread's top-level function -- that would call std::terminate and take down
// the whole host process. A throw instead becomes a terminal error state, and
// the inner try/catch guarantees the state store runs even if building the
// error string itself fails (so a poller never hangs in Running).
void RunRender(std::shared_ptr<Job> job, Adm2iamfRenderConfig cfg,
               std::string in_path, std::string out_path) {
  try {
    // `job` is copied (not moved) so it is still valid in the catch handlers.
    RunRenderImpl(job, cfg, std::move(in_path), std::move(out_path));
    return;
  } catch (const std::exception& e) {
    try {
      job->result_json =
          ErrorJsonString(absl::StrCat("internal error: ", e.what()));
    } catch (...) {  // NOLINT(bugprone-empty-catch): best-effort message only.
    }
  } catch (...) {
    try {
      job->result_json = ErrorJsonString("internal error");
    } catch (...) {  // NOLINT(bugprone-empty-catch)
    }
  }
  job->state.store(kAdm2iamfRenderError, std::memory_order_release);
}

}  // namespace
}  // namespace adm2iamf

// ── C ABI ────────────────────────────────────────────────────────────────────

extern "C" {

char* adm2iamf_probe_json(const char* path) {
  return adm2iamf::GuardAbi(
      [&]() -> char* {
        if (path == nullptr) return adm2iamf::ErrorJson("null path");
        return adm2iamf::DupCStr(adm2iamf::BuildProbeJson(path));
      },
      nullptr);
}

void adm2iamf_string_free(char* s) {
  if (s != nullptr) std::free(s);
}

int adm2iamf_render_start(const Adm2iamfRenderConfig* cfg) {
  if (cfg == nullptr || cfg->in_path == nullptr || cfg->out_path == nullptr) {
    return -1;
  }
  return adm2iamf::GuardAbi(
      [&]() -> int {
        auto job = std::make_shared<adm2iamf::Job>();
        // Copy everything the worker needs onto owned storage *now*, on the
        // calling thread, so the caller may free `cfg` and its strings as soon
        // as this returns: the struct copy carries the inline scalars, and
        // the path pointers are dereferenced into std::strings here (never
        // on the worker).
        Adm2iamfRenderConfig copy = *cfg;
        std::string in_path = cfg->in_path;
        std::string out_path = cfg->out_path;
        copy.in_path = nullptr;   // Defensive: worker uses the owned strings.
        copy.out_path = nullptr;  // (likewise).

        // Hold the worker in a named entry. From the moment it is constructed
        // the thread is joinable, so EVERY path from here on -- locking the
        // mutex, joining a reaped worker, or emplacing -- must join `entry` if
        // it throws; otherwise a joinable std::thread destructs and calls
        // std::terminate. One try covers all of them.
        adm2iamf::JobEntry entry;
        entry.job = job;
        entry.worker = std::thread(adm2iamf::RunRender, job, copy,
                                   std::move(in_path), std::move(out_path));
        try {
          std::lock_guard<std::mutex> lock(adm2iamf::JobsMutex());
          // Reap finished jobs from earlier renders: join the (already
          // terminal) worker -- which blocks only briefly -- then drop the
          // entry so no stale thread outlives the table.
          for (auto it = adm2iamf::Jobs().begin();
               it != adm2iamf::Jobs().end();) {
            if (it->second.job->state.load(std::memory_order_acquire) !=
                kAdm2iamfRenderRunning) {
              if (it->second.worker.joinable()) it->second.worker.join();
              it = adm2iamf::Jobs().erase(it);
            } else {
              ++it;
            }
          }
          const int id = ++adm2iamf::NextJobId();
          // On success the move into the map leaves `entry.worker` empty; on a
          // throwing emplace the move did not complete, so the catch still owns
          // and joins it.
          adm2iamf::Jobs().emplace(id, std::move(entry));
          return id;
        } catch (...) {
          entry.job->cancel.store(true, std::memory_order_relaxed);
          if (entry.worker.joinable()) entry.worker.join();
          return -1;
        }
      },
      -1);
}

float adm2iamf_render_progress(int job) {
  return adm2iamf::GuardAbi(
      [&]() -> float {
        auto j = adm2iamf::FindJob(job);
        if (j == nullptr) return -1.0f;
        return j->progress.load(std::memory_order_relaxed);
      },
      -1.0f);
}

int adm2iamf_render_state(int job) {
  return adm2iamf::GuardAbi(
      [&]() -> int {
        auto j = adm2iamf::FindJob(job);
        if (j == nullptr) return kAdm2iamfRenderUnknownJob;
        return j->state.load(std::memory_order_acquire);
      },
      kAdm2iamfRenderUnknownJob);
}

char* adm2iamf_render_result_json(int job) {
  return adm2iamf::GuardAbi(
      [&]() -> char* {
        auto j = adm2iamf::FindJob(job);
        if (j == nullptr) return nullptr;
        if (j->state.load(std::memory_order_acquire) ==
            kAdm2iamfRenderRunning) {
          return nullptr;
        }
        return adm2iamf::DupCStr(j->result_json);
      },
      nullptr);
}

void adm2iamf_render_cancel(int job) {
  try {
    auto j = adm2iamf::FindJob(job);
    if (j != nullptr) j->cancel.store(true, std::memory_order_relaxed);
  } catch (...) {  // NOLINT(bugprone-empty-catch): never let it cross the ABI.
  }
}

void adm2iamf_shutdown(void) {
  // Cancel every job and take ownership of the table, then join outside the
  // lock (workers never take JobsMutex, so this cannot deadlock). The host must
  // stop issuing renders before calling this; see the header contract.
  std::map<int, adm2iamf::JobEntry> drained;
  try {
    std::lock_guard<std::mutex> lock(adm2iamf::JobsMutex());
    for (auto& [id, entry] : adm2iamf::Jobs()) {
      entry.job->cancel.store(true, std::memory_order_relaxed);
    }
    drained = std::move(adm2iamf::Jobs());
    adm2iamf::Jobs().clear();  // Moved-from map is unspecified; force it empty.
  } catch (...) {  // NOLINT(bugprone-empty-catch): drain whatever we moved out.
  }
  for (auto& [id, entry] : drained) {
    if (entry.worker.joinable()) entry.worker.join();
  }
}

const char* adm2iamf_version(void) { return "adm2iamf 0.1.0"; }

}  // extern "C"
