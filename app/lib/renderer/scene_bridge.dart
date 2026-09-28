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

import 'dart:math' as math;
import 'dart:ui';

import 'package:vector_math/vector_math.dart';

import '../ffi_bridge.dart';
import '../state.dart';
import '../theme.dart';
import 'colormap.dart';
import 'coordinate_utils.dart';
import 'element_stats.dart';
import 'renderable_scene.dart';
import 'sh_utils.dart';
import 'speaker_layout.dart';
import 'viz_module.dart';
import 'viz_state.dart';

/// Converts app state (AudioElement list + output layout + meter levels)
/// into a [RenderableScene] for the 3D renderer.
class SceneBridge {
  SceneBridge._();

  /// Timestamp of the first build() call — used to derive wall-clock
  /// time for viz modules that animate (wavefronts etc.). Resettable
  /// via [resetTiming] so a renderer teardown + re-init doesn't hand
  /// the first frame an hour-long dt.
  static DateTime? _firstBuildTime;
  static DateTime? _lastBuildTime;

  /// Clear the timing state. Called by the renderer when the GL
  /// context is (re)initialised so the next [build] starts at t=0
  /// with a sane dt.
  static void resetTiming() {
    _firstBuildTime = null;
    _lastBuildTime = null;
  }

  /// Build a [RenderableScene] from current app state.
  ///
  /// [elements] — audio elements from state
  /// [outputLayout] — current output layout string (e.g. "7.1.4")
  /// [levels] — per-element peak levels (linear 0..1+), outer = elements,
  ///            inner = channels per element
  /// [stats]  — per-element channel-stats snapshots, outer = elements,
  ///            order matches [levels]. Pass empty list to skip modules.
  /// [colormap] — colormap for level-to-color mapping
  /// [vizNotifier] — when provided, enabled [ChannelVizModule]s are run
  ///                 and their output layers attached to the scene.
  static RenderableScene build({
    required List<AudioElement> elements,
    EclipsaStudioEngine? engine,
    List<List<double>> levels = const [],
    List<ElementStats> stats = const [],
    List<List<double>> shSnapshots = const [],
    Colormap colormap = Colormap.audioMeter,
    VizStateNotifier? vizNotifier,
  }) {
    final objects = <RenderableObject>[];
    final soundfields = <_SoundfieldContribution>[];
    final speakers = <RenderableSpeaker>[];

    for (var i = 0; i < elements.length; i++) {
      final el = elements[i];
      final elLevels = i < levels.length ? levels[i] : const <double>[];
      final peakLevel = elLevels.isEmpty
          ? 0.0
          : elLevels.reduce((a, b) => a > b ? a : b);
      final type = el.type.toLowerCase();

      if (type.contains('object')) {
        objects.addAll(_buildObject(el, peakLevel, colormap));
      } else if (type.contains('scene')) {
        // SH snapshots are already scaled by mix gain in the tick
        // loop (_updateMetersFromEngine).
        final elSh = i < shSnapshots.length ? shSnapshots[i] : const <double>[];
        soundfields.add(
          _SoundfieldContribution(
            channelLevels: elSh,
            order: el.ambisonicsOrder,
            color: Color(el.color),
          ),
        );
      } else {
        // Channel-based: show speakers matching this element's layout.
        final layout = SpeakerLayout.byName(el.layout);
        if (layout != null) {
          speakers.addAll(
            _buildSpeakers(layout, Color(el.color), elLevels, colormap),
          );
        }
      }
    }

    // SH coefficients — always computed when scene-based elements
    // are present. The Mollweide overlay and the SoundfieldSphere
    // module both consume these; kept here so the summed coeffs are
    // built exactly once per frame.
    List<double>? shCoeffs;
    int shOrder = 0;
    if (soundfields.isNotEmpty) {
      for (final sf in soundfields) {
        if (sf.order > shOrder) shOrder = sf.order;
      }
      final nCh = ShUtils.channelCount(shOrder);
      final coeffs = List<double>.filled(nCh, 0.0);
      for (final sf in soundfields) {
        final n = math.min(sf.channelLevels.length, nCh);
        for (var c = 0; c < n; c++) {
          coeffs[c] += sf.channelLevels[c];
        }
      }
      shCoeffs = coeffs;
    }

    // Channel-viz modules. Build the input set once (channel-based
    // elements only), then run each enabled module. Scene/object
    // elements are routed through their legacy paths above.
    final layers = <VizLayer>[];
    if (vizNotifier != null) {
      final now = DateTime.now();
      _firstBuildTime ??= now;
      final prev = _lastBuildTime ?? now;
      _lastBuildTime = now;
      final timeSec = now.difference(_firstBuildTime!).inMicroseconds / 1e6;
      final dtSec = (now.difference(prev).inMicroseconds / 1e6).clamp(
        0.0,
        0.1,
      ); // clamp post-pause bursts to 100 ms

      // Split elements by domain.
      final channelElements = <ChannelVizElement>[];
      final sceneElements = <SceneVizElement>[];
      for (var i = 0; i < elements.length; i++) {
        final el = elements[i];
        final type = el.type.toLowerCase();
        if (type.contains('object')) continue;
        final elSh = i < shSnapshots.length ? shSnapshots[i] : const <double>[];
        if (type.contains('scene')) {
          sceneElements.add(
            SceneVizElement(
              element: el,
              order: el.ambisonicsOrder,
              shSnapshots: elSh,
            ),
          );
          continue;
        }
        final layout = SpeakerLayout.byName(el.layout);
        if (layout == null) continue;
        final elLevels = i < levels.length ? levels[i] : const <double>[];
        final elStats = i < stats.length ? stats[i] : ElementStats.empty();
        channelElements.add(
          ChannelVizElement(
            element: el,
            layout: layout,
            peaks: elLevels,
            stats: elStats,
          ),
        );
      }

      // Run channel modules even with no channel-based elements: the
      // modules self-guard on empty input, and some depend on being
      // ticked regardless — AmbientParticles keeps its cloud alive
      // during silence by contract, and Wavefronts must keep decaying
      // in-flight pulses after the last channel element is removed.
      {
        final input = ChannelVizInput(
          elements: channelElements,
          timeSec: timeSec,
          dtSec: dtSec,
        );
        for (final m in VizRegistry.modules) {
          if (m is! ChannelVizModule) continue;
          final s = vizNotifier.stateFor(m.id);
          if (!s.enabled) continue;
          final values = vizNotifier.paramsFor(m);
          layers.addAll(m.build(input, values));
        }
      }

      if (sceneElements.isNotEmpty) {
        // Reuse the summed SH coefficients we already built above.
        final input = SceneVizInput(
          elements: sceneElements,
          combinedCoeffs: shCoeffs ?? const <double>[],
          combinedOrder: shOrder,
          engine: engine,
          timeSec: timeSec,
          dtSec: dtSec,
        );
        for (final m in VizRegistry.modules) {
          if (m is! SceneVizModule) continue;
          final s = vizNotifier.stateFor(m.id);
          if (!s.enabled) continue;
          final values = vizNotifier.paramsFor(m);
          layers.addAll(m.build(input, values));
        }
      }
    }

    return RenderableScene(
      objects: objects,
      speakers: speakers,
      shCoeffs: shCoeffs,
      shOrder: shOrder,
      showAxes: true,
      layers: layers,
    );
  }

  /// Build renderable objects for an object-based element.
  static List<RenderableObject> _buildObject(
    AudioElement el,
    double peakLevel,
    Colormap colormap,
  ) {
    final color = colormap.sample(peakLevel.clamp(0, 1));
    const baseRadius = 0.06;
    // Modulate radius by level (subtle: +50% at full level)
    final radius = baseRadius + baseRadius * 0.5 * peakLevel.clamp(0, 1);

    final pos = CoordinateUtils.sphericalToVisualizer(
      el.azimuth,
      el.elevation,
      el.distance,
    );

    if (el.isDual) {
      // Stereo pair — two spheres offset by spread
      final halfSpread = el.spread / 2;
      final posL = CoordinateUtils.sphericalToVisualizer(
        el.azimuth + halfSpread,
        el.elevation,
        el.distance,
      );
      final posR = CoordinateUtils.sphericalToVisualizer(
        el.azimuth - halfSpread,
        el.elevation,
        el.distance,
      );
      return [
        RenderableObject(
          id: el.id * 2,
          position: posL,
          radius: radius,
          color: color,
        ),
        RenderableObject(
          id: el.id * 2 + 1,
          position: posR,
          radius: radius,
          color: color,
        ),
      ];
    }

    return [
      RenderableObject(id: el.id, position: pos, radius: radius, color: color),
    ];
  }

  /// Build renderable speakers from a layout definition.
  /// [elementColor] tints the speakers to match the element's color.
  /// [channelLevels] are per-channel levels for the element.
  static List<RenderableSpeaker> _buildSpeakers(
    SpeakerLayout layout,
    Color? elementColor,
    List<double> channelLevels,
    Colormap colormap,
  ) {
    return List.generate(layout.speakers.length, (i) {
      final spk = layout.speakers[i];
      final pos = CoordinateUtils.sphericalToVisualizer(
        spk.azDeg,
        spk.elDeg,
        spk.distance,
      );
      final level = i < channelLevels.length ? channelLevels[i] : 0.0;
      final baseColor = elementColor ?? T.typeScene;
      // Blend between base color and colormap-driven color based
      // on level.
      final levelColor = colormap.sample(level.clamp(0, 1));
      final color = level > 0.01
          ? Color.lerp(baseColor, levelColor, 0.6)!
          : (spk.isLFE ? Color.lerp(baseColor, T.typeScene, 0.5)! : baseColor);
      return RenderableSpeaker(
        position: pos,
        lookAtOrigin: Vector3.zero(),
        color: color,
        label: spk.label,
        width: spk.isLFE ? 0.06 : 0.08,
        height: spk.isLFE ? 0.06 : 0.12,
        depth: spk.isLFE ? 0.06 : 0.06,
        level: level,
      );
    });
  }
}

class _SoundfieldContribution {
  /// Per-channel meter levels in ACN order — these are the
  /// SH coefficients for the scene element.
  final List<double> channelLevels;
  final int order;
  final Color color;

  const _SoundfieldContribution({
    required this.channelLevels,
    required this.order,
    required this.color,
  });
}
