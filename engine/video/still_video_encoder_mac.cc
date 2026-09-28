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

// macOS still→video encoder: VideoToolbox (C API) H.264 encode of one
// repeated frame, written as a video-only MP4 via libgpac's ISO-media
// authoring API (the same library the IAMF mux already links).

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

// gpac last: its headers poison strcpy/strcat with #error macros, which
// breaks any standard header included after them.
#include <gpac/isomedia.h>
#include <gpac/list.h>
#include <gpac/mpeg4_odf.h>
#include <gpac/tools.h>

#include "engine_log.h"
#include "iamf/gpac_system.h"
#include "video/still_video_encoder.h"

namespace eclipsa_studio {
namespace {

__attribute__((format(printf, 2, 3))) void LogEnc(EclipsaStudioLogLevel level,
                                                  const char* fmt, ...) {
  char buf[256];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  engine_log(level, "video", buf);
}

struct EncodedSample {
  std::vector<uint8_t> avcc;  // length-prefixed NAL units (ISOBMFF layout)
  int64_t pts = 0;            // in track-timescale (= fps) units
  bool keyframe = false;
};

// Shared with the VT output callback, which runs on VideoToolbox's own
// thread — everything mutable is guarded by `mu`, including the final
// read-back after the VTCompressionSessionCompleteFrames barrier (the
// barrier orders the work but the lock is what publishes it to TSan
// and the memory model).
struct EncodeContext {
  std::mutex mu;
  std::vector<EncodedSample> samples;
  std::vector<uint8_t> sps;
  std::vector<uint8_t> pps;
  int nal_length_size = 4;
  int32_t fps = 1;  // set before encoding starts; read-only afterwards
  OSStatus first_error = noErr;
};

void OnEncodedFrame(void* refcon, void* /*source*/, OSStatus status,
                    VTEncodeInfoFlags /*flags*/, CMSampleBufferRef sample) {
  auto* ctx = static_cast<EncodeContext*>(refcon);
  std::lock_guard<std::mutex> lk(ctx->mu);
  if (status != noErr) {
    if (ctx->first_error == noErr) ctx->first_error = status;
    return;
  }
  if (sample == nullptr || !CMSampleBufferDataIsReady(sample)) return;

  // SPS/PPS ride on the format description of the first (key)frame.
  if (ctx->sps.empty()) {
    CMFormatDescriptionRef desc = CMSampleBufferGetFormatDescription(sample);
    if (desc != nullptr) {
      const uint8_t* set = nullptr;
      size_t set_size = 0, count = 0;
      int nal_len = 0;
      if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
              desc, 0, &set, &set_size, &count, &nal_len) == noErr) {
        ctx->sps.assign(set, set + set_size);
        // The avcC length-prefix size must match the sample payloads;
        // VT reports it here (4 in practice, but honor what it says).
        if (nal_len >= 1 && nal_len <= 4) ctx->nal_length_size = nal_len;
      }
      if (count > 1 &&
          CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
              desc, 1, &set, &set_size, nullptr, nullptr) == noErr) {
        ctx->pps.assign(set, set + set_size);
      }
    }
  }

  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
  if (block == nullptr) return;
  const size_t len = CMBlockBufferGetDataLength(block);
  EncodedSample out;
  out.avcc.resize(len);
  if (CMBlockBufferCopyDataBytes(block, 0, len, out.avcc.data()) != noErr) {
    if (ctx->first_error == noErr) ctx->first_error = kVTParameterErr;
    return;
  }
  // Normalize to the track timescale (== fps) rather than assuming VT
  // preserved the timescale it was handed.
  const CMTime pts =
      CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),
                         ctx->fps, kCMTimeRoundingMethod_Default);
  out.pts = pts.value;

  // A sample is sync unless kCMSampleAttachmentKey_NotSync says otherwise.
  out.keyframe = true;
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
    auto dict =
        static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
    CFBooleanRef not_sync = nullptr;
    if (CFDictionaryGetValueIfPresent(
            dict, kCMSampleAttachmentKey_NotSync,
            reinterpret_cast<const void**>(&not_sync)) &&
        CFBooleanGetValue(not_sync)) {
      out.keyframe = false;
    }
  }
  ctx->samples.push_back(std::move(out));
}

// Write the encoded samples as the sole track of a fresh MP4. Track
// timescale = fps, so every sample has duration 1 and DTS = frame index.
// On failure the partially written file is deleted — same contract as
// IamfMuxer::Mux (a failed export must not leave a file behind).
bool WriteMp4(const char* path, const std::vector<EncodedSample>& samples,
              const std::vector<uint8_t>& sps, const std::vector<uint8_t>& pps,
              int nal_length_size, uint32_t width, uint32_t height,
              uint32_t fps) {
  GF_ISOFile* file = gf_isom_open(path, GF_ISOM_OPEN_WRITE, nullptr);
  if (file == nullptr) {
    LogEnc(ECLIPSA_STUDIO_LOG_ERROR, "still encode: cannot create %s", path);
    return false;
  }
  bool ok = false;
  GF_AVCConfig* cfg = nullptr;
  do {
    const u32 track = gf_isom_new_track(file, 0, GF_ISOM_MEDIA_VISUAL, fps);
    if (track == 0) break;
    if (gf_isom_set_track_enabled(file, track, GF_TRUE) != GF_OK) break;

    cfg = gf_odf_avc_cfg_new();
    if (cfg == nullptr) break;
    cfg->configurationVersion = 1;
    cfg->AVCProfileIndication = sps.size() > 1 ? sps[1] : 0x64;
    cfg->profile_compatibility = sps.size() > 2 ? sps[2] : 0;
    cfg->AVCLevelIndication = sps.size() > 3 ? sps[3] : 0x28;
    cfg->nal_unit_size = static_cast<u8>(nal_length_size);
    // Parameter sets are bounded by the H.264 spec to well under 64 KiB,
    // so the u16 size field cannot truncate; still guard the allocs.
    auto add_param = [](const std::vector<uint8_t>& nal,
                        GF_List* list) -> bool {
      if (nal.empty() || nal.size() > UINT16_MAX) return false;
      auto* slot =
          static_cast<GF_NALUFFParam*>(gf_malloc(sizeof(GF_NALUFFParam)));
      if (slot == nullptr) return false;
      memset(slot, 0, sizeof(*slot));
      slot->size = static_cast<u16>(nal.size());
      slot->data = static_cast<u8*>(gf_malloc(nal.size()));
      if (slot->data == nullptr) {
        gf_free(slot);
        return false;
      }
      memcpy(slot->data, nal.data(), nal.size());
      return gf_list_add(list, slot) == GF_OK;
    };
    if (!add_param(sps, cfg->sequenceParameterSets)) break;
    if (!add_param(pps, cfg->pictureParameterSets)) break;

    u32 desc_index = 0;
    if (gf_isom_avc_config_new(file, track, cfg, nullptr, nullptr,
                               &desc_index) != GF_OK) {
      break;
    }
    if (gf_isom_set_visual_info(file, track, desc_index, width, height) !=
        GF_OK) {
      break;
    }
    // Tag BT.709 limited range (colr/nclx) — matching the VT session's
    // color properties — so sub-720p downscaled stills are not decoded
    // with the BT.601 matrix many players assume when untagged.
    if (gf_isom_set_visual_color_info(file, track, desc_index,
                                      GF_4CC('n', 'c', 'l', 'x'), 1, 1, 1,
                                      GF_FALSE, nullptr, 0) != GF_OK) {
      break;
    }

    bool sample_failed = false;
    for (const EncodedSample& s : samples) {
      GF_ISOSample sample = {};
      sample.data = reinterpret_cast<u8*>(const_cast<uint8_t*>(s.avcc.data()));
      sample.dataLength = static_cast<u32>(s.avcc.size());
      sample.DTS = static_cast<u64>(s.pts);
      sample.CTS_Offset = 0;  // no B-frames (AllowFrameReordering=false)
      sample.IsRAP = s.keyframe ? RAP : RAP_NO;
      if (gf_isom_add_sample(file, track, desc_index, &sample) != GF_OK) {
        sample_failed = true;
        break;
      }
    }
    if (sample_failed) break;
    if (gf_isom_set_last_sample_duration(file, track, 1) != GF_OK) break;
    ok = true;
  } while (false);

  if (cfg != nullptr) gf_odf_avc_cfg_del(cfg);
  if (ok) {
    const GF_Err close_err = gf_isom_close(file);  // writes moov
    if (close_err != GF_OK) {
      LogEnc(ECLIPSA_STUDIO_LOG_ERROR, "still encode: mp4 close failed: %s",
             gf_error_to_string(close_err));
      ok = false;
      std::remove(path);
    }
  } else {
    // Abort without finalizing, then unlink whatever partial data the
    // open/write left on disk.
    gf_isom_delete(file);
    std::remove(path);
  }
  return ok;
}

}  // namespace

int32_t StillVideoEncode(const uint8_t* rgba, uint64_t rgba_size,
                         uint32_t width, uint32_t height, uint32_t fps,
                         double duration_seconds, const char* output_mp4) {
  if (!StillVideoArgsValid(rgba, rgba_size, width, height, fps,
                           duration_seconds, output_mp4)) {
    return -1;
  }
  // Round UP so the video never ends before the audio.
  const int64_t num_frames = std::max<int64_t>(
      1, static_cast<int64_t>(std::ceil(duration_seconds * fps)));

  // One BGRA pixel buffer, reused for every frame (the encoder copies /
  // retains what it needs per submission).
  CVPixelBufferRef pixbuf = nullptr;
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                          kCVPixelFormatType_32BGRA, nullptr,
                          &pixbuf) != kCVReturnSuccess) {
    return -2;
  }
  if (CVPixelBufferLockBaseAddress(pixbuf, 0) != kCVReturnSuccess) {
    CVPixelBufferRelease(pixbuf);
    return -2;
  }
  {
    auto* dst_base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixbuf));
    const size_t dst_stride = CVPixelBufferGetBytesPerRow(pixbuf);
    for (uint32_t y = 0; y < height; ++y) {
      const uint8_t* src = rgba + static_cast<size_t>(y) * width * 4;
      uint8_t* dst = dst_base + static_cast<size_t>(y) * dst_stride;
      for (uint32_t x = 0; x < width; ++x) {
        dst[4 * x + 0] = src[4 * x + 2];  // B
        dst[4 * x + 1] = src[4 * x + 1];  // G
        dst[4 * x + 2] = src[4 * x + 0];  // R
        dst[4 * x + 3] = src[4 * x + 3];  // A (ignored by the encoder)
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(pixbuf, 0);

  EncodeContext ctx;
  ctx.fps = static_cast<int32_t>(fps);
  VTCompressionSessionRef session = nullptr;
  OSStatus status = VTCompressionSessionCreate(
      kCFAllocatorDefault, static_cast<int32_t>(width),
      static_cast<int32_t>(height), kCMVideoCodecType_H264, nullptr, nullptr,
      nullptr, &OnEncodedFrame, &ctx, &session);
  if (status != noErr || session == nullptr) {
    LogEnc(ECLIPSA_STUDIO_LOG_ERROR,
           "still encode: VTCompressionSessionCreate failed (%d)",
           static_cast<int>(status));
    CVPixelBufferRelease(pixbuf);
    return -2;
  }

  auto set_prop = [&session](CFStringRef key, CFTypeRef value) {
    // Best-effort: a codec that rejects a hint still encodes correctly.
    if (value != nullptr) VTSessionSetProperty(session, key, value);
  };
  auto set_number = [&session, &set_prop](CFStringRef key, int64_t value) {
    CFNumberRef num = CFNumberCreate(nullptr, kCFNumberSInt64Type, &value);
    if (num != nullptr) {
      set_prop(key, num);
      CFRelease(num);
    }
  };
  set_prop(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
  set_prop(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
  set_prop(kVTCompressionPropertyKey_ProfileLevel,
           kVTProfileLevel_H264_High_AutoLevel);
  // BT.709 limited range — mirrored by the colr/nclx box in WriteMp4.
  set_prop(kVTCompressionPropertyKey_ColorPrimaries,
           kCVImageBufferColorPrimaries_ITU_R_709_2);
  set_prop(kVTCompressionPropertyKey_TransferFunction,
           kCVImageBufferTransferFunction_ITU_R_709_2);
  set_prop(kVTCompressionPropertyKey_YCbCrMatrix,
           kCVImageBufferYCbCrMatrix_ITU_R_709_2);
  // Still content: the keyframes carry all the quality; inter frames are
  // near-empty. Scale the budget with the pixel count, clamped to sane
  // bounds so tiny and huge stills both behave.
  set_number(kVTCompressionPropertyKey_AverageBitRate,
             std::clamp<int64_t>(static_cast<int64_t>(width) * height * 2,
                                 2'000'000, 20'000'000));
  set_number(kVTCompressionPropertyKey_MaxKeyFrameInterval,
             static_cast<int64_t>(fps) * 10);

  bool encode_failed = false;
  for (int64_t i = 0; i < num_frames && !encode_failed; ++i) {
    const CMTime pts = CMTimeMake(i, static_cast<int32_t>(fps));
    const CMTime dur = CMTimeMake(1, static_cast<int32_t>(fps));
    status = VTCompressionSessionEncodeFrame(session, pixbuf, pts, dur, nullptr,
                                             nullptr, nullptr);
    if (status != noErr) encode_failed = true;
  }
  // Barrier: all pending output callbacks have run once this returns.
  // Its status is part of the encode result — a failed completion means
  // frames were dropped.
  const OSStatus complete_status =
      VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
  VTCompressionSessionInvalidate(session);
  CFRelease(session);
  CVPixelBufferRelease(pixbuf);

  // Move the callback-shared state into locals under the lock: the
  // barrier above ordered the work, but the mutex is what makes the
  // hand-off valid under the memory model (and visible to TSan).
  std::vector<EncodedSample> samples;
  std::vector<uint8_t> sps;
  std::vector<uint8_t> pps;
  int nal_length_size = 4;
  OSStatus callback_error = noErr;
  {
    std::lock_guard<std::mutex> lk(ctx.mu);
    samples = std::move(ctx.samples);
    sps = std::move(ctx.sps);
    pps = std::move(ctx.pps);
    nal_length_size = ctx.nal_length_size;
    callback_error = ctx.first_error;
  }

  if (encode_failed || callback_error != noErr || complete_status != noErr) {
    LogEnc(ECLIPSA_STUDIO_LOG_ERROR,
           "still encode: encoding failed (encode=%d callback=%d "
           "complete=%d)",
           static_cast<int>(encode_failed ? status : noErr),
           static_cast<int>(callback_error), static_cast<int>(complete_status));
    return -3;
  }
  if (samples.empty() || sps.empty() || pps.empty()) {
    LogEnc(ECLIPSA_STUDIO_LOG_ERROR,
           "still encode: encoder produced no usable output "
           "(samples=%zu sps=%zu pps=%zu)",
           samples.size(), sps.size(), pps.size());
    return -3;
  }
  // Callback order is submission order in practice (no reordering), but
  // the container write requires monotonic DTS — sort as insurance.
  std::sort(samples.begin(), samples.end(),
            [](const EncodedSample& a, const EncodedSample& b) {
              return a.pts < b.pts;
            });

  // Bracket gpac per repo convention (see iamf/gpac_system.h): library
  // state must not outlive a sibling user's gf_sys_close.
  bool wrote = false;
  {
    eclipsa_studio::GpacSystem gpac;
    wrote = gpac.ok() && WriteMp4(output_mp4, samples, sps, pps,
                                  nal_length_size, width, height, fps);
  }
  if (!wrote) return -4;

  LogEnc(ECLIPSA_STUDIO_LOG_INFO,
         "still encode: %ux%u @%u fps, %lld frames -> %s", width, height, fps,
         static_cast<long long>(num_frames), output_mp4);
  return 0;
}

}  // namespace eclipsa_studio
