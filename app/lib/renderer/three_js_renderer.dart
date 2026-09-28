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
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:three_js/three_js.dart' as three;

import '../theme.dart';
import 'renderable_scene.dart';
import 'renderer_capabilities.dart';
import 'scene_bridge.dart';
import 'scene_renderer.dart';

enum CameraPreset { top, front, perspective }

/// GPU-accelerated 3D renderer using the three_js package.
class ThreeJsRenderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities => const RendererCapabilities(
    name: 'Three.js (GPU)',
    description: 'GPU-accelerated via three_js (ANGLE on desktop).',
    supportsVertexColors: true,
    supportsWireframe: true,
    supportsTransparency: true,
    supportsOrbitCamera: true,
    supportsDynamicMeshUpdate: true,
  );

  late three.ThreeJS _threeJs;
  three.Scene? _scene;
  three.PerspectiveCamera? _camera;
  three.OrbitControls? _controls;
  bool _initialized = false;

  final _objectMeshes = <int, three.Mesh>{};
  final _speakerMeshes = <int, three.Mesh>{};
  three.Group? _objectGroup;
  three.Group? _speakerGroup;
  three.Group? _soundfieldGroup;

  // Cached soundfield mesh — topology is static, only colors/alpha
  // change per frame.
  three.Mesh? _sfMesh;
  three.MeshBasicMaterial? _sfMaterial;
  three.Float32BufferAttribute? _sfColorAttr;
  int _sfFaceCount = 0;
  double _sfRadius = 0;
  bool _sfHasWireframe = false;

  /// Whether the soundfield wireframe was built for a light ground; a
  /// theme switch across that line rebuilds it.
  bool _sfLight = false;

  three.Group? _gridGroup;
  three.Group? _axesGroup;

  // Layer dispatch — each VizLayer.id maps to its own Group. Unknown
  // layer types are skipped by the dispatcher in _applyScene.
  final Map<String, three.Group> _layerGroups = {};

  // Per-layer caches.
  three.Mesh? _shellMesh;
  three.MeshBasicMaterial? _shellMaterial;
  three.Float32BufferAttribute? _shellPosAttr;
  three.Float32BufferAttribute? _shellColorAttr;
  int _shellVertexCount = 0;
  int _shellFaceCount = 0;

  // Correlation ribbon pool — one Line per ribbon, reused across frames.
  final List<three.Line> _ribbonLines = [];
  final List<three.LineBasicMaterial> _ribbonMaterials = [];
  int _ribbonSegments = 0;

  // Wavefront pool — one translucent sphere shell per active pulse.
  final List<three.Mesh> _wavefrontMeshes = [];
  final List<three.MeshBasicMaterial> _wavefrontMaterials = [];
  static const int _wavefrontSphereSegments = 24;

  // Most recent ambient-particles layer — applied by _tickParticles
  // each frame. Null means the module is not emitting this frame
  // (either disabled or no channel-based elements).
  AmbientParticlesLayer? _particlesLayer;

  // Ambient particle cloud — elastic sphere with dipole strain.
  static const int _maxParticles = 3000;
  three.Points? _particles;
  three.PointsMaterial? _particleMat;
  three.Float32BufferAttribute? _particlePosAttr;
  three.Float32BufferAttribute? _particleColorAttr;
  // Rest position (random within sphere).
  final Float32List _pRestX = Float32List(_maxParticles);
  final Float32List _pRestY = Float32List(_maxParticles);
  final Float32List _pRestZ = Float32List(_maxParticles);
  // Normalized rest direction from origin (for dot products).
  final Float32List _pDirX = Float32List(_maxParticles);
  final Float32List _pDirY = Float32List(_maxParticles);
  final Float32List _pDirZ = Float32List(_maxParticles);
  // Distance from origin (for radial scaling).
  final Float32List _pRestR = Float32List(_maxParticles);
  // Oscillation phase & frequency per particle.
  final Float32List _pPhase = Float32List(_maxParticles);
  final Float32List _pFreq = Float32List(_maxParticles);
  // Previous total level for rate-of-change detection.
  double _prevTotalLevel = 0;
  double _levelSlew = 0; // smoothed derivative
  final math.Random _rng = math.Random();

  // Per-speaker scratch for _tickParticles — grown to the high-water
  // mark and reused so the animation ticker allocates nothing per
  // frame. Skipped speakers keep stale dir/color entries; consumers
  // gate on spkLevel, which is rewritten for every slot each tick.
  Float32List _spkDirX = Float32List(0);
  Float32List _spkDirY = Float32List(0);
  Float32List _spkDirZ = Float32List(0);
  Float32List _spkLevel = Float32List(0);
  Float32List _spkR = Float32List(0);
  Float32List _spkG = Float32List(0);
  Float32List _spkB = Float32List(0);

  RenderableScene _pendingScene = const RenderableScene();

  /// Upper-left 3x3 of the camera view matrix (column-major,
  /// 9 floats).  Updated each animation frame so the corner
  /// axes gizmo can track camera orientation.
  final cameraRotationNotifier = ValueNotifier<List<double>>(const [
    1,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
  ]);

  /// Callback invoked once the GL context is ready and the first
  /// frame can render.  Used by the widget to swap the loading
  /// placeholder for the live scene.
  VoidCallback? onReady;

  @override
  Widget buildWidget({Key? key}) {
    return _ThreeJsWidget(key: key, renderer: this);
  }

  /// Initialize the GL context with the given viewport [size].
  /// Must be called once before rendering.
  void initWithSize(Size size) => _initThreeJs(size);

  /// Build the inner three_js rendering widget.
  Widget buildInnerWidget() => _threeJs.build();

  /// Update the camera aspect ratio when the viewport resizes.
  void updateAspect(double width, double height) {
    if (_camera != null && width > 0 && height > 0) {
      _camera!.aspect = width / height;
      _camera!.updateProjectionMatrix();
    }
  }

  void _initThreeJs(Size size) {
    _threeJs = three.ThreeJS(
      onSetupComplete: () {},
      setup: _setup,
      size: size,
      settings: three.Settings(
        clearColor: T.bgDeep.toARGB32() & 0xFFFFFF,
        enableShadowMap: false,
        antialias: true,
      ),
    );
  }

  /// Update the GL clear color at runtime — used to keep the scene
  /// background in sync with the active theme. No-op until the GL
  /// context has been initialized.
  void setClearColor(ui.Color color) {
    if (!_initialized) return;
    final hex = color.toARGB32() & 0xFFFFFF;
    _threeJs.renderer?.setClearColor(three.Color.fromHex32(hex));
  }

  Future<void> _setup() async {
    _scene = three.Scene();
    _threeJs.scene = _scene!;

    _camera = three.PerspectiveCamera(
      50,
      _threeJs.width / _threeJs.height,
      0.1,
      100,
    );
    _camera!.position.setValues(0, 2.0, 4.0);
    _camera!.lookAt(three.Vector3.zero());
    _threeJs.camera = _camera!;

    _controls = three.OrbitControls(_camera!, _threeJs.globalKey);
    _controls!.enableDamping = true;
    _controls!.dampingFactor = 0.08;
    _controls!.minDistance = 0.5;
    _controls!.maxDistance = 10.0;
    // The listener at the origin is the scene's fixed subject; panning the
    // orbit target away from it can push the scene out of view with no
    // visible way back (ES-329).
    _controls!.enablePan = false;

    // Lighting
    final keyLight = three.DirectionalLight(0xffffff, 1.0);
    keyLight.position.setValues(3, 3, 3);
    _scene!.add(keyLight);

    final fillLight = three.DirectionalLight(0x8888cc, 0.4);
    fillLight.position.setValues(-3, 2, -3);
    _scene!.add(fillLight);

    _scene!.add(three.AmbientLight(0x404060, 0.3));

    // Groups
    _objectGroup = three.Group();
    _speakerGroup = three.Group();
    _soundfieldGroup = three.Group();
    _gridGroup = three.Group();
    _axesGroup = three.Group();
    _scene!.add(_objectGroup!);
    _scene!.add(_speakerGroup!);
    _scene!.add(_soundfieldGroup!);
    _scene!.add(_gridGroup!);
    _scene!.add(_axesGroup!);

    _buildGrid();
    _buildAxes();
    _buildParticles();

    _initialized = true;
    // Clear SceneBridge's cross-frame timing so wavefront / animation
    // modules see a sane dt on the first frame after a renderer
    // re-init (window teardown, hot restart in debug, etc.).
    SceneBridge.resetTiming();
    _applyScene(_pendingScene);
    onReady?.call();

    _threeJs.addAnimationEvent((dt) {
      _controls?.update();
      _updateCameraRotation();
      _tickParticles(dt);
    });
  }

  void _buildGrid() {
    final positions = <double>[];
    for (var i = -5; i <= 5; i++) {
      final t = i * 0.2;
      positions.addAll([t, 0, -1, t, 0, 1]);
      positions.addAll([-1, 0, t, 1, 0, t]);
    }
    final geo = three.BufferGeometry();
    geo.setAttributeFromString(
      'position',
      three.Float32BufferAttribute.fromList(positions, 3),
    );
    final mat = three.LineBasicMaterial({
      three.MaterialProperty.color: three.Color.fromHex32(0xFF222233),
      three.MaterialProperty.transparent: true,
      three.MaterialProperty.opacity: 0.35,
    });
    _gridGroup!.add(three.LineSegments(geo, mat));
  }

  void _buildAxes() {
    void addAxis(double x, double y, double z, int color) {
      final geo = three.BufferGeometry();
      geo.setAttributeFromString(
        'position',
        three.Float32BufferAttribute.fromList([0, 0, 0, x, y, z], 3),
      );
      final mat = three.LineBasicMaterial({
        three.MaterialProperty.color: three.Color.fromHex32(0xFF000000 | color),
      });
      _axesGroup!.add(three.LineSegments(geo, mat));
    }

    // User convention: X=right(red), Y=front(green), Z=up(blue)
    // three.js is Y-up, so: Y(front) → -Z, Z(up) → +Y
    addAxis(1.6, 0, 0, 0xFF4444); // X red  = right
    addAxis(0, 0, -1.6, 0x44FF44); // Y green = front (-Z)
    addAxis(0, 1.6, 0, 0x4488FF); // Z blue  = up    (+Y)
  }

  void _buildParticles() {
    final positions = Float32List(_maxParticles * 3);
    final colors = Float32List(_maxParticles * 3);
    const restRadius = 0.2;

    for (var i = 0; i < _maxParticles; i++) {
      // Uniform volume distribution via rejection sampling.
      double x, y, z;
      do {
        x = _rng.nextDouble() * 2 - 1;
        y = _rng.nextDouble() * 2 - 1;
        z = _rng.nextDouble() * 2 - 1;
      } while (x * x + y * y + z * z > 1);
      x *= restRadius;
      y *= restRadius;
      z *= restRadius;

      _pRestX[i] = x;
      _pRestY[i] = y;
      _pRestZ[i] = z;

      final r = math.sqrt(x * x + y * y + z * z);
      _pRestR[i] = r;
      if (r > 1e-6) {
        _pDirX[i] = x / r;
        _pDirY[i] = y / r;
        _pDirZ[i] = z / r;
      }

      positions[i * 3] = x;
      positions[i * 3 + 1] = y;
      positions[i * 3 + 2] = z;

      // Rest color: dim indigo.
      colors[i * 3] = 0.25;
      colors[i * 3 + 1] = 0.22;
      colors[i * 3 + 2] = 0.45;

      _pPhase[i] = _rng.nextDouble() * math.pi * 2;
      _pFreq[i] = 1.0 + _rng.nextDouble() * 2.0;
    }

    final geo = three.BufferGeometry();
    _particlePosAttr = three.Float32BufferAttribute.fromList(positions, 3);
    _particleColorAttr = three.Float32BufferAttribute.fromList(colors, 3);
    geo.setAttributeFromString('position', _particlePosAttr!);
    geo.setAttributeFromString('color', _particleColorAttr!);
    _particleMat = three.PointsMaterial({
      three.MaterialProperty.size: 0.05,
      three.MaterialProperty.sizeAttenuation: true,
      three.MaterialProperty.vertexColors: true,
      three.MaterialProperty.transparent: true,
      three.MaterialProperty.opacity: 0.85,
    });
    _particles = three.Points(geo, _particleMat!);
    _particles!.frustumCulled = false;
    _scene!.add(_particles!);
  }

  void _tickParticles(double dt) {
    if (_particlePosAttr == null) return;
    if (_particles?.visible == false) return;
    final pos = _particlePosAttr!.array;
    final col = _particleColorAttr!.array;
    final cdt = dt.clamp(0.001, 0.05);

    final speakers = _pendingScene.speakers;

    // Compute total level + rate of change for color mapping.
    var totalLevel = 0.0;
    for (final spk in speakers) {
      totalLevel += spk.level;
    }
    final levelDelta = (totalLevel - _prevTotalLevel) / cdt;
    _prevTotalLevel = totalLevel;
    final slewTarget = levelDelta.clamp(-50.0, 50.0);
    _levelSlew +=
        (slewTarget - _levelSlew) * (slewTarget > _levelSlew ? 0.4 : 0.08);

    // Color temperature from level dynamics.
    final slewNorm = (_levelSlew / 20.0).clamp(-1.0, 1.0);
    const warmR = 1.0, warmG = 0.7, warmB = 0.3;
    const coolR = 0.25, coolG = 0.22, coolB = 0.45;
    const deepR = 0.35, deepG = 0.15, deepB = 0.5;

    double tgtR, tgtG, tgtB;
    if (slewNorm >= 0) {
      tgtR = coolR + (warmR - coolR) * slewNorm;
      tgtG = coolG + (warmG - coolG) * slewNorm;
      tgtB = coolB + (warmB - coolB) * slewNorm;
    } else {
      final t = -slewNorm;
      tgtR = coolR + (deepR - coolR) * t;
      tgtG = coolG + (deepG - coolG) * t;
      tgtB = coolB + (deepB - coolB) * t;
    }

    // Module knobs (null → defaults preserve legacy look).
    final layer = _particlesLayer;
    final intensity = layer?.intensity ?? 1.0;
    final visibleRatio = layer?.visibleRatio ?? 1.0;

    // Visible count scales with total level and the user ratio.
    final levelNorm = (totalLevel / math.max(speakers.length, 1)).clamp(
      0.0,
      1.0,
    );
    final maxVisible = (_maxParticles * visibleRatio).round().clamp(
      0,
      _maxParticles,
    );
    final visibleCount = (levelNorm * maxVisible).round().clamp(0, maxVisible);
    _particles!.geometry!.setDrawRange(0, visibleCount);

    // Pre-compute normalized speaker directions + levels.
    // Avoids redundant sqrt per particle.
    final nSpk = speakers.length;
    if (_spkDirX.length < nSpk) {
      _spkDirX = Float32List(nSpk);
      _spkDirY = Float32List(nSpk);
      _spkDirZ = Float32List(nSpk);
      _spkLevel = Float32List(nSpk);
      _spkR = Float32List(nSpk);
      _spkG = Float32List(nSpk);
      _spkB = Float32List(nSpk);
    }
    final spkDirX = _spkDirX;
    final spkDirY = _spkDirY;
    final spkDirZ = _spkDirZ;
    final spkLevel = _spkLevel;
    final spkR = _spkR;
    final spkG = _spkG;
    final spkB = _spkB;
    for (var s = 0; s < nSpk; s++) {
      final sp = speakers[s];
      // Rewrite the level for every slot — it's the consumer-side gate
      // that makes stale dir/color entries in the reused scratch inert.
      spkLevel[s] = sp.level;
      if (sp.level < 0.01) continue;
      final sx = sp.position.x;
      final sy = sp.position.y;
      final sz = sp.position.z;
      final d = math.sqrt(sx * sx + sy * sy + sz * sz);
      if (d > 1e-6) {
        spkDirX[s] = sx / d;
        spkDirY[s] = sy / d;
        spkDirZ[s] = sz / d;
      } else {
        spkDirX[s] = 0;
        spkDirY[s] = 0;
        spkDirZ[s] = 0;
      }
      final hex = _colorToHex(sp.color);
      spkR[s] = ((hex >> 16) & 0xFF) / 255.0;
      spkG[s] = ((hex >> 8) & 0xFF) / 255.0;
      spkB[s] = (hex & 0xFF) / 255.0;
    }

    // Dipole strain: each speaker stretches the sphere along
    // its direction.  displacement = sum_j [ level_j * stretch
    //   * max(0, dot(particleDir, spkDir))^2 * spkDir ]
    // Plus a uniform radial "breathing" expansion with overall
    // level.  Oscillation adds subtle organic motion.
    final stretchK = 2.0 * intensity;
    final breathK = 0.2 * intensity;
    const oscAmp = 0.008;

    for (var i = 0; i < visibleCount; i++) {
      final si = i * 3;
      final dx = _pDirX[i];
      final dy = _pDirY[i];
      final dz = _pDirZ[i];
      final r = _pRestR[i];

      // Displacement from dipole strain + weighted speaker color.
      var dispX = 0.0, dispY = 0.0, dispZ = 0.0;
      var colAccR = 0.0, colAccG = 0.0, colAccB = 0.0;
      var colWeight = 0.0;
      for (var s = 0; s < nSpk; s++) {
        final lv = spkLevel[s];
        if (lv < 0.01) continue;
        final dot = dx * spkDirX[s] + dy * spkDirY[s] + dz * spkDirZ[s];
        if (dot <= 0) continue;
        final scale = dot * dot * lv * stretchK * (0.15 + r);
        dispX += spkDirX[s] * scale;
        dispY += spkDirY[s] * scale;
        dispZ += spkDirZ[s] * scale;

        // Accumulate color weighted by pull strength.
        final w = dot * dot * lv;
        colAccR += spkR[s] * w;
        colAccG += spkG[s] * w;
        colAccB += spkB[s] * w;
        colWeight += w;
      }

      // Uniform radial breathing.
      final avgLevel = speakers.isEmpty ? 0.0 : totalLevel / speakers.length;
      final breath = avgLevel.clamp(0.0, 1.0) * breathK * (0.1 + r);
      dispX += dx * breath;
      dispY += dy * breath;
      dispZ += dz * breath;

      // Gentle oscillation.
      _pPhase[i] += cdt * _pFreq[i];
      final ph = _pPhase[i];
      dispX += math.sin(ph) * oscAmp;
      dispY += math.cos(ph * 0.7) * oscAmp;
      dispZ += math.sin(ph * 1.3) * oscAmp;

      // Final position.
      pos[si] = _pRestX[i] + dispX;
      pos[si + 1] = _pRestY[i] + dispY;
      pos[si + 2] = _pRestZ[i] + dispZ;

      // Per-particle color: blend rest color toward weighted
      // speaker color based on pull, tinted by level dynamics.
      if (colWeight > 0.01) {
        final inv = 1.0 / colWeight;
        final sr = colAccR * inv;
        final sg = colAccG * inv;
        final sb = colAccB * inv;
        // Mix speaker color with dynamics tint.
        final t = colWeight.clamp(0.0, 1.0);
        col[si] = coolR + (sr * 0.7 + tgtR * 0.3 - coolR) * t;
        col[si + 1] = coolG + (sg * 0.7 + tgtG * 0.3 - coolG) * t;
        col[si + 2] = coolB + (sb * 0.7 + tgtB * 0.3 - coolB) * t;
      } else {
        col[si] = coolR;
        col[si + 1] = coolG;
        col[si + 2] = coolB;
      }
    }

    _particlePosAttr!.needsUpdate = true;
    _particleColorAttr!.needsUpdate = true;
  }

  @override
  void updateScene(RenderableScene scene) {
    _pendingScene = scene;
    if (_initialized) _applyScene(scene);
  }

  void _applyScene(RenderableScene scene) {
    if (_scene == null) return;
    _axesGroup?.visible = scene.showAxes;
    _updateObjects(scene.objects);
    _updateSpeakers(scene.speakers);
    _updateLayers(scene.layers);
  }

  void _updateLayers(List<VizLayer> layers) {
    // Track which layer ids were present this frame so we can hide
    // groups that dropped out (module disabled or no data).
    final seen = <String>{};
    for (final layer in layers) {
      seen.add(layer.id);
      switch (layer) {
        case EnergyShellLayer():
          _updateEnergyShell(layer);
        case CorrelationRibbonLayer():
          _updateRibbons(layer);
        case WavefrontLayer():
          _updateWavefronts(layer);
        case AmbientParticlesLayer():
          _applyParticlesLayer(layer);
        case SoundfieldSphereLayer():
          _updateSoundfieldSphere(layer);
        case IntensityVectorLayer():
          _updateIntensityVectors(layer);
      }
    }
    if (!seen.contains('energy_shell') && _shellMesh != null) {
      _shellMesh!.visible = false;
    }
    if (!seen.contains('corr_ribbons')) _hideRibbons();
    if (!seen.contains('wavefronts')) _hideWavefronts();
    if (!seen.contains('ambient_particles')) {
      _particlesLayer = null;
      _particles?.visible = false;
    }
    if (!seen.contains('soundfield_sphere')) _hideSoundfieldSphere();
    if (!seen.contains('intensity_vector')) _hideIntensityVectors();
  }

  void _applyParticlesLayer(AmbientParticlesLayer layer) {
    _particlesLayer = layer;
    _particles?.visible = true;
    // Apply static material properties immediately; dynamics (draw
    // range, per-particle displacement) are applied in _tickParticles.
    final mat = _particleMat;
    if (mat != null) {
      mat.opacity = layer.opacity;
      mat.size = layer.pointSize;
    }
  }

  void _updateEnergyShell(EnergyShellLayer layer) {
    final group = _layerGroups.putIfAbsent(layer.id, () {
      final g = three.Group();
      _scene!.add(g);
      return g;
    });

    final nVerts = layer.vertices.length;
    final nFaces = layer.faces.length;
    final topologyChanged =
        _shellMesh == null ||
        nVerts != _shellVertexCount ||
        nFaces != _shellFaceCount;

    if (topologyChanged) {
      // Drop old mesh if topology changed (e.g. subdivision slider).
      if (_shellMesh != null) {
        group.remove(_shellMesh!);
        _shellMesh!.geometry?.dispose();
        _shellMesh!.material?.dispose();
      }

      // Build geometry with duplicated vertices per face so each face
      // can carry its own colors without smoothing across shared edges.
      final positions = Float32List(nFaces * 9);
      final colors = Float32List(nFaces * 9);
      _shellPosAttr = three.Float32BufferAttribute.fromList(positions, 3);
      _shellColorAttr = three.Float32BufferAttribute.fromList(colors, 3);
      final geo = three.BufferGeometry();
      geo.setAttributeFromString('position', _shellPosAttr!);
      geo.setAttributeFromString('color', _shellColorAttr!);
      _shellMaterial = three.MeshBasicMaterial({
        three.MaterialProperty.vertexColors: true,
        three.MaterialProperty.transparent: true,
        three.MaterialProperty.opacity: layer.alpha,
        three.MaterialProperty.depthWrite: false,
      });
      _shellMesh = three.Mesh(geo, _shellMaterial!);
      _shellMesh!.frustumCulled = false;
      group.add(_shellMesh!);
      _shellVertexCount = nVerts;
      _shellFaceCount = nFaces;
    }

    _shellMesh!.visible = true;
    _shellMaterial!.opacity = layer.alpha;

    final pos = _shellPosAttr!.array;
    final col = _shellColorAttr!.array;
    final base = layer.baseRadius;
    for (var fi = 0; fi < nFaces; fi++) {
      final (a, b, c) = layer.faces[fi];
      final idxs = [a, b, c];
      for (var k = 0; k < 3; k++) {
        final vi = idxs[k];
        final v = layer.vertices[vi];
        final r = base + layer.displacement[vi];
        final off = fi * 9 + k * 3;
        pos[off] = v.x * r;
        pos[off + 1] = v.y * r;
        pos[off + 2] = v.z * r;
        final color = layer.vertexColors[vi];
        col[off] = color.r;
        col[off + 1] = color.g;
        col[off + 2] = color.b;
      }
    }
    _shellPosAttr!.needsUpdate = true;
    _shellColorAttr!.needsUpdate = true;
  }

  // ── Correlation ribbons ────────────────────────────────────────────

  void _updateRibbons(CorrelationRibbonLayer layer) {
    final group = _layerGroups.putIfAbsent('corr_ribbons', () {
      final g = three.Group();
      _scene!.add(g);
      return g;
    });

    final nRibbons = layer.ribbons.length;
    final segments = layer.segments.clamp(4, 64);

    // Ensure pool has enough lines and matches the segment count.
    final segmentsChanged = segments != _ribbonSegments;
    if (segmentsChanged) {
      // Topology change — dispose the pool.
      for (final line in _ribbonLines) {
        group.remove(line);
        line.geometry?.dispose();
      }
      for (final mat in _ribbonMaterials) {
        mat.dispose();
      }
      _ribbonLines.clear();
      _ribbonMaterials.clear();
      _ribbonSegments = segments;
    }
    while (_ribbonLines.length < nRibbons) {
      final positions = Float32List(segments * 3);
      final geo = three.BufferGeometry();
      geo.setAttributeFromString(
        'position',
        three.Float32BufferAttribute.fromList(positions, 3),
      );
      final mat = three.LineBasicMaterial({
        three.MaterialProperty.color: three.Color.fromHex32(0xFFFFFFFF),
        three.MaterialProperty.transparent: true,
        three.MaterialProperty.opacity: 0.0,
        three.MaterialProperty.depthWrite: false,
      });
      final line = three.Line(geo, mat);
      line.frustumCulled = false;
      _ribbonLines.add(line);
      _ribbonMaterials.add(mat);
      group.add(line);
    }
    // Trim the pool if it has grown well past what we currently need,
    // so GPU buffers for transient spikes in ribbon count get released.
    // Threshold is 2× with a small minimum to avoid thrashing.
    final ribbonTrim = math.max(8, nRibbons * 2);
    while (_ribbonLines.length > ribbonTrim) {
      final line = _ribbonLines.removeLast();
      final mat = _ribbonMaterials.removeLast();
      group.remove(line);
      line.geometry?.dispose();
      mat.dispose();
    }
    // Hide any surplus lines still in the pool.
    for (var i = nRibbons; i < _ribbonLines.length; i++) {
      _ribbonLines[i].visible = false;
    }

    final curvature = layer.curvature;
    for (var i = 0; i < nRibbons; i++) {
      final r = layer.ribbons[i];
      final line = _ribbonLines[i]..visible = true;
      final mat = _ribbonMaterials[i];
      mat.color = three.Color.fromHex32(_colorToHex(r.color));
      mat.opacity = r.alpha;

      // Quadratic bezier: p(t) = (1-t)² a + 2(1-t)t c + t² b.
      // c = midpoint ± curvature * midDir. Positive corr pulls through
      // origin; negative pushes outward.
      final midX = (r.a.x + r.b.x) * 0.5;
      final midY = (r.a.y + r.b.y) * 0.5;
      final midZ = (r.a.z + r.b.z) * 0.5;
      final midLen = math.sqrt(midX * midX + midY * midY + midZ * midZ);
      double ndx = 0, ndy = 0, ndz = 0;
      if (midLen > 1e-6) {
        ndx = midX / midLen;
        ndy = midY / midLen;
        ndz = midZ / midLen;
      }
      final offset = r.curvatureSign >= 0 ? -curvature : curvature;
      final cX = midX + ndx * offset;
      final cY = midY + ndy * offset;
      final cZ = midZ + ndz * offset;

      final attr =
          line.geometry!.getAttributeFromString('position')!
              as three.Float32BufferAttribute;
      final arr = attr.array;
      for (var s = 0; s < segments; s++) {
        final t = s / (segments - 1);
        final u = 1 - t;
        final px = u * u * r.a.x + 2 * u * t * cX + t * t * r.b.x;
        final py = u * u * r.a.y + 2 * u * t * cY + t * t * r.b.y;
        final pz = u * u * r.a.z + 2 * u * t * cZ + t * t * r.b.z;
        arr[s * 3] = px;
        arr[s * 3 + 1] = py;
        arr[s * 3 + 2] = pz;
      }
      attr.needsUpdate = true;
    }
  }

  void _hideRibbons() {
    for (final line in _ribbonLines) {
      line.visible = false;
    }
  }

  // ── Transient wavefronts ──────────────────────────────────────────

  void _updateWavefronts(WavefrontLayer layer) {
    final group = _layerGroups.putIfAbsent('wavefronts', () {
      final g = three.Group();
      _scene!.add(g);
      return g;
    });

    final n = layer.pulses.length;
    while (_wavefrontMeshes.length < n) {
      final geo = three.SphereGeometry(
        1.0,
        _wavefrontSphereSegments,
        _wavefrontSphereSegments,
      );
      // The colour is the element's, set per frame in _updateWavefronts,
      // which also keeps the blending in step with the theme.
      final mat = three.MeshBasicMaterial({
        three.MaterialProperty.color: three.Color.fromHex32(0xFFFFFFFF),
        three.MaterialProperty.transparent: true,
        three.MaterialProperty.opacity: 0.0,
        three.MaterialProperty.depthWrite: false,
        three.MaterialProperty.blending: _wavefrontBlending,
        three.MaterialProperty.wireframe: true,
      });
      final mesh = three.Mesh(geo, mat);
      mesh.frustumCulled = false;
      _wavefrontMeshes.add(mesh);
      _wavefrontMaterials.add(mat);
      group.add(mesh);
    }
    // Trim surplus sphere meshes when the active pulse count drops —
    // SphereGeometry holds GPU buffers, so an unbounded high-water
    // mark would leak VRAM after a loud session.
    final wavefrontTrim = math.max(16, n * 2);
    while (_wavefrontMeshes.length > wavefrontTrim) {
      final mesh = _wavefrontMeshes.removeLast();
      final mat = _wavefrontMaterials.removeLast();
      group.remove(mesh);
      mesh.geometry?.dispose();
      mat.dispose();
    }
    for (var i = n; i < _wavefrontMeshes.length; i++) {
      _wavefrontMeshes[i].visible = false;
    }

    // The pool outlives a theme switch, so the blending is checked
    // per frame rather than fixed at creation.
    final blending = _wavefrontBlending;
    for (var i = 0; i < n; i++) {
      final w = layer.pulses[i];
      final mesh = _wavefrontMeshes[i]..visible = true;
      final mat = _wavefrontMaterials[i];
      if (mat.blending != blending) {
        mat.blending = blending;
        mat.needsUpdate = true;
      }
      mat.color = three.Color.fromHex32(_colorToHex(w.color));
      mat.opacity = w.alpha;
      mesh.position.setValues(w.origin.x, w.origin.y, w.origin.z);
      final s = math.max(0.001, w.radius);
      mesh.scale.setValues(s, s, s);
    }
  }

  /// Additive blending makes overlapping pulses brighten over a dark
  /// ground; over Light's ground additive colour vanishes, so the
  /// pulses blend normally there.
  int get _wavefrontBlending => T.brightness == Brightness.light
      ? three.NormalBlending
      : three.AdditiveBlending;

  void _hideWavefronts() {
    for (final mesh in _wavefrontMeshes) {
      mesh.visible = false;
    }
  }

  void _updateObjects(List<RenderableObject> objects) {
    // Remove meshes whose IDs are no longer present.
    final activeIds = objects.map((o) => o.id).toSet();
    final toRemove = _objectMeshes.keys
        .where((id) => !activeIds.contains(id))
        .toList();
    for (final id in toRemove) {
      _objectGroup!.remove(_objectMeshes[id]!);
      _objectMeshes.remove(id);
    }

    for (final obj in objects) {
      var mesh = _objectMeshes[obj.id];

      if (mesh == null) {
        final geo = three.SphereGeometry(obj.radius, 16, 16);
        final mat = three.MeshPhongMaterial({
          three.MaterialProperty.color: three.Color.fromHex32(
            _colorToHex(obj.color),
          ),
        });
        mesh = three.Mesh(geo, mat);
        _objectMeshes[obj.id] = mesh;
        _objectGroup!.add(mesh);
      }

      mesh.position.setValues(obj.position.x, obj.position.y, obj.position.z);
      final s = obj.radius / 0.08;
      mesh.scale.setValues(s, s, s);

      final mat = mesh.material as three.MeshPhongMaterial;
      mat.color = three.Color.fromHex32(_colorToHex(obj.color));
    }
  }

  void _updateSpeakers(List<RenderableSpeaker> speakers) {
    final toRemove = _speakerMeshes.keys
        .where((id) => id >= speakers.length)
        .toList();
    for (final id in toRemove) {
      _speakerGroup!.remove(_speakerMeshes[id]!);
      _speakerMeshes.remove(id);
    }

    for (var i = 0; i < speakers.length; i++) {
      final spk = speakers[i];
      var mesh = _speakerMeshes[i];

      if (mesh == null) {
        final geo = _buildSpeakerGeo(spk.width, spk.height, spk.depth);
        final mat = three.MeshPhongMaterial({
          three.MaterialProperty.color: three.Color.fromHex32(
            _colorToHex(spk.color),
          ),
          three.MaterialProperty.flatShading: true,
        });
        mesh = three.Mesh(geo, mat);
        _speakerMeshes[i] = mesh;
        _speakerGroup!.add(mesh);
      }

      mesh.position.setValues(spk.position.x, spk.position.y, spk.position.z);
      mesh.lookAt(three.Vector3.zero());

      final mat = mesh.material as three.MeshPhongMaterial;
      mat.color = three.Color.fromHex32(_colorToHex(spk.color));
    }
  }

  /// Procedural speaker cabinet: solid box with face normals.
  ///
  /// The mesh faces -Z in local space so that [lookAt] orients
  /// the front face toward the origin.
  static three.BufferGeometry _buildSpeakerGeo(double w, double h, double d) {
    final hw = w / 2;
    final hh = h / 2;
    final hd = d / 2;

    //        Front (-Z)          Back (+Z)
    //   3 ---- 2            7 ---- 6
    //   |      |            |      |
    //   0 ---- 1            4 ---- 5
    final verts = <List<double>>[
      [-hw, -hh, -hd], // 0 front-bottom-left
      [hw, -hh, -hd], // 1 front-bottom-right
      [hw, hh, -hd], // 2 front-top-right
      [-hw, hh, -hd], // 3 front-top-left
      [-hw, -hh, hd], // 4 back-bottom-left
      [hw, -hh, hd], // 5 back-bottom-right
      [hw, hh, hd], // 6 back-top-right
      [-hw, hh, hd], // 7 back-top-left
    ];

    // 6 faces × 2 triangles each, CCW winding + precomputed
    // normals (axis-aligned box).
    final faceData = <(List<int>, List<double>)>[
      ([0, 1, 2, 0, 2, 3], [0, 0, -1]), // front
      ([5, 4, 7, 5, 7, 6], [0, 0, 1]), // back
      ([4, 0, 3, 4, 3, 7], [-1, 0, 0]), // left
      ([1, 5, 6, 1, 6, 2], [1, 0, 0]), // right
      ([3, 2, 6, 3, 6, 7], [0, 1, 0]), // top
      ([4, 5, 1, 4, 1, 0], [0, -1, 0]), // bottom
    ];

    final positions = <double>[];
    final normals = <double>[];

    for (final (indices, normal) in faceData) {
      for (final idx in indices) {
        positions.addAll(verts[idx]);
        normals.addAll(normal);
      }
    }

    final geo = three.BufferGeometry();
    geo.setAttributeFromString(
      'position',
      three.Float32BufferAttribute.fromList(positions, 3),
    );
    geo.setAttributeFromString(
      'normal',
      three.Float32BufferAttribute.fromList(normals, 3),
    );
    return geo;
  }

  void _updateSoundfieldSphere(SoundfieldSphereLayer sf) {
    final topologyChanged =
        sf.faces.length != _sfFaceCount ||
        sf.radius != _sfRadius ||
        sf.showWireframe != _sfHasWireframe ||
        (T.brightness == Brightness.light) != _sfLight;

    if (topologyChanged || _sfMesh == null) {
      _clearSoundfield();
      _buildSoundfieldMesh(sf);
    }

    _sfMesh!.visible = true;

    final arr = _sfColorAttr!.array;
    for (var fi = 0; fi < sf.faces.length; fi++) {
      final col = sf.faceColors[fi];
      final r = col.r;
      final g = col.g;
      final b = col.b;
      final base = fi * 9;
      arr[base] = r;
      arr[base + 1] = g;
      arr[base + 2] = b;
      arr[base + 3] = r;
      arr[base + 4] = g;
      arr[base + 5] = b;
      arr[base + 6] = r;
      arr[base + 7] = g;
      arr[base + 8] = b;
    }
    _sfColorAttr!.needsUpdate = true;
    _sfMaterial!.opacity = sf.alpha;
  }

  void _hideSoundfieldSphere() {
    _sfMesh?.visible = false;
    for (final child in _soundfieldGroup!.children) {
      if (child is three.LineSegments) child.visible = false;
    }
  }

  void _clearSoundfield() {
    for (final child in _soundfieldGroup!.children.toList()) {
      _soundfieldGroup!.remove(child);
      if (child is three.Mesh) {
        child.geometry?.dispose();
        child.material?.dispose();
      } else if (child is three.LineSegments) {
        child.geometry?.dispose();
        child.material?.dispose();
      }
    }
    _sfMesh = null;
    _sfMaterial = null;
    _sfColorAttr = null;
    _sfFaceCount = 0;
    _sfRadius = 0;
    _sfHasWireframe = false;
  }

  void _buildSoundfieldMesh(SoundfieldSphereLayer sf) {
    final nFaces = sf.faces.length;
    final positions = <double>[];
    final colors = <double>[];
    for (var fi = 0; fi < nFaces; fi++) {
      final (a, b, c) = sf.faces[fi];
      for (final idx in [a, b, c]) {
        final v = sf.vertices[idx];
        positions.addAll([v.x * sf.radius, v.y * sf.radius, v.z * sf.radius]);
        final col = sf.faceColors[fi];
        colors.addAll([col.r, col.g, col.b]);
      }
    }
    final geo = three.BufferGeometry();
    geo.setAttributeFromString(
      'position',
      three.Float32BufferAttribute.fromList(positions, 3),
    );
    _sfColorAttr = three.Float32BufferAttribute.fromList(colors, 3);
    geo.setAttributeFromString('color', _sfColorAttr!);
    _sfMaterial = three.MeshBasicMaterial({
      three.MaterialProperty.vertexColors: true,
      three.MaterialProperty.transparent: true,
      three.MaterialProperty.opacity: sf.alpha,
      three.MaterialProperty.depthWrite: false,
    });
    _sfMesh = three.Mesh(geo, _sfMaterial!);
    _soundfieldGroup!.add(_sfMesh!);
    _sfFaceCount = nFaces;
    _sfRadius = sf.radius;
    if (sf.showWireframe) {
      _addWireframeLines(sf);
      _sfHasWireframe = true;
    }
  }

  void _addWireframeLines(SoundfieldSphereLayer sf) {
    final positions = <double>[];
    final edgeSet = <int>{};
    for (final (a, b, c) in sf.faces) {
      for (final (i, j) in [(a, b), (b, c), (c, a)]) {
        // Key encoding: safe for vertex counts < 100k (icosahedron
        // subdivision 3 has ~2562 vertices).
        final key = i < j ? i * 100000 + j : j * 100000 + i;
        if (edgeSet.add(key)) {
          final va = sf.vertices[i];
          final vb = sf.vertices[j];
          positions.addAll([
            va.x * sf.radius,
            va.y * sf.radius,
            va.z * sf.radius,
            vb.x * sf.radius,
            vb.y * sf.radius,
            vb.z * sf.radius,
          ]);
        }
      }
    }
    final geo = three.BufferGeometry();
    geo.setAttributeFromString(
      'position',
      three.Float32BufferAttribute.fromList(positions, 3),
    );
    // White at 20% over a dark ground; the body ink at 35% over
    // Light's, where white does not read.
    final light = T.brightness == Brightness.light;
    _sfLight = light;
    final mat = three.LineBasicMaterial({
      three.MaterialProperty.color: three.Color.fromHex32(
        light ? T.textPrimary.toARGB32() : 0x20FFFFFF,
      ),
      three.MaterialProperty.transparent: true,
      three.MaterialProperty.opacity: light ? 0.35 : 0.2,
      three.MaterialProperty.depthWrite: false,
    });
    _soundfieldGroup!.add(three.LineSegments(geo, mat));
  }

  // ── Intensity vector ──────────────────────────────────────────────

  final List<three.Mesh> _intensityShafts = [];
  final List<three.Mesh> _intensityTips = [];
  final List<three.MeshBasicMaterial> _intensityMats = [];

  void _updateIntensityVectors(IntensityVectorLayer layer) {
    final group = _layerGroups.putIfAbsent('intensity_vector', () {
      final g = three.Group();
      _scene!.add(g);
      return g;
    });

    final n = layer.arrows.length;
    // Grow pool.
    while (_intensityShafts.length < n) {
      final shaftGeo = three.CylinderGeometry(1.0, 1.0, 1.0, 12, 1, true);
      final tipGeo = three.ConeGeometry(1.0, 1.0, 12);
      final mat = three.MeshBasicMaterial({
        three.MaterialProperty.color: three.Color.fromHex32(0xFFFFFFFF),
        three.MaterialProperty.transparent: true,
        three.MaterialProperty.opacity: 1.0,
        three.MaterialProperty.depthWrite: false,
      });
      final shaft = three.Mesh(shaftGeo, mat);
      final tip = three.Mesh(tipGeo, mat);
      shaft.frustumCulled = false;
      tip.frustumCulled = false;
      _intensityShafts.add(shaft);
      _intensityTips.add(tip);
      _intensityMats.add(mat);
      group.add(shaft);
      group.add(tip);
    }
    // Trim surplus arrows when the scene element count drops — usually
    // only 1–2 arrows are active but the pool could have grown briefly.
    final intensityTrim = math.max(4, n * 2);
    while (_intensityShafts.length > intensityTrim) {
      final shaft = _intensityShafts.removeLast();
      final tip = _intensityTips.removeLast();
      final mat = _intensityMats.removeLast();
      group.remove(shaft);
      group.remove(tip);
      shaft.geometry?.dispose();
      tip.geometry?.dispose();
      mat.dispose();
    }
    for (var i = n; i < _intensityShafts.length; i++) {
      _intensityShafts[i].visible = false;
      _intensityTips[i].visible = false;
    }

    for (var i = 0; i < n; i++) {
      final a = layer.arrows[i];
      final shaft = _intensityShafts[i]..visible = true;
      final tip = _intensityTips[i]..visible = true;
      final mat = _intensityMats[i];
      mat.color = three.Color.fromHex32(_colorToHex(a.color));
      mat.opacity = a.alpha;

      final dirX = a.tip.x - a.origin.x;
      final dirY = a.tip.y - a.origin.y;
      final dirZ = a.tip.z - a.origin.z;
      final len = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ);
      if (len < 1e-6) {
        shaft.visible = false;
        tip.visible = false;
        continue;
      }

      final tipLen = math.min(0.12, len * 0.25);
      final shaftLen = len - tipLen;
      // Cylinders are built along +Y — rotate default +Y onto direction.
      final dir = three.Vector3(dirX, dirY, dirZ)..normalize();
      final up = three.Vector3(0, 1, 0);
      final quat = three.Quaternion()..setFromUnitVectors(up, dir);

      shaft.quaternion.setFrom(quat);
      shaft.position.setValues(
        a.origin.x + dir.x * shaftLen * 0.5,
        a.origin.y + dir.y * shaftLen * 0.5,
        a.origin.z + dir.z * shaftLen * 0.5,
      );
      shaft.scale.setValues(a.thickness, shaftLen, a.thickness);

      tip.quaternion.setFrom(quat);
      tip.position.setValues(
        a.origin.x + dir.x * (shaftLen + tipLen * 0.5),
        a.origin.y + dir.y * (shaftLen + tipLen * 0.5),
        a.origin.z + dir.z * (shaftLen + tipLen * 0.5),
      );
      tip.scale.setValues(a.thickness * 2.4, tipLen, a.thickness * 2.4);
    }
  }

  void _hideIntensityVectors() {
    for (final m in _intensityShafts) {
      m.visible = false;
    }
    for (final m in _intensityTips) {
      m.visible = false;
    }
  }

  void _updateCameraRotation() {
    final s = _camera?.matrixWorldInverse.storage;
    if (s == null) return;
    // Column-major 3x3: indices 0,1,2, 4,5,6, 8,9,10
    final cur = cameraRotationNotifier.value;
    const eps = 1e-4;
    if ((s[0] - cur[0]).abs() < eps &&
        (s[1] - cur[1]).abs() < eps &&
        (s[2] - cur[2]).abs() < eps &&
        (s[4] - cur[3]).abs() < eps &&
        (s[5] - cur[4]).abs() < eps &&
        (s[6] - cur[5]).abs() < eps &&
        (s[8] - cur[6]).abs() < eps &&
        (s[9] - cur[7]).abs() < eps &&
        (s[10] - cur[8]).abs() < eps) {
      return;
    }
    cameraRotationNotifier.value = [
      s[0],
      s[1],
      s[2],
      s[4],
      s[5],
      s[6],
      s[8],
      s[9],
      s[10],
    ];
  }

  /// Snap camera to a named preset position.
  void setCameraPreset(CameraPreset preset) {
    if (_camera == null || _controls == null) return;
    switch (preset) {
      case CameraPreset.top:
        _camera!.position.setValues(0, 5, 0.01);
      case CameraPreset.front:
        _camera!.position.setValues(0, 0.5, 4);
      case CameraPreset.perspective:
        _camera!.position.setValues(0, 2, 4);
    }
    _controls!.target.setValues(0, 0, 0);
    _controls!.update();
    _updateCameraRotation();
  }

  @override
  void setCamera(double azRad, double elRad, double distance) {
    // Orbit controls handle camera
  }

  @override
  void dispose() {
    if (_initialized) {
      _threeJs.dispose();
    }
    cameraRotationNotifier.dispose();
    _objectMeshes.clear();
    _speakerMeshes.clear();
    _initialized = false;
  }

  static int _colorToHex(ui.Color color) {
    final r = (color.r * 255.0).round().clamp(0, 255);
    final g = (color.g * 255.0).round().clamp(0, 255);
    final b = (color.b * 255.0).round().clamp(0, 255);
    return 0xFF000000 | (r << 16) | (g << 8) | b;
  }
}

/// Defers ThreeJS init until layout size is known.
class _ThreeJsWidget extends StatefulWidget {
  final ThreeJsRenderer renderer;
  const _ThreeJsWidget({super.key, required this.renderer});

  @override
  State<_ThreeJsWidget> createState() => _ThreeJsWidgetState();
}

class _ThreeJsWidgetState extends State<_ThreeJsWidget> {
  bool _glInitStarted = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    widget.renderer.onReady = () {
      if (mounted) setState(() => _ready = true);
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_glInitStarted) {
          _glInitStarted = true;
          widget.renderer.initWithSize(
            Size(constraints.maxWidth, constraints.maxHeight),
          );
        } else {
          widget.renderer.updateAspect(
            constraints.maxWidth,
            constraints.maxHeight,
          );
        }
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Stack(
            children: [
              Positioned.fill(child: widget.renderer.buildInnerWidget()),
              if (!_ready)
                Positioned.fill(
                  child: ColoredBox(
                    color: T.bgDeep,
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: T.purpleLight,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    widget.renderer.onReady = null;
    super.dispose();
  }
}
