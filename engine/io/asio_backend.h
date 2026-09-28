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

#ifndef ECLIPSA_STUDIO_IO_ASIO_BACKEND_H_
#define ECLIPSA_STUDIO_IO_ASIO_BACKEND_H_

#include <cstdint>
#include <string>
#include <vector>

/// Windows-only ASIO output backend (GitHub ES-101 step 3).
///
/// Wraps the Steinberg ASIO SDK host interface (@asio//:asio)
/// behind the same enumerate / start / stop shape as the WASAPI
/// backend. No ASIO SDK types appear in this header; the Windows
/// DeviceManager backend (device_manager_wasapi.cc) consumes it.
///
/// The ASIO C API is a process-global singleton by design — one loaded
/// driver at a time, and driver callbacks carry no context pointer — so
/// this class is a singleton too.
///
/// Thread-safety: all methods are control-thread only (the same thread
/// that owns DeviceManager; COM apartment affinity makes this a hard
/// requirement, not a convention). The driver's bufferSwitch is serviced
/// internally on the driver's real-time thread.
class AsioBackend {
 public:
  struct DriverCaps {
    uint32_t output_channels = 2;
    uint32_t preferred_buffer_frames = 512;
    std::vector<uint32_t> supported_sample_rates;
  };

  struct DriverInfo {
    std::string name;
    /// Registry enumeration order — the token the Windows backend
    /// stores in its per-device BackendRef. Stable within one
    /// enumerate() snapshot.
    uint32_t driver_index = 0;
    DriverCaps caps;
  };

  /// Matches DeviceManager::DataCallback: fills interleaved f32.
  using DataCallback = void (*)(void* output, uint32_t frames,
                                uint32_t channels, void* user_data);

  static AsioBackend& instance();

  // Non-copyable singleton.
  AsioBackend(const AsioBackend&) = delete;
  AsioBackend& operator=(const AsioBackend&) = delete;

  /// Enumerate installed ASIO drivers (registry walk) and probe each
  /// unseen one for channels / preferred buffer / sample rates. While a
  /// stream is running the previous snapshot is returned unchanged —
  /// probing loads drivers, and the SDK unloads the current driver
  /// before loading another, which would kill the active stream.
  ///
  /// Drivers whose probe failed (refused to load — usually the
  /// hardware is disconnected) are omitted from the snapshot rather
  /// than listed as dead entries. Failures are negative-cached and
  /// re-probed on a slow interval, so a reconnected interface shows up
  /// on a later enumerate without the app's hot-plug poll re-running
  /// ASIOInit against dead drivers every cycle (ES-275 field report).
  const std::vector<DriverInfo>& enumerate();

  /// Load driver `driver_index` (from the current snapshot) and start
  /// output. The buffer size is driver-owned (its preferred size,
  /// clamped to the graph's frame cap); `sample_rate` is requested via
  /// ASIOSetSampleRate and the driver's actual rate is adopted if it
  /// refuses. Any running stream is stopped first.
  bool start(uint32_t driver_index, uint32_t sample_rate, DataCallback cb,
             void* user_data);

  /// Stop, dispose buffers, and unload the driver. No-op when idle.
  void stop();

  bool is_running() const;

  /// Output channel count of the open driver (0 when idle).
  uint32_t channel_count() const;

  /// Current sample rate — kept live by the driver's
  /// sampleRateDidChange callback (0 when idle).
  uint32_t current_sample_rate() const;

  /// Frames per bufferSwitch of the open stream (0 when idle).
  uint32_t buffer_frames() const;

  /// Failure message from the last start() (empty on success).
  const std::string& last_error() const;

 private:
  AsioBackend() = default;
};

#endif  // ECLIPSA_STUDIO_IO_ASIO_BACKEND_H_
