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

// A fake engine for tests of the element and mix-settings pushes.

import 'package:eclipsa_studio/ffi_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// Holds the engine state the mix settings live in, as the engine
/// treats it: an add resets an element's exclusion and mix gain, a type
/// call gives it OAR's default rendering config (mode 1, profile 0), and
/// a staged config takes effect at the next commit. Any engine call it
/// does not model fails the test.
class MixStateEngine extends Fake implements EclipsaStudioEngine {
  /// The elements in the audio graph.
  final live = <int>{};
  final excluded = <int, bool>{};
  final mixGain = <int, double>{};
  final routing = <int, List<int>?>{};
  double outputMixGain = 0;

  /// The committed rendering config by element, as (mode, profile).
  final rendering = <int, (int, int)>{};
  final _staged = <int, (int, int)>{};

  /// The ids passed to [removeElement], in call order.
  final removed = <int>[];

  @override
  int get currentSampleRate => 48000;

  @override
  int addElement(int elementId, String wavPath) {
    live.add(elementId);
    excluded[elementId] = false;
    mixGain[elementId] = 0;
    routing[elementId] = null;
    return 0;
  }

  @override
  void removeElement(int elementId) {
    removed.add(elementId);
    live.remove(elementId);
    rendering.remove(elementId);
    _staged.remove(elementId);
  }

  @override
  bool setElementType(int elementId, int type, int subType, int channels) {
    rendering[elementId] = (1, 0);
    _staged.remove(elementId);
    return true;
  }

  @override
  bool stageElementRenderingConfig(int elementId, int mode, int profile) {
    if (!rendering.containsKey(elementId)) return false;
    _staged[elementId] = (mode, profile);
    return true;
  }

  @override
  bool commitRenderingConfig() {
    rendering.addAll(_staged);
    _staged.clear();
    return true;
  }

  @override
  void setElementMixExcluded(int elementId, bool excluded) {
    if (live.contains(elementId)) this.excluded[elementId] = excluded;
  }

  @override
  void setElementMixGain(int elementId, double gainDb) {
    if (live.contains(elementId)) mixGain[elementId] = gainDb;
  }

  @override
  void setElementInputRouting(int elementId, List<int>? routing) {
    if (live.contains(elementId)) this.routing[elementId] = routing;
  }

  @override
  void setOutputMixGain(double gainDb) => outputMixGain = gainDb;

  @override
  void setElementChannelOrder(int elementId, int order) {}

  @override
  void setElementGain(int elementId, double gainDb) {}

  @override
  void setElementMute(int elementId, bool muted) {}

  @override
  void setElementSolo(int elementId, bool solo) {}
}
