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

/// Per-device monitoring persistence: encode/decode one device sub-object of
/// the [AppPreferences.kMonitoringByDevice] blob, plus read-modify-write
/// helpers keyed by device name.
///
/// The blob is treated as untrusted input (same posture as
/// [AppPreferences.load]): unknown layouts are dropped, routing lengths
/// reconciled to each layout. Decode never throws.
///
/// Routing and labels are NOT clamped to any device channel count here:
/// the stored config is the user's full patch, and the current device's
/// channel count is a *view* applied at the engine-push and matrix-display
/// boundaries (see ES-24/ES-63). Clamping at decode — and then persisting the
/// clamped result — is exactly how high-channel routing used to be lost.
library;

import '../state.dart' show MonitoringConfig, kMaxRoutingChannels;
import 'app_preferences.dart';

/// Combine [cfg] + [labels] into one device sub-object.
Map<String, dynamic> encodeDevice(
  MonitoringConfig cfg,
  Map<int, String> labels,
) => {
  ...cfg.toJson(),
  'labels': {for (final e in labels.entries) '${e.key}': e.value},
};

/// Defensive decode of one device sub-object. Routing and labels are kept
/// in full — including entries past the current device's channel count —
/// so a later device (or channel-count) switch restores them intact.
({MonitoringConfig config, Map<int, String> labels}) decodeDevice(
  Map<String, dynamic> j,
) {
  final config = MonitoringConfig.fromJson(j);
  final labels = <int, String>{};
  final lj = j['labels'];
  if (lj is Map) {
    lj.forEach((k, v) {
      final ch = k is String ? int.tryParse(k) : (k is int ? k : null);
      if (ch != null &&
          ch >= 0 &&
          ch < kMaxRoutingChannels &&
          v is String &&
          v.isNotEmpty) {
        labels[ch] = v;
      }
    });
  }
  return (config: config, labels: labels);
}

/// Serialises the read-modify-write saves below. A config edit and a label
/// edit can fire their persistence listeners in the same microtask batch;
/// without chaining, both [AppPreferences.load] calls would observe the same
/// stale map and the later [AppPreferences.setAll] would clobber the earlier
/// device entry, losing an update. Chaining makes each save observe the prior
/// write.
Future<void> _saveChain = Future<void>.value();

/// Read-modify-write one device entry. [AppPreferences.setAll] replaces the
/// whole nested map, so the existing map must be merged first. Saves run
/// one at a time (see [_saveChain]).
Future<void> saveMonitoringForDevice(
  String deviceName,
  MonitoringConfig cfg,
  Map<int, String> labels,
) {
  final next = _saveChain.then((_) async {
    final prefs = await AppPreferences.load();
    final byDevice = Map<String, dynamic>.from(
      (prefs[AppPreferences.kMonitoringByDevice] as Map?) ?? const {},
    );
    byDevice[deviceName] = encodeDevice(cfg, labels);
    await AppPreferences.setAll({AppPreferences.kMonitoringByDevice: byDevice});
  });
  // Keep the chain alive after a failure so one bad save can't wedge the rest;
  // the caller still sees the error via the returned future.
  _saveChain = next.catchError((_) {});
  return next;
}

/// Decode the saved config + labels for [deviceName] out of an already-loaded
/// [prefs] map. Synchronous, so a caller that already holds the prefs map
/// avoids a second disk read. Returns null if the device has no saved entry.
({MonitoringConfig config, Map<int, String> labels})? monitoringForDeviceIn(
  Map<String, dynamic> prefs,
  String deviceName,
) {
  final byDevice = prefs[AppPreferences.kMonitoringByDevice] as Map?;
  final entry = byDevice?[deviceName];
  if (entry is! Map) return null;
  return decodeDevice(entry.cast<String, dynamic>());
}

/// Load the saved config + labels for [deviceName]. Returns null if the
/// device has no saved entry.
Future<({MonitoringConfig config, Map<int, String> labels})?>
loadMonitoringForDevice(String deviceName) async {
  final prefs = await AppPreferences.load();
  return monitoringForDeviceIn(prefs, deviceName);
}

/// Completes when all saves queued so far have been written. A restore that
/// loads prefs without waiting can observe a snapshot missing an in-flight
/// device entry and resurrect stale state — await this first.
Future<void> monitoringSavesSettled() => _saveChain;
