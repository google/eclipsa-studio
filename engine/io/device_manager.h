/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef ECLIPSA_STUDIO_IO_DEVICE_MANAGER_H_
#define ECLIPSA_STUDIO_IO_DEVICE_MANAGER_H_

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

/// Backend-private state (open device handle, native device IDs).
/// Exactly one backend translation unit is compiled per platform (see
/// the select() in io/BUILD.bazel) and provides the definition.
struct DeviceManagerImpl;

/// Output-device enumeration and lifecycle behind a backend-neutral
/// surface. The platform backend (native CoreAudio on macOS — ES-334;
/// native WASAPI on Windows — ES-355) implements enumeration and the
/// device open/close path; shared selection/bookkeeping logic lives in
/// device_manager_common.cc.
///
/// Provides a list of available output devices, allows selecting one, and
/// starts/stops the output stream.  The audio callback is set externally.
///
/// Thread-safety: all methods except the audio callback are called from the
/// control thread only.
class DeviceManager {
 public:
  struct DeviceInfo {
    std::string name;
    uint32_t channel_count = 2;  // max channels reported
    uint32_t default_sample_rate = 48000;
    bool is_default = false;
    std::vector<uint32_t> supported_sample_rates;
    std::vector<uint32_t> supported_channel_counts;
    // Backend-native device IDs live in DeviceManagerImpl, indexed in
    // lockstep with device_list().
  };

  DeviceManager();
  ~DeviceManager();

  // Non-copyable.
  DeviceManager(const DeviceManager&) = delete;
  DeviceManager& operator=(const DeviceManager&) = delete;

  /// Enumerate available output devices.  Populates device_list().
  /// Also queries per-device native formats.
  bool enumerate();

  /// Re-enumerate at runtime (hot-plug / OS default changes). Uses a
  /// transient context, so it is safe while a stream is open and never
  /// touches the open device. Enumeration indices shift when devices
  /// come and go, so the selection is remapped by device name; if the
  /// selected device disappeared, it falls back to the system default
  /// (the same posture start() applies to an out-of-range index).
  bool refresh();

  const std::vector<DeviceInfo>& device_list() const { return devices_; }
  uint32_t device_count() const {
    return static_cast<uint32_t>(devices_.size());
  }
  const std::string& device_name(uint32_t index) const;

  /// Hardware-reported name of output channel `channel` (0-based) on
  /// the OPEN device — e.g. "Phones 2" on a MOTU MicroBook II (ES-349).
  /// Empty when no device is open, the channel is out of range, or the
  /// backend reports no label (the WASAPI backend never does).
  /// Control-thread only, same as device_name().
  const std::string& output_channel_name(uint32_t channel) const;

  /// Select device by index (call before start()).
  bool select_device(uint32_t index);
  uint32_t selected_index() const { return selected_index_; }

  uint32_t channel_count() const;

  /// Sample rate the open stream is actually running at, as reported
  /// by the device at open time — NOT the rate start() was asked for,
  /// and distinct from the engine's target rate (g_sample_rate), which
  /// converges on this value via AdoptHardwareSampleRate (ES-518).
  uint32_t current_sample_rate() const { return current_sample_rate_; }

  /// The device's hardware rate as reported at open time. On CoreAudio
  /// this always equals current_sample_rate() (adopt-only); on WASAPI
  /// it can differ when the stream format the backend negotiated is
  /// not the hardware's mix rate. 0 until a device has been opened.
  uint32_t hardware_sample_rate() const { return hardware_sample_rate_; }

  /// Live query of the open device's CURRENT hardware rate (the user
  /// can change it in Audio MIDI Setup at any time). 0 when no device
  /// is open or the platform query is unavailable. Control-thread
  /// only.
  uint32_t query_hardware_sample_rate() const;

  /// Frames per data callback for the open device — the block size
  /// downstream consumers (graph, OAR) must be sized for. The backend
  /// guarantees fixed-size callbacks of exactly this many frames even
  /// when the hardware clamps its internal period to something else.
  /// 512 until a device has been opened.
  uint32_t current_buffer_size() const { return current_buffer_size_; }

  using DataCallback = void (*)(void* output, uint32_t frames,
                                uint32_t channels, void* user_data);

  /// Set the audio data callback and user-data pointer.
  /// Must be called before start(); the values are captured and not
  /// modified while the device is running.
  void set_callback(DataCallback cb, void* user) {
    cb_ = cb;
    cb_user_ = user;
  }

  /// Open and start the selected output device. `sample_rate` is a
  /// request only: the CoreAudio backend ignores it entirely and
  /// adopts the device's current nominal rate (adopt-only, ES-518); the
  /// WASAPI backend uses it as a format candidate. Read the rate in
  /// effect from current_sample_rate() afterwards.
  bool start(uint32_t sample_rate, uint32_t buffer_frames,
             DataCallback callback, void* user_data);

  /// Stop and close the device.
  void stop();

  bool is_running() const { return running_; }

  /// Last failure message from start() (empty if the last call succeeded
  /// or has not been made). Format: "<phase> FAILED: rc=<code> (<desc>)
  /// on \"<device name>\"", e.g. "AudioDeviceStart FAILED: rc=1852797029
  /// ('nope') on \"MOTU MicroBook II\"".
  ///
  /// Returned by value because callers may live on a different thread
  /// from `start()`; the mutex synchronises access to the underlying
  /// string.
  std::string last_error() const {
    std::lock_guard<std::mutex> lock(last_error_mu_);
    return last_error_;
  }

  /// Resolve `selected_index` against a list of enumerated `devices`.
  ///
  /// - If `selected_index` is in range, returns it unchanged.
  /// - Otherwise, returns the index of the first device whose
  ///   `is_default` flag is set.
  /// - If no in-range index and no default is found (including the
  ///   empty-list case), returns `UINT32_MAX` to signal "no concrete
  ///   device" — the caller should fall back to the backend's notion
  ///   of the system default.
  ///
  /// Exposed as a pure static so the selection rule is unit-testable
  /// without opening real audio hardware.
  static uint32_t ResolveSelectedIndex(const std::vector<DeviceInfo>& devices,
                                       uint32_t selected_index);

 private:
  // Audio data callback and opaque user pointer.
  // Thread-safety contract: these are set via set_callback() (or start())
  // *before* the device is started, and are only read from the audio
  // callback while the device is running.  Because the write happens-before
  // the first read (device start acts as a full barrier), no atomic is
  // needed.
  DataCallback cb_ = nullptr;
  void* cb_user_ = nullptr;

  std::vector<DeviceInfo> devices_;
  uint32_t selected_index_ =
      UINT32_MAX;  // No explicit selection → system default
  bool running_ = false;
  // Channel count of the open device; nonzero only between a successful
  // start() and stop(). Written by the backend, read by channel_count().
  uint32_t open_channels_ = 0;
  // Hardware channel names for the open device, indexed by 0-based
  // device channel. Populated by the backend in start() (CoreAudio
  // only); output_channel_name() ignores it while !running_, so stale
  // entries from a previous open are never visible.
  std::vector<std::string> channel_names_;
  std::string last_error_;
  // Synchronises read/write of last_error_ across the engine control
  // thread (start() / reconfigure) and the Dart UI thread (via the
  // FFI accessor).
  mutable std::mutex last_error_mu_;
  uint32_t current_sample_rate_ = 48000;
  uint32_t hardware_sample_rate_ = 0;
  uint32_t current_buffer_size_ = 512;

  // Heap-allocated backend state.  Using an opaque struct keeps backend
  // types (e.g. the large ma_device definition) out of headers that
  // include this file.
  std::unique_ptr<DeviceManagerImpl> impl_;
};

#endif  // ECLIPSA_STUDIO_IO_DEVICE_MANAGER_H_
