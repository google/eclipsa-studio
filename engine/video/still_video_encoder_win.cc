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

// Windows still→video encoder: Media Foundation SinkWriter encodes one
// repeated RGB32 frame to H.264 and writes the MP4 container itself
// (no gpac authoring needed on this path — the SinkWriter owns the file).

// windows.h must precede the Media Foundation headers (see the same
// ordering note in io/device_manager_wasapi.cc).
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "engine_log.h"
#include "video/still_video_encoder.h"

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")

namespace eclipsa_studio {
namespace {

using Microsoft::WRL::ComPtr;

constexpr int64_t kTicksPerSecond = 10'000'000;  // MF 100-ns units

void LogEnc(EclipsaStudioLogLevel level, const char* msg, long hr) {
  char buf[256];
  snprintf(buf, sizeof(buf), "still encode: %s (hr=0x%08lx)", msg, hr);
  engine_log(level, "video", buf);
}

std::wstring Widen(const char* utf8) {
  const int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  // len counts the terminator; the string is sized without it and
  // MultiByteToWideChar writes the terminator into wide.data()[len-1],
  // which std::wstring guarantees is valid writable storage. A
  // conversion failure yields an empty string, rejected below.
  std::wstring wide(len > 0 ? len - 1 : 0, L'\0');
  if (len > 1) {
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide.data(), len);
  }
  return wide;
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

  const std::wstring wide_path = Widen(output_mp4);
  if (wide_path.empty()) {
    LogEnc(ECLIPSA_STUDIO_LOG_ERROR, "invalid output path", 0);
    return -4;
  }

  // COM init: tolerate an already-initialized caller thread.
  const HRESULT co_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool co_owned = SUCCEEDED(co_hr);
  if (FAILED(co_hr) && co_hr != RPC_E_CHANGED_MODE) {
    LogEnc(ECLIPSA_STUDIO_LOG_ERROR, "CoInitializeEx failed", co_hr);
    return -2;
  }
  HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(hr)) {
    LogEnc(ECLIPSA_STUDIO_LOG_ERROR, "MFStartup failed", hr);
    if (co_owned) CoUninitialize();
    return -2;
  }

  int32_t result = 0;
  {
    ComPtr<IMFSinkWriter> writer;
    ComPtr<IMFMediaType> out_type;
    ComPtr<IMFMediaType> in_type;
    DWORD stream = 0;

    const int64_t bitrate = std::clamp<int64_t>(
        static_cast<int64_t>(width) * height * 2, 2'000'000, 20'000'000);
    const size_t frame_bytes = static_cast<size_t>(width) * height * 4;

    // Force the MP4 container regardless of the output extension (the
    // export pipeline writes scratch names like *.still_video.mp4, but
    // don't rely on it).
    ComPtr<IMFAttributes> attrs;
    hr = MFCreateAttributes(&attrs, 1);
    if (SUCCEEDED(hr)) {
      hr = attrs->SetGUID(MF_TRANSCODE_CONTAINERTYPE,
                          MFTranscodeContainerType_MPEG4);
    }
    if (SUCCEEDED(hr)) {
      hr = MFCreateSinkWriterFromURL(wide_path.c_str(), nullptr, attrs.Get(),
                                     &writer);
    }
    if (FAILED(hr)) {
      // Sink creation is where an unwritable path surfaces — report it
      // as the MP4-write error the header documents, matching macOS.
      LogEnc(ECLIPSA_STUDIO_LOG_ERROR, "sink writer creation failed", hr);
      result = -4;
    }

    if (result == 0) {
      hr = MFCreateMediaType(&out_type);
      if (SUCCEEDED(hr)) {
        hr = out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      }
      if (SUCCEEDED(hr)) {
        hr = out_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
      }
      if (SUCCEEDED(hr)) {
        hr = out_type->SetUINT32(MF_MT_AVG_BITRATE,
                                 static_cast<UINT32>(bitrate));
      }
      if (SUCCEEDED(hr)) {
        hr = out_type->SetUINT32(MF_MT_INTERLACE_MODE,
                                 MFVideoInterlace_Progressive);
      }
      if (SUCCEEDED(hr)) {
        hr =
            MFSetAttributeSize(out_type.Get(), MF_MT_FRAME_SIZE, width, height);
      }
      if (SUCCEEDED(hr)) {
        hr = MFSetAttributeRatio(out_type.Get(), MF_MT_FRAME_RATE, fps, 1);
      }
      if (SUCCEEDED(hr)) {
        hr =
            MFSetAttributeRatio(out_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
      }
      if (SUCCEEDED(hr)) hr = writer->AddStream(out_type.Get(), &stream);
      if (SUCCEEDED(hr)) hr = MFCreateMediaType(&in_type);
      if (SUCCEEDED(hr)) {
        hr = in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      }
      if (SUCCEEDED(hr)) {
        hr = in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
      }
      if (SUCCEEDED(hr)) {
        hr = in_type->SetUINT32(MF_MT_INTERLACE_MODE,
                                MFVideoInterlace_Progressive);
      }
      if (SUCCEEDED(hr)) {
        // Explicit positive stride = top-down rows, so the frame copy
        // below is a straight row-order copy instead of relying on MF's
        // implicit bottom-up default for RGB32.
        hr = in_type->SetUINT32(MF_MT_DEFAULT_STRIDE,
                                static_cast<UINT32>(width * 4));
      }
      if (SUCCEEDED(hr)) {
        hr = MFSetAttributeSize(in_type.Get(), MF_MT_FRAME_SIZE, width, height);
      }
      if (SUCCEEDED(hr)) {
        hr = MFSetAttributeRatio(in_type.Get(), MF_MT_FRAME_RATE, fps, 1);
      }
      if (SUCCEEDED(hr)) {
        hr = MFSetAttributeRatio(in_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
      }
      if (SUCCEEDED(hr)) {
        hr = writer->SetInputMediaType(stream, in_type.Get(), nullptr);
      }
      if (FAILED(hr)) {
        LogEnc(ECLIPSA_STUDIO_LOG_ERROR, "sink writer setup failed", hr);
        result = -2;
      }
    }

    // Template frame: RGB32 is BGRA little-endian; rows top-down to
    // match the explicit positive stride above.
    std::vector<BYTE> frame_template;
    if (result == 0) {
      frame_template.resize(frame_bytes);
      for (uint32_t y = 0; y < height; ++y) {
        const uint8_t* src = rgba + static_cast<size_t>(y) * width * 4;
        BYTE* row = frame_template.data() + static_cast<size_t>(y) * width * 4;
        for (uint32_t x = 0; x < width; ++x) {
          row[4 * x + 0] = src[4 * x + 2];  // B
          row[4 * x + 1] = src[4 * x + 1];  // G
          row[4 * x + 2] = src[4 * x + 0];  // R
          row[4 * x + 3] = 0xFF;
        }
      }
      hr = writer->BeginWriting();
      if (FAILED(hr)) {
        LogEnc(ECLIPSA_STUDIO_LOG_ERROR, "BeginWriting failed", hr);
        result = -2;
      }
    }
    if (result == 0) {
      const int64_t frame_ticks = kTicksPerSecond / fps;
      for (int64_t i = 0; i < num_frames; ++i) {
        // Fresh buffer per sample: the SinkWriter pipeline is
        // asynchronous, so a shared buffer could be locked by the
        // encoder MFT while we fill the next frame.
        ComPtr<IMFMediaBuffer> buffer;
        ComPtr<IMFSample> sample;
        BYTE* dst = nullptr;
        hr = MFCreateMemoryBuffer(static_cast<DWORD>(frame_bytes), &buffer);
        if (SUCCEEDED(hr)) hr = buffer->Lock(&dst, nullptr, nullptr);
        if (SUCCEEDED(hr)) {
          memcpy(dst, frame_template.data(), frame_bytes);
          buffer->Unlock();
          hr = buffer->SetCurrentLength(static_cast<DWORD>(frame_bytes));
        }
        if (SUCCEEDED(hr)) hr = MFCreateSample(&sample);
        if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer.Get());
        if (SUCCEEDED(hr)) hr = sample->SetSampleTime(i * frame_ticks);
        if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(frame_ticks);
        if (SUCCEEDED(hr)) hr = writer->WriteSample(stream, sample.Get());
        if (FAILED(hr)) {
          LogEnc(ECLIPSA_STUDIO_LOG_ERROR, "WriteSample failed", hr);
          result = -3;
          break;
        }
      }
    }
    if (result == 0) {
      hr = writer->Finalize();
      if (FAILED(hr)) {
        LogEnc(ECLIPSA_STUDIO_LOG_ERROR, "Finalize failed", hr);
        result = -4;
      }
    }
  }

  MFShutdown();
  if (co_owned) CoUninitialize();
  if (result != 0) {
    // Same contract as macOS / IamfMuxer::Mux: a failed encode must not
    // leave a partial file behind.
    DeleteFileW(wide_path.c_str());
  } else {
    char buf[256];
    snprintf(buf, sizeof(buf), "still encode: %ux%u @%u fps, %lld frames -> %s",
             width, height, fps, static_cast<long long>(num_frames),
             output_mp4);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "video", buf);
  }
  return result;
}

}  // namespace eclipsa_studio
