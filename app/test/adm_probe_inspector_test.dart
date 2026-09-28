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

import 'dart:convert';
import 'dart:math' as math;

import 'package:eclipsa_studio/import/adm_probe_inspector.dart';
import 'package:eclipsa_studio/renderer/speaker_layout.dart';
import 'package:eclipsa_studio/util/time_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

/// Tests for the ADM probe inspector (ES-448): the defensive probe-JSON decode
/// and the pane's widget layout at its dialog width.

const _probeJson = '''
{
  "ok": true,
  "format": {
    "channels": 4, "sample_rate": 48000, "bits_per_sample": 24,
    "is_float": false, "num_frames": 96000, "duration_s": 2.0
  },
  "scene": {
    "sources": [
      {"label": "L", "lfe": false, "azimuth": 30, "elevation": 0,
       "distance": 1, "gain": 1, "track": 1,
       "resolution": {"method": "polar", "resolved": true,
                      "fallback": false, "note": ""}},
      {"label": "LFE", "lfe": true, "azimuth": 0, "elevation": 0,
       "distance": 1, "gain": 0.5, "track": 2,
       "resolution": {"method": "lfe_label", "resolved": true,
                      "fallback": false, "note": ""}},
      {"label": "Vend", "lfe": false, "azimuth": -110, "elevation": 0,
       "distance": 1, "gain": 1, "track": 3, "spread": 22.01,
       "resolution": {"method": "cube_slot", "resolved": true,
                      "fallback": true, "note": "cube corner matched"}}
    ],
    "objects": [
      {"label": "mover", "track": 4, "importance": 10, "blocks": 3,
       "azimuth": 30, "elevation": 0, "distance": 1,
       "trajectory": [[30, 0, 1], [0, 15, 1], [-30, 0, 1]]},
      {"label": "parked", "track": 5, "importance": 10, "blocks": 1,
       "azimuth": 0, "elevation": 45, "distance": 1, "spread": 41.76}
    ],
    "unresolved_channels": [
      {"id": "AC_9", "name": "Mystery", "reason": "no usable position"}
    ],
    "trajectory_objects_dropped": 2
  }
}
''';

/// Objects covering the three cases the hull projection has to distinguish
/// (ES-635): a cartesian-authored object whose `distance` is not a radius, a
/// polar-authored one whose distance is, and one that converts below 7.1.4's
/// mid ring. The mover's path also takes a 190° azimuth step, which the
/// painter must subdivide along the great circle rather than chord through
/// the scene.
///
/// Every `spread` here is what `ImageSpreadMeter` reports for that position
/// on 7.1.4 (ES-640), so the widths the rows print are the real ones: 55.6°
/// for the cube object at distance 0.5, 18.6° for the polar object at 0.75,
/// and 6.0° rising to 42.1° along the below-ring mover's path.
const _hullProbeJson = '''
{
  "ok": true,
  "format": {
    "channels": 3, "sample_rate": 48000, "bits_per_sample": 24,
    "is_float": false, "num_frames": 48000, "duration_s": 1.0
  },
  "scene": {
    "sources": [],
    "objects": [
      {"label": "cube", "track": 1, "importance": 10, "blocks": 1,
       "azimuth": 30, "elevation": 0, "distance": 0.5, "spread": 55.64,
       "cartesian": true, "x": 0.5, "y": 0.5, "z": 0},
      {"label": "under", "track": 2, "importance": 10, "blocks": 2,
       "azimuth": 0, "elevation": -20, "distance": 1, "cartesian": false,
       "spread": 5.98, "start_s": 0.25, "end_s": 0.75,
       "trajectory": [[0, -20, 1, 0.25, 5.98], [190, -10, 1, 0.75, 42.13]]},
      {"label": "polar", "track": 3, "importance": 10, "blocks": 1,
       "azimuth": -30, "elevation": 0, "distance": 0.75, "cartesian": false,
       "spread": 18.63},
      {"label": "centre", "track": 4, "importance": 10, "blocks": 1,
       "azimuth": 0, "elevation": 0, "distance": 0, "cartesian": true,
       "x": 0, "y": 0, "z": 0, "spread": 88.2}
    ],
    "unresolved_channels": []
  }
}
''';

/// One moving object whose image starts as a flat horizontal smear and ends
/// round, so the interpolation of both shape fields is visible.
const _shapeProbeJson = '''
{
  "ok": true,
  "format": {
    "channels": 1, "sample_rate": 48000, "bits_per_sample": 24,
    "is_float": false, "num_frames": 48000, "duration_s": 1.0
  },
  "scene": {
    "sources": [],
    "objects": [
      {"label": "mover", "track": 1, "importance": 10, "blocks": 2,
       "azimuth": 0, "elevation": 0, "distance": 1, "cartesian": false,
       "spread": 20, "spread_ratio": 0, "spread_tilt": 0,
       "start_s": 0, "end_s": 1,
       "trajectory": [[0, 0, 1, 0, 20, 0, 0], [0, 30, 1, 1, 40, 1, 90]]}
    ],
    "unresolved_channels": []
  }
}
''';

void main() {
  group('AdmProbeData.decode', () {
    test('decodes format, sources, objects and unresolved channels', () {
      final data = AdmProbeData.decode(
        jsonDecode(_probeJson) as Map<String, dynamic>,
      );

      expect(data.channels, 4);
      expect(data.sampleRate, 48000);
      expect(data.bitsPerSample, 24);
      expect(data.isFloat, false);
      expect(data.durationS, 2.0);

      expect(data.sources, hasLength(3));
      expect(data.sources[0].label, 'L');
      expect(data.sources[0].azimuth, 30);
      expect(data.sources[0].fallback, false);
      // L sits on a 7.1.4 speaker, so the probe emits no width for it and
      // the row draws no halo.
      expect(data.sources[0].spread, 0);
      expect(data.sources[1].isLfe, true);
      expect(data.sources[1].gain, 0.5);
      expect(data.sources[2].fallback, true);
      expect(data.sources[2].note, 'cube corner matched');
      expect(data.sources[2].spread, 22.01);

      expect(data.objects, hasLength(2));
      expect(data.objects[0].moves, true);
      expect(data.objects[0].trajectory, hasLength(3));
      // Three-element vertices predate the scrubber and the measured image:
      // they decode with t = 0, no width, and the round shape the halo used
      // to be drawn at, rather than being dropped, so an older probe still
      // draws its paths.
      expect(data.objects[0].trajectory[1], (
        az: 0.0,
        el: 15.0,
        dist: 1.0,
        t: 0.0,
        spread: 0.0,
        ratio: 1.0,
        tilt: 0.0,
        focus: 1.0,
      ));
      expect(data.objects[1].moves, false);
      expect(data.objects[1].trajectory, isEmpty);
      expect(data.objects[1].spread, 41.76);

      expect(data.unresolved, hasLength(1));
      expect(data.unresolved[0].name, 'Mystery');
      expect(data.unresolved[0].reason, 'no usable position');

      expect(data.trajectoryObjectsDropped, 2);
    });

    test('malformed or missing fields degrade instead of throwing', () {
      // Nothing usable at all.
      final empty = AdmProbeData.decode(const {'ok': true});
      expect(empty.channels, 0);
      expect(empty.trajectoryObjectsDropped, 0);
      expect(empty.sources, isEmpty);
      expect(empty.objects, isEmpty);
      expect(empty.unresolved, isEmpty);

      // Wrong types everywhere: entries are skipped or zeroed, never thrown.
      final mangled = AdmProbeData.decode(const {
        'format': 'not-a-map',
        'scene': {
          'sources': [1, 'two', {}],
          'objects': [
            {'label': 3, 'trajectory': 'nope'},
            {
              'label': 'ok',
              'trajectory': [
                [1, 2],
                'x',
                [3, 4, 5],
              ],
            },
          ],
          'unresolved_channels': [null, {}],
        },
      });
      expect(mangled.channels, 0);
      // The `{}` source decodes to an all-defaults row rather than dropping —
      // a present-but-empty entry still represents a channel.
      expect(mangled.sources, hasLength(1));
      expect(mangled.objects, hasLength(2));
      // Short or non-list trajectory points are skipped.
      expect(mangled.objects[0].trajectory, isEmpty);
      expect(mangled.objects[1].trajectory, hasLength(1));
      expect(mangled.unresolved, hasLength(1));
    });

    test('decodes the authored cube and flags below-ring objects', () {
      final data = AdmProbeData.decode(
        jsonDecode(_hullProbeJson) as Map<String, dynamic>,
      );

      final cube = data.objects[0];
      expect(cube.cartesian, true);
      expect((cube.x, cube.y, cube.z), (0.5, 0.5, 0.0));
      // Its own converted elevation is on the ring, and it has no path.
      expect(cube.belowRing, false);

      // The marker's elevation is below the ring, and so is a path vertex.
      expect(data.objects[1].cartesian, false);
      expect(data.objects[1].belowRing, true);

      // Polar-authored, on the ring: neither flag.
      expect(data.objects[2].cartesian, false);
      expect(data.objects[2].belowRing, false);
      expect(data.objects[2].distance, 0.75);
    });

    test('an object with no cube fields degrades to polar, not to origin', () {
      final data = AdmProbeData.decode(const {
        'scene': {
          'objects': [
            {'label': 'legacy', 'azimuth': 10, 'elevation': 5, 'distance': 1},
          ],
        },
      });
      // A probe predating the cube fields must not read as a cartesian
      // object parked at the centre of the room.
      expect(data.objects.single.cartesian, false);
      expect(data.objects.single.x, 0);
    });
  });

  group('admHullElevation', () {
    test('floors below the mid ring and never caps above it', () {
      // 7.1.4 has no speakers under the mid ring: the render collapses these
      // to 0°, so the preview draws them there.
      expect(admHullElevation(-90), 0);
      expect(admHullElevation(-0.1), 0);
      expect(admHullElevation(0), 0);
      // Above the ring is left alone: driving the four top speakers together
      // images above them, all the way to the zenith.
      expect(admHullElevation(30), 30);
      expect(admHullElevation(86.1), 86.1);
      expect(admHullElevation(90), 90);
    });
  });

  group('image spread', () {
    // The width itself is measured in C++ — image_spread_test.cc pins it
    // against RenderChannelBed's own gain vectors — and arrives per source,
    // per object and per trajectory vertex in the probe JSON (ES-640). These
    // pin what the preview does with the figure once it has it.
    test('the halo is drawn at the measured radius, capped at a '
        'hemisphere', () {
      expect(admHaloRadiusDeg(0), 0);
      // A phantom between two speakers 30° apart, and the whole mid ring
      // driven evenly from its centre: both drawn at what they measure.
      expect(admHaloRadiusDeg(9.2), 9.2);
      expect(admHaloRadiusDeg(88.2), 88.2);
      // Past a hemisphere a wider cap says nothing a full one does not.
      expect(admHaloRadiusDeg(104.8), 90);
      expect(admHaloRadiusDeg(-1), 0);
    });

    test('drawing weight rises from a point image to a hemisphere', () {
      expect(admSpreadWeight(0), 0);
      // A front phantom draws at a tenth of the weight of a fully diffuse
      // mark, which is what keeps an ordinary master legible.
      expect(admSpreadWeight(9), closeTo(0.1, 1e-9));
      expect(admSpreadWeight(45), closeTo(0.5, 1e-9));
      expect(admSpreadWeight(90), 1.0);
      expect(admSpreadWeight(104.8), 1.0);
    });

    test('an object image width follows the scrubber between vertices', () {
      final data = AdmProbeData.decode(
        jsonDecode(_hullProbeJson) as Map<String, dynamic>,
      );
      final under = data.objects[1];
      expect(admObjectSpreadAt(under, 0.25), closeTo(5.98, 1e-9));
      expect(admObjectSpreadAt(under, 0.5), closeTo((5.98 + 42.13) / 2, 1e-9));
      expect(admObjectSpreadAt(under, 0.75), closeTo(42.13, 1e-9));
      // Outside the path the figure holds, as the position does.
      expect(admObjectSpreadAt(under, 0), closeTo(5.98, 1e-9));
      expect(admObjectSpreadAt(under, 99), closeTo(42.13, 1e-9));
      // An object with no path carries one figure for the whole file.
      expect(admObjectSpreadAt(data.objects[0], 99), closeTo(55.64, 1e-9));
    });

    test('the range covers the whole path, not just its first vertex', () {
      final data = AdmProbeData.decode(
        jsonDecode(_hullProbeJson) as Map<String, dynamic>,
      );
      expect(admObjectSpreadRange(data.objects[1]), (5.98, 42.13));
      expect(admObjectSpreadRange(data.objects[0]), (55.64, 55.64));
    });

    test('a band opens only where the gains agree on no direction', () {
      // Focus is the render's energy-vector length. A source shared by two
      // speakers, or one at d = 0.5, still has a direction: a cap.
      expect(admBandFactor(0.99, 0), 0);
      expect(admBandFactor(0.71, 0), 0);
      // The room centre drives all seven mid-ring speakers equally and
      // agrees on nothing: a band.
      expect(admBandFactor(0.19, 0), 1);
      // The zenith reads 0.5 too, but its image is round and genuinely a
      // 60° cap. Roundness holds the band off.
      expect(admBandFactor(0.5, 1), 0);
      expect(admBandFactor(0.19, 1), 0);
      // And the ramp between is monotone, so a scrub inward opens rather
      // than switches.
      var last = 0.0;
      for (var f = 0.5; f >= 0.25; f -= 0.05) {
        final b = admBandFactor(f, 0);
        expect(b, greaterThanOrEqualTo(last));
        last = b;
      }
    });

    test('the halo stays a streak while the source has a direction, and '
        'opens into a band only at the room centre', () {
      // Focus measured off the renderer at az 22.5° (image_spread_test.cc
      // holds the same sweep), so the ramp below is tied to what OLR does
      // rather than to a curve fitted in Dart.
      // (distance, focus) pairs, in order.
      const measured = <(double, double)>[
        (1.00, 0.987),
        (0.80, 0.965),
        (0.60, 0.839),
        (0.50, 0.707),
        (0.40, 0.593),
        (0.35, 0.534),
        (0.30, 0.475),
        (0.25, 0.418),
        (0.20, 0.364),
        (0.15, 0.313),
        (0.10, 0.267),
        (0.05, 0.225),
        (0.00, 0.188),
      ];
      double bandAt(double d) => admBandFactor(
        measured.firstWhere((m) => (m.$1 - d).abs() < 1e-9).$2,
        0,
      );

      // Anything with a direction of its own stays a streak: at d = 0.35
      // the render is still panning across part of the ring.
      for (final d in [1.00, 0.80, 0.60, 0.50, 0.40, 0.35]) {
        expect(bandAt(d), 0, reason: 'd=\$d');
      }
      // It opens through the distances where the ring fills in...
      expect(bandAt(0.30), lessThan(0.1));
      expect(bandAt(0.25), closeTo(0.25, 0.05));
      expect(bandAt(0.20), closeTo(0.57, 0.05));
      expect(bandAt(0.15), closeTo(0.84, 0.05));
      // ...and is a closed band by the time the source reaches the centre.
      expect(bandAt(0.05), 1);
      expect(bandAt(0.00), 1);
      // Monotone throughout, so scrubbing a mover inward never jumps.
      var last = 0.0;
      for (final m in measured) {
        final b = bandAt(m.$1);
        expect(b, greaterThanOrEqualTo(last - 1e-9));
        last = b;
      }
    });

    test('the ellipse keeps its measured width whatever the band does', () {
      // The band is drawn as its own shape and cross-faded in, so the
      // ellipse is never stretched toward a ring: it stays the patch the
      // measurement describes, tapered ends and all.
      for (final focus in [0.99, 0.5, 0.19]) {
        expect(
          admHaloMajorDeg((spread: 9.2, ratio: 0, tilt: 0, focus: focus)),
          closeTo(9.2, 1e-9),
        );
      }
      expect(
        admHaloMajorDeg((spread: 88.2, ratio: 0, tilt: 0, focus: 0.19)),
        closeTo(88.2, 1e-9),
      );
      // Past a hemisphere a wider patch says nothing a full one does not.
      expect(
        admHaloMajorDeg((spread: 104.8, ratio: 0, tilt: 0, focus: 0.9)),
        closeTo(90, 1e-9),
      );
    });

    test('a tilt lerps as an axis, not as a direction', () {
      // 170 and 10 are 20 apart through 180, not 160 the other way: an
      // object crossing the wrap must not swing its halo the long way.
      expect(admLerpTilt(170, 10, 0.5), closeTo(0, 1e-9));
      expect(admLerpTilt(10, 170, 0.5), closeTo(0, 1e-9));
      expect(admLerpTilt(0, 90, 0.5), closeTo(45, 1e-9));
      expect(admLerpTilt(80, 100, 0.5), closeTo(90, 1e-9));
      // The result stays in [0, 180).
      expect(admLerpTilt(179, 1, 1.0), closeTo(1, 1e-9));
      expect(admLerpTilt(10, 10, 0.3), closeTo(10, 1e-9));
    });

    test('an object image shape follows the scrubber between vertices', () {
      final data = AdmProbeData.decode(
        jsonDecode(_shapeProbeJson) as Map<String, dynamic>,
      );
      final o = data.objects[0];
      // Flat and horizontal at the first vertex, round at the last.
      expect(admObjectShapeAt(o, 0.0).ratio, closeTo(0, 1e-9));
      expect(admObjectShapeAt(o, 0.0).tilt, closeTo(0, 1e-9));
      expect(admObjectShapeAt(o, 1.0).ratio, closeTo(1, 1e-9));
      expect(admObjectShapeAt(o, 0.5).ratio, closeTo(0.5, 1e-6));
      // Halfway between a horizontal and a vertical smear.
      expect(admObjectShapeAt(o, 0.5).tilt, closeTo(45, 1e-6));
    });

    test('a probe with no measured shape decodes as round', () {
      final data = AdmProbeData.decode(
        jsonDecode(_hullProbeJson) as Map<String, dynamic>,
      );
      // The hull fixture carries widths but no ratio or tilt, as a probe
      // from before the shape was measured does.
      expect(data.objects[0].spreadRatio, 1.0);
      expect(data.objects[0].spreadTilt, 0.0);
      expect(data.objects[0].shape.ratio, 1.0);
    });

    test('the distance term range covers the whole path too', () {
      final data = AdmProbeData.decode(
        jsonDecode(_hullProbeJson) as Map<String, dynamic>,
      );
      // The term the render is handed, not a radius after the conversion.
      // A pathless object carries its own figure for the whole file.
      expect(admObjectDistanceRange(data.objects[0]), (0.5, 0.5));
      expect(admObjectDistanceRange(data.objects[1]), (1.0, 1.0));
      expect(admObjectDistanceRange(data.objects[3]), (0.0, 0.0));
    });
  });

  group('admCapOutline', () {
    double radiusOf(Offset o) => math.sqrt(o.dx * o.dx + o.dy * o.dy);

    test('a cap facing the viewer is a circle of sin theta', () {
      final out = admCapOutline(Vector3(0, 0, 1), 0.3)!;
      for (final p in out) {
        // Vector3 is single-precision, so the tolerance is float-sized.
        expect(radiusOf(p), closeTo(math.sin(0.3), 1e-6));
      }
    });

    test('an elliptical cap facing the viewer draws its two axes', () {
      // Facing the viewer, the tangent plane is the screen, so the axis
      // vector picks the direction the ellipse is wide in. Horizontal here.
      const major = 0.4, minor = 0.1;
      final out = admCapOutline(
        Vector3(0, 0, 1),
        major,
        minorRad: minor,
        axis: Vector3(1, 0, 0),
      )!;
      var widest = 0.0, tallest = 0.0;
      for (final p in out) {
        widest = math.max(widest, p.dx.abs());
        tallest = math.max(tallest, p.dy.abs());
      }
      expect(widest, closeTo(math.sin(major), 1e-3));
      expect(tallest, closeTo(math.sin(minor), 1e-3));
    });

    test('the axis turns the ellipse with it', () {
      const major = 0.4, minor = 0.1;
      final out = admCapOutline(
        Vector3(0, 0, 1),
        major,
        minorRad: minor,
        axis: Vector3(0, 1, 0),
      )!;
      var widest = 0.0, tallest = 0.0;
      for (final p in out) {
        widest = math.max(widest, p.dx.abs());
        tallest = math.max(tallest, p.dy.abs());
      }
      // The same image, upright: a pan between the layers rather than
      // inside one.
      expect(widest, closeTo(math.sin(minor), 1e-3));
      expect(tallest, closeTo(math.sin(major), 1e-3));
    });

    test('equal axes give the circle the single figure used to', () {
      final round = admCapOutline(Vector3(0, 0, 1), 0.3)!;
      final explicit = admCapOutline(
        Vector3(0, 0, 1),
        0.3,
        minorRad: 0.3,
        axis: Vector3(1, 0, 0),
      )!;
      for (final p in explicit) {
        expect(radiusOf(p), closeTo(math.sin(0.3), 1e-6));
      }
      expect(explicit, hasLength(round.length));
    });

    test('the run along the rim is stepped by angle, not by count', () {
      // A wide, flat cap centred on the limb with its long axis along the
      // silhouette: half its boundary is on the far side, so the near
      // outline is closed by a run of about 140° along the rim. That run
      // used to be 24 chords whatever its length; over a sweep this size
      // each chord fell about 2 px inside the silhouette at the preview's
      // radius, and the halo read as dashes on the sphere's outline.
      final out = admCapOutline(
        Vector3(1, 0, 0),
        1.2,
        minorRad: 0.3,
        axis: Vector3(0, 1, 0),
      )!;
      bool onRim(Offset p) => (radiusOf(p) - 1).abs() < 1e-3;
      expect(
        out.where(onRim).length,
        greaterThan(24),
        reason: 'the rim run must be present',
      );
      // Outline-adjacent pairs that both sit on the rim are steps of the
      // run (the polygon closes, so the last-first pair counts too).
      const stepRad = 3 * math.pi / 180;
      var maxStep = 0.0;
      for (var i = 0; i < out.length; i++) {
        final a = out[(i - 1 + out.length) % out.length];
        final b = out[i];
        if (!onRim(a) || !onRim(b)) continue;
        var d = (math.atan2(b.dy, b.dx) - math.atan2(a.dy, a.dx)).abs();
        if (d > math.pi) d = 2 * math.pi - d;
        maxStep = math.max(maxStep, d);
      }
      expect(maxStep, lessThanOrEqualTo(stepRad * 1.01));
    });

    test('an elliptical cap on the silhouette still closes on the rim', () {
      final out = admCapOutline(
        Vector3(1, 0, 0),
        0.4,
        minorRad: 0.1,
        axis: Vector3(0, 0, 1),
      )!;
      // Its widest axis runs off the limb, so the outline has to close
      // along the rim rather than project to a lens inside the disc.
      expect(out.where((p) => radiusOf(p) > 0.999), isNotEmpty);
      for (final p in out) {
        expect(radiusOf(p), lessThan(1.0001));
      }
    });

    test('an elongated cap is subdivided so no chord cuts the sphere', () {
      // The whole-ring case: 88° across, a tenth of that high. Sampling the
      // ellipse uniformly in its parameter put consecutive boundary points
      // 17° apart near the long ends, and the straight screen chord between
      // them passed well inside the hull, so the halo read as a flat sheet
      // rather than a patch of the sphere.
      final major = 88.2 * math.pi / 180;
      final minor = major * 0.12;
      final out = admCapOutline(
        Vector3(0, 0, 1),
        major,
        minorRad: minor,
        axis: Vector3(1, 0, 0),
      )!;
      var widest = 0.0;
      for (var i = 0; i < out.length; i++) {
        final a = out[i];
        final b = out[(i + 1) % out.length];
        widest = math.max(widest, (b - a).distance);
      }
      // Every step short enough that its chord's sag is under a pixel on a
      // 300 px sphere: a 3° step on the unit sphere spans about 0.052.
      expect(widest, lessThan(0.06));
      // And the whole outline still lies on the projected sphere.
      for (final p in out) {
        expect(radiusOf(p), lessThan(1.0001));
      }
    });

    test('a round cap needs no subdivision and keeps its sample count', () {
      expect(admCapOutline(Vector3(0, 0, 1), 0.3)!, hasLength(72));
    });

    test('a closed band is the hull less a cap at each of its poles', () {
      // A band has no ends. Drawn as a capsule long enough to close on
      // itself it pinches to a point behind its centre, which reads as the
      // band stopping there; the painter takes the two polar caps out of
      // the hull instead, and those are what this returns.
      const bw = 5 * math.pi / 180;
      final (a, b) = admBandCaps(
        Vector3(0, 0, 1),
        Vector3(1, 0, 0),
        bw,
        far: false,
      );
      // The band's poles are up and down here, so both caps are edge-on:
      // each shows a half, and between them they leave a horizontal strip.
      expect(a, isNotNull);
      expect(b, isNotNull);
      for (final cap in [a!, b!]) {
        for (final p in cap) {
          expect(radiusOf(p), lessThan(1.0001));
        }
      }
      // The strip they leave is the band's own width: neither cap reaches
      // within sin(w) of the great circle, and both come that close.
      double nearest(List<Offset> cap) => cap
          .where((p) => p.dx.abs() < 0.5)
          .map((p) => p.dy.abs())
          .reduce(math.min);
      expect(nearest(a), closeTo(math.sin(bw), 0.01));
      expect(nearest(b), closeTo(math.sin(bw), 0.01));
      // And they sit on opposite sides, so the strip runs between them.
      expect(a.map((p) => p.dy).reduce(math.max), greaterThan(0));
      expect(b.map((p) => p.dy).reduce(math.min), lessThan(0));
    });

    test('a cap behind the sphere draws nothing', () {
      expect(admCapOutline(Vector3(0, 0, -1), 0.3), isNull);
      // Just past the silhouette, by more than its own angular radius.
      expect(admCapOutline(Vector3(0.2, 0, -0.98)..normalize(), 0.15), isNull);
    });

    test('a cap on the silhouette is a crescent, not a sliver', () {
      const theta = 0.3;
      final out = admCapOutline(Vector3(1, 0, 0), theta)!;
      // It reaches the rim and runs inward to the boundary circle, rather
      // than collapsing to the near-zero-width ellipse the projection of
      // its full boundary would give.
      expect(out.map(radiusOf).reduce(math.max), closeTo(1.0, 1e-6));
      expect(
        out.map((p) => p.dx).reduce(math.min),
        closeTo(math.cos(theta), 1e-6),
      );
      expect(out.map((p) => p.dx).reduce(math.max), closeTo(1.0, 1e-6));
    });

    test('every point stays on the sphere disc', () {
      for (final dir in [
        Vector3(0, 0, 1),
        Vector3(1, 0, 0),
        Vector3(0.6, 0.6, 0.5)..normalize(),
        Vector3(0.9, 0.1, -0.4)..normalize(),
      ]) {
        final out = admCapOutline(dir, 0.4);
        if (out == null) continue;
        for (final p in out) {
          expect(radiusOf(p), lessThanOrEqualTo(1.0 + 1e-6));
        }
      }
    });

    test('the far side is the other half of the same cap', () {
      // Facing the viewer, there is no far side; behind, no near side.
      expect(admCapOutline(Vector3(0, 0, 1), 0.3, far: true), isNull);
      expect(admCapOutline(Vector3(0, 0, -1), 0.3), isNull);
      final behind = admCapOutline(Vector3(0, 0, -1), 0.3, far: true)!;
      for (final p in behind) {
        expect(radiusOf(p), closeTo(math.sin(0.3), 1e-6));
      }
    });

    test('a cap on the silhouette draws both sides, meeting at the rim', () {
      const theta = 0.3;
      final near = admCapOutline(Vector3(1, 0, 0), theta)!;
      final far = admCapOutline(Vector3(1, 0, 0), theta, far: true)!;
      // Each side runs from the boundary circle out to the rim, so the two
      // together cover the cap and share their extremes.
      for (final side in [near, far]) {
        expect(side.map(radiusOf).reduce(math.max), closeTo(1.0, 1e-6));
        expect(
          side.map((p) => p.dx).reduce(math.min),
          closeTo(math.cos(theta), 1e-6),
        );
      }
    });

    test('a cap with no angular radius draws nothing', () {
      expect(admCapOutline(Vector3(0, 0, 1), 0), isNull);
    });
  });

  group('admDepthOrder', () {
    test('breaks ties by insertion order so the scene cannot flicker', () {
      // Dart's List.sort is not stable. Marks at equal depth used to draw in
      // a different order each frame, and the top of the stack changed hue
      // while the view orbited.
      expect(admDepthOrder([0.5, 0.5, 0.5, 0.5]), [0, 1, 2, 3]);
      expect(admDepthOrder(List<double>.filled(40, -0.25)), [
        for (var i = 0; i < 40; i++) i,
      ]);
    });

    test('still draws far to near', () {
      expect(admDepthOrder([1.0, -1.0, 0.0]), [1, 2, 0]);
      // Ties inside a mixed list keep their order relative to each other.
      expect(admDepthOrder([0.5, -0.5, 0.5, -0.5]), [1, 3, 0, 2]);
    });

    test('an empty scene orders nothing', () {
      expect(admDepthOrder(const []), isEmpty);
    });
  });

  group('AdmProbeObject.segmentAt', () {
    // Vertices carry their own time because the probe collapses the middle
    // of a hold. These pin that a hold holds: indexing by a fraction of the
    // vertex count would slide the mark across it.
    AdmProbeObject obj(List<AdmTrajectoryPoint> t) => AdmProbeObject(
      label: 'o',
      track: 1,
      blocks: t.length,
      azimuth: 10,
      elevation: 20,
      distance: 0.5,
      cartesian: false,
      x: 0,
      y: 0,
      z: 0,
      trajectory: t,
      startS: t.isEmpty ? 0 : t.first.t,
      endS: t.isEmpty ? 0 : t.last.t,
      spread: 0,
      spreadRatio: 1,
      spreadTilt: 0,
      spreadFocus: 1,
    );

    test('an object with no path holds one position for the whole file', () {
      expect(obj(const []).segmentAt(0), isNull);
      expect(
        obj(const [
          (az: 0, el: 0, dist: 1, t: 0, spread: 0, ratio: 1, tilt: 0, focus: 1),
        ]).segmentAt(5),
        isNull,
      );
    });

    test('clamps to the ends rather than extrapolating past them', () {
      final o = obj(const [
        (az: 0, el: 0, dist: 1, t: 1, spread: 0, ratio: 1, tilt: 0, focus: 1),
        (az: 90, el: 0, dist: 1, t: 2, spread: 0, ratio: 1, tilt: 0, focus: 1),
      ]);
      expect(o.segmentAt(0), (0, 0.0));
      expect(o.segmentAt(1), (0, 0.0));
      expect(o.segmentAt(1.5), (0, 0.5));
      expect(o.segmentAt(2), (0, 1.0));
      expect(o.segmentAt(99), (0, 1.0));
    });

    test('finds the segment by time, not by vertex fraction', () {
      // A hold from 1 s to 9 s between two short moves. Halfway through the
      // file (5 s) the object is inside the hold, at its start — a fraction
      // of the vertex count would put it a third of the way along the last
      // segment instead.
      final o = obj(const [
        (az: 0, el: 0, dist: 1, t: 0, spread: 0, ratio: 1, tilt: 0, focus: 1),
        (az: 90, el: 0, dist: 1, t: 1, spread: 0, ratio: 1, tilt: 0, focus: 1),
        (az: 90, el: 0, dist: 1, t: 9, spread: 0, ratio: 1, tilt: 0, focus: 1),
        (
          az: 180,
          el: 0,
          dist: 1,
          t: 10,
          spread: 0,
          ratio: 1,
          tilt: 0,
          focus: 1,
        ),
      ]);
      expect(o.segmentAt(5), (1, 0.5));
      final (i, u) = o.segmentAt(5)!;
      expect(o.trajectory[i].az, 90);
      expect(o.trajectory[i + 1].az, 90);
      // Interpolating inside a hold cannot move the object.
      final a = o.trajectory[i];
      final b = o.trajectory[i + 1];
      expect(a.az + (b.az - a.az) * u, 90);
      expect(o.segmentAt(9.5), (2, 0.5));
    });

    test('a zero-length segment does not divide by zero', () {
      final o = obj(const [
        (az: 0, el: 0, dist: 1, t: 0, spread: 0, ratio: 1, tilt: 0, focus: 1),
        (az: 90, el: 0, dist: 1, t: 0, spread: 0, ratio: 1, tilt: 0, focus: 1),
        (az: 180, el: 0, dist: 1, t: 1, spread: 0, ratio: 1, tilt: 0, focus: 1),
      ]);
      expect(o.segmentAt(0), (0, 0.0));
      expect(o.segmentAt(0.5), (1, 0.5));
    });
  });

  group('admFileSpecs', () {
    test('reports channels, rate, depth and duration', () {
      final data = AdmProbeData.decode(
        jsonDecode(_probeJson) as Map<String, dynamic>,
      );
      expect(admFileSpecs(data), '4 ch · 48 kHz · 24-bit · 00:02.000');
    });

    test('omits the parts the probe could not read', () {
      // Empty rather than a stray separator: the dialog drops the row.
      expect(admFileSpecs(AdmProbeData.decode(const {'ok': true})), '');
    });
  });

  group('AdmProbeInspector', () {
    /// The dialog's own composition: the preview pane with the channel
    /// table under it, both driven by one state. Pumped rather than the
    /// pane alone, because the pane carries no table of its own — an
    /// overflow at this width would also overflow in the dialog.
    Future<AdmInspectorState> pumpPane(
      WidgetTester tester, {
      required AdmProbeData data,
      required AdmPreviewTarget target,
    }) async {
      final state = AdmInspectorState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 574,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AdmProbeInspector(
                        data: data,
                        target: target,
                        state: state,
                      ),
                      AdmProbeChannelTable(data: data, state: state),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return state;
    }

    Future<AdmProbeData> pumpInspector(
      WidgetTester tester,
      AdmPreviewTarget target,
    ) async {
      final data = AdmProbeData.decode(
        jsonDecode(_probeJson) as Map<String, dynamic>,
      );
      await pumpPane(tester, data: data, target: target);
      return data;
    }

    testWidgets('the transport scrubs the previewed instant and plays', (
      tester,
    ) async {
      await pumpInspector(tester, const AdmPreviewTarget());

      // The readout starts at zero, where the scene shows every object at
      // its first keyframe — the view before this existed.
      expect(find.text(formatDuration(0)), findsOneWidget);

      final scrubber = find.byKey(const ValueKey('admProbePreviewScrubber'));
      expect(scrubber, findsOneWidget);
      tester.widget<Slider>(scrubber).onChanged!(1.25);
      await tester.pump();
      expect(find.text(formatDuration(1.25)), findsOneWidget);

      // Play runs the scene forward on wall-clock time and keeps the
      // playhead where it was.
      final play = find.byKey(const ValueKey('admProbePreviewPlay'));
      expect(find.text('Play'), findsOneWidget);
      await tester.tap(play);
      await tester.pump();
      expect(find.text('Pause'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      final t = tester.widget<Slider>(scrubber).value;
      expect(t, greaterThan(1.25));
      // Pausing leaves it there rather than resetting.
      await tester.tap(play);
      await tester.pump();
      expect(find.text('Play'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<Slider>(scrubber).value, t);
    });

    testWidgets('the enlarged view shares the pane\'s transport: one clock, '
        'one state', (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final data = AdmProbeData.decode(
        jsonDecode(_probeJson) as Map<String, dynamic>,
      );
      final state = await pumpPane(
        tester,
        data: data,
        target: AdmPreviewTarget(speakers: SpeakerLayout.byName('7.1.4')),
      );

      final play = find.byKey(const ValueKey('admProbePreviewPlay'));
      await tester.tap(play);
      await tester.pump();
      expect(state.playing.value, isTrue);

      // Opened while playing, the enlarged view's transport shows the
      // shared state rather than a fresh 'Play'. pump() with durations
      // rather than pumpAndSettle(): a running ticker never settles.
      await tester.tap(find.byKey(const ValueKey('admProbePreviewExpand')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('admProbePreviewOrbitExpanded')),
        findsOneWidget,
      );
      expect(find.text('Pause'), findsNWidgets(2));
      expect(find.text('Play'), findsNothing);

      // One clock drives the shared instant: 500 ms of playback advances
      // it by 0.5 s. Two tickers each adding their own delta gave 1.0 s.
      final t0 = state.time.value;
      await tester.pump(const Duration(milliseconds: 500));
      expect(state.time.value - t0, closeTo(0.5, 0.01));

      // Pausing from the enlarged view pauses the pane's transport too.
      await tester.tap(play.last);
      await tester.pump();
      expect(state.playing.value, isFalse);
      expect(find.text('Play'), findsNWidgets(2));
      final t1 = state.time.value;
      await tester.pump(const Duration(milliseconds: 200));
      expect(state.time.value, t1);
    });

    testWidgets('no transport when nothing in the file moves', (tester) async {
      // A still scene has no instant to choose: the strip would be a
      // control over nothing.
      final data = AdmProbeData.decode(
        jsonDecode(_probeJson.replaceAll('"trajectory"', '"was_trajectory"'))
            as Map<String, dynamic>,
      );
      await pumpPane(tester, data: data, target: const AdmPreviewTarget());
      expect(
        find.byKey(const ValueKey('admProbePreviewScrubber')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('admProbePreviewPlay')), findsNothing);
    });

    testWidgets('renders summary, channel rows and badges at dialog width', (
      tester,
    ) async {
      await pumpInspector(
        tester,
        AdmPreviewTarget(speakers: SpeakerLayout.byName('7.1.4')),
      );

      // One row per source/object/unresolved channel.
      expect(find.text('L'), findsOneWidget);
      expect(find.text('LFE'), findsOneWidget);
      expect(find.text('mover'), findsOneWidget);
      expect(find.text('parked'), findsOneWidget);
      expect(find.text('Mystery'), findsOneWidget);

      // Badges: LFE routing, fallback resolution, motion, dropped channel.
      expect(find.text('lfe'), findsOneWidget);
      expect(find.text('fallback'), findsOneWidget);
      expect(find.text('3 blocks'), findsOneWidget);
      expect(find.text('static'), findsOneWidget);
      expect(find.text('unresolved'), findsOneWidget);

      // Truncation disclosure: 1 drawn path + 2 dropped -> 2 of 3.
      expect(
        find.text(
          'Paths not shown for 2 of 3 moving objects '
          '(preview point budget).',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('cartesian and below-ring objects are marked, and the '
        'non-radius distance stays out of the table', (tester) async {
      final data = AdmProbeData.decode(
        jsonDecode(_hullProbeJson) as Map<String, dynamic>,
      );
      await pumpPane(
        tester,
        data: data,
        target: AdmPreviewTarget(speakers: SpeakerLayout.byName('7.1.4')),
      );

      // Direction only, in its own columns. There is no distance column:
      // after the anchored conversion the third term is r_xy or |z| rather
      // than a radius (ES-635), so what the render does with it is reported
      // as the spread beside it, and the term itself in the row tooltip.
      expect(find.text('+30°'), findsOneWidget);
      expect(find.text('-30°'), findsOneWidget);
      expect(find.text('Dist'), findsNothing);
      expect(find.text('0.50'), findsNothing);
      expect(find.text('0.00'), findsNothing);
      // The Spread column is the render's measured image width in degrees,
      // not a percentage of anything (ES-640).
      expect(find.text('55.6°'), findsOneWidget);
      expect(find.text('18.6°'), findsOneWidget);

      // Rows carry every applicable badge, not just the motion one.
      expect(find.text('cartesian'), findsNWidgets(2));
      expect(find.text('below ring'), findsOneWidget);
      expect(find.text('static'), findsNWidgets(3));
      expect(find.text('2 blocks'), findsOneWidget);

      // Each new badge is explained on hover. The cartesian object's
      // tooltip leads with the diffuseness its inside-the-room conversion
      // causes, and still never prints the non-radius number.
      expect(
        find.byTooltip(
          'Its position’s third term is below 1, so the render splits it '
          'across the nearest speakers rather than panning it to a point: '
          'an image 55.6° wide, measured off the renderer. The mark carries '
          'a halo, not a shifted position. Authored in room cube at '
          '(0.50, 0.50, 0.00); converted for the 7.1.4 target. '
          'The render receives 0.50 as its position’s third term, which is '
          'what widens the image; it never moves the source closer. '
          'For a room-authored object that term comes out of the '
          'room-to-speaker conversion and is not a distance from the '
          'listener.',
        ),
        findsOneWidget,
      );
      // A cartesian (0, 0, 0) object converts to azimuth 0, which is not a
      // bearing the render uses: at that term it drives the whole ring.
      expect(
        find.byTooltip(
          'Its position’s third term is below 1, so the render splits it '
          'across the nearest speakers rather than panning it to a point: '
          'an image 88.2° wide, measured off the renderer. The mark carries '
          'a halo, not a shifted position. Authored in room cube at '
          '(0.00, 0.00, 0.00); converted for the 7.1.4 target. '
          'The render receives 0.00 as its position’s third term, which is '
          'what widens the image; it never moves the source closer. '
          'For a room-authored object that term comes out of the '
          'room-to-speaker conversion and is not a distance from the '
          'listener. Where that term reaches 0 the render drives every '
          'speaker of the ring at this elevation equally and ignores the '
          'azimuth, so the mark’s direction there is not one the render '
          'uses.',
        ),
        findsOneWidget,
      );
      // The polar object at 0.75 names its distance, since there it is a
      // radius.
      expect(
        find.byTooltip(
          'Its position’s third term is below 1, so the render splits it '
          'across the nearest speakers rather than panning it to a point: '
          'an image 18.6° wide, measured off the renderer. The mark carries '
          'a halo, not a shifted position. The render receives 0.75 as its '
          'position’s third term, which is what widens the image; it never '
          'moves the source closer. Here it is the authored distance.',
        ),
        findsOneWidget,
      );
      // The below-ring object also carries its motion span, which is where
      // to scrub to see it move.
      expect(
        find.byTooltip(
          'Moves from 00:00.250 to 00:00.750. '
          'The render images this diffusely rather than as a point, 6° to '
          '42.1° wide along its path (measured off the renderer). The mark '
          'carries a halo, not a shifted position. '
          'Part of this object converts below 7.1.4\u2019s mid ring, which '
          'has no speakers under it. The render places it at 0°, and so does '
          'the preview.',
        ),
        findsOneWidget,
      );

      // The 190° path step exercises the great-circle subdivision.
      expect(tester.takeException(), isNull);
    });

    testWidgets('a speakerless target renders without speakers', (
      tester,
    ) async {
      await pumpInspector(tester, const AdmPreviewTarget());
      // No layout, nothing to overlay — the toggle must not render.
      expect(find.byKey(const ValueKey('admProbeTargetToggle')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no truncation disclosure when nothing was dropped', (
      tester,
    ) async {
      final data = AdmProbeData.decode(
        jsonDecode(_probeJson) as Map<String, dynamic>,
      );
      final clean = AdmProbeData(
        channels: data.channels,
        sampleRate: data.sampleRate,
        bitsPerSample: data.bitsPerSample,
        isFloat: data.isFloat,
        durationS: data.durationS,
        sources: data.sources,
        objects: data.objects,
        unresolved: data.unresolved,
        trajectoryObjectsDropped: 0,
      );
      await pumpPane(tester, data: clean, target: const AdmPreviewTarget());
      expect(
        find.byKey(const ValueKey('admProbeTrajectoryTruncation')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('enlarged dialog fits at the minimum window height', (
      tester,
    ) async {
      // 1400x900 is the app's enforced minimum window size; the canvas
      // bound (min(560, screen - 340)) must keep the dialog overflow-free
      // here — this is the case the chrome constant is reasoned against.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpInspector(
        tester,
        AdmPreviewTarget(speakers: SpeakerLayout.byName('7.1.4')),
      );
      await tester.tap(find.byKey(const ValueKey('admProbePreviewExpand')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('admProbePreviewOrbitExpanded')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('row selection drives the painter', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpInspector(tester, const AdmPreviewTarget());

      // Clicking the object row toggles selection (and back off). Only the
      // hovered or selected object's path draws, so both states paint.
      await tester.tap(find.text('mover'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('mover'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('an LFE row explains that it is routed', (tester) async {
      await pumpInspector(tester, const AdmPreviewTarget());
      // The position column is empty for an LFE channel; without the
      // tooltip that reads as a failure to place it rather than as the
      // renderer routing it.
      await tester.longPress(find.text('LFE'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Routed straight to the 7.1.4 bed'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('any row selects, and only one at a time', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = await pumpPane(
        tester,
        data: AdmProbeData.decode(
          jsonDecode(_probeJson) as Map<String, dynamic>,
        ),
        target: const AdmPreviewTarget(),
      );

      // A bed row selects, not just an object row.
      await tester.tap(find.text('L'));
      await tester.pump();
      expect(state.selected, (kind: AdmRowKind.source, index: 0));

      // LFE is routed rather than panned, and still takes a click.
      await tester.tap(find.text('LFE'));
      await tester.pump();
      expect(state.selected, (kind: AdmRowKind.source, index: 1));

      // Picking a row from another list clears the last one, so the scene
      // never rings two marks at once.
      await tester.tap(find.text('mover'));
      await tester.pump();
      expect(state.selected, (kind: AdmRowKind.object, index: 0));
      expect(state.selectedIndexOf(AdmRowKind.source), isNull);

      // A channel that never reaches the render selects too.
      await tester.tap(find.text('Mystery'));
      await tester.pump();
      expect(state.selected, (kind: AdmRowKind.unresolved, index: 0));

      // Tapping the selected row again clears it.
      await tester.tap(find.text('Mystery'));
      await tester.pump();
      expect(state.selected, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expand button opens the enlarged preview dialog', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpInspector(
        tester,
        AdmPreviewTarget(speakers: SpeakerLayout.byName('7.1.4')),
      );

      await tester.tap(find.byKey(const ValueKey('admProbePreviewExpand')));
      await tester.pumpAndSettle();

      // The enlarged scene renders in its own dialog, with the legend and
      // the truncation disclosure (this fixture drops 2 paths) repeated.
      expect(
        find.byKey(const ValueKey('admProbePreviewOrbitExpanded')),
        findsOneWidget,
      );
      expect(
        find.text(
          'Paths not shown for 2 of 3 moving objects '
          '(preview point budget).',
        ),
        findsNWidgets(2),
      );

      // The enlarged view is a second view of one scene: the pane's
      // selection is already applied to it.
      expect(tester.takeException(), isNull);
    });

    testWidgets('preview orbit: drag rotates, pitch clamps, double-tap '
        'resets to the 45°/45° default', (tester) async {
      // The pane is taller than the default 600 px test surface, which
      // would give the harness scroll view scroll extent — and its
      // vertical drag recognizer would then win the gesture arena over
      // the preview's pan. The real dialog has no scrollable around the
      // pane, so give the surface enough height that nothing scrolls.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpInspector(tester, const AdmPreviewTarget());
      final preview = find.byKey(const ValueKey('admProbePreviewOrbit'));
      // The preview's state class is private; its public @visibleForTesting
      // getters are reachable dynamically.
      final dynamic state = tester.state(preview);
      const rad45 = 45 * math.pi / 180;

      // Default view: front of the room toward the upper right (yaw
      // -45°), eye 45° above the horizon.
      expect(state.debugYawRad, closeTo(-rad45, 1e-9));
      expect(state.debugPitchRad, closeTo(rad45, 1e-9));

      // Drag right and up: yaw grows, pitch shrinks. (Directional only —
      // the pan recognizer consumes its touch slop before tracking, so
      // exact deltas would encode the slop constant.)
      await tester.drag(preview, const Offset(50, -20));
      await tester.pump();
      expect(state.debugYawRad, greaterThan(-rad45));
      expect(state.debugPitchRad, lessThan(rad45));
      expect(tester.takeException(), isNull);

      // A huge downward drag pins pitch at the ±85° clamp.
      await tester.drag(preview, const Offset(0, 10000));
      await tester.pump();
      expect(state.debugPitchRad, closeTo(85 * math.pi / 180, 1e-9));
      expect(tester.takeException(), isNull);

      // Double-tap restores the default view.
      await tester.tap(preview);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(preview);
      await tester.pumpAndSettle();
      expect(state.debugYawRad, closeTo(-rad45, 1e-9));
      expect(state.debugPitchRad, closeTo(rad45, 1e-9));
    });
  });
}
