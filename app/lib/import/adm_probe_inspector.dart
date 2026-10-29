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

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Vector3 only: vector_math also exports a `Colors` that would collide with
// material's.
import 'package:vector_math/vector_math.dart' show Vector3;

import '../meters/label_painter_cache.dart';
import '../renderer/coordinate_utils.dart';
import '../renderer/scene_label_overlay.dart' show SceneLabelOverlay;
import '../renderer/speaker_layout.dart';
import '../state.dart';
import '../theme.dart';
import '../util/time_format.dart';
import '../widgets/app_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/eyebrow_label.dart';

/// Probe inspector pane for the ADM import dialog (ES-448): the per-channel
/// metadata list and a small 3D position preview, fed entirely from the
/// probe JSON the engine already emits. Read-only and purely informational —
/// it answers "what is in this master, where will it land, and how does it
/// move" before the user commits to a render. Scope rule: it surfaces only
/// what the rendering pipeline actually consumes (positions, gain, LFE
/// routing, resolution outcome, trajectories, format facts) — no ADM
/// bookkeeping, and no object importance (the import always sends
/// minImportance = 0, so importance never affects the render today).

// ── Probe model ──────────────────────────────────────────────────────────────

/// One `[azimuth, elevation, distance, t, spread, ratio, tilt, focus]`
/// sample of an object's motion path (ADM degrees: azimuth positive-left,
/// elevation positive-up; [t] in seconds from the start of the file).
///
/// [spread], [ratio], [tilt] and [focus] are the render's image at this vertex,
/// measured off the renderer by the engine (ES-640) — see [AdmImageShape].
///
/// Vertices are **not** uniform in time. The probe places them on the corners
/// of the authored path — keyframe starts, ramp ends and snaps — and drops
/// the ones the drawn polyline can do without (ES-608), so the gap between
/// consecutive vertices varies and only [t] says when each one happens
/// (ES-637). Both ends of a hold survive, so a hold draws flat.
typedef AdmTrajectoryPoint = ({
  double az,
  double el,
  double dist,
  double t,
  double spread,
  double ratio,
  double tilt,
  double focus,
});

/// The measured shape of the render's image at one position.
///
/// [spread] is its angular radius along its widest axis, in degrees.
/// [ratio] is how much narrower it is across that axis, 0 to 1: 1 is round,
/// 0 is a line. [tilt] is the widest axis's direction in the tangent plane
/// at the image's centre, degrees anticlockwise from horizontal, in
/// [0, 180) — 0 a horizontal smear, 90 a vertical one.
///
/// Most images are lines. A source panned inside one layer is split across
/// speakers that share an elevation, so it has no vertical extent at all,
/// and that is the ordinary case on 7.1.4 — a front phantom, a rear pan,
/// anything at d < 1. Drawing one figure as a circle claimed a vertical
/// smear the render does not produce, which is why the halo is an ellipse.
typedef AdmImageShape = ({
  double spread,
  double ratio,
  double tilt,
  double focus,
});

/// One bed source from the probe's `scene.sources[]`.
class AdmProbeSource {
  const AdmProbeSource({
    required this.label,
    required this.isLfe,
    required this.azimuth,
    required this.elevation,
    required this.distance,
    required this.gain,
    required this.track,
    required this.fallback,
    required this.note,
    required this.spread,
    required this.spreadRatio,
    required this.spreadTilt,
    required this.spreadFocus,
  });

  final String label;
  final bool isLfe;
  final double azimuth; // ADM degrees, positive = left.
  final double elevation; // ADM degrees, positive = up.
  final double distance;
  final double gain; // Linear.
  final int track; // 1-based WAV track.
  final bool fallback; // Resolved, but via a lenient path.
  final String note; // Resolution detail (tooltip for the fallback badge).

  /// How wide the render images this channel, in degrees (ES-640). Zero for
  /// an LFE channel, which routes rather than pans, and for a channel that
  /// lands on a target loudspeaker, the case the renderer passes through — a
  /// measurement there is the arithmetic's own noise, about 0.01°.
  final double spread;

  /// The image's shape beside its width — see [AdmImageShape].
  final double spreadRatio;
  final double spreadTilt;
  final double spreadFocus;

  AdmImageShape get shape => (
    spread: spread,
    ratio: spreadRatio,
    tilt: spreadTilt,
    focus: spreadFocus,
  );
}

/// One dynamic object from the probe's `scene.objects[]`. The trajectory is
/// the engine's downsampled sampling of the *interpolated* motion (the same
/// evaluation the render bakes in); empty for static objects.
class AdmProbeObject {
  const AdmProbeObject({
    required this.label,
    required this.track,
    required this.blocks,
    required this.azimuth,
    required this.elevation,
    required this.distance,
    required this.cartesian,
    required this.x,
    required this.y,
    required this.z,
    required this.trajectory,
    required this.startS,
    required this.endS,
    required this.spread,
    required this.spreadRatio,
    required this.spreadTilt,
    required this.spreadFocus,
  });

  final String label;
  final int track;
  final int blocks; // Keyframe count; 1 = static, >1 = moving.
  final double azimuth; // Initial position.
  final double elevation;

  /// The conversion's third term, **not a radius** for a cartesian-authored
  /// object: BS.2127 §10 yields r_xy below 45° of tilde-elevation and |z|
  /// above it. Reported for polar-authored objects only (ES-635).
  final double distance;

  /// Whether the first keyframe was authored in room-cube cartesian and went
  /// through the layout-anchored conversion. A timeline that mixes coordinate
  /// systems (out of spec) reports only what its first keyframe was.
  final bool cartesian;

  /// The authored room-cube position, meaningful only when [cartesian].
  final double x;
  final double y;
  final double z;

  /// How wide the render images the initial position, in degrees (ES-640).
  /// A moving object's path carries its own figure per vertex; this is the
  /// one that applies before the motion starts and to a static object.
  final double spread;

  /// The image's shape beside its width — see [AdmImageShape].
  final double spreadRatio;
  final double spreadTilt;
  final double spreadFocus;

  AdmImageShape get shape => (
    spread: spread,
    ratio: spreadRatio,
    tilt: spreadTilt,
    focus: spreadFocus,
  );

  final List<AdmTrajectoryPoint> trajectory;

  /// The object's motion span in seconds: the first keyframe's time, and the
  /// time the last keyframe's ramp completes. Both 0 when the probe emitted
  /// no path.
  ///
  /// The authoritative span, and not derived from [trajectory] even though
  /// the two agree: the probe samples the span's ends, so its first and last
  /// vertex land on these times. That coincidence is a property of how it
  /// samples, not a contract, and a degenerate span (keyframes that all snap
  /// at one instant) breaks it — every vertex there carries [startS] while
  /// [endS] is at or before it.
  final double startS;
  final double endS;

  bool get moves => blocks > 1;

  /// Which trajectory segment covers [t] seconds: the index of the segment's
  /// first vertex, and how far into it. Null when the object has no path and
  /// therefore holds one position for the whole file.
  ///
  /// Indexed by timestamp rather than by a fraction of the vertex count,
  /// because the vertices are not uniform in time (see [AdmTrajectoryPoint]);
  /// a fraction would slide an object through its own holds. Outside the
  /// path the position holds, which is what the render does before the first
  /// block and after the last ramp completes.
  (int, double)? segmentAt(double t) {
    if (trajectory.length < 2) return null;
    if (t <= trajectory.first.t) return (0, 0);
    if (t >= trajectory.last.t) return (trajectory.length - 2, 1);
    var lo = 0;
    var hi = trajectory.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (trajectory[mid].t <= t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = trajectory[hi].t - trajectory[lo].t;
    return (lo, span <= 0 ? 0.0 : (t - trajectory[lo].t) / span);
  }

  /// True when any part of this object converts below 7.1.4's mid ring, which
  /// has no speakers under it: the render collapses such a direction to 0°,
  /// and so does the preview.
  bool get belowRing => elevation < 0 || trajectory.any((p) => p.el < 0);
}

/// Object [o]'s polar position at [t] seconds, in ADM degrees: the numbers
/// behind the mark the preview draws at that instant.
///
/// Azimuth lerps the short way round the circle. The engine wraps object
/// azimuths into (-180, 180], so a path crossing the back of the room puts
/// consecutive vertices at +179 and -179 and a plain lerp would sweep the
/// object the long way through the front instead. Elevation and distance
/// lerp linearly, the vertices already being samples of the render's own
/// linear ramp. Outside the path the position holds, as
/// [AdmProbeObject.segmentAt] defines and as the render does.
///
/// The drawn mark slerps its *direction* between the same two vertices so
/// it rides on the great-circle polyline; that is a drawing concern. These
/// are the authored scalars the render reads.
({double az, double el, double dist}) admObjectPolarAt(
  AdmProbeObject o,
  double t,
) {
  final seg = o.segmentAt(t);
  if (seg == null) {
    return (az: o.azimuth, el: o.elevation, dist: o.distance);
  }
  final (i, u) = seg;
  final a = o.trajectory[i];
  final b = o.trajectory[i + 1];
  var step = b.az - a.az;
  if (step > 180) {
    step -= 360;
  } else if (step < -180) {
    step += 360;
  }
  var az = a.az + step * u;
  if (az > 180) az -= 360;
  if (az <= -180) az += 360;
  return (
    az: az,
    el: a.el + (b.el - a.el) * u,
    dist: a.dist + (b.dist - a.dist) * u,
  );
}

/// One dropped channel from `scene.unresolved_channels[]`. These never reach
/// the render, so they must be visible here, not only in the warnings box.
class AdmProbeUnresolved {
  const AdmProbeUnresolved({required this.name, required this.reason});
  final String name;
  final String reason;
}

/// Everything the inspector shows, decoded defensively from the probe JSON —
/// a malformed field degrades to an empty/zero value, never a throw (the
/// import must not fail on inspector cosmetics).
class AdmProbeData {
  const AdmProbeData({
    required this.channels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.isFloat,
    required this.durationS,
    required this.sources,
    required this.objects,
    required this.unresolved,
    required this.trajectoryObjectsDropped,
  });

  final int channels;
  final int sampleRate;
  final int bitsPerSample;
  final bool isFloat;
  final double durationS;
  final List<AdmProbeSource> sources;
  final List<AdmProbeObject> objects;
  final List<AdmProbeUnresolved> unresolved;

  /// Moving objects whose path the probe dropped because the file-wide
  /// trajectory point budget ran out (`trajectory_objects_dropped`).
  /// Zero when every moving object's path made it into [objects].
  final int trajectoryObjectsDropped;

  static double _d(dynamic v) => v is num ? v.toDouble() : 0;

  /// An image's aspect ratio, defaulting to round. Absent on a probe from
  /// before the shape was measured, and on one whose meter could not be
  /// created; clamped because it scales a drawn axis.
  static double _ratio(dynamic v) =>
      v is num ? v.toDouble().clamp(0.0, 1.0) : 1.0;
  static int _i(dynamic v) => v is num ? v.toInt() : 0;
  static String _s(dynamic v) => v is String ? v : '';

  factory AdmProbeData.decode(Map<String, dynamic> probe) {
    final fmt = probe['format'];
    final scene = probe['scene'];

    final sources = <AdmProbeSource>[];
    if (scene is Map && scene['sources'] is List) {
      for (final e in scene['sources'] as List) {
        if (e is! Map) continue;
        final res = e['resolution'];
        sources.add(
          AdmProbeSource(
            label: _s(e['label']),
            isLfe: e['lfe'] == true,
            azimuth: _d(e['azimuth']),
            elevation: _d(e['elevation']),
            distance: _d(e['distance']),
            gain: e['gain'] is num ? (e['gain'] as num).toDouble() : 1,
            track: _i(e['track']),
            fallback: res is Map && res['fallback'] == true,
            note: res is Map ? _s(res['note']) : '',
            spread: _d(e['spread']),
            spreadRatio: _ratio(e['spread_ratio']),
            spreadTilt: _d(e['spread_tilt']),
            spreadFocus: _ratio(e['spread_focus']),
          ),
        );
      }
    }

    final objects = <AdmProbeObject>[];
    if (scene is Map && scene['objects'] is List) {
      for (final e in scene['objects'] as List) {
        if (e is! Map) continue;
        final trajectory = <AdmTrajectoryPoint>[];
        if (e['trajectory'] is List) {
          for (final p in e['trajectory'] as List) {
            if (p is List && p.length >= 3) {
              trajectory.add((
                az: _d(p[0]),
                el: _d(p[1]),
                dist: _d(p[2]),
                // Probes from before the scrubber emit no time. Zero leaves
                // every vertex at the start, which reads as a static object
                // rather than as motion the scrubber cannot place.
                t: p.length >= 4 ? _d(p[3]) : 0,
                // A probe that could not measure the render omits this, and
                // the vertex draws with no halo (ES-640).
                spread: p.length >= 5 ? _d(p[4]) : 0,
                // A probe from before the image had a shape carries only the
                // width; a round halo is what it used to draw.
                ratio: p.length >= 6 ? _ratio(p[5]) : 1,
                tilt: p.length >= 7 ? _d(p[6]) : 0,
                focus: p.length >= 8 ? _ratio(p[7]) : 1,
              ));
            }
          }
        }
        objects.add(
          AdmProbeObject(
            label: _s(e['label']),
            track: _i(e['track']),
            blocks: _i(e['blocks']),
            azimuth: _d(e['azimuth']),
            elevation: _d(e['elevation']),
            distance: _d(e['distance']),
            cartesian: e['cartesian'] == true,
            x: _d(e['x']),
            y: _d(e['y']),
            z: _d(e['z']),
            trajectory: trajectory,
            startS: _d(e['start_s']),
            endS: _d(e['end_s']),
            spread: _d(e['spread']),
            spreadRatio: _ratio(e['spread_ratio']),
            spreadTilt: _d(e['spread_tilt']),
            spreadFocus: _ratio(e['spread_focus']),
          ),
        );
      }
    }

    final unresolved = <AdmProbeUnresolved>[];
    if (scene is Map && scene['unresolved_channels'] is List) {
      for (final e in scene['unresolved_channels'] as List) {
        if (e is! Map) continue;
        final name = _s(e['name']);
        unresolved.add(
          AdmProbeUnresolved(
            name: name.isNotEmpty ? name : _s(e['id']),
            reason: _s(e['reason']),
          ),
        );
      }
    }

    return AdmProbeData(
      channels: fmt is Map ? _i(fmt['channels']) : 0,
      sampleRate: fmt is Map ? _i(fmt['sample_rate']) : 0,
      bitsPerSample: fmt is Map ? _i(fmt['bits_per_sample']) : 0,
      isFloat: fmt is Map && fmt['is_float'] == true,
      durationS: fmt is Map ? _d(fmt['duration_s']) : 0,
      sources: sources,
      objects: objects,
      unresolved: unresolved,
      trajectoryObjectsDropped: scene is Map
          ? _i(scene['trajectory_objects_dropped'])
          : 0,
    );
  }
}

/// What the preview draws the scene against — the import's fixed 7.1.4
/// target. [speakers] carries the target layout's speaker positions (null
/// when the layout is unknown to the renderer map).
class AdmPreviewTarget {
  const AdmPreviewTarget({this.speakers});
  final SpeakerLayout? speakers;
}

/// One trailing tag on a channel row. A row can carry more than one, since a
/// single object may be moving, cartesian-authored and below the ring at once.
typedef AdmRowBadge = ({String text, Color? color});

/// What the master is, in the '·' idiom the rest of the dialog uses:
/// channel count, sample rate, bit depth, duration. Empty when the probe
/// could read none of them.
///
/// The file's name is not in here. It sits on its own row above this one,
/// so a long name wraps or elides without dragging the numbers with it.
String admFileSpecs(AdmProbeData d) {
  final parts = <String>[];
  if (d.channels > 0) parts.add('${d.channels} ch');
  if (d.sampleRate > 0) {
    final khz = d.sampleRate / 1000;
    parts.add('${khz.toStringAsFixed(d.sampleRate % 1000 == 0 ? 0 : 1)} kHz');
  }
  if (d.bitsPerSample > 0) {
    parts.add('${d.bitsPerSample}-bit${d.isFloat ? ' float' : ''}');
  }
  if (d.durationS > 0) parts.add(formatDuration(d.durationS));
  return parts.join(' · ');
}

/// Which of the channel table's three lists a row comes from.
enum AdmRowKind { source, object, unresolved }

/// A row in the channel table: its list and its index in that list.
///
/// Records compare by value, so one nullable field holds the whole
/// selection and picking any row clears the last one, whatever list it
/// came from.
typedef AdmRowRef = ({AdmRowKind kind, int index});

/// True when anything in [d] moves. Gates the transport, the paths toggle
/// and the channel table's live columns.
bool admSceneMoves(AdmProbeData d) =>
    d.objects.any((o) => o.trajectory.length >= 2);

/// The inspector's shared view state: which instant the scene shows,
/// whether the transport is playing, and which row is hovered or selected.
///
/// Hoisted out of the pane so the preview and [AdmProbeChannelTable] can
/// sit in different parts of the import dialog and still track one scene.
/// Click state goes through [ChangeNotifier] and rebuilds both. [time] does
/// not, deliberately: the painter takes it as its repaint listenable and
/// the table's moving rows subscribe per cell, so scrubbing repaints
/// without rebuilding either widget.
///
/// The transport's clock lives here too, because the pane and the enlarged
/// view each show a transport over the same [time]. When each widget owned
/// its own [Ticker], playing in both added two deltas per frame and ran the
/// scene at double speed, and the enlarged view opened on "Play" while the
/// pane was already playing.
class AdmInspectorState extends ChangeNotifier {
  AdmInspectorState() {
    time.addListener(_publishTableTime);
    // A plain Ticker rather than one from a TickerProvider: the state is
    // shared across two routes and outlives either transport widget.
    _ticker = Ticker(_onTick);
  }

  /// The previewed instant, in seconds from the start of the file.
  final ValueNotifier<double> time = ValueNotifier<double>(0);

  /// [time] rounded to [_tableQuantumS], for the table's numeric cells.
  ///
  /// A ValueNotifier is silent when the rounded value repeats, so this caps
  /// the table at 20 updates a second while the painter keeps every frame.
  /// Each live cell costs a paragraph layout, and digits changing 60 times
  /// a second are not readable anyway.
  final ValueNotifier<double> tableTime = ValueNotifier<double>(0);

  static const double _tableQuantumS = 0.05;

  /// Whether the transport is running. Both transports read it for their
  /// label, so pressing either one acts on the same clock.
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);

  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _durationS = 0;

  int? _hoverSource;
  int? _hoverObject;
  AdmRowRef? _selected;

  /// Hovered channel row, echoed in the preview (marker ring, full-strength
  /// trace while the others dim). Sources and objects index separately.
  int? get hoverSource => _hoverSource;
  int? get hoverObject => _hoverObject;

  /// The click-selected channel row, of whichever kind: its marker stays
  /// ringed and its numbers stay in the scene's readout without the mouse
  /// parked on the row, and an object's path keeps drawing.
  AdmRowRef? get selected => _selected;

  /// The selected row's index when it comes from [kind], else null — the
  /// form the painter reads, one list at a time.
  int? selectedIndexOf(AdmRowKind kind) =>
      _selected?.kind == kind ? _selected!.index : null;

  void setHover({int? source, int? object}) {
    if (_hoverSource == source && _hoverObject == object) return;
    _hoverSource = source;
    _hoverObject = object;
    notifyListeners();
  }

  /// Selects [row], or clears the selection when it is already selected.
  void toggleSelected(AdmRowRef row) {
    _selected = _selected == row ? null : row;
    notifyListeners();
  }

  /// Starts the transport looping over [durationS] seconds, or pauses it.
  void togglePlaying(double durationS) {
    if (playing.value) {
      pause();
    } else {
      play(durationS);
    }
  }

  void play(double durationS) {
    if (playing.value || durationS <= 0) return;
    _durationS = durationS;
    // A Ticker's elapsed restarts at zero on every start, so the first
    // delta must be measured from there rather than from the last stop.
    _last = Duration.zero;
    _ticker.start();
    playing.value = true;
  }

  void pause() {
    if (!playing.value) return;
    _ticker.stop();
    playing.value = false;
  }

  /// Advances by wall-clock delta and wraps at the end, so the preview loops
  /// the file instead of parking on its last frame.
  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0) return;
    final t = time.value + dt;
    time.value = t >= _durationS ? t % _durationS : t;
  }

  void _publishTableTime() {
    tableTime.value =
        (time.value / _tableQuantumS).roundToDouble() * _tableQuantumS;
  }

  @override
  void dispose() {
    _ticker.dispose();
    playing.dispose();
    time.removeListener(_publishTableTime);
    time.dispose();
    tableTime.dispose();
    super.dispose();
  }
}

// ── Inspector pane ───────────────────────────────────────────────────────────

class AdmProbeInspector extends ConsumerStatefulWidget {
  const AdmProbeInspector({
    super.key,
    required this.data,
    required this.target,
    this.state,
  });

  final AdmProbeData data;
  final AdmPreviewTarget target;

  /// The scene state to share with the [AdmProbeChannelTable] the caller
  /// places under this pane. Null means the pane owns one, which is only
  /// useful on its own: nothing then echoes a row into the scene.
  final AdmInspectorState? state;

  @override
  ConsumerState<AdmProbeInspector> createState() => _AdmProbeInspectorState();
}

class _AdmProbeInspectorState extends ConsumerState<AdmProbeInspector> {
  /// Non-null only when the pane created the state it uses, which is the
  /// only case where it may dispose it.
  AdmInspectorState? _owned;
  late final AdmInspectorState _s;

  @override
  void initState() {
    super.initState();
    _s = widget.state ?? (_owned = AdmInspectorState());
    _s.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _s.removeListener(_onStateChanged);
    _owned?.dispose();
    super.dispose();
  }

  // No mounted guard needed: the listener is dropped in dispose(), so a
  // notification from the enlarged dialog cannot land after this unmounts.
  void _onStateChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final d = widget.data;
    // Gating the target here keeps the painter, the legend's speaker
    // entry, and the enlarged dialog consistent for free — they all key
    // off target.speakers != null.
    final moves = admSceneMoves(d);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const EyebrowLabel('Preview'),
        const SizedBox(height: T.gapPair),
        Stack(
          children: [
            Tooltip(
              message: 'Drag to rotate · double-click to reset',
              waitDuration: const Duration(milliseconds: 500),
              child: _OrbitPreview(
                key: const ValueKey('admProbePreviewOrbit'),
                data: d,
                target: widget.target,
                hoverSource: _s.hoverSource,
                hoverObject: _s.hoverObject,
                selSource: _s.selectedIndexOf(AdmRowKind.source),
                selObject: _s.selectedIndexOf(AdmRowKind.object),
                time: _s.time,
              ),
            ),
            // Click-to-enlarge: the same scene at dialog size. Sits above
            // the orbit gesture surface so the tap never starts a drag.
            // Hand-built icon chip (Tooltip + InkWell + Icon) matching the
            // video/viz panels' affordances — not a Material IconButton.
            Positioned(
              top: T.gapXs,
              right: T.gapXs,
              child: Tooltip(
                message: 'Enlarge preview',
                child: InkWell(
                  key: const ValueKey('admProbePreviewExpand'),
                  borderRadius: BorderRadius.circular(T.radiusSm),
                  onTap: () => showAppDialog<void>(
                    context: context,
                    builder: (_) => _ExpandedPreviewDialog(
                      data: d,
                      target: widget.target,
                      state: _s,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.open_in_full,
                      size: T.iconSm,
                      color: T.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        // Under the canvas, above the overlay toggles: it moves what the
        // scene depicts, where the toggles only choose what is drawn.
        if (d.durationS > 0 && moves) ...[
          const SizedBox(height: T.gapPair),
          _PreviewTransport(state: _s, durationS: d.durationS),
        ],
        if (d.trajectoryObjectsDropped > 0) ...[
          const SizedBox(height: T.gapPair),
          Text(
            _truncationNote(d),
            key: const ValueKey('admProbeTrajectoryTruncation'),
            style: TextStyle(color: T.meterYellow, fontSize: T.fontCaption),
          ),
        ],
      ],
    );
  }
}

// ── Channel table ────────────────────────────────────────────────────────────

/// One angle, to at most one decimal, always with its degree sign.
String _deg(double v, {bool signed = false}) {
  final r = (v * 10).round() / 10;
  final s = r == r.roundToDouble()
      ? r.round().toString()
      : r.toStringAsFixed(1);
  return '${signed && r > 0 ? '+' : ''}$s°';
}

String? _gainDb(double linear) {
  if ((linear - 1.0).abs() < 0.0005) return null;
  if (linear <= 0) return '−∞ dB';
  final db = 20 * math.log(linear) / math.ln10;
  return '${db > 0 ? '+' : ''}${db.toStringAsFixed(1)} dB';
}

/// The bed-row tooltip: why an LFE channel has no position, and how a
/// leniently-resolved one was resolved. Null when neither applies, so
/// ordinary rows stay hover-free.
///
/// The LFE wording states what `ChannelRenderer` does — sums the channel
/// into the target layout's LFE with its gain and nothing else — because
/// an empty position column otherwise reads as a failure to place it.
String? _sourceNote(AdmProbeSource s) {
  final parts = <String>[
    if (s.isLfe)
      'Routed straight to the 7.1.4 bed’s LFE channel, with this '
          'channel’s gain applied. It is never panned, so it has no '
          'direction and the preview does not place it.',
    if (s.fallback && s.note.isNotEmpty) s.note,
  ];
  return parts.isEmpty ? null : parts.join(' ');
}

/// The row tooltip: the authored room position a cartesian object's polar
/// numbers came from, the fact that a below-ring direction is rendered
/// (and drawn) at the mid ring, and what the mark's halo means when the
/// render images the object diffusely. Null when there is none of that to
/// say, so ordinary rows stay hover-free.
String? _objectNote(AdmProbeObject o) {
  final parts = <String>[];
  // When to scrub to, for an object that is not moving the whole file.
  if (o.trajectory.length >= 2 && o.endS > o.startS) {
    parts.add(
      'Moves from ${formatDuration(o.startS)} to ${formatDuration(o.endS)}.',
    );
  }
  final (lo, hi) = admObjectSpreadRange(o);
  if (hi >= _kSpreadFloorDeg) {
    if (hi - lo >= _kSpreadFloorDeg) {
      // A path that crosses speakers and gaps images at a different width
      // at every vertex, and no one cause holds along it. State the range
      // the path covers and leave the reason to the numbers in the row.
      parts.add(
        'The render images this diffusely rather than as a point, '
        '${_deg(lo)} to ${_deg(hi)} wide along its path (measured off the '
        'renderer). The mark carries a halo, not a shifted position.',
      );
    } else {
      // Names what put the source off a speaker. Order matters: above the
      // top ring elevation drives the spread whatever the distance, and
      // below d = 0.9 the distance term drives it whatever the direction;
      // what is left is a direction between speakers, which every layout
      // has. The term's own value is left to the part below, which states
      // what it is as well as what it reads, for cartesian and polar
      // objects alike.
      final cause = o.elevation > _admTopRingEl
          ? 'Sits above 7.1.4’s 30° top ring'
          : o.distance >= 0.9
          ? 'No 7.1.4 speaker sits in that direction'
          : 'Its position’s third term is below 1';
      parts.add(
        '$cause, so the render splits it across the nearest speakers rather '
        'than panning it to a point: an image ${_deg(hi)} wide, measured '
        'off the renderer. The mark carries a halo, not a shifted position.',
      );
    }
  }
  if (o.cartesian) {
    String c(double v) => v.toStringAsFixed(2);
    parts.add(
      'Authored in room cube at (${c(o.x)}, ${c(o.y)}, ${c(o.z)}); '
      'converted for the 7.1.4 target.',
    );
  }
  // The third term of the position the render is handed. Reported here
  // rather than as a column: it is not a radius after the conversion, and a
  // number in a table headed Dist would invite the reading the preview
  // stopped making (ES-635). Stated as a range, because the tooltip is built
  // once per row rather than per scrubbed frame — a range says what the
  // whole path does, which is more than a live cell would. Silent while it
  // holds at 1, where there is nothing to explain.
  final (dLo, dHi) = admObjectDistanceRange(o);
  if (dLo < 0.995) {
    String c(double v) => v.toStringAsFixed(2);
    final reads = dHi - dLo >= 0.005
        ? '${c(dLo)} to ${c(dHi)} along this path'
        : c(dLo);
    parts.add(
      'The render receives $reads as its position’s third term, which is '
      'what widens the image; it never moves the source closer.',
    );
    parts.add(
      o.cartesian
          ? 'For a room-authored object that term comes out of the '
                'room-to-speaker conversion and is not a distance from the '
                'listener.'
          : 'Here it is the authored distance.',
    );
    // At 0 the pan has collapsed to the whole ring of the source's layer
    // and the azimuth no longer reaches the output — pinned in C++ by
    // ImageSpread.ZeroDistanceDiscardsTheAzimuth. A cartesian (0, 0, 0)
    // object converts to azimuth 0, so the mark would otherwise read as a
    // front-centre source and the row has to say the bearing is not one
    // the render uses.
    if (dLo < 0.005) {
      parts.add(
        'Where that term reaches 0 the render drives every speaker of the '
        'ring at this elevation equally and ignores the azimuth, so the '
        'mark’s direction there is not one the render uses.',
      );
    }
  }
  if (o.belowRing) {
    parts.add(
      'Part of this object converts below 7.1.4’s mid ring, which has '
      'no speakers under it. The render places it at 0°, and so does '
      'the preview.',
    );
  }
  return parts.isEmpty ? null : parts.join(' ');
}

/// The numeric cells of a wide row, already formatted, plus the two facts
/// that colour them.
typedef _AdmCells = ({
  String az,
  String el,
  String spread,
  bool held,
  bool elClamped,
  bool spreadOn,
});

const _AdmCells _kNoCells = (
  az: '—',
  el: '—',
  spread: '—',
  held: true,
  elClamped: false,
  spreadOn: false,
);

/// Below this the image is a point for drawing purposes: the render put it
/// on one speaker, and what is left is the arithmetic's own noise (a source
/// at a speaker angle measures about 0.01°).
const double _kSpreadFloorDeg = 0.5;

/// The render parameters for a source at [az]/[el], imaged [spread]° wide.
///
/// Distance is not a column. After the layout-anchored conversion it is
/// r_xy or |z| rather than a radius (ES-635), so printing it invites the
/// radius reading that change removed. It is not omitted for being
/// constant: on the reported master 9 of 82 objects start below 1, 40 of
/// the 44 movers dip below it along their paths, and a quarter of the
/// drawn vertices sit under it. What the term does to the render is the
/// [spread] beside it, measured at the position it describes.
_AdmCells _cellsFor(double az, double el, double spread, {required bool held}) {
  final clamped = el < 0;
  final on = spread >= _kSpreadFloorDeg;
  return (
    az: _deg(az, signed: true),
    // Says what the render does with a below-ring direction, in the cell
    // rather than only in the tooltip: authored, then where it lands.
    el: clamped ? '${_deg(el)}→0°' : _deg(el),
    spread: on ? _deg(spread) : '—',
    held: held,
    elClamped: clamped,
    spreadOn: on,
  );
}

_AdmCells _sourceCells(AdmProbeSource s) => s.isLfe
    ? _kNoCells
    : _cellsFor(s.azimuth, s.elevation, s.spread, held: false);

_AdmCells _objectCells(AdmProbeObject o, double t) {
  final p = admObjectPolarAt(o, t);
  final moves = o.trajectory.length >= 2;
  return _cellsFor(
    p.az,
    p.el,
    admObjectSpreadAt(o, t),
    // Outside its motion span a mover holds its end position. Dimming says
    // the numbers are a hold rather than the ramp the scrubber is in.
    held: moves && (t < o.startS || t > o.endS),
  );
}

/// The per-channel table: bed sources, then objects, then unresolved
/// channels, in probe order, as aligned columns under a header.
///
/// A moving object's numbers follow the scrubber rather than standing at
/// its first keyframe (ES-637). Needs roughly 420 px to lay its columns out;
/// the dialog gives it the 574 px preview column.
class AdmProbeChannelTable extends ConsumerStatefulWidget {
  const AdmProbeChannelTable({
    super.key,
    required this.data,
    required this.state,
    this.expand = false,
    this.maxHeight = 150,
  });

  final AdmProbeData data;
  final AdmInspectorState state;

  /// Fill the parent's height (the caller supplies a bounded one) instead
  /// of capping at [maxHeight].
  final bool expand;

  /// The cap in the pane arrangement: that dialog column has no outer
  /// scroll view, so the list bounds its own height and scrolls.
  final double maxHeight;

  @override
  ConsumerState<AdmProbeChannelTable> createState() =>
      _AdmProbeChannelTableState();
}

/// Row height, and the numeric column widths, at font scale 1. Fixed so a
/// live cell's rebuild cannot resize its row: a tight box is a relayout
/// boundary, so the scrolling column above it is never marked dirty.
///
/// Sized to their widest content in the mono face at [T.fontCaption], plus
/// what each header needs: azimuth runs to '-129.5°', elevation to
/// '-89.5°→0°' when the render floors it, spread to '105°'. Trimmed to
/// that, because the table also sits in the 574 px preview column where
/// every pixel these do not take goes to the channel name.
const double _kRowH = 17;
const double _kTrackW = 38;
const double _kAzW = 52;
const double _kElW = 64;
const double _kSpreadW = 54;

class _AdmProbeChannelTableState extends ConsumerState<AdmProbeChannelTable> {
  final ScrollController _scroll = ScrollController();

  /// The row under the cursor, tracked here rather than in the shared
  /// state: an LFE or unresolved row has no mark for the scene to echo,
  /// but it still highlights, and across a full-width row that highlight
  /// is what carries the eye from the label to the numbers.
  AdmRowRef? _hoverRow;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onStateChanged() => setState(() {});

  double get _numbersW => T.fs(_kAzW + _kElW + _kSpreadW);

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final d = widget.data;
    if (d.sources.isEmpty && d.objects.isEmpty && d.unresolved.isEmpty) {
      return Text(
        'No renderable channels.',
        style: TextStyle(color: T.textSecondary, fontSize: T.fontSmall),
      );
    }
    final rows = <Widget>[
      for (var i = 0; i < d.sources.length; i++) _sourceRow(d.sources[i], i),
      for (var i = 0; i < d.objects.length; i++) _objectRow(d.objects[i], i),
      for (var i = 0; i < d.unresolved.length; i++)
        _unresolvedRow(d.unresolved[i], i),
    ];
    // Same idiom as the warnings panel: the list scrolls inside its own
    // bound rather than relying on an outer scroll view.
    final list = Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.only(right: T.gapMd),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
    return Column(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _headerRow(),
        if (widget.expand)
          Expanded(child: list)
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: list,
          ),
      ],
    );
  }

  Widget _headerRow() {
    Widget h(String s, {bool end = false}) => Text(
      s,
      textAlign: end ? TextAlign.right : TextAlign.left,
      style: TextStyle(color: T.textMuted, fontSize: T.fontCaption),
    );
    return Padding(
      padding: const EdgeInsets.only(right: T.gapMd, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(width: T.fs(14)),
              SizedBox(width: T.fs(_kTrackW), child: h('Track')),
              Expanded(flex: 5, child: h('Channel')),
              Expanded(flex: 4, child: h('Notes')),
              SizedBox(width: T.fs(_kAzW), child: h('Az', end: true)),
              SizedBox(width: T.fs(_kElW), child: h('El', end: true)),
              SizedBox(width: T.fs(_kSpreadW), child: h('Spread', end: true)),
            ],
          ),
          const SizedBox(height: 3),
          Container(height: 1, color: T.border),
        ],
      ),
    );
  }

  Widget _cell(String s, double w, {Color? color}) => SizedBox(
    width: T.fs(w),
    child: Text(
      s,
      textAlign: TextAlign.right,
      maxLines: 1,
      // Mono digits, like every other numeric readout in the app —
      // proportional digits would break column alignment while scanning.
      style: TextStyle(
        fontFamily: T.monoFamily,
        color: color ?? T.textValueDim,
        fontSize: T.fontCaption,
      ),
    ),
  );

  Widget _numbers(_AdmCells c) {
    final dim = c.held ? T.textMuted : null;
    return Row(
      children: [
        _cell(c.az, _kAzW, color: dim),
        // The clamp is the one place a cell reports a render decision
        // rather than a value, so it carries the same yellow as the
        // 'below ring' badge that explains it.
        _cell(c.el, _kElW, color: c.elClamped ? T.meterYellow : dim),
        _cell(
          c.spread,
          _kSpreadW,
          color: c.spreadOn ? T.objAmber : T.textMuted,
        ),
      ],
    );
  }

  Widget _badgeStrip(List<AdmRowBadge> badges) => Row(
    children: [
      for (var i = 0; i < badges.length; i++) ...[
        if (i > 0) const SizedBox(width: T.gapPair),
        // Flexible, not a bare Text: several badges on one row shrink
        // each other rather than overflowing the fixed column.
        Flexible(
          child: Text(
            badges[i].text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: badges[i].color ?? T.textSecondary,
              fontSize: T.fontCaption,
            ),
          ),
        ),
      ],
    ],
  );

  Widget _row({
    required AdmRowRef ref,
    required AdmMarkShape marker,
    required Color markerColor,
    required int? track,
    required String label,
    required Widget numbers,
    List<AdmRowBadge> badges = const [],
    String? tooltip,
    void Function(bool)? onSceneHover,
  }) {
    final selected = widget.state.selected == ref;
    final hovered = _hoverRow == ref;
    final markerGlyph = _MarkGlyph(shape: marker, color: markerColor);
    final trackText = Text(
      track?.toString() ?? '—',
      style: TextStyle(color: T.textMuted, fontSize: T.fontCaption),
    );
    final labelText = Text(
      label,
      style: TextStyle(color: T.textPrimary, fontSize: T.fontSmall),
      overflow: TextOverflow.ellipsis,
    );
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SizedBox(
        height: T.fs(_kRowH),
        child: Row(
          children: [
            markerGlyph,
            SizedBox(width: T.fs(_kTrackW), child: trackText),
            Expanded(flex: 5, child: labelText),
            Expanded(flex: 4, child: _badgeStrip(badges)),
            // Tight both ways, so a live cell's rebuild stops here instead
            // of dirtying the whole scrolling column.
            SizedBox(width: _numbersW, height: T.fs(_kRowH), child: numbers),
          ],
        ),
      ),
    );
    if (tooltip != null && tooltip.isNotEmpty) {
      row = Tooltip(message: tooltip, child: row);
    }
    if (selected || hovered) {
      row = DecoratedBox(
        decoration: BoxDecoration(
          // Hover is a weaker wash than selection: across a full-width row
          // the highlight is what carries the eye from label to numbers.
          color: selected ? T.bgHover : T.bgHover.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(T.radiusSm),
        ),
        child: row,
      );
    }
    // Every row takes a click, so every row gets the pointer and the
    // highlight. Only the ones with a mark in the scene report their hover
    // onward to it.
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hoverRow = ref);
        onSceneHover?.call(true);
      },
      onExit: (_) {
        setState(() => _hoverRow = null);
        onSceneHover?.call(false);
      },
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.state.toggleSelected(ref),
        child: row,
      ),
    );
  }

  Widget _sourceRow(AdmProbeSource s, int index) {
    final gain = _gainDb(s.gain);
    return _row(
      ref: (kind: AdmRowKind.source, index: index),
      marker: AdmMarkShape.dot,
      // The row's hue is its dot's in the scene, the link between the
      // panes; LFE has no dot, so its marker is muted.
      markerColor: s.isLfe ? T.textMuted : bedHue(index),
      track: s.track,
      label: s.label.isNotEmpty ? s.label : 'ch ${s.track}',
      numbers: _numbers(_sourceCells(s)),
      badges: [
        // Gain has no column of its own; it is signal only when it is not
        // unity, which _gainDb reports by returning null.
        if (gain != null) (text: gain, color: null),
        if (s.isLfe)
          (text: 'lfe', color: null)
        // Neutral, not amber: the engine files channel_fallback as an
        // info-severity notice, so the badge should not claim more than
        // the report does. The badge and the tooltip are where a
        // fallback shows; the dot carries the channel's identity hue.
        else if (s.fallback)
          (text: 'fallback', color: null),
      ],
      tooltip: _sourceNote(s),
      // LFE is routed rather than panned, so there is no mark for the
      // scene to light up. The row still clicks and highlights like the
      // rest; it just has nothing to echo.
      onSceneHover: s.isLfe
          ? null
          : (on) => widget.state.setHover(source: on ? index : null),
    );
  }

  Widget _objectRow(AdmProbeObject o, int index) {
    final Widget numbers;
    if (o.trajectory.length >= 2) {
      // Only movers subscribe, and only their numeric cluster: a bed
      // channel or a static object has nothing to follow, and rebuilding
      // its row every scrub frame would cost a paragraph layout for a
      // string that never changes.
      numbers = ValueListenableBuilder<double>(
        valueListenable: widget.state.tableTime,
        builder: (_, t, _) => _numbers(_objectCells(o, t)),
      );
    } else {
      numbers = _numbers(_objectCells(o, 0));
    }
    return _row(
      ref: (kind: AdmRowKind.object, index: index),
      marker: AdmMarkShape.diamond,
      markerColor: objectHue(index),
      track: o.track,
      label: o.label.isNotEmpty ? o.label : 'object ${index + 1}',
      numbers: numbers,
      badges: [
        (
          text: o.moves ? '${o.blocks} blocks' : 'static',
          color: o.moves ? objectHue(index) : null,
        ),
        if (o.cartesian) (text: 'cartesian', color: null),
        if (o.belowRing) (text: 'below ring', color: T.meterYellow),
      ],
      tooltip: _objectNote(o),
      onSceneHover: (on) => widget.state.setHover(object: on ? index : null),
    );
  }

  Widget _unresolvedRow(AdmProbeUnresolved u, int index) {
    return _row(
      ref: (kind: AdmRowKind.unresolved, index: index),
      marker: AdmMarkShape.dot,
      markerColor: T.errorRed,
      track: null,
      label: u.name.isNotEmpty ? u.name : '(unnamed)',
      numbers: _numbers(_kNoCells),
      badges: [(text: 'unresolved', color: T.errorRed)],
      // Nothing to echo in the scene: the channel never reaches it.
      tooltip: u.reason,
    );
  }
}

/// The truncation disclosure: without it, a moving object whose path
/// fell past the probe's point budget is indistinguishable from a
/// genuinely static one. The denominator is paths drawn + paths
/// dropped (not `moves`, which also counts stationary multi-block
/// objects that legitimately have no path).
String _truncationNote(AdmProbeData d) {
  final drawn = d.objects.where((o) => o.trajectory.length >= 2).length;
  final moving = drawn + d.trajectoryObjectsDropped;
  return 'Paths not shown for ${d.trajectoryObjectsDropped} of '
      '$moving moving objects (preview point budget).';
}

/// The top speaker ring of the import target. `ImportLayout()` fixes it at
/// 7.1.4, whose highest speakers sit at 30°; a selectable target would have
/// to read this from the layout. Named only where a row has to say what put
/// a source off a speaker — the image width itself is measured, so nothing
/// in the drawing needs the layout's geometry any more (ES-640).
const double _admTopRingEl = 30.0;

/// The elevation the import target can actually image [elDeg] at.
///
/// 7.1.4 has no speakers below its mid ring, so a negative elevation
/// collapses to 0° in the render and is drawn there. There is deliberately
/// no upper clamp: the render reaches above the top ring by driving that
/// whole ring evenly, so a mark at 70° is where it images the source (ES-635).
/// It gets there diffusely rather than as a point, which is what the halo
/// around the mark draws.
double admHullElevation(double elDeg) => elDeg < 0 ? 0 : elDeg;

/// The angular radius, in degrees, of the halo drawn for an image the probe
/// measured as [spreadDeg] wide.
///
/// Nothing here models the renderer. The width arrives per source, per
/// object and per trajectory vertex in the probe JSON, measured off OLR by
/// `engine/adm_import/render/image_spread.h` as the energy-weighted rms
/// angle of the render's speaker gains about their energy-vector direction
/// (ES-640). Drawing the cap at exactly that radius is what makes it mean
/// something: at an even split between two speakers the edge lands on both
/// of them.
///
/// Capped at a hemisphere. The measured figure keeps rising past 90° — to
/// about 105° in a pocket around the centre of the room, where most of the
/// energy sits further than a right angle from a very short energy vector —
/// but a wider cap says nothing a full hemisphere does not. The render is
/// driving the whole ring there, and a cap understates that footprint at
/// any radius.
double admHaloRadiusDeg(double spreadDeg) =>
    spreadDeg.clamp(0.0, _kHemisphereDeg).toDouble();

/// How much drawing weight an image measured at [spreadDeg] carries: 0 for
/// a point image, 1 for one spread over a hemisphere or more.
///
/// Kept apart from [admHaloRadiusDeg] because the cap's size states the
/// measurement while the halo's opacity, the core mark's fade and the
/// trajectory's width say how diffuse the image is. A front phantom between
/// two speakers 30° apart measures about 9°, so it draws at a tenth of the
/// weight an object at the centre of the room does: visible when looked
/// for, never competing with a genuinely diffuse mark.
double admSpreadWeight(double spreadDeg) =>
    (spreadDeg / _kHemisphereDeg).clamp(0.0, 1.0).toDouble();

/// How much of a band, rather than a patch, the image is: 0 draws the cap
/// at its measured width, 1 draws it right around the ring.
///
/// A cap has to be centred somewhere, and at the room's centre there is
/// nowhere: the render drives all seven of the mid ring's speakers at
/// 1/√7, the rears at ±135° included, and the direction the conversion
/// reports is an artefact. Drawn as a cap of the measured 88.2° the halo
/// reaches ±88.2° and misses the rears, which is the footprint understated
/// by a third of the ring.
///
/// [focus] is the length of the render's energy vector, which is what says
/// whether the gains agree on a direction at all: 0.99 for a source shared
/// by two speakers, 0.71 at d = 0.5, 0.19 for the whole ring. The ramp
/// between 0.5 and 0.25 spans the distances over which the ring fills in,
/// so scrubbing an object inward widens the halo into a band instead of
/// switching. Roundness holds it off: the zenith drives its whole ring too
/// and reads 0.5, but it is a genuine cap 60° across, and a band there
/// would be wrong.
///
/// The thresholds are drawing decisions. [focus] itself is measured.
double admBandFactor(double focus, double ratio) {
  const hi = 0.5, lo = 0.25;
  final t = ((hi - focus) / (hi - lo)).clamp(0.0, 1.0);
  // Smoothstep, so a scrub through the ramp has no visible corner.
  return t * t * (3 - 2 * t) * (1 - ratio.clamp(0.0, 1.0));
}

/// The ellipse's major half-axis for an image of [shape], in degrees: the
/// measured width, up to a hemisphere ([admHaloRadiusDeg]).
///
/// It does not open toward 180° as the image loses its direction. An
/// ellipse stretched that far makes a poor band — it tapers away at its
/// ends where a band holds its width, and reads as a sticker laid on the
/// hull — so the band is drawn as its own shape ([admBandCaps]) and the
/// two are cross-faded by [admBandFactor]. The ellipse keeps the taper,
/// which is what a source the render still points somewhere looks like.
double admHaloMajorDeg(AdmImageShape shape) => admHaloRadiusDeg(shape.spread);

const double _kHemisphereDeg = 90.0;

/// How wide the render images object [o] at [t] seconds, in degrees.
///
/// Lerped between the two vertices the mark is drawn between, so the halo
/// tracks the scrubber the way the position does. Outside the path the
/// figure holds, as the position does. An object with no path carries one
/// figure for the whole file.
/// The narrowest and widest the render images object [o] anywhere on its
/// path, in degrees. Both are the object's own figure when it has no path.
(double, double) admObjectSpreadRange(AdmProbeObject o) {
  if (o.trajectory.isEmpty) return (o.spread, o.spread);
  var lo = o.trajectory.first.spread;
  var hi = lo;
  for (final p in o.trajectory) {
    if (p.spread < lo) lo = p.spread;
    if (p.spread > hi) hi = p.spread;
  }
  return (lo, hi);
}

/// The lowest and highest third term the render is handed anywhere on
/// object [o]'s path. Both are the object's own figure when it has no
/// path. Not a distance after the layout-anchored conversion — see
/// `_objectNote`, the one place it is shown.
(double, double) admObjectDistanceRange(AdmProbeObject o) {
  if (o.trajectory.isEmpty) return (o.distance, o.distance);
  var lo = o.trajectory.first.dist;
  var hi = lo;
  for (final p in o.trajectory) {
    if (p.dist < lo) lo = p.dist;
    if (p.dist > hi) hi = p.dist;
  }
  return (lo, hi);
}

double admObjectSpreadAt(AdmProbeObject o, double t) =>
    admObjectShapeAt(o, t).spread;

/// The shape of the render's image of object [o] at [t] seconds.
///
/// Lerped between the two vertices the mark is drawn between, so the halo
/// tracks the scrubber the way the position does. Outside the path the
/// shape holds, as the position does. An object with no path carries one
/// shape for the whole file.
AdmImageShape admObjectShapeAt(AdmProbeObject o, double t) {
  final seg = o.segmentAt(t);
  if (seg == null) return o.shape;
  final (i, u) = seg;
  final a = o.trajectory[i];
  final b = o.trajectory[i + 1];
  return (
    spread: a.spread + (b.spread - a.spread) * u,
    ratio: a.ratio + (b.ratio - a.ratio) * u,
    tilt: admLerpTilt(a.tilt, b.tilt, u),
    focus: a.focus + (b.focus - a.focus) * u,
  );
}

/// Interpolates an image's tilt, which is an axis rather than a direction:
/// 170° and 10° are 20° apart through 180, not 160° apart the other way.
/// Lerping the raw numbers would swing a halo the long way round as an
/// object crosses the wrap.
double admLerpTilt(double a, double b, double u) {
  var d = (b - a) % 180;
  if (d > 90) d -= 180;
  final r = (a + d * u) % 180;
  return r < 0 ? r + 180 : r;
}

/// The outline of one side of the halo's patch of hull, in units of the
/// sphere's screen radius (x right, y up, origin at the sphere's centre).
///
/// [dir] is the patch's centre as a unit vector in view space — x right, y
/// up, z toward the viewer. [majorRad] and [minorRad] are its angular
/// half-widths along [axis] and across it, [axis] being a view-space unit
/// vector tangent to [dir]. [far] selects the half of the hull the patch
/// sits on: the near side by default, the side away from the viewer when
/// set.
///
/// An ellipse, so the patch tapers toward its ends the way the render's
/// energy does. It is not the shape for a source the render spreads right
/// around a ring — nothing centred on a direction is — and that case is
/// drawn as a band instead, from [admBandCaps].
List<Offset>? admCapOutline(
  Vector3 dir,
  double majorRad, {
  double? minorRad,
  Vector3? axis,
  bool far = false,
  int segments = 72,
}) {
  if (majorRad <= 0) return null;
  final minor = (minorRad ?? majorRad).clamp(1e-9, majorRad);

  // A basis for the tangent plane, with u along the image's widest axis.
  // Any axis component along dir is dropped rather than trusted: the
  // caller's came through a rotation.
  var u = axis == null
      ? (dir.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0)).cross(dir)
      : axis - dir * axis.dot(dir);
  if (u.length2 < 1e-12) {
    u = (dir.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0)).cross(dir);
  }
  u.normalize();
  final v = dir.cross(u)..normalize();

  // The ellipse in polar form about its own centre: [majorRad] along the
  // axis, [minorRad] across it.
  double boundaryAt(double phi) {
    final cp = math.cos(phi);
    final sp = math.sin(phi);
    final denom = math.sqrt(
      minor * minor * cp * cp + majorRad * majorRad * sp * sp,
    );
    return denom < 1e-12 ? 0.0 : majorRad * minor / denom;
  }

  Vector3 at(double phi) {
    final theta = boundaryAt(phi);
    return dir * math.cos(theta) +
        (u * math.cos(phi) + v * math.sin(phi)) * math.sin(theta);
  }

  /// Whether `p` is inside the ellipse: its angle from the centre against
  /// the boundary in its own direction.
  bool inside(Vector3 p) {
    final dot = p.dot(dir).clamp(-1.0, 1.0);
    final tangent = p - dir * dot;
    final phi = tangent.length2 < 1e-12
        ? 0.0
        : math.atan2(tangent.dot(v), tangent.dot(u));
    return math.acos(dot) <= boundaryAt(phi) + 1e-9;
  }

  // Sampling uniformly in the parameter is not enough once the ellipse is
  // elongated, and it usually is: at 88° by 10° the boundary runs from 88°
  // off the centre at phi = 0 to 72° five degrees later, and a straight
  // screen chord across that 17° step passes well inside the sphere — the
  // halo stops looking like a patch of the hull, the same way trajectory
  // chords did before they were subdivided (ES-635). Intervals are bisected
  // until consecutive samples are within [kOutlineStepRad] of each other,
  // so the step is bounded in angle rather than in parameter.
  const kOutlineStepRad = 3 * math.pi / 180;
  final cosStep = math.cos(kOutlineStepRad);
  const maxDepth = 6;
  final pts = <Vector3>[];
  void refine(double s0, Vector3 v0, double s1, Vector3 v1, int depth) {
    if (depth == 0 || v0.dot(v1) >= cosStep) {
      pts.add(v1);
      return;
    }
    final sm = 0.5 * (s0 + s1);
    final vm = at(sm);
    refine(s0, v0, sm, vm, depth - 1);
    refine(sm, vm, s1, v1, depth - 1);
  }

  var prevPhi = 0.0;
  var prev = at(0);
  pts.add(prev);
  for (var i = 1; i <= segments; i++) {
    final phi = 2 * math.pi * i / segments;
    final next = at(phi);
    refine(prevPhi, prev, phi, next, maxDepth);
    prevPhi = phi;
    prev = next;
  }
  // The last interval closed onto phi = 2*pi, which is the first sample.
  pts.removeLast();

  final n = pts.length;
  final keep = [for (final p in pts) far ? p.z <= 0 : p.z >= 0];
  if (!keep.contains(true)) return null;
  if (!keep.contains(false)) {
    return [for (final p in pts) Offset(p.x, p.y)];
  }

  // Where the boundary crosses the silhouette, exactly: a point of the
  // boundary with z = 0 also has x² + y² = 1, so a crossing lands on the
  // sphere's rim and the outline closes flush against it.
  Offset crossing(Vector3 back, Vector3 fwd) {
    final p = back + (fwd - back) * (back.z / (back.z - fwd.z));
    final d = math.sqrt(p.x * p.x + p.y * p.y);
    return d > 1e-9 ? Offset(p.x / d, p.y / d) : Offset(p.x, p.y);
  }

  // One pass around the boundary in its own order, dropping the samples on
  // the far side and running along the rim across each gap. Walking in
  // boundary order rather than gathering the runs first keeps one closed
  // polygon whatever the number of gaps. The rim arc is stepped by angle,
  // [kOutlineStepRad] like the boundary itself: a fixed count of steps
  // made a long sweep a coarse polygon whose chords fell up to 2 px
  // inside the silhouette between vertices, so a halo along the rim read
  // as dashes on the sphere's outline.
  final arc = <Offset>[];
  var start = 0;
  for (var i = 0; i < n; i++) {
    if (keep[i] && !keep[(i - 1 + n) % n]) {
      start = i;
      break;
    }
  }
  double? pendingExit;
  for (var k = 0; k <= n; k++) {
    final i = (start + k) % n;
    final wrapped = k == n;
    final on = wrapped ? true : keep[i];
    if (on) {
      final entry = pendingExit == null
          ? null
          : crossing(pts[(i - 1 + n) % n], pts[i]);
      if (entry != null) {
        // Of the two rim arcs between the gap's ends, the one bounding
        // this side of the patch is the one whose midpoint is inside it.
        final to = math.atan2(entry.dy, entry.dx);
        var sweep = to - pendingExit!;
        while (sweep <= -math.pi) {
          sweep += 2 * math.pi;
        }
        while (sweep > math.pi) {
          sweep -= 2 * math.pi;
        }
        final mid = pendingExit + sweep / 2;
        if (!inside(Vector3(math.cos(mid), math.sin(mid), 0))) {
          sweep += sweep > 0 ? -2 * math.pi : 2 * math.pi;
        }
        final rimSteps = math.max(1, (sweep.abs() / kOutlineStepRad).ceil());
        for (var r = 1; r < rimSteps; r++) {
          final a = pendingExit + sweep * r / rimSteps;
          arc.add(Offset(math.cos(a), math.sin(a)));
        }
        arc.add(entry);
        pendingExit = null;
      }
      if (!wrapped) arc.add(Offset(pts[i].x, pts[i].y));
    } else if (pendingExit == null) {
      final exit = crossing(pts[i], pts[(i - 1 + n) % n]);
      arc.add(exit);
      pendingExit = math.atan2(exit.dy, exit.dx);
    }
  }
  return arc.length < 3 ? null : arc;
}

/// The two polar caps whose complement is a band of half-width [halfWidth]
/// about the great circle through [dir] along [axis].
///
/// A band has no ends, so its boundary is two separate circles and the
/// single closed loop [admCapOutline] walks cannot describe it. What it can
/// describe is each cap around the band's poles, and the band is the hull
/// with both of those taken out — which is how the painter builds it, and
/// why this returns the caps rather than the band.
///
/// Returns each cap's outline on the requested side, or null for one that
/// is wholly on the other side.
(List<Offset>?, List<Offset>?) admBandCaps(
  Vector3 dir,
  Vector3 axis,
  double halfWidth, {
  bool far = false,
}) {
  var u = axis - dir * axis.dot(dir);
  if (u.length2 < 1e-12) {
    u = (dir.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0)).cross(dir);
  }
  u.normalize();
  final pole = dir.cross(u)..normalize();
  final capRadius = math.pi / 2 - halfWidth;
  return (
    admCapOutline(pole, capRadius, far: far),
    admCapOutline(pole * -1, capRadius, far: far),
  );
}

/// Draw order for [depths]: farthest first, ties in insertion order.
///
/// The tie-break is the point. Dart's `List.sort` is not stable, so marks at
/// equal depth — objects sharing a direction, and the whole mid ring seen
/// edge-on — drew in a different order every frame and the stack's top hue
/// flickered while the view orbited. Stacking transparent marks is fine; an
/// order that is not fixed is not.
List<int> admDepthOrder(List<double> depths) {
  final order = List<int>.generate(depths.length, (i) => i);
  order.sort((a, b) {
    final c = depths[a].compareTo(depths[b]);
    return c != 0 ? c : a.compareTo(b);
  });
  return order;
}

/// Per-object identity color: [T.objAmber] hue-rotated by the golden
/// angle per index, keeping amber's saturation/lightness so every hue
/// carries the same weight against the scene. Object 0 stays amber
/// (matching the legend); overlapping paths from different objects
/// separate by hue instead of blurring into one.
///
/// Deliberately a procedural ink, not a palette token: identity needs
/// one colour per object and the object count is unbounded. It stays
/// theme-reactive by deriving from the live [T.objAmber]; note HSL
/// lightness is not perceptually uniform across hues, so rotated blues
/// read slightly dimmer than ambers — acceptable for identity marks
/// that always sit beside their labeled channel row.
Color objectHue(int index) {
  final base = HSLColor.fromColor(T.objAmber);
  return base.withHue((base.hue + index * 137.5) % 360).toColor();
}

/// Identity colour for bed channel [index], the same way [objectHue]
/// serves objects: one hue per channel, shared by its dot in the scene
/// and its row in the table, so the legend needs no colour of its own.
/// Rotated from the purple the bed used to draw in as one colour, and
/// offset half a step from the object ink so a bed channel and an object
/// with the same index do not land on one hue.
Color bedHue(int index) {
  final base = HSLColor.fromColor(T.purpleLight);
  return base.withHue((base.hue + 68.75 + index * 137.5) % 360).toColor();
}

/// Play and scrub the previewed file.
///
/// The scene draws one instant. Without a way to move it, a master with 44
/// movers shows every path at once and no object's position at any
/// particular moment, which is the state ES-637 was filed against. Moving the
/// instant moves the marks, and with them their halos, which is where the
/// render's diffuseness becomes legible rather than decorative.
///
/// Silent: nothing is loaded into the audio engine at probe time, so this
/// animates the scene only.
class _PreviewTransport extends StatelessWidget {
  const _PreviewTransport({required this.state, required this.durationS});

  /// Owns the clock and the playing flag. [AdmInspectorState.time] is also
  /// the painter's `repaint` listenable, so playback never rebuilds the
  /// pane around the canvas; the enlarged view's transport reads the same
  /// state, so the two never run separate tickers against one instant.
  final AdmInspectorState state;
  final double durationS;

  @override
  Widget build(BuildContext context) {
    final time = state.time;
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          // Fixed width: the label swaps between two lengths on every
          // press, and a button that resizes under the cursor shifts the
          // scrubber beside it. 64 fits 'Pause' inside the compact
          // button's 10 px padding and 2 px rim at the largest font mode.
          SizedBox(
            width: 64,
            child: ValueListenableBuilder<bool>(
              valueListenable: state.playing,
              builder: (context, playing, _) => AppButton(
                key: const ValueKey('admProbePreviewPlay'),
                label: playing ? 'Pause' : 'Play',
                size: AppButtonSize.compact,
                onPressed: () => state.togglePlaying(durationS),
              ),
            ),
          ),
          const SizedBox(width: T.gapMd),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                thumbColor: T.white,
                activeTrackColor: T.purpleLight,
                inactiveTrackColor: T.bgDeep,
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: ValueListenableBuilder<double>(
                valueListenable: time,
                builder: (context, t, _) => Slider(
                  key: const ValueKey('admProbePreviewScrubber'),
                  value: t.clamp(0, durationS),
                  max: durationS,
                  // Scrubbing while playing just moves the playhead; it does
                  // not stop the transport, matching the main timeline.
                  onChanged: (v) => time.value = v,
                ),
              ),
            ),
          ),
          const SizedBox(width: T.gapMd),
          ValueListenableBuilder<double>(
            valueListenable: time,
            builder: (context, t, _) => Text(
              formatDuration(t),
              style: TextStyle(
                color: T.textSecondary,
                fontSize: T.fontCaption,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The click-to-enlarge preview: the same orbitable scene at dialog size,
/// with the legend and truncation note. Its own ConsumerWidget so theme
/// and font switches rebuild it while it is open (the const-skip rule).
class _ExpandedPreviewDialog extends ConsumerWidget {
  const _ExpandedPreviewDialog({
    required this.data,
    required this.target,
    required this.state,
  });

  final AdmProbeData data;

  final AdmPreviewTarget target;

  /// The pane's own state, shared rather than seeded: the dialog is a
  /// second view of one scene, so scrubbing in either moves both.
  final AdmInspectorState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final moves = admSceneMoves(data);
    // Bound the canvas, not the dialog: a scroll view here would claim
    // vertical drags (macOS bouncing physics accepts them even with
    // nothing to scroll) and kill pitch-orbiting. 320 covers the title
    // block, paddings, transport strip (24 + its 6 gap), toggles,
    // truncation note, footer and dialog inset — 70 less than before the
    // legend moved onto the canvas. Pinned at the minimum window height by
    // the enlarged-dialog test.
    final canvasH = math.min(560.0, MediaQuery.of(context).size.height - 320);
    return DialogShell(
      title: 'Preview',
      width: 648,
      actions: [DialogShell.done(context)],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: 'Drag to rotate · double-click to reset',
            waitDuration: const Duration(milliseconds: 500),
            child: _OrbitPreview(
              key: const ValueKey('admProbePreviewOrbitExpanded'),
              data: data,
              target: target,
              hoverSource: null,
              hoverObject: null,
              selSource: state.selectedIndexOf(AdmRowKind.source),
              selObject: state.selectedIndexOf(AdmRowKind.object),
              time: state.time,
              height: canvasH,
            ),
          ),
          if (data.durationS > 0 && moves) ...[
            const SizedBox(height: T.gapPair),
            _PreviewTransport(state: state, durationS: data.durationS),
          ],
          if (data.trajectoryObjectsDropped > 0) ...[
            const SizedBox(height: T.gapPair),
            Text(
              _truncationNote(data),
              style: TextStyle(color: T.meterYellow, fontSize: T.fontCaption),
            ),
          ],
        ],
      ),
    );
  }
}

// ── 3D position preview ──────────────────────────────────────────────────────

/// The drag-orbitable preview surface. Its own widget so pan deltas only
/// rebuild this subtree — routing orbit state through the inspector's
/// setState would rerun the whole pane (file summary, legend, channel
/// rows) on every drag frame.
class _OrbitPreview extends StatefulWidget {
  const _OrbitPreview({
    super.key,
    required this.data,
    required this.target,
    required this.hoverSource,
    required this.hoverObject,
    required this.selSource,
    required this.selObject,
    required this.time,
    this.height = 300,
  });

  final AdmProbeData data;
  final AdmPreviewTarget target;
  final int? hoverSource;
  final int? hoverObject;
  final int? selSource;
  final int? selObject;

  /// The previewed instant, driven by [_PreviewTransport].
  final ValueListenable<double> time;

  /// Drawing surface height; the width fills the parent. The inline pane
  /// uses the default, the enlarged dialog passes its own.
  final double height;

  @override
  State<_OrbitPreview> createState() => _OrbitPreviewState();
}

class _OrbitPreviewState extends State<_OrbitPreview> {
  /// Camera orbit. Default: a three-quarter view from 45° above, with
  /// the front of the room toward the upper right — enough yaw and
  /// height that depth reads at a glance. Drag orbits
  /// (grab-the-near-side, matching the main renderer's OrbitControls
  /// feel); double-tap resets. Not persisted — every dialog opens on
  /// the default view.
  static const double _defaultYawRad = -45 * math.pi / 180;
  static const double _defaultPitchRad = 45 * math.pi / 180;

  /// Drag sensitivity: ~0.57°/px, a half-turn across the pane.
  static const double _orbitRadPerPx = 0.01;

  /// Pitch stops short of the poles; crossing them flips yaw's direction
  /// mid-drag. Yaw is unclamped.
  static const double _maxPitchRad = 85 * math.pi / 180;

  double _yawRad = _defaultYawRad;
  double _pitchRad = _defaultPitchRad;
  bool _orbiting = false;

  @visibleForTesting
  double get debugYawRad => _yawRad;
  @visibleForTesting
  double get debugPitchRad => _pitchRad;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _orbiting ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
      child: GestureDetector(
        onPanStart: (_) => setState(() => _orbiting = true),
        onPanEnd: (_) => setState(() => _orbiting = false),
        onPanCancel: () => setState(() => _orbiting = false),
        onPanUpdate: (details) => setState(() {
          _yawRad += details.delta.dx * _orbitRadPerPx;
          _pitchRad = (_pitchRad + details.delta.dy * _orbitRadPerPx).clamp(
            -_maxPitchRad,
            _maxPitchRad,
          );
        }),
        onDoubleTap: () => setState(() {
          _yawRad = _defaultYawRad;
          _pitchRad = _defaultPitchRad;
        }),
        child: Container(
          height: widget.height,
          width: double.infinity,
          decoration: BoxDecoration(
            color: T.bgBase,
            borderRadius: BorderRadius.circular(T.radiusMd),
          ),
          // Isolate the painter's repaints (continuous while orbiting)
          // from the rest of the dialog.
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _PositionPreviewPainter(
                sources: widget.data.sources,
                objects: widget.data.objects,
                target: widget.target,
                hoverSource: widget.hoverSource,
                hoverObject: widget.hoverObject,
                selSource: widget.selSource,
                selObject: widget.selObject,
                yawRad: _yawRad,
                pitchRad: _pitchRad,
                time: widget.time,
                themeMode: T.mode,
                fontMode: T.fontMode,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The mark shapes the preview uses for its sources, drawn the same way in
/// the scene's legend and in the channel table: a dot for a bed channel,
/// a diamond for an object, a ring for a target loudspeaker.
///
/// Drawn as shapes rather than text glyphs: the font's ◆ is smaller than
/// its ● and sits below the circles' line, so glyph marks showed a small,
/// low diamond wherever the two met.
enum AdmMarkShape { dot, ring, diamond }

/// Paints one mark of [shape] in [color], centred on [c], at the size the
/// scene draws its marks: the diamond larger than the dot, as there.
void paintAdmMark(Canvas canvas, AdmMarkShape shape, Color color, Offset c) {
  final r = T.fs(3.4);
  switch (shape) {
    case AdmMarkShape.dot:
      canvas.drawCircle(c, r, Paint()..color = color);
    case AdmMarkShape.ring:
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    case AdmMarkShape.diamond:
      final d = T.fs(4.8);
      canvas.drawPath(
        Path()
          ..moveTo(c.dx, c.dy - d)
          ..lineTo(c.dx + d, c.dy)
          ..lineTo(c.dx, c.dy + d)
          ..lineTo(c.dx - d, c.dy)
          ..close(),
        Paint()..color = color,
      );
  }
}

/// A mark as a widget, for the channel table's rows. Sized like the
/// legend's mark column so the two panes encode a source the same way.
class _MarkGlyph extends StatelessWidget {
  final AdmMarkShape shape;
  final Color color;
  const _MarkGlyph({required this.shape, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: T.fs(14),
      height: T.fs(12),
      child: CustomPaint(painter: _MarkGlyphPainter(shape, color)),
    );
  }
}

class _MarkGlyphPainter extends CustomPainter {
  final AdmMarkShape shape;
  final Color color;
  const _MarkGlyphPainter(this.shape, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    paintAdmMark(canvas, shape, color, Offset(size.width / 2, size.height / 2));
  }

  @override
  bool shouldRepaint(_MarkGlyphPainter old) =>
      old.shape != shape || old.color != color;
}

/// An orthographic projection of the unit sphere from an orbitable eye
/// ([yawRad]/[pitchRad], drag-controlled by the inspector; at yaw 0 the
/// front of the room is up-screen with left speakers on the left).
/// Positions run through [CoordinateUtils] (ADM azimuth is
/// positive-left; a hand-rolled transform here would mirror the room).
///
/// Draws reference geometry first — a ground disc of horizon rings and
/// spokes with its far half dimmed, a vertical pole, a listener glyph, and
/// F/B/L/R labels pinned to the room — then the target layout's
/// loudspeakers hollow (labelled), bed sources as filled dots in one hue
/// each ([bedHue]) and objects as diamonds ([objectHue]), all in one
/// depth-sorted pass with drop-lines to the ground plane, plus each
/// object's trajectory as a polyline fading from the start marker toward
/// the path's end; the sphere's outline goes on last, over the hull fills.
/// Reads `T.*` at paint time; [themeMode] and [fontMode] exist so
/// [shouldRepaint] notices theme/font switches.
class _PositionPreviewPainter extends CustomPainter {
  _PositionPreviewPainter({
    required this.sources,
    required this.objects,
    required this.target,
    required this.hoverSource,
    required this.hoverObject,
    required this.selSource,
    required this.selObject,
    required this.yawRad,
    required this.pitchRad,
    required this.time,
    required this.themeMode,
    required this.fontMode,
  }) : super(repaint: time);

  final List<AdmProbeSource> sources;
  final List<AdmProbeObject> objects;
  final AdmPreviewTarget target;
  final int? hoverSource;
  final int? hoverObject;
  final int? selSource;
  final int? selObject;

  /// Camera orbit: [yawRad] spins the scene around the vertical axis,
  /// [pitchRad] is how far above (negative: below) the horizon the eye sits.
  final double yawRad;
  final double pitchRad;

  /// The previewed instant, in seconds. Passed as the painter's `repaint`
  /// listenable so scrubbing and playback repaint the scene without
  /// rebuilding the pane around it — the channel list must not rebuild 60
  /// times a second.
  final ValueListenable<double> time;

  final AppThemeMode themeMode;
  final FontSizeMode fontMode;

  // Orbit trig, computed once per painter instance — _project runs per
  // speaker/marker/trajectory sample, and the painter repaints every
  // drag frame.
  late final double _cosY = math.cos(yawRad);
  late final double _sinY = math.sin(yawRad);
  late final double _cosT = math.cos(pitchRad);
  late final double _sinT = math.sin(pitchRad);

  /// The orbit rotation alone, without the screen mapping: view space is
  /// x right, y up, z toward the viewer.
  Vector3 _viewVec(double vx, double vy, double vz) {
    // Yaw around the vertical axis, then pitch around the screen-X axis.
    final x = vx * _cosY + vz * _sinY;
    final z = -vx * _sinY + vz * _cosY;
    return Vector3(x, vy * _cosT - z * _sinT, vy * _sinT + z * _cosT);
  }

  /// Projects a visualizer-space vector (y up, see [CoordinateUtils]):
  /// screen offset plus a depth in [-1, 1] (positive = nearer the viewer)
  /// for size/alpha cues and draw ordering.
  (Offset, double) _projectVec(
    double vx,
    double vy,
    double vz,
    Offset center,
    double radius,
  ) {
    final v = _viewVec(vx, vy, vz);
    return (Offset(center.dx + v.x * radius, center.dy - v.y * radius), v.z);
  }

  /// A direction on the speaker hull, as a visualizer-space unit vector.
  Vector3 _hullVec(double az, double el) =>
      CoordinateUtils.sphericalToVisualizer(az, admHullElevation(el), 1);

  /// Places a direction on the speaker hull.
  ///
  /// The scene depicts where the render puts the sound, so every mark sits at
  /// radius 1 and the conversion's `distance` term never enters the drawing.
  /// It is not a radius: after the layout-anchored BS.2127 §10 warp it is
  /// r_xy below 45° of tilde-elevation and |z| above, so using it as one drew
  /// interior objects at neither their authored position nor the direction
  /// the render pans to, and objects at d = 0 on the listener's head (ES-635).
  (Offset, double) _project(
    double az,
    double el,
    Offset center,
    double radius,
  ) {
    final v = _hullVec(az, el);
    return _projectVec(v.x, v.y, v.z, center, radius);
  }

  // Depth cues, deliberately wide: against reference geometry a marker at
  // the back must read clearly smaller and dimmer than one at the front.
  double _scaleFor(double depth) => 0.7 + 0.45 * (depth + 1) / 2;
  double _alphaFor(double depth) => 0.35 + 0.65 * (depth + 1) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 16;
    if (radius <= 0) return;

    _paintReferenceGeometry(canvas, center, radius);
    // One depth-sorted pass for everything with a position — speakers,
    // bed sources, object markers and trajectory segments — so occlusion
    // follows depth, not the accident of draw order.
    _paintMarkers(canvas, center, radius);
    // The sphere's outline goes on last. Halos and bands are filled to the
    // silhouette, and their anti-aliased edges landing on the stroke
    // brightened it in patches that moved with the view; one hairline
    // over everything keeps the rim a single even line.
    _paintSphereOutline(canvas, center, radius);
    _paintLegend(canvas, size);
    _paintReadout(canvas, size);
  }

  /// The marker legend, drawn on the scene rather than under it.
  ///
  /// It names the marks the scene is made of, so it reads against them;
  /// as a widget below the canvas it cost two wrapped lines of the pane's
  /// height for reference the eye only wants while looking at the picture.
  ///
  /// The marks are the scene's shapes ([paintAdmMark]), each centred on
  /// its label's line box left of the text, all in the text colour: the
  /// legend names kinds, and colour in the scene is identity.
  ///
  /// The label painter is cached in a static, like the label painters
  /// below and for the same reason: this painter is rebuilt every orbit
  /// frame, so a per-instance cache would never survive one. The text is
  /// fixed for a given file, so the key only has to cover the entries and
  /// the two display modes.
  void _paintLegend(Canvas canvas, Size size) {
    // Shapes only, in the text colour: bed channels and objects carry
    // one hue each in the scene, shared with their table rows, so no
    // single colour stands for either; a fallback-resolved channel is
    // named by its row's badge and tooltip, not here.
    final entries = <(AdmMarkShape, String)>[
      (AdmMarkShape.dot, 'bed loudspeakers'),
      if (objects.isNotEmpty)
        (AdmMarkShape.diamond, objects.length > 1 ? 'objects' : 'object'),
      if (target.speakers != null) (AdmMarkShape.ring, 'target loudspeakers'),
    ];
    if (entries.isEmpty) return;

    final key = '${entries.map((e) => e.$2).join('|')}|$fontMode|$themeMode';
    if (key != _legendKey) {
      _legendPainter?.dispose();
      _legendPainter = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: entries.map((e) => e.$2).join('\n'),
          style: TextStyle(color: T.textSecondary, fontSize: T.fontCaption),
        ),
      )..layout();
      _legendKey = key;
    }
    final tp = _legendPainter!;
    final markW = T.fs(14);
    const at = Offset(8, 8);
    _drawPanel(canvas, tp, at, leftInset: markW);

    final cx = at.dx + _kPanelPad + markW / 2;
    final lines = tp.computeLineMetrics();
    for (var i = 0; i < entries.length && i < lines.length; i++) {
      final lm = lines[i];
      final cy = at.dy + _kPanelPad + lm.baseline - lm.ascent + lm.height / 2;
      paintAdmMark(canvas, entries[i].$1, T.textSecondary, Offset(cx, cy));
    }
  }

  static TextPainter? _legendPainter;
  static String? _legendKey;

  static const double _kPanelPad = 6.0;

  /// Paints [tp] on a translucent rounded panel with its top-left at [at],
  /// so canvas text stays legible over the scene's rings and marks.
  /// [leftInset] reserves room inside the panel, left of the text, for
  /// the legend's marks.
  void _drawPanel(
    Canvas canvas,
    TextPainter tp,
    Offset at, {
    double leftInset = 0,
  }) {
    const pad = _kPanelPad;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          at.dx,
          at.dy,
          tp.width + 2 * pad + leftInset,
          tp.height + 2 * pad,
        ),
        Radius.circular(T.radiusSm),
      ),
      Paint()..color = T.bgDeep.withValues(alpha: 0.82),
    );
    tp.paint(canvas, at + Offset(pad + leftInset, pad));
  }

  /// The selected row's numbers, in the corner of the scene.
  ///
  /// Drawn by the painter rather than built as widgets: [time] is already
  /// this painter's repaint listenable, so the readout follows the
  /// scrubber at frame rate for no rebuild at all. One row only — the
  /// numbers for everything at once are the tangle selection exists to
  /// cut, and the table carries those.
  ///
  /// Its TextPainter is built per frame instead of going through
  /// [LabelPainterCache]: the text is a changing number, so a cache keyed
  /// by string would grow without bound.
  void _paintReadout(Canvas canvas, Size size) {
    final String name;
    final Color hue;
    final double az, el, spread;
    final i = selObject;
    final s = selSource;
    if (i != null && i >= 0 && i < objects.length) {
      final o = objects[i];
      final p = admObjectPolarAt(o, time.value);
      name = o.label.isNotEmpty ? o.label : 'object ${i + 1}';
      hue = objectHue(i);
      az = p.az;
      el = p.el;
      spread = admObjectSpreadAt(o, time.value);
    } else if (s != null && s >= 0 && s < sources.length && !sources[s].isLfe) {
      final bed = sources[s];
      name = bed.label.isNotEmpty ? bed.label : 'ch ${bed.track}';
      hue = bedHue(s);
      az = bed.azimuth;
      el = bed.elevation;
      spread = bed.spread;
    } else {
      // An LFE or unresolved row selects, but has no direction to report.
      return;
    }
    // Every field is padded to its widest form and always drawn, spread
    // included when it is zero. Dropping a field or letting one shrink —
    // 10.0 stepping to 9.9, a clamp arrow appearing — reflows everything
    // after it, and at 60 frames a second that reads as the panel shaking.
    // The block is mono so the padding lines up.
    String fixed(double v, int width, {bool signed = false}) {
      // Round first, then drop the sign of a rounded zero: a value drifting
      // across it would otherwise flip between '0.0' and '-0.0'.
      final r = (v * 10).roundToDouble() / 10;
      final s = (r == 0 ? 0.0 : r).toStringAsFixed(1);
      return (signed && r > 0 ? '+$s' : s).padLeft(width);
    }

    // Distance is not reported here. It is an input to the spread below,
    // not an outcome, and after the layout-anchored conversion it is not a
    // radius at all — r_xy or |z| (ES-635) — which is the reading a number
    // in a live overlay invites. The row tooltip states the term, with
    // what it is, for anyone who wants it.
    //
    // The spread is the measured width of the render's image (ES-640), not
    // the drawn cap, so the number stays honest where the cap is capped at
    // a hemisphere.
    final clamp = el < 0 ? '→0°' : '   ';
    final line =
        'az ${fixed(az, 6, signed: true)}°   '
        'el ${fixed(el, 5)}°$clamp   '
        'spread ${fixed(spread, 5)}°';

    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        children: [
          TextSpan(
            text: '$name\n',
            style: TextStyle(color: hue, fontSize: T.fontCaption),
          ),
          TextSpan(
            text: line,
            style: TextStyle(
              fontFamily: T.monoFamily,
              color: T.textPrimary,
              fontSize: T.fontCaption,
              height: 1.45,
            ),
          ),
        ],
      ),
    )..layout();
    _drawPanel(canvas, tp, Offset(8, size.height - tp.height - 20));
    tp.dispose();
  }

  /// The unit sphere's silhouette, a hairline in the border colour. Drawn
  /// after the markers (see [paint]) so nothing filled to the rim can
  /// mottle it.
  void _paintSphereOutline(Canvas canvas, Offset center, double radius) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = T.border,
    );
  }

  /// The scene furniture the markers sit against: a ground disc
  /// (concentric horizon rings + radial spokes,
  /// the far half dimmed by depth), a vertical pole through the origin,
  /// a listener glyph at the centre, and F/B/L/R labels that stay pinned
  /// to the room as the view orbits.
  void _paintReferenceGeometry(Canvas canvas, Offset center, double radius) {
    // Ground disc: horizon rings at 1/3, 2/3 and 1 of the room radius.
    // Segmented so each piece can dim with its own depth — the far half
    // of the grid receding is what makes front/back unambiguous.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const segments = 48;
    for (final r in const [1 / 3, 2 / 3, 1.0]) {
      for (var i = 0; i < segments; i++) {
        final a0 = 2 * math.pi * i / segments;
        final a1 = 2 * math.pi * (i + 1) / segments;
        final p0 = _projectVec(
          r * math.cos(a0),
          0,
          r * math.sin(a0),
          center,
          radius,
        );
        final p1 = _projectVec(
          r * math.cos(a1),
          0,
          r * math.sin(a1),
          center,
          radius,
        );
        ring.color = T.border.withValues(
          alpha: (r == 1.0 ? 0.6 : 0.35) * _alphaFor(p0.$2),
        );
        canvas.drawLine(p0.$1, p1.$1, ring);
      }
    }
    // Radial spokes toward front/back/left/right. The origin projects to
    // the centre exactly, so each spoke runs centre → horizon point.
    final spoke = Paint()..strokeWidth = 1;
    for (final az in const [0.0, 90.0, 180.0, -90.0]) {
      final (o, depth) = _project(az, 0, center, radius);
      spoke.color = T.border.withValues(alpha: 0.35 * _alphaFor(depth));
      canvas.drawLine(center, o, spoke);
    }

    // Vertical pole through the origin: the one line that keeps "up"
    // legible at any orbit.
    final (top, topDepth) = _projectVec(0, 1, 0, center, radius);
    final (bottom, bottomDepth) = _projectVec(0, -1, 0, center, radius);
    final pole = Paint()
      ..strokeWidth = 1
      ..color = T.border.withValues(
        alpha: 0.35 * _alphaFor(math.max(topDepth, bottomDepth)),
      );
    canvas.drawLine(bottom, top, pole);

    // Listener at the centre, nose toward the front of the room.
    canvas.drawCircle(
      center,
      3,
      Paint()..color = T.textSecondary.withValues(alpha: 0.9),
    );
    final (front, _) = _project(0, 0, center, radius);
    final dir = front - center;
    if (dir.distance > 1e-3) {
      final u = dir / dir.distance;
      canvas.drawLine(
        center,
        center + u * 8,
        Paint()
          ..strokeWidth = 1.4
          ..color = T.textSecondary.withValues(alpha: 0.9),
      );
    }

    // Orientation labels, pinned to the room (ADM azimuth is
    // positive-left, so +90° is the left wall). Projected unclamped —
    // _project saturates distance at 1.0, which would pin the words onto
    // the rim clutter where the far ones drown — so they float clear,
    // just outside the sphere. Skipped on surfaces too small to carry
    // text without clutter.
    if (radius >= 60) {
      for (final (az, label) in const [
        (0.0, 'Front'),
        (180.0, 'Back'),
        (90.0, 'Left'),
        (-90.0, 'Right'),
      ]) {
        final v = CoordinateUtils.sphericalToVisualizer(az, 0, 1.18);
        final (o, _) = _projectVec(v.x, v.y, v.z, center, radius);
        // A word orbited to the screen edge must not leave the canvas:
        // clamp its anchor inside the paint bounds (center is size/2).
        final clamped = Offset(
          o.dx.clamp(16.0, center.dx * 2 - 16.0),
          o.dy.clamp(8.0, center.dy * 2 - 8.0),
        );
        _drawLabel(canvas, label, clamped, _orientationLabelCache);
      }
    }
  }

  /// Label painters are cached statically (the LabelPainterCache
  /// contract: this painter is reconstructed every orbit frame, so a
  /// per-instance cache would never survive one) — up to ~19 labels per
  /// frame at 60 Hz is exactly the per-frame TextPainter churn the cache
  /// exists for. The cost: cached spans bake their colour in, so label
  /// text keeps a fixed alpha instead of the per-depth modulation — the
  /// rings and markers beneath still carry the depth cue.
  static final _orientationLabelCache = LabelPainterCache(
    () => TextStyle(color: T.textSecondary, fontSize: T.fontMeter),
  );
  // The 3D scene's speaker labels share this style.
  static final _speakerLabelCache = LabelPainterCache(
    SceneLabelOverlay.labelStyle,
  );

  /// Paints [text] centred on [at] from [cache].
  void _drawLabel(
    Canvas canvas,
    String text,
    Offset at,
    LabelPainterCache cache,
  ) {
    final tp = cache.painterFor(text, fontMode, themeMode);
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  /// Whether object [i]'s path draws. Only the hovered or selected one
  /// does: a master with dozens of movers draws every path at once as an
  /// unreadable tangle, and the row under the cursor is the question being
  /// asked.
  bool _pathVisible(int i) => hoverObject == i || selObject == i;

  /// Widest angular step a single drawn chord may span before the segment
  /// subdivides along its great circle.
  ///
  /// A chord between two points on the hull passes inside it, by
  /// 1 − cos(θ/2) of the radius. Wide steps are the common case, not the
  /// exception: the probe's point budget leaves a dense mover's kept corners
  /// far apart, and 2825 of the 7698 segments in the sollevante master
  /// exceed 10°, the widest at 180°. Chords across those
  /// dive through the scene, which is the shape this fix removes everywhere
  /// else (ES-635). At 10° the residual sag is 0.38% of the radius, under a
  /// pixel at any canvas size the preview uses.
  static const double _kMaxArcStepDeg = 10;

  /// Chords to draw between two unit directions so none spans more than
  /// [_kMaxArcStepDeg]. 1 leaves the segment as the single chord it was.
  static int _arcSteps(Vector3 a, Vector3 b) {
    final deg = math.acos(a.dot(b).clamp(-1.0, 1.0)) * 180 / math.pi;
    return math.max(1, (deg / _kMaxArcStepDeg).ceil());
  }

  /// Spherical linear interpolation between two unit directions.
  ///
  /// Nearly parallel or exactly antiparallel inputs have no well-defined
  /// great circle between them. The first case is never subdivided; the
  /// second falls back to the chord rather than picking an arbitrary plane.
  static Vector3 _slerp(Vector3 a, Vector3 b, double u) {
    final theta = math.acos(a.dot(b).clamp(-1.0, 1.0));
    final sin = math.sin(theta);
    if (sin.abs() < 1e-6) return a * (1 - u) + b * u;
    return a * (math.sin((1 - u) * theta) / sin) +
        b * (math.sin(u * theta) / sin);
  }

  /// Emits object [i]'s trajectory into [entries]: one depth-sorted
  /// entry per segment, plus a filled start dot and an arrowhead at the
  /// end so travel direction is explicit rather than implied by the
  /// alpha ramp alone.
  void _addTrajectoryEntries(
    Canvas canvas,
    int i,
    Offset center,
    double radius,
    List<(double, void Function())> entries,
  ) {
    final t = objects[i].trajectory;
    if (t.length < 2 || !_pathVisible(i)) return;
    final emphasized = hoverObject == i || selObject == i;
    // A non-emphasized path (mode All) stays thin and pale — the tangle
    // must never outshout the marks; while something is emphasized the
    // rest recede further.
    final anyFocus = hoverObject != null || selObject != null;
    final dim = anyFocus && !emphasized ? 0.4 : 1.0;
    final startA = (emphasized ? 0.9 : 0.4) * dim;
    final endA = (emphasized ? 0.3 : 0.08) * dim;
    final width = emphasized ? 1.6 : 1.0;
    final color = objectHue(i);

    final dirs = [
      for (final p in t)
        CoordinateUtils.sphericalToVisualizer(p.az, admHullElevation(p.el), 1),
    ];
    // How diffusely the render images each vertex, measured per vertex by
    // the probe, so a path through the room interior or over the top ring
    // reads as the smear it renders as rather than as a sharp line.
    final spreads = [for (final p in t) p.spread];

    // One depth-sorted entry per authored segment, as before. Subdivision
    // adds vertices *inside* an entry rather than entries of its own: on a
    // heavy master it multiplies the drawn chords by about five, and paying
    // that in the depth sort and one closure each costs more paint time than
    // the whole rest of the scene.
    late Offset startO;
    late double startDepth;
    late Offset endO;
    late double endDepth;
    Offset tailFrom = Offset.zero;

    for (var s = 0; s < dirs.length - 1; s++) {
      final f = dirs.length == 2 ? 0.0 : s / (dirs.length - 2);
      final ramp = startA + (endA - startA) * f;
      final segSpread = (spreads[s] + spreads[s + 1]) / 2;
      final (a, depth) = _projectVec(
        dirs[s].x,
        dirs[s].y,
        dirs[s].z,
        center,
        radius,
      );
      if (s == 0) {
        startO = a;
        startDepth = depth;
      }
      final path = Path()..moveTo(a.dx, a.dy);
      var prev = a;
      final steps = _arcSteps(dirs[s], dirs[s + 1]);
      for (var k = 1; k <= steps; k++) {
        // Land on the authored endpoint exactly rather than on a slerp of
        // itself, so consecutive segments meet without a seam.
        final v = k == steps
            ? dirs[s + 1]
            : _slerp(dirs[s], dirs[s + 1], k / steps);
        final (o, d) = _projectVec(v.x, v.y, v.z, center, radius);
        path.lineTo(o.dx, o.dy);
        tailFrom = prev;
        prev = o;
        endO = o;
        endDepth = d;
      }
      // Widen and pale together where the image spreads: the ink stays
      // about constant, so a diffuse stretch reads as smeared rather than
      // as emphasized.
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * (1 + 1.8 * admSpreadWeight(segSpread))
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(
          alpha: ramp * _coreAlpha(segSpread) * _alphaFor(depth),
        );
      entries.add((depth, () => canvas.drawPath(path, paint)));
    }

    // Filled start dot: where the motion begins.
    entries.add((
      startDepth,
      () {
        canvas.drawCircle(
          startO,
          2.5 * _scaleFor(startDepth),
          Paint()
            ..color = color.withValues(alpha: startA * _alphaFor(startDepth)),
        );
      },
    ));

    // Arrowhead: oriented along the last chord drawn. Degenerate
    // (zero-length) tails skip it rather than drawing an unoriented mark.
    final tail = endO - tailFrom;
    if (tail.distance > 1e-3) {
      final u = tail / tail.distance;
      final n = Offset(-u.dy, u.dx);
      final len = 6 * _scaleFor(endDepth);
      final base = endO - u * len;
      entries.add((
        endDepth,
        () {
          final head = Path()
            ..moveTo(endO.dx, endO.dy)
            ..lineTo(base.dx + n.dx * len * 0.4, base.dy + n.dy * len * 0.4)
            ..lineTo(base.dx - n.dx * len * 0.4, base.dy - n.dy * len * 0.4)
            ..close();
          canvas.drawPath(
            head,
            Paint()
              ..color = color.withValues(
                alpha: (emphasized ? 0.8 : 0.4) * dim * _alphaFor(endDepth),
              ),
          );
        },
      ));
    }
  }

  /// A dim line from an elevated marker straight down to the ground
  /// plane — the standard 3D-scatter cue that makes elevation legible.
  /// Its foot lands at horizontal radius cos(el), so with everything on the
  /// hull the ground rings read as elevation contours rather than depth.
  void _drawDropLine(
    Canvas canvas,
    double az,
    double el,
    Offset center,
    double radius,
    Color color,
    double depth,
  ) => _drawDropLineVec(
    canvas,
    CoordinateUtils.sphericalToVisualizer(az, admHullElevation(el), 1),
    center,
    radius,
    color,
    depth,
  );

  /// [_drawDropLine] for a mark already placed as a hull vector, which an
  /// object on a scrubbed trajectory is: its direction is slerped between
  /// two vertices rather than named by one azimuth.
  void _drawDropLineVec(
    Canvas canvas,
    Vector3 v,
    Offset center,
    double radius,
    Color color,
    double depth,
  ) {
    if (v.y.abs() < 1e-3) return;
    final (top, _) = _projectVec(v.x, v.y, v.z, center, radius);
    final (foot, _) = _projectVec(v.x, 0, v.z, center, radius);
    canvas.drawLine(
      top,
      foot,
      Paint()
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.25 * _alphaFor(depth)),
    );
  }

  void _paintMarkers(Canvas canvas, Offset center, double radius) {
    // Depth-sort so nearer marks draw over farther ones — speakers, bed
    // sources and objects all in the one ordering.
    final entries = <(double depth, void Function() draw)>[];

    final layout = target.speakers;
    if (layout != null) {
      for (final sp in layout.speakers) {
        if (sp.isLFE) continue; // Routed, not panned; nothing to place.
        final (o, depth) = _project(sp.azDeg, sp.elDeg, center, radius);
        entries.add((
          depth,
          () {
            _drawDropLine(
              canvas,
              sp.azDeg,
              sp.elDeg,
              center,
              radius,
              T.textSecondary,
              depth,
            );
            final ringR = 4 * _scaleFor(depth);
            canvas.drawCircle(
              o,
              ringR,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.2
                ..color = T.textSecondary.withValues(
                  alpha: 0.75 * _alphaFor(depth),
                ),
            );
            // Name the ring — eleven identical circles are not a layout.
            if (radius >= 60) {
              _drawLabel(
                canvas,
                sp.label,
                o + Offset(0, ringR + 6),
                _speakerLabelCache,
              );
            }
          },
        ));
      }
    }

    for (var i = 0; i < sources.length; i++) {
      final s = sources[i];
      if (s.isLfe) continue; // Routed, not panned; nothing to place.
      final hull = _hullVec(s.azimuth, s.elevation);
      final (o, depth) = _projectVec(hull.x, hull.y, hull.z, center, radius);
      final color = bedHue(i);
      final spread = s.spread;
      final hovered = hoverSource == i || selSource == i;
      entries.add((
        depth,
        () {
          _drawDropLine(
            canvas,
            s.azimuth,
            s.elevation,
            center,
            radius,
            color,
            depth,
          );
          final r = 3.5 * _scaleFor(depth);
          _drawSpreadHalo(canvas, hull, center, radius, s.shape, color, depth);
          canvas.drawCircle(
            o,
            r,
            Paint()
              ..color = color.withValues(
                alpha: _coreAlpha(spread) * _alphaFor(depth),
              ),
          );
          if (hovered) _drawHoverRing(canvas, o, 6.5 * _scaleFor(depth));
        },
      ));
    }

    for (var i = 0; i < objects.length; i++) {
      final ob = objects[i];
      _addTrajectoryEntries(canvas, i, center, radius, entries);
      final (v, shape) = _objectStateAt(ob);
      final spread = shape.spread;
      final (o, depth) = _projectVec(v.x, v.y, v.z, center, radius);
      final hovered = hoverObject == i || selObject == i;
      entries.add((
        depth,
        () {
          _drawDropLineVec(canvas, v, center, radius, objectHue(i), depth);
          final r = 4.0 * _scaleFor(depth);
          _drawSpreadHalo(
            canvas,
            v,
            center,
            radius,
            shape,
            objectHue(i),
            depth,
          );
          final path = Path()
            ..moveTo(o.dx, o.dy - r)
            ..lineTo(o.dx + r, o.dy)
            ..lineTo(o.dx, o.dy + r)
            ..lineTo(o.dx - r, o.dy)
            ..close();
          canvas.drawPath(
            path,
            Paint()
              ..color = objectHue(
                i,
              ).withValues(alpha: _coreAlpha(spread) * _alphaFor(depth)),
          );
          if (hovered) _drawHoverRing(canvas, o, r + 3);
        },
      ));
    }

    for (final i in admDepthOrder([for (final e in entries) e.$1])) {
      entries[i].$2();
    }
  }

  /// A diffusely imaged source has no point to mark. The halo covers the
  /// patch of hull the render actually spreads it over, at the width the
  /// probe measured (ES-640); the core mark stays visible at reduced weight,
  /// since it is still the row's hit target and its identity colour.
  ///
  /// Weight of the far side of a halo relative to the near side. Both are
  /// drawn — a source imaged behind the listener spreads there too, and
  /// hiding it left the back of a busy scene looking empty — but the near
  /// side has to win the contrast, so the far one is thinned.
  static const double _kFarHaloAlpha = 0.38;

  /// Shortest half-width a halo is drawn at, in pixels. The measured figure
  /// is 0 for any pan inside one speaker layer, which is most of them, and
  /// a zero-width ellipse fills nothing.
  static const double _kMinHaloMinorPx = 1.5;

  /// ...and as a fraction of the halo's own width, which is what keeps a
  /// wide one coherent. A pixel floor is enough for a 9° front phantom, but
  /// the whole-ring case is 88° across, and 1.5 px of height under 88° of
  /// width reads as a hairline drawn across the sphere rather than as a
  /// flat image. Scaling the floor with the width gives that case about 5°
  /// and leaves the narrow ones where they were.
  static const double _kMinHaloRatio = 0.06;

  /// The image's widest axis in view space, for a mark on the hull at
  /// [hull] whose image is tilted [tiltDeg] from horizontal.
  ///
  /// The engine measures the tilt against the horizontal tangent at the
  /// image's centre, so the same basis is rebuilt here and rotated with the
  /// scene: the halo then keeps its orientation on the hull as the view
  /// orbits, instead of staying upright on screen.
  Vector3 _tiltAxisView(Vector3 hull, double tiltDeg) {
    // Horizontal tangent: perpendicular to the world's vertical (y up here)
    // and to the direction. A mark on the vertical axis has none, and its
    // image is round anyway, so any axis serves.
    var e1 = Vector3(hull.z, 0, -hull.x);
    if (e1.length2 < 1e-12) e1 = Vector3(1, 0, 0);
    e1.normalize();
    final e2 = hull.cross(e1)..normalize();
    final a = tiltDeg * math.pi / 180;
    final axis = e1 * math.cos(a) + e2 * math.sin(a);
    return _viewVec(axis.x, axis.y, axis.z);
  }

  /// Drawn as the patch of hull the cap actually covers ([admCapOutline]),
  /// not as its full projected ellipse: near the silhouette the far half of
  /// a cap projects back inside the sphere's disc, so filling the ellipse
  /// at one weight painted near and far surface identically, which is what
  /// made the halo read as a disc lying on the sphere. The two sides are
  /// filled separately instead, far first so the near one lies over it.
  void _drawSpreadHalo(
    Canvas canvas,
    Vector3 hull,
    Offset center,
    double radius,
    AdmImageShape shape,
    Color color,
    double depth,
  ) {
    final spreadDeg = shape.spread;
    if (spreadDeg < _kSpreadFloorDeg) return;
    // Opens to a band where the gains agree on no direction at all, so the
    // halo covers the ring the render is actually driving rather than a
    // patch centred on an arithmetic artefact.
    final major = admHaloMajorDeg(shape) * math.pi / 180;
    // Under half a pixel across there is nothing to draw.
    if (radius * math.sin(math.min(major, math.pi / 2)) < 0.5) return;
    // A flat image is a line, and a line fills no pixels. The short axis
    // gets a floor so the smear stays visible and keeps its direction, the
    // way a hairline path is still stroked at a minimum width: a pixel and
    // a half for a narrow halo, and a fraction of the width for a wide one,
    // whichever is larger. It is the one place the halo overstates the
    // render, and the fraction is a drawing decision rather than anything
    // measured.
    // The floor tracks the measured width, not the drawn major: opening a
    // halo into a band must not fatten it as well.
    final measured = admHaloRadiusDeg(spreadDeg) * math.pi / 180;
    final minorFloor = math.max(
      math.asin((_kMinHaloMinorPx / radius).clamp(0.0, 1.0)),
      _kMinHaloRatio * measured,
    );
    final minor = math
        .max(shape.ratio * measured, minorFloor)
        .clamp(0.0, major);
    final dir = _viewVec(hull.x, hull.y, hull.z);
    final base = 0.22 * admSpreadWeight(spreadDeg) * _alphaFor(depth);
    final axis = _tiltAxisView(hull, shape.tilt);
    // How much of this image has stopped being a patch with a direction.
    // The two shapes are cross-faded rather than morphed: an ellipse
    // stretched to a full ring tapers away at its ends where a band holds
    // its width, and it was that stretched ellipse that read as a sticker.
    final band = admBandFactor(shape.focus, shape.ratio);

    Path poly(List<Offset> outline) {
      final path = Path();
      for (var i = 0; i < outline.length; i++) {
        final dx = center.dx + outline[i].dx * radius;
        final dy = center.dy - outline[i].dy * radius;
        if (i == 0) {
          path.moveTo(dx, dy);
        } else {
          path.lineTo(dx, dy);
        }
      }
      return path..close();
    }

    for (final (far, weight) in [(true, _kFarHaloAlpha), (false, 1.0)]) {
      if (band < 1) {
        final outline = admCapOutline(
          dir,
          major,
          minorRad: minor,
          axis: axis,
          far: far,
        );
        if (outline != null) {
          canvas.drawPath(
            poly(outline),
            Paint()
              ..color = color.withValues(alpha: base * weight * (1 - band)),
          );
        }
      }
      if (band > 0) {
        // The near hemisphere covers the whole disc in projection, so the
        // band's own patch is the disc less each pole's cap. The caps are
        // cut out by even-odd filling one path rather than by
        // Path.combine: a cap's rim run lies on the disc's own edge, and
        // Skia's path ops fail on coincident edges ("Path.combine()
        // failed", seen while orbiting). Each cap is a simple polygon
        // inside the disc, so even-odd leaves exactly the band.
        final (a, b) = admBandCaps(dir, axis, minor, far: far);
        final path = Path()
          ..fillType = PathFillType.evenOdd
          ..addOval(Rect.fromCircle(center: center, radius: radius));
        for (final cap in [a, b]) {
          if (cap == null) continue;
          path.addPath(poly(cap), Offset.zero);
        }
        canvas.drawPath(
          path,
          Paint()..color = color.withValues(alpha: base * weight * band),
        );
      }
    }
  }

  /// Weight of the point mark itself, for an image measured [spreadDeg]
  /// wide: full for a point image, floored at 0.4 so a fully diffuse object
  /// can still be found and hovered.
  static double _coreAlpha(double spreadDeg) =>
      1.0 - 0.6 * admSpreadWeight(spreadDeg);

  /// Where object [ob] is at the previewed instant: the hull direction its
  /// mark goes on, and the measured image width that sizes its halo.
  ///
  /// The direction is slerped between the same two vertices the path draws
  /// between, so the mark rides on the drawn line instead of sitting beside
  /// it — a wide step's great circle and its azimuth/elevation lerp part
  /// company badly, and 577 of the 647 segments in the reported master
  /// exceed 10°. The width lerps linearly, the vertices already being
  /// samples of the render's own linear ramp.
  (Vector3, AdmImageShape) _objectStateAt(AdmProbeObject ob) {
    final seg = ob.segmentAt(time.value);
    if (seg == null) {
      return (
        CoordinateUtils.sphericalToVisualizer(
          ob.azimuth,
          admHullElevation(ob.elevation),
          1,
        ),
        ob.shape,
      );
    }
    final (i, u) = seg;
    final a = ob.trajectory[i];
    final b = ob.trajectory[i + 1];
    return (
      _slerp(
        CoordinateUtils.sphericalToVisualizer(a.az, admHullElevation(a.el), 1),
        CoordinateUtils.sphericalToVisualizer(b.az, admHullElevation(b.el), 1),
        u,
      ),
      (
        spread: a.spread + (b.spread - a.spread) * u,
        ratio: a.ratio + (b.ratio - a.ratio) * u,
        tilt: admLerpTilt(a.tilt, b.tilt, u),
        focus: a.focus + (b.focus - a.focus) * u,
      ),
    );
  }

  void _drawHoverRing(Canvas canvas, Offset o, double r) {
    canvas.drawCircle(
      o,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = T.textPrimary,
    );
  }

  @override
  bool shouldRepaint(_PositionPreviewPainter old) =>
      old.sources != sources ||
      old.objects != objects ||
      old.target.speakers != target.speakers ||
      old.hoverSource != hoverSource ||
      old.hoverObject != hoverObject ||
      old.selSource != selSource ||
      old.selObject != selObject ||
      old.time != time ||
      old.yawRad != yawRad ||
      old.pitchRad != pitchRad ||
      old.themeMode != themeMode ||
      old.fontMode != fontMode;
}
