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

/// Converts app state (AudioElement list + monitoring target + meter
/// levels) into a [RenderableScene] for the 3D renderer.
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
  /// [outputLayout] — a loudspeaker monitoring target, drawn as its
  ///            loudspeakers; null on the binaural target
  /// [isBinauralTarget] — the binaural target is monitored: the scene
  ///            carries [RenderableScene.headphones], and channel sources
  ///            sit at OBR's virtual loudspeakers
  ///            ([SpeakerLayout.binauralGeometry])
  /// [outputLevels] — meter levels (linear 0..1+) of the monitoring
  ///            render's output channels in the target's channel order;
  ///            they light the loudspeakers and the earcups
  /// [stereoOnHeadphones] — ids of the channel-based elements the
  ///            binaural target plays on the headphones as plain stereo;
  ///            their sources sit inside the head. Ignored on a
  ///            loudspeaker target.
  /// [silenced] — ids of the elements muted or excluded by a solo; their
  ///            sources and objects fade towards the scene background
  /// [silencedOutputs] — indices of the target's output channels muted
  ///            or excluded by a solo in the Monitoring panel; their
  ///            loudspeakers or earcups fade the same way
  /// [levels] — per-element peak levels (linear 0..1+), outer = elements,
  ///            inner = channels per element
  /// [stats]  — per-element channel-stats snapshots, outer = elements,
  ///            order matches [levels]. Pass empty list to skip modules.
  /// [colormap] — colormap for level-to-color mapping
  /// [vizNotifier] — when provided, enabled [ChannelVizModule]s are run
  ///                 and their output layers attached to the scene.
  static RenderableScene build({
    required List<AudioElement> elements,
    SpeakerLayout? outputLayout,
    bool isBinauralTarget = false,
    List<double> outputLevels = const [],
    Set<int> stereoOnHeadphones = const {},
    Set<int> silenced = const {},
    Set<int> silencedOutputs = const {},
    EclipsaStudioEngine? engine,
    List<List<double>> levels = const [],
    List<ElementStats> stats = const [],
    List<List<double>> shSnapshots = const [],
    Colormap colormap = Colormap.audioMeter,
    VizStateNotifier? vizNotifier,
  }) {
    final objects = <RenderableObject>[];
    final soundfields = <_SoundfieldContribution>[];
    final sources = <RenderableSource>[];
    bool onHeadphones(AudioElement el) =>
        isBinauralTarget && stereoOnHeadphones.contains(el.id);

    for (var i = 0; i < elements.length; i++) {
      final el = elements[i];
      final elLevels = i < levels.length ? levels[i] : const <double>[];
      final peakLevel = elLevels.isEmpty
          ? 0.0
          : elLevels.reduce((a, b) => a > b ? a : b);
      final type = el.type.toLowerCase();
      final isSilenced = silenced.contains(el.id);

      if (type.contains('object')) {
        objects.addAll(_buildObject(el, peakLevel, colormap, isSilenced));
      } else if (type.contains('scene')) {
        // SH snapshots are already scaled by mix gain in the tick
        // loop (_updateMetersFromEngine).
        final elSh = i < shSnapshots.length ? shSnapshots[i] : const <double>[];
        soundfields.add(
          _SoundfieldContribution(
            channelLevels: elSh,
            order: el.ambisonicsOrder,
          ),
        );
      } else {
        // Channel-based: one source per channel where the monitoring
        // render takes it from, or a pair inside the head when the
        // headphones play the element as plain stereo.
        final layout = _channelLayout(el, isBinauralTarget);
        if (layout == null) continue;
        final built = onHeadphones(el)
            ? _buildHeadphonesSources(
                layout,
                aeTypeColor(el.type),
                elLevels,
                colormap,
              )
            : _buildSources(layout, aeTypeColor(el.type), elLevels, colormap);
        sources.addAll(isSilenced ? built.map(_silence) : built);
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
        // Stereo on the headphones has no position in the room for the
        // channel modules to draw from.
        final layout = _channelLayout(el, isBinauralTarget);
        if (layout == null || onHeadphones(el)) continue;
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
      sources: sources,
      speakers: outputLayout == null || isBinauralTarget
          ? const []
          : _buildOutputSpeakers(
              outputLayout,
              outputLevels,
              silencedOutputs,
              colormap,
            ),
      headphones: isBinauralTarget
          ? _buildHeadphones(outputLevels, silencedOutputs, colormap)
          : null,
      shCoeffs: shCoeffs,
      shOrder: shOrder,
      showAxes: true,
      layers: layers,
    );
  }

  /// The positions the channels of a channel-based [el] are rendered
  /// from: its layout's loudspeaker positions, or OBR's virtual
  /// loudspeakers on the binaural target, which OBR places at distance
  /// 1.0 (OAR specification 1.0.0, section 4.2.1). Null for a layout the
  /// scene has no table for.
  static SpeakerLayout? _channelLayout(AudioElement el, bool isBinauralTarget) {
    final layout = SpeakerLayout.byName(el.layout);
    return isBinauralTarget ? layout?.binauralGeometry : layout;
  }

  /// Build renderable objects for an object-based element, faded towards
  /// the scene background when [isSilenced].
  static List<RenderableObject> _buildObject(
    AudioElement el,
    double peakLevel,
    Colormap colormap,
    bool isSilenced,
  ) {
    final levelColor = colormap.sample(peakLevel.clamp(0, 1));
    final color = isSilenced ? _faded(levelColor) : levelColor;
    const baseRadius = 0.06;
    // Modulate radius by level (subtle: +50% at full level)
    final radius = baseRadius + baseRadius * 0.5 * peakLevel.clamp(0, 1);

    final pos = CoordinateUtils.sphericalToVisualizer(
      el.azimuth,
      el.elevation,
      el.distance,
    );

    // Mesh ids: element n owns 2n and 2n + 1, so a single object (2n)
    // and a dual object's pair (2n, 2n + 1) never share an id with
    // another element's.
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
      RenderableObject(
        id: el.id * 2,
        position: pos,
        radius: radius,
        color: color,
      ),
    ];
  }

  /// [color] faded most of the way to the scene background, for the
  /// sources of an element the engine silences.
  static Color _faded(Color color) => Color.lerp(color, T.bgDeep, 0.7)!;

  /// [source] as a silenced element draws it: faded, at its silent size
  /// and level. The element's meters fall to zero behind the engine's
  /// mute ramp anyway; this shows the silence at once.
  static RenderableSource _silence(RenderableSource source) => RenderableSource(
    position: source.position,
    color: _faded(source.color),
    radius: _sourceRadius,
  );

  /// Radius of a silent channel source; it grows by up to half at full
  /// level, as an object does.
  static const double _sourceRadius = 0.03;

  static double _sourceRadiusAt(double level) =>
      _sourceRadius + _sourceRadius * 0.5 * level.clamp(0, 1);

  /// One source per channel of [layout], in [elementColor] tinted by the
  /// channel's level from [channelLevels].
  static List<RenderableSource> _buildSources(
    SpeakerLayout layout,
    Color elementColor,
    List<double> channelLevels,
    Colormap colormap,
  ) {
    return List.generate(layout.speakers.length, (i) {
      final spk = layout.speakers[i];
      final level = i < channelLevels.length ? channelLevels[i] : 0.0;
      final color = spk.isLFE && level <= 0.01
          ? Color.lerp(elementColor, T.typeScene, 0.5)!
          : _levelTint(elementColor, level, colormap);
      return RenderableSource(
        position: CoordinateUtils.sphericalToVisualizer(
          spk.azDeg,
          spk.elDeg,
          spk.distance,
        ),
        color: color,
        radius: _sourceRadiusAt(level),
        level: level,
      );
    });
  }

  /// Where the pair of an element the headphones play as plain stereo
  /// sits inside the head: on the ear axis halfway to each earcup. Every
  /// such element shares the place; the translucent spheres show through
  /// each other.
  static const double _headSourceX = RenderableHeadphones.headRadius / 2;

  /// The sources of an element the headphones play as plain stereo: a
  /// pair inside the head, the region where OBR renders an object nearer
  /// than the head radius (OAR specification 1.0.0, section 4.2.3). Each
  /// source of the pair carries the level of the element's loudest
  /// non-LFE channel on its side of the head (positive azimuth is left;
  /// a channel at 0° or 180° counts for both sides).
  static List<RenderableSource> _buildHeadphonesSources(
    SpeakerLayout layout,
    Color elementColor,
    List<double> channelLevels,
    Colormap colormap,
  ) {
    var left = 0.0;
    var right = 0.0;
    for (var c = 0; c < layout.speakers.length; c++) {
      final spk = layout.speakers[c];
      if (spk.isLFE) continue;
      final level = c < channelLevels.length ? channelLevels[c] : 0.0;
      final side = math.sin(spk.azDeg * math.pi / 180);
      if (side > -1e-6) left = math.max(left, level);
      if (side < 1e-6) right = math.max(right, level);
    }
    // Audio left is visualizer -X.
    RenderableSource at(double x, double level) => RenderableSource(
      position: Vector3(x, 0, 0),
      color: _levelTint(elementColor, level, colormap),
      radius: _sourceRadiusAt(level),
      level: level,
    );
    return [at(-_headSourceX, left), at(_headSourceX, right)];
  }

  /// Distance of the target's loudspeakers from the listener, as a
  /// multiple of their layout distance: just outside the unit sphere the
  /// sources sit on, so a source pointing the same way as a loudspeaker
  /// stays in front of the cabinet face at its largest radius.
  static const double _outputDistance = 1.1;

  /// The loudspeakers of a loudspeaker monitoring target, tinted from a
  /// neutral body by [outputLevels], the output channels' meter levels,
  /// and faded for the channels in [silenced].
  static List<RenderableSpeaker> _buildOutputSpeakers(
    SpeakerLayout layout,
    List<double> outputLevels,
    Set<int> silenced,
    Colormap colormap,
  ) {
    final body = T.textTertiary;
    return List.generate(layout.speakers.length, (i) {
      final spk = layout.speakers[i];
      final level = i < outputLevels.length ? outputLevels[i] : 0.0;
      final tint = _levelTint(body, level, colormap);
      return RenderableSpeaker(
        position: CoordinateUtils.sphericalToVisualizer(
          spk.azDeg,
          spk.elDeg,
          spk.distance * _outputDistance,
        ),
        color: silenced.contains(i) ? _faded(tint) : tint,
        label: spk.label,
        width: spk.isLFE ? 0.06 : 0.08,
        height: spk.isLFE ? 0.06 : 0.12,
        depth: 0.06,
        level: level,
      );
    });
  }

  /// Headphones whose earcups are tinted from a neutral body by the
  /// meter levels of the binaural render's two output channels, L then
  /// R ([outputLevels]), and faded for the channels in [silenced].
  static RenderableHeadphones _buildHeadphones(
    List<double> outputLevels,
    Set<int> silenced,
    Colormap colormap,
  ) {
    final body = T.textTertiary;
    final left = outputLevels.isNotEmpty ? outputLevels[0] : 0.0;
    final right = outputLevels.length > 1 ? outputLevels[1] : 0.0;
    Color earcup(int channel, double level) {
      final tint = _levelTint(body, level, colormap);
      return silenced.contains(channel) ? _faded(tint) : tint;
    }

    return RenderableHeadphones(
      bandColor: body,
      leftColor: earcup(0, left),
      rightColor: earcup(1, right),
      leftLevel: left,
      rightLevel: right,
    );
  }

  /// [base] blended towards the colormap's color for [level] once the
  /// level passes 0.01.
  static Color _levelTint(Color base, double level, Colormap colormap) =>
      level > 0.01
      ? Color.lerp(base, colormap.sample(level.clamp(0, 1)), 0.6)!
      : base;
}

class _SoundfieldContribution {
  /// Per-channel meter levels in ACN order — these are the
  /// SH coefficients for the scene element.
  final List<double> channelLevels;
  final int order;

  const _SoundfieldContribution({
    required this.channelLevels,
    required this.order,
  });
}
