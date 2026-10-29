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

#include "adm_import/adm/adm_model.h"

#include <cstdint>
#include <string>

namespace adm2iamf {
namespace adm {

std::string ChnaEntry::ChannelFormatId() const {
  if (track_ref.empty()) return "";
  if (track_ref.rfind("AC_", 0) == 0) {
    // BS.2076-2+ chna rows may reference the channel format directly,
    // optionally with a counter suffix: "AC_yyyyxxxx_zz" -> "AC_yyyyxxxx".
    const auto us = track_ref.find('_', 3);
    return us == std::string::npos ? track_ref : track_ref.substr(0, us);
  }
  if (track_ref.rfind("AT_", 0) == 0) {
    // "AT_xxxxyyyy_zz" -> "AC_xxxxyyyy".
    std::string body = track_ref.substr(3);
    auto us = body.find('_');
    if (us != std::string::npos) body = body.substr(0, us);
    return "AC_" + body;
  }
  return "";
}

const AudioPackFormat* Model::Pack(const std::string& id) const {
  for (const auto& p : packs) {
    if (p.id == id) return &p;
  }
  return nullptr;
}

const AudioChannelFormat* Model::Channel(const std::string& id) const {
  for (const auto& c : channels) {
    if (c.id == id) return &c;
  }
  return nullptr;
}

const AudioObject* Model::Object(const std::string& id) const {
  for (const auto& o : objects) {
    if (o.id == id) return &o;
  }
  return nullptr;
}

uint16_t Model::TrackIndexForChannel(
    const std::string& channel_format_id) const {
  for (const auto& e : chna) {
    if (e.track_index != 0 && e.ChannelFormatId() == channel_format_id) {
      return e.track_index;
    }
  }
  return 0;
}

uint16_t Model::TrackIndexForUid(const std::string& uid) const {
  for (const auto& e : chna) {
    if (e.track_index != 0 && e.uid == uid) return e.track_index;
  }
  return 0;
}

// try_emplace keeps the first entry for a key, as the Model scans do.
ModelIndex::ModelIndex(const Model& model) {
  packs_.reserve(model.packs.size());
  for (const auto& p : model.packs) packs_.try_emplace(p.id, &p);
  channels_.reserve(model.channels.size());
  for (const auto& c : model.channels) channels_.try_emplace(c.id, &c);
  track_by_channel_.reserve(model.chna.size());
  track_by_uid_.reserve(model.chna.size());
  for (const auto& e : model.chna) {
    if (e.track_index == 0) continue;
    track_by_channel_.try_emplace(e.ChannelFormatId(), e.track_index);
    track_by_uid_.try_emplace(e.uid, e.track_index);
  }
}

const AudioPackFormat* ModelIndex::Pack(const std::string& id) const {
  const auto it = packs_.find(id);
  return it == packs_.end() ? nullptr : it->second;
}

const AudioChannelFormat* ModelIndex::Channel(const std::string& id) const {
  const auto it = channels_.find(id);
  return it == channels_.end() ? nullptr : it->second;
}

uint16_t ModelIndex::TrackIndexForChannel(
    const std::string& channel_format_id) const {
  const auto it = track_by_channel_.find(channel_format_id);
  return it == track_by_channel_.end() ? 0 : it->second;
}

uint16_t ModelIndex::TrackIndexForUid(const std::string& uid) const {
  const auto it = track_by_uid_.find(uid);
  return it == track_by_uid_.end() ? 0 : it->second;
}

}  // namespace adm
}  // namespace adm2iamf
