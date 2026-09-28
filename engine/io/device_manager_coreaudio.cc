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

// Native CoreAudio HAL backend for DeviceManager (macOS). Implements
// enumerate(), start(), stop() and query_hardware_sample_rate();
// backend-independent logic lives in device_manager_common.cc.
//
// Why not miniaudio here: its CoreAudio backend is built on AUHAL,
// which binds a single stream, so multi-stream interfaces (MOTU
// MicroBook II: 8 outs as four stereo streams) degenerate to their
// primary stereo pair (ES-334). A raw HAL IOProc receives one buffer per
// output stream, making every physical output addressable. It also
// lets us query the device's nominal sample rate without reaching into
// backend internals: the engine adopts whatever rate the device runs
// at — the device clock is never touched, so opening our stream can't
// interrupt other apps sharing the device (ES-518).

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "engine_log.h"
#include "io/device_manager.h"
#include "io/device_manager_internal.h"
#include "io/stream_layout.h"

namespace {

// Upper bound on output streams per device; devices beyond this are
// rejected at open so the IOProc can use a fixed-size stack array.
constexpr size_t kMaxStreams = 64;

// Rates offered inside a continuous kAudioDevicePropertyAvailable-
// NominalSampleRates range (plus the range endpoints themselves).
constexpr uint32_t kStandardRates[] = {8000,   11025,  16000,  22050, 24000,
                                       32000,  44100,  48000,  88200, 96000,
                                       176400, 192000, 352800, 384000};

}  // namespace

// Backend-private state. The IOProc reads only this struct (via its
// client pointer), never DeviceManager itself — all fields it touches
// are written in start() before AudioDeviceStart(), which acts as the
// happens-before barrier (same contract as cb_ / cb_user_ in
// device_manager.h).
struct DeviceManagerImpl {
  AudioObjectID device = kAudioObjectUnknown;  // open device
  AudioDeviceIOProcID io_proc = nullptr;
  stream_layout::StreamLayout layout;
  // Interleaved render target handed to the engine callback, scattered
  // into the per-stream IOProc buffers. Allocated at open — nothing
  // allocates on the audio thread.
  std::vector<float> scratch;
  uint32_t scratch_frames = 0;
  uint32_t channels = 0;  // layout.total
  DeviceManager::DataCallback cb = nullptr;
  void* cb_user = nullptr;
  bool warned_frames = false;  // one-shot IOProc frame-mismatch warning
  bool overload_listener_installed = false;
  // Enumerated device IDs, indexed in lockstep with device_list().
  std::vector<AudioObjectID> ids;
};

namespace {

// HAL notifications default to run-loop delivery, and engine calls
// arrive on Flutter's UI/FFI thread, which never pumps one — without
// this, re-enumeration keeps returning the snapshot taken at HAL init.
// Detaching moves HAL notifications onto CoreAudio's own internal
// thread.
void ConfigureHalRunLoopOnce() {
  static bool done = false;
  if (done) return;
  done = true;
  CFRunLoopRef null_run_loop = nullptr;
  AudioObjectPropertyAddress addr = {
      kAudioHardwarePropertyRunLoop,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  const OSStatus status =
      AudioObjectSetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr,
                                 sizeof(CFRunLoopRef), &null_run_loop);
  if (status != noErr) {
    char buf[96];
    snprintf(buf, sizeof(buf),
             "Failed to detach CoreAudio HAL run loop (OSStatus=%d)",
             static_cast<int>(status));
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "device", buf);
  }
}

// Render an OSStatus as its four-character code when printable
// (CoreAudio errors like '!dat'), else as a decimal number.
std::string OsStatusDesc(OSStatus status) {
  const uint32_t u = static_cast<uint32_t>(status);
  char c[4] = {static_cast<char>(u >> 24), static_cast<char>(u >> 16),
               static_cast<char>(u >> 8), static_cast<char>(u)};
  bool printable = true;
  for (char ch : c) {
    if (ch < 0x20 || ch > 0x7e) printable = false;
  }
  if (printable) {
    return std::string("'") + c[0] + c[1] + c[2] + c[3] + "'";
  }
  return std::to_string(status);
}

std::string FormatCaError(const char* phase, OSStatus status,
                          const std::string& dev_name) {
  return device_backend::FormatDeviceError(
      phase, status, OsStatusDesc(status).c_str(), dev_name);
}

bool GetPropertySize(AudioObjectID obj, const AudioObjectPropertyAddress& addr,
                     UInt32* size) {
  return AudioObjectGetPropertyDataSize(obj, &addr, 0, nullptr, size) == noErr;
}

bool GetProperty(AudioObjectID obj, const AudioObjectPropertyAddress& addr,
                 UInt32 size, void* out) {
  return AudioObjectGetPropertyData(obj, &addr, 0, nullptr, &size, out) ==
         noErr;
}

// Read a CFString property as UTF-8; empty when absent or unreadable.
std::string CopyStringProperty(AudioObjectID obj,
                               const AudioObjectPropertyAddress& addr) {
  CFStringRef name = nullptr;
  if (!GetProperty(obj, addr, sizeof(name), &name) || name == nullptr) {
    return {};
  }
  char buf[256] = {0};
  std::string result;
  if (CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8)) {
    result = buf;
  }
  CFRelease(name);
  return result;
}

std::string DeviceName(AudioObjectID dev) {
  return CopyStringProperty(dev, {
                                     kAudioDevicePropertyDeviceNameCFString,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain,
                                 });
}

// Human-readable names for the device's output channels, in device
// channel order (ES-349). Per channel the ladder is: the channel's
// ElementName, then ChannelNameCFString, then the owning stream's name
// plus the 1-based position within it, then empty. Names that merely
// repeat the device name (a common HAL filler) are treated as absent —
// an empty result must render exactly like an unlabeled channel.
std::vector<std::string> OutputChannelNames(
    AudioObjectID dev, const std::vector<AudioStreamID>& streams,
    const stream_layout::StreamLayout& layout, const std::string& dev_name) {
  std::vector<std::string> names(layout.total);
  for (size_t s = 0; s < layout.counts.size() && s < streams.size(); ++s) {
    const std::string stream_name =
        CopyStringProperty(streams[s], {
                                           kAudioObjectPropertyName,
                                           kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain,
                                       });
    for (uint32_t c = 0; c < layout.counts[s]; ++c) {
      const uint32_t ch = layout.offsets[s] + c;  // 0-based device channel
      // Output-scope element addresses are 1-based device channels
      // (element 0 is the main/master element).
      const UInt32 element = ch + 1;
      std::string name =
          CopyStringProperty(dev, {kAudioObjectPropertyElementName,
                                   kAudioObjectPropertyScopeOutput, element});
      if (name.empty() || name == dev_name) {
        name =
            CopyStringProperty(dev, {kAudioDevicePropertyChannelNameCFString,
                                     kAudioObjectPropertyScopeOutput, element});
      }
      if ((name.empty() || name == dev_name) && !stream_name.empty() &&
          stream_name != dev_name) {
        name = stream_name + " " + std::to_string(c + 1);
      }
      if (name == dev_name) name.clear();
      names[ch] = std::move(name);
    }
  }
  return names;
}

// Per-stream output channel counts from the device's stream
// configuration; empty when the device has no output channels.
std::vector<uint32_t> OutputStreamChannelCounts(AudioObjectID dev) {
  AudioObjectPropertyAddress addr = {
      kAudioDevicePropertyStreamConfiguration,
      kAudioObjectPropertyScopeOutput,
      kAudioObjectPropertyElementMain,
  };
  UInt32 size = 0;
  if (!GetPropertySize(dev, addr, &size) || size == 0) return {};
  std::vector<uint8_t> storage(size);
  auto* abl = reinterpret_cast<AudioBufferList*>(storage.data());
  if (!GetProperty(dev, addr, size, abl)) return {};
  std::vector<uint32_t> counts;
  counts.reserve(abl->mNumberBuffers);
  for (UInt32 b = 0; b < abl->mNumberBuffers; ++b) {
    counts.push_back(abl->mBuffers[b].mNumberChannels);
  }
  return counts;
}

std::vector<uint32_t> SupportedSampleRates(AudioObjectID dev) {
  AudioObjectPropertyAddress addr = {
      kAudioDevicePropertyAvailableNominalSampleRates,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  UInt32 size = 0;
  if (!GetPropertySize(dev, addr, &size) || size == 0) return {};
  std::vector<AudioValueRange> ranges(size / sizeof(AudioValueRange));
  if (!GetProperty(dev, addr, size, ranges.data())) return {};
  std::vector<uint32_t> rates;
  auto add = [&rates](uint32_t r) {
    if (r > 0 && std::find(rates.begin(), rates.end(), r) == rates.end()) {
      rates.push_back(r);
    }
  };
  for (const auto& range : ranges) {
    add(static_cast<uint32_t>(range.mMinimum + 0.5));
    add(static_cast<uint32_t>(range.mMaximum + 0.5));
    for (uint32_t r : kStandardRates) {
      if (r >= range.mMinimum - 0.5 && r <= range.mMaximum + 0.5) add(r);
    }
  }
  std::sort(rates.begin(), rates.end());
  return rates;
}

double GetNominalRate(AudioObjectID dev) {
  AudioObjectPropertyAddress addr = {
      kAudioDevicePropertyNominalSampleRate,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  Float64 rate = 0.0;
  if (!GetProperty(dev, addr, sizeof(rate), &rate)) return 0.0;
  return rate;
}

bool IsHidden(AudioObjectID dev) {
  AudioObjectPropertyAddress addr = {
      kAudioDevicePropertyIsHidden,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  UInt32 hidden = 0;
  return GetProperty(dev, addr, sizeof(hidden), &hidden) && hidden != 0;
}

OSStatus OverloadListener(AudioObjectID /*obj*/, UInt32 /*num_addresses*/,
                          const AudioObjectPropertyAddress* /*addresses*/,
                          void* /*client*/) {
  engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "device",
                "CoreAudio processor overload (output underrun)");
  return noErr;
}

constexpr AudioObjectPropertyAddress kOverloadAddr = {
    kAudioDeviceProcessorOverload,
    kAudioObjectPropertyScopeOutput,
    kAudioObjectPropertyElementMain,
};

// Real-time output callback. Runs on the HAL's I/O thread; must not
// allocate, lock, or touch DeviceManager (see DeviceManagerImpl).
OSStatus IoProc(AudioObjectID /*device*/, const AudioTimeStamp* /*now*/,
                const AudioBufferList* /*input*/,
                const AudioTimeStamp* /*input_time*/, AudioBufferList* output,
                const AudioTimeStamp* /*output_time*/, void* client) {
  auto* impl = static_cast<DeviceManagerImpl*>(client);
  if (impl == nullptr || output == nullptr || output->mNumberBuffers == 0) {
    return noErr;
  }

  // Zero everything up front so every early-out (and any stream beyond
  // the captured layout) emits silence rather than stale data.
  for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
    if (output->mBuffers[b].mData != nullptr) {
      std::memset(output->mBuffers[b].mData, 0,
                  output->mBuffers[b].mDataByteSize);
    }
  }

  const AudioBuffer& first = output->mBuffers[0];
  if (impl->cb == nullptr || first.mNumberChannels == 0) return noErr;
  const uint32_t frames =
      first.mDataByteSize / (first.mNumberChannels * sizeof(float));
  if (frames != impl->scratch_frames) {
    // The granted kAudioDevicePropertyBufferFrameSize is the fixed
    // callback size downstream consumers (OAR) were configured for; a
    // different frame count would desync them, so emit silence and
    // flag it once.
    if (!impl->warned_frames) {
      impl->warned_frames = true;
      char buf[128];
      snprintf(buf, sizeof(buf),
               "IOProc frame count %u != configured %u; emitting silence",
               frames, impl->scratch_frames);
      engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "device", buf);
    }
    return noErr;
  }

  impl->cb(impl->scratch.data(), frames, impl->channels, impl->cb_user);

  float* dsts[kMaxStreams];
  const size_t streams =
      std::min<size_t>(impl->layout.counts.size(), output->mNumberBuffers);
  for (size_t s = 0; s < impl->layout.counts.size(); ++s) {
    dsts[s] = nullptr;
    if (s >= streams) continue;
    AudioBuffer& buf = output->mBuffers[s];
    // Leave a stream silent rather than overflow it if its buffer is
    // smaller than the layout captured at open.
    const size_t needed =
        static_cast<size_t>(frames) * impl->layout.counts[s] * sizeof(float);
    if (buf.mData != nullptr && buf.mDataByteSize >= needed) {
      dsts[s] = static_cast<float*>(buf.mData);
    }
  }
  stream_layout::ScatterToStreams(impl->scratch.data(), frames, impl->layout,
                                  dsts);
  return noErr;
}

}  // namespace

DeviceManager::DeviceManager() : impl_(std::make_unique<DeviceManagerImpl>()) {}

DeviceManager::~DeviceManager() { stop(); }

bool DeviceManager::enumerate() {
  ConfigureHalRunLoopOnce();
  devices_.clear();
  impl_->ids.clear();

  AudioObjectPropertyAddress addr = {
      kAudioHardwarePropertyDevices,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  UInt32 size = 0;
  if (!GetPropertySize(kAudioObjectSystemObject, addr, &size)) return false;
  std::vector<AudioObjectID> all(size / sizeof(AudioObjectID));
  if (!all.empty() &&
      !GetProperty(kAudioObjectSystemObject, addr, size, all.data())) {
    return false;
  }

  AudioObjectID default_out = kAudioObjectUnknown;
  AudioObjectPropertyAddress def_addr = {
      kAudioHardwarePropertyDefaultOutputDevice,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  GetProperty(kAudioObjectSystemObject, def_addr, sizeof(default_out),
              &default_out);

  for (AudioObjectID dev : all) {
    const std::vector<uint32_t> counts = OutputStreamChannelCounts(dev);
    uint32_t total = 0;
    for (uint32_t c : counts) total += c;
    if (total == 0) continue;  // input-only device
    if (IsHidden(dev)) continue;

    DeviceInfo info;
    info.name = DeviceName(dev);
    if (info.name.empty()) continue;
    info.is_default = (dev == default_out);
    info.channel_count = total;
    info.supported_channel_counts = {total};
    info.supported_sample_rates = SupportedSampleRates(dev);
    if (info.supported_sample_rates.empty()) {
      info.supported_sample_rates = {44100, 48000, 96000, 192000};
    }

    // Prefer 48000 as default; fall back to first available.
    info.default_sample_rate = 48000;
    const auto& rates = info.supported_sample_rates;
    if (std::find(rates.begin(), rates.end(), 48000u) == rates.end()) {
      info.default_sample_rate = rates[0];
    }

    devices_.push_back(std::move(info));
    impl_->ids.push_back(dev);
  }
  return true;
}

bool DeviceManager::start(uint32_t sample_rate, uint32_t buffer_frames,
                          DataCallback callback, void* user_data) {
  if (running_) return true;

  if (devices_.empty()) {
    {
      std::lock_guard<std::mutex> lock(last_error_mu_);
      last_error_ = "no output devices available";
    }
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "device",
               "no output devices available");
    return false;
  }

  // Pre-resolve "system default" to a concrete enumerated index so the
  // open path always addresses an explicit device.
  selected_index_ = ResolveSelectedIndex(devices_, selected_index_);

  {
    char buf[192];
    const char* name = (selected_index_ < devices_.size())
                           ? devices_[selected_index_].name.c_str()
                           : "<none>";
    snprintf(buf, sizeof(buf),
             "Opening device: index=%u (%s), req_rate=%u (ignored), "
             "bufFrames=%u",
             selected_index_, name, sample_rate, buffer_frames);
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "device", buf);
  }

  const std::string dev_name = (selected_index_ < devices_.size())
                                   ? devices_[selected_index_].name
                                   : std::string("system default");
  auto fail = [this, &dev_name](const char* phase, OSStatus status) {
    const std::string msg = FormatCaError(phase, status, dev_name);
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "device", msg.c_str());
    std::lock_guard<std::mutex> lock(last_error_mu_);
    last_error_ = msg;
    return false;
  };

  if (selected_index_ >= impl_->ids.size()) {
    return fail("resolve device", kAudioHardwareBadDeviceError);
  }
  const AudioObjectID dev = impl_->ids[selected_index_];

  // Adopt the device's current nominal rate as-is — never set it.
  // Nominal rate is device-global state (the same thing Audio MIDI
  // Setup changes); forcing it interrupts other apps sharing the
  // device (ES-518). The engine converges on the rate we report
  // (AdoptHardwareSampleRate in engine.cc). This early read is a
  // validity check; the rate committed to current_sample_rate_ is
  // re-read just before the commit, after the HAL setup below.
  const double nominal = GetNominalRate(dev);
  if (nominal <= 0.0) {
    return fail("query nominal sample rate", kAudioHardwareUnspecifiedError);
  }

  // Request the buffer size, then adopt whatever the device granted —
  // the granted value is the fixed IOProc callback size downstream
  // consumers (OAR) must be configured for.
  AudioObjectPropertyAddress buf_addr = {
      kAudioDevicePropertyBufferFrameSize,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  UInt32 frames = buffer_frames;
  if (AudioObjectSetPropertyData(dev, &buf_addr, 0, nullptr, sizeof(frames),
                                 &frames) != noErr) {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "Could not request buffer size %u; using device's current",
             buffer_frames);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "device", buf);
  }
  UInt32 granted = 0;
  if (!GetProperty(dev, buf_addr, sizeof(granted), &granted) || granted == 0) {
    return fail("read buffer frame size", kAudioHardwareUnspecifiedError);
  }

  // Capture the output stream layout and make sure every stream's
  // virtual format (the client-side format our floats land in) is
  // Float32. The HAL default is Float32 at the nominal rate, so the
  // set path is a rarely-taken repair.
  AudioObjectPropertyAddress streams_addr = {
      kAudioDevicePropertyStreams,
      kAudioObjectPropertyScopeOutput,
      kAudioObjectPropertyElementMain,
  };
  UInt32 streams_size = 0;
  if (!GetPropertySize(dev, streams_addr, &streams_size) || streams_size == 0) {
    return fail("query output streams", kAudioHardwareBadDeviceError);
  }
  std::vector<AudioStreamID> streams(streams_size / sizeof(AudioStreamID));
  if (!GetProperty(dev, streams_addr, streams_size, streams.data())) {
    return fail("query output streams", kAudioHardwareBadDeviceError);
  }
  if (streams.size() > kMaxStreams) {
    return fail("stream count exceeds supported maximum",
                kAudioHardwareBadDeviceError);
  }

  std::vector<uint32_t> counts;
  counts.reserve(streams.size());
  for (AudioStreamID stream : streams) {
    AudioObjectPropertyAddress fmt_addr = {
        kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioStreamBasicDescription fmt = {};
    if (!GetProperty(stream, fmt_addr, sizeof(fmt), &fmt)) {
      return fail("query stream virtual format", kAudioHardwareBadObjectError);
    }
    const bool is_f32 = fmt.mFormatID == kAudioFormatLinearPCM &&
                        (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
                        fmt.mBitsPerChannel == 32;
    if (!is_f32) {
      AudioStreamBasicDescription want = fmt;
      want.mFormatID = kAudioFormatLinearPCM;
      want.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
      want.mBitsPerChannel = 32;
      want.mBytesPerFrame = 4 * want.mChannelsPerFrame;
      want.mBytesPerPacket = want.mBytesPerFrame;
      want.mFramesPerPacket = 1;
      const OSStatus st = AudioObjectSetPropertyData(
          stream, &fmt_addr, 0, nullptr, sizeof(want), &want);
      if (st != noErr) {
        return fail("set stream virtual format to Float32", st);
      }
      fmt = want;
    }
    counts.push_back(fmt.mChannelsPerFrame);
  }

  impl_->layout = stream_layout::MakeStreamLayout(counts);
  if (impl_->layout.total == 0) {
    return fail("device reports zero output channels",
                kAudioHardwareBadDeviceError);
  }
  if (impl_->layout.total != devices_[selected_index_].channel_count) {
    char buf[160];
    snprintf(buf, sizeof(buf),
             "Stream layout total %u differs from enumerated %u; using %u",
             impl_->layout.total, devices_[selected_index_].channel_count,
             impl_->layout.total);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "device", buf);
  }

  // Only readable via output_channel_name() once running_ flips, so a
  // failure below never exposes names for a device that didn't open.
  channel_names_ = OutputChannelNames(dev, streams, impl_->layout, dev_name);
  {
    // Breadcrumb for checking what the HAL reported on real hardware
    // (ES-349); '-' marks channels the device left unlabeled.
    std::string joined;
    for (const auto& n : channel_names_) {
      if (!joined.empty()) joined += ", ";
      joined += n.empty() ? "-" : n;
    }
    char buf[512];
    snprintf(buf, sizeof(buf), "Output channel names: [%s]", joined.c_str());
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "device", buf);
  }

  cb_ = callback;
  cb_user_ = user_data;
  impl_->scratch.assign(static_cast<size_t>(impl_->layout.total) * granted,
                        0.0f);
  impl_->scratch_frames = granted;
  impl_->channels = impl_->layout.total;
  impl_->cb = cb_;
  impl_->cb_user = cb_user_;
  impl_->warned_frames = false;

  OSStatus st =
      AudioDeviceCreateIOProcID(dev, IoProc, impl_.get(), &impl_->io_proc);
  if (st != noErr || impl_->io_proc == nullptr) {
    return fail("AudioDeviceCreateIOProcID", st);
  }
  st = AudioDeviceStart(dev, impl_->io_proc);
  if (st != noErr) {
    AudioDeviceDestroyIOProcID(dev, impl_->io_proc);
    impl_->io_proc = nullptr;
    return fail("AudioDeviceStart", st);
  }
  impl_->device = dev;

  impl_->overload_listener_installed =
      AudioObjectAddPropertyListener(dev, &kOverloadAddr, OverloadListener,
                                     impl_.get()) == noErr;

  open_channels_ = impl_->channels;
  // Re-read the nominal rate now that the stream is running: another
  // client can move the device clock during the HAL setup between the
  // early snapshot and here, and nothing pins it any more (ES-518).
  // Committing a stale rate would leave the engine converged on the
  // wrong clock until the 1 Hz hardware-rate poll heals it. Fall back
  // to the early snapshot if the re-read fails.
  const double live_rate = GetNominalRate(dev);
  current_sample_rate_ =
      static_cast<uint32_t>((live_rate > 0.0 ? live_rate : nominal) + 0.5);
  hardware_sample_rate_ = current_sample_rate_;
  current_buffer_size_ = granted;

  {
    char buf[128];
    snprintf(buf, sizeof(buf), "Device opened: actualChannels=%u (%zu streams)",
             impl_->channels, impl_->layout.counts.size());
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "device", buf);
  }
  {
    char buf[192];
    snprintf(buf, sizeof(buf),
             "Device buffer: requested=%u callback=%u hw_period=%u "
             "rate=%u hw_rate=%u channels=%u",
             buffer_frames, current_buffer_size_, granted, current_sample_rate_,
             hardware_sample_rate_, impl_->channels);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "device", buf);
  }
  // Co-locate the success-state writes so the contract is obvious:
  // last_error_ is empty iff running_ is true at function exit.
  {
    std::lock_guard<std::mutex> lock(last_error_mu_);
    last_error_.clear();
  }
  running_ = true;
  return true;
}

uint32_t DeviceManager::query_hardware_sample_rate() const {
  if (!running_ || impl_->device == kAudioObjectUnknown) return 0;
  // Live query — hardware_sample_rate_ is a snapshot from open time,
  // but the user can change the device's nominal rate in Audio MIDI
  // Setup at any moment. Control-thread only (same thread that calls
  // start()/stop(), so the device can't be torn down underneath).
  const double rate = GetNominalRate(impl_->device);
  if (rate <= 0.0) return 0;
  return static_cast<uint32_t>(rate + 0.5);
}

void DeviceManager::stop() {
  if (!running_) return;
  if (impl_->device != kAudioObjectUnknown && impl_->io_proc != nullptr) {
    if (impl_->overload_listener_installed) {
      AudioObjectRemovePropertyListener(impl_->device, &kOverloadAddr,
                                        OverloadListener, impl_.get());
      impl_->overload_listener_installed = false;
    }
    AudioDeviceStop(impl_->device, impl_->io_proc);
    AudioDeviceDestroyIOProcID(impl_->device, impl_->io_proc);
  }
  impl_->io_proc = nullptr;
  impl_->device = kAudioObjectUnknown;
  open_channels_ = 0;
  running_ = false;
}
