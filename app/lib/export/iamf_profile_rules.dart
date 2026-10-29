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

// IAMF profile rule engine — pure, UI-free profile-constraint logic.
//
// The limits follow the profile definitions in the IAMF spec and
// iamf-tools' profile_filter.cc, applied to Eclipsa Studio's data model.
//
// This is the single source of truth for "what does profile X permit", used
// to drive profile-aware UI gating (disable selections a profile can't fit)
// and export validation. Kept intentionally pure — no Riverpod, no file I/O,
// no UI imports — so it is trivially unit-testable.
//
// Two independent mechanisms decide legality, mirroring the spec:
//   1. The layout/feature filter — gates expanded layouts, head-locked
//      binaural and the binaural_filter_profile field by the spec version a
//      profile complies with (IamfSpecVersion).
//   2. The channel budget — caps summed pre-mix element channels per profile
//      (16 / 18 / 28); it can reject a large layout the filter would allow.

import '../models/audio_element_enums.dart';
import '../state.dart';

// ── Spec-version requirements per feature ───────────────────────────────

/// Lowest spec version that defines [layout] as a channel-element layout.
/// Standard layouts exist from v1.0.0; 9.1.6 arrived in v1.1.0; 7.1.5.4 and
/// 10.2.9.3 are v2.0.0 expanded layouts.
IamfSpecVersion minSpecVersionForLayout(LoudspeakerLayout layout) {
  switch (layout) {
    case LoudspeakerLayout.k9_1_6:
      return IamfSpecVersion.v1_1;
    case LoudspeakerLayout.k7_1_5_4:
    case LoudspeakerLayout.k10_2_9_3:
      return IamfSpecVersion.v2_0;
    default:
      return IamfSpecVersion.v1_0;
  }
}

/// Lowest spec version that defines [system] as a mix-presentation output
/// (loudness) layout. Expanded output layouts gate like the element layouts:
/// 9.1.6 → v1.1.0; 7.1.5.4 and 10.2.9.3 (SS-H, a.k.a. 22.2) → v2.0.0.
IamfSpecVersion minSpecVersionForSoundSystem(SoundSystem system) {
  switch (system) {
    case SoundSystem.surround9_1_6:
      return IamfSpecVersion.v1_1;
    case SoundSystem.surround7_1_5_4:
    case SoundSystem.surround10_2_9_3:
      return IamfSpecVersion.v2_0;
    default:
      return IamfSpecVersion.v1_0;
  }
}

/// Lowest spec version that defines headphones rendering [mode]. Stereo (0)
/// and binaural world-locked (1) exist from v1.0.0; head-locked binaural (2)
/// is a v2.0.0 addition.
IamfSpecVersion minSpecVersionForHeadphonesMode(HeadphonesRenderingMode mode) {
  return mode == HeadphonesRenderingMode.binauralHeadLocked
      ? IamfSpecVersion.v2_0
      : IamfSpecVersion.v1_0;
}

// ── Per-profile "is this allowed" predicates ────────────────────────────

/// Whether [profile]'s spec version permits the channel-element [layout].
/// Does not account for the channel budget — a layout can pass this yet
/// still blow the per-profile channel cap (see [profileConflicts]).
bool profileAllowsLayout(IamfProfile profile, LoudspeakerLayout layout) =>
    profile.specVersion.atLeast(minSpecVersionForLayout(layout));

/// Whether [profile]'s spec version permits the output (loudness) [system].
bool profileAllowsSoundSystem(IamfProfile profile, SoundSystem system) =>
    profile.specVersion.atLeast(minSpecVersionForSoundSystem(system));

/// Whether [profile] permits headphones rendering [mode].
bool profileAllowsHeadphonesMode(
  IamfProfile profile,
  HeadphonesRenderingMode mode,
) => profile.specVersion.atLeast(minSpecVersionForHeadphonesMode(mode));

/// Whether [profile] defines the `binaural_filter_profile` field (v2.0.0+).
bool profileAllowsBinauralFilterProfile(IamfProfile profile) =>
    profile.specVersion.atLeast(IamfSpecVersion.v2_0);

/// Whether [profile] permits an audio element of [type] ('Channel' /
/// 'Scene' / 'Object'). Only object-based elements are profile-gated.
bool profileAllowsElementType(IamfProfile profile, String type) =>
    type != 'Object' || profile.allowObjectBased;

/// Whether [profile] permits element config [c]: object-based configs need
/// `allowObjectBased`, expanded channel layouts need the spec version that
/// introduced them, and the config's own channel count must fit the
/// profile's budget — a config that alone exceeds it (4OA's 25ch vs
/// Base's 18) can never fit, regardless of session contents. This is
/// what actually caps ambisonic order: the spec has no per-profile
/// order field. Session-dependent rules (summed channels, mixed types)
/// are still out of scope here.
bool profileAllowsConfig(IamfProfile profile, ElementConfig c) {
  if (!profileAllowsElementType(profile, c.type)) return false;
  final layout = c.layout == null
      ? null
      : LoudspeakerLayout.fromDisplayName(c.layout!);
  if (layout != null && !profileAllowsLayout(profile, layout)) return false;
  return _configChannelCount(c) <= profile.maxChannels;
}

/// Channel count of config [c] for the budget gate. Unlike
/// [elementConfigChannelCount] (whose caller-supplied fallback would
/// defeat the gate), this parses `Custom (Nch)` layouts via
/// [_channelLayoutChannelCount]; a truly unmappable layout yields 0 —
/// budget-checked at the session level only.
int _configChannelCount(ElementConfig c) {
  switch (c.type) {
    case 'Scene':
      return ambisonicsChannelCount(c.ambisonicsOrder ?? 1);
    case 'Object':
      return (c.isDual ?? false) ? 2 : 1;
    default:
      return _channelLayoutChannelCount(c.layout ?? '');
  }
}

/// Element configs for a [channels]-channel WAV that [profile] permits, in
/// [validConfigsForChannelCount] order (recommended first). More than one
/// entry means the interpretation is ambiguous and import should ask the
/// user instead of guessing (ES-152).
List<ElementConfig> profileAllowedConfigsForChannelCount(
  IamfProfile profile,
  int channels,
) => validConfigsForChannelCount(
  channels,
).where((c) => profileAllowsConfig(profile, c)).toList();

// ── "Minimum profile for feature X" (for UI explainers) ─────────────────

/// First profile (in `IamfProfile.values` order) satisfying [test], or null.
/// Relies on `IamfProfile.values` being declared in ascending-capability
/// order, so the first match is the lowest-capability profile — keep the
/// enum declaration in that order.
IamfProfile? _firstProfileWhere(bool Function(IamfProfile) test) {
  for (final p in IamfProfile.values) {
    if (test(p)) return p;
  }
  return null;
}

/// Lowest-capability profile that permits [layout], or null if none does.
/// Powers tooltips like "9.1.6 requires Base-Enhanced or higher". Considers
/// the layout filter only, not the channel budget. IamfProfile.values is
/// declared in ascending capability order, so the first match is the lowest.
IamfProfile? minProfileForLayout(LoudspeakerLayout layout) =>
    _firstProfileWhere((p) => profileAllowsLayout(p, layout));

/// Lowest-capability profile whose channel budget fits [channels], or null
/// if none does (> 28). Powers reasons like "4OA needs Base-Enhanced".
IamfProfile? minProfileForChannelCount(int channels) =>
    _firstProfileWhere((p) => channels <= p.maxChannels);

/// Lowest-capability profile that permits output [system], or null.
IamfProfile? minProfileForSoundSystem(SoundSystem system) =>
    _firstProfileWhere((p) => profileAllowsSoundSystem(p, system));

/// Lowest-capability profile that permits headphones rendering [mode], or
/// null.
IamfProfile? minProfileForHeadphonesMode(HeadphonesRenderingMode mode) =>
    _firstProfileWhere((p) => profileAllowsHeadphonesMode(p, mode));

/// Lowest-capability profile that defines `binaural_filter_profile`, or null.
IamfProfile? minProfileForBinauralFilterProfile() =>
    _firstProfileWhere(profileAllowsBinauralFilterProfile);

/// Lowest-capability profile that permits element [type], or null.
IamfProfile? minProfileForElementType(String type) =>
    _firstProfileWhere((p) => profileAllowsElementType(p, type));

/// Lowest-capability profile that permits element config [c], or null.
/// Powers explainers like "9.1.6 needs Base-Enhanced" on gated options.
IamfProfile? minProfileForConfig(ElementConfig c) =>
    _firstProfileWhere((p) => profileAllowsConfig(p, c));

/// Lowest-capability profile that fits the whole session ([elements] +
/// [mixes]) with no conflicts, or null if none does. Powers the
/// load-time validation notice's switch-profile offer (ES-490).
IamfProfile? minProfileForSession({
  required List<AudioElement> elements,
  required List<Mix> mixes,
}) => _firstProfileWhere(
  (p) => profileFits(elements: elements, mixes: mixes, profile: p),
);

// ── Channel accounting ──────────────────────────────────────────────────

/// Channels attributable to a single audio element, for the per-profile
/// channel budget. Scene → (order+1)²; Object → 1 (mono) or 2 (dual);
/// Channel → the layout's channel count. Uses [LoudspeakerLayout] (the model
/// truth) so it stays correct as the enum evolves.
int audioElementChannelCount(AudioElement element) {
  switch (element.type) {
    case 'Scene':
      return ambisonicsChannelCount(element.ambisonicsOrder);
    case 'Object':
      return element.isDual ? 2 : 1;
    default:
      return _channelLayoutChannelCount(element.layout);
  }
}

int _channelLayoutChannelCount(String layout) {
  final known = LoudspeakerLayout.fromDisplayName(layout);
  if (known != null) return known.channelCount;
  // `\s*` tolerates the space in the "Custom (Nch)" form emitted by
  // validConfigsForChannelCount (audio_element_enums.dart) as well as a
  // bare "Custom(Nch)".
  final custom = RegExp(r'^[Cc]ustom\s*\((\d+)ch\)$').firstMatch(layout.trim());
  if (custom != null) return int.parse(custom.group(1)!);
  return 0; // Unmappable — surfaced as a separate validation error.
}

// ── Conflicts: how a session violates a target profile ──────────────────

/// The kind of profile violation, for grouping/styling and so callers can
/// react to specific conflicts.
enum ProfileConflictKind {
  /// Pool has more audio elements than the profile allows.
  tooManyElements,

  /// Summed element channels exceed the profile's channel budget.
  tooManyChannels,

  /// Object-based elements present in a profile that forbids them.
  objectNotAllowed,

  /// More than one element type present in a profile that forbids mixing.
  mixedTypesNotAllowed,

  /// A mix presentation references object-based elements together with
  /// channel- or scene-based ones in a profile that requires object-only
  /// mix presentations.
  objectMixedWithOtherTypes,

  /// Some mix presentation includes object-based elements, and the first
  /// includes none, in a profile that requires the first to be
  /// object-only then.
  firstMixNotObjectOnly,

  /// A channel element uses an expanded layout the profile predates.
  elementLayoutNotAllowed,

  /// A mix presentation references more elements than the profile allows.
  tooManyElementRefs,

  /// A mix presentation has more sub-mixes than the profile allows.
  tooManySubMixes,

  /// A sub-mix uses an output layout the profile predates.
  mixLayoutNotAllowed,

  /// An element reference uses a headphones mode the profile predates.
  headphonesModeNotAllowed,

  /// An element reference sets a binaural filter profile the profile predates.
  binauralFilterNotAllowed,
}

/// One concrete way the current session violates a target profile's caps.
class ProfileConflict {
  /// Discriminator for grouping/styling and caller logic.
  final ProfileConflictKind kind;

  /// Terse suffix for a profile-dropdown option (e.g. "−2 AE", "no 9.1.6").
  final String shortLabel;

  /// Full sentence explaining what would have to change to switch.
  final String message;

  const ProfileConflict({
    required this.kind,
    required this.shortLabel,
    required this.message,
  });

  @override
  String toString() => 'ProfileConflict($kind, "$shortLabel")';
}

/// Whether [profile] can represent the given session with no conflicts.
bool profileFits({
  required List<AudioElement> elements,
  required List<Mix> mixes,
  required IamfProfile profile,
}) => profileConflicts(
  elements: elements,
  mixes: mixes,
  profile: profile,
).isEmpty;

/// Every way [elements] + [mixes] violate [profile]'s caps. Empty means the
/// session is valid under the profile. Used to disable infeasible profiles
/// in the picker (and tell the user exactly what to change) and as the basis
/// for export validation.
///
/// Covers the per-profile caps, the sub-mix count and the mix output
/// layouts (`mixLayoutNotAllowed`). Channel counts are summed across the
/// whole pool (matching the export validator), not per mix presentation.
List<ProfileConflict> profileConflicts({
  required List<AudioElement> elements,
  required List<Mix> mixes,
  required IamfProfile profile,
}) {
  final issues = <ProfileConflict>[];

  // Audio element count.
  if (elements.length > profile.maxAudioElements) {
    final over = elements.length - profile.maxAudioElements;
    issues.add(
      ProfileConflict(
        kind: ProfileConflictKind.tooManyElements,
        shortLabel: '−$over AE',
        message:
            'Session has ${elements.length} audio elements; '
            '${profile.label} allows ${profile.maxAudioElements}.',
      ),
    );
  }

  // Channel budget. Summed across the whole element pool, matching the
  // existing export validator. The spec defines the cap per mix
  // presentation (sum of the AEs a single MP references); pool-wide is an
  // overestimate when mixes reference different subsets — revisit if a
  // future phase moves this to per-MP scope.
  final totalChannels = elements.fold<int>(
    0,
    (sum, e) => sum + audioElementChannelCount(e),
  );
  if (totalChannels > profile.maxChannels) {
    final over = totalChannels - profile.maxChannels;
    issues.add(
      ProfileConflict(
        kind: ProfileConflictKind.tooManyChannels,
        shortLabel: '−$over ch',
        message:
            'Session totals $totalChannels channels; '
            '${profile.label} allows ${profile.maxChannels}.',
      ),
    );
  }

  // Object-based elements.
  if (!profile.allowObjectBased && elements.any((e) => e.type == 'Object')) {
    issues.add(
      ProfileConflict(
        kind: ProfileConflictKind.objectNotAllowed,
        shortLabel: 'no Object',
        message:
            '${profile.label} does not support object-based audio '
            'elements; convert or remove them.',
      ),
    );
  }

  // Mixed element types.
  final types = elements.map((e) => e.type).toSet();
  if (types.length > 1 && !profile.allowMixedTypes) {
    issues.add(
      ProfileConflict(
        kind: ProfileConflictKind.mixedTypesNotAllowed,
        shortLabel: 'one type only',
        message:
            '${profile.label} does not allow mixing element types '
            '(${(types.toList()..sort()).join(", ")}).',
      ),
    );
  }

  final byId = {for (final e in elements) e.id: e};

  // Base-Advanced's object rules, as iamf-tools' profile filter applies
  // them. A mix presentation that includes object-based elements must
  // include only object-based elements: the encoder drops Base-Advanced
  // for one that does not. When any mix presentation includes object-based
  // elements, the first must include only object-based elements: the
  // decoder rejects the whole file otherwise. Types are counted over each
  // mix presentation's included elements across all its sub-mixes.
  if (profile.requiresObjectOnlyMixes && mixes.isNotEmpty) {
    final mixTypes = [
      for (final m in mixes)
        {
          for (final sm in m.subMixes)
            for (final s in sm.elementSettings)
              if (s.included && byId[s.elementId] != null)
                byId[s.elementId]!.type,
        },
    ];
    final mixedNames = [
      for (var i = 0; i < mixes.length; i++)
        if (mixTypes[i].contains('Object') && mixTypes[i].length > 1)
          '"${mixes[i].name}"',
    ];
    if (mixedNames.isNotEmpty) {
      final one = mixedNames.length == 1;
      issues.add(
        ProfileConflict(
          kind: ProfileConflictKind.objectMixedWithOtherTypes,
          shortLabel: 'object-only mixes',
          message:
              'Mix presentation${one ? '' : 's'} ${mixedNames.join(', ')} '
              'include${one ? 's' : ''} object-based elements together '
              'with channel- or scene-based elements, which '
              '${profile.label} does not support. Move the object-based '
              'elements to a mix presentation of their own.',
        ),
      );
    }
    // A first mix presentation that includes object-based elements and
    // others is reported above; this covers one without object-based
    // elements, empty included.
    final anyObjects = mixTypes.any((t) => t.contains('Object'));
    if (anyObjects && !mixTypes.first.contains('Object')) {
      issues.add(
        ProfileConflict(
          kind: ProfileConflictKind.firstMixNotObjectOnly,
          shortLabel: 'object mix first',
          message:
              '${profile.label} requires the first mix presentation to '
              'include only object-based elements when any mix '
              'presentation includes them, and the first, '
              '"${mixes.first.name}", does not. Move a mix presentation '
              'with only object-based elements to the first position in '
              'the Mix view.',
        ),
      );
    }
  }

  // Expanded channel-element layouts the profile predates.
  final badLayouts = <String>{};
  for (final e in elements) {
    if (e.type != 'Channel') continue;
    final layout = LoudspeakerLayout.fromDisplayName(e.layout);
    if (layout != null && !profileAllowsLayout(profile, layout)) {
      badLayouts.add(layout.displayName);
    }
  }
  if (badLayouts.isNotEmpty) {
    final list = (badLayouts.toList()..sort()).join(' / ');
    issues.add(
      ProfileConflict(
        kind: ProfileConflictKind.elementLayoutNotAllowed,
        shortLabel: 'no $list',
        message:
            '${profile.label} does not support the $list loudspeaker '
            'layout${badLayouts.length == 1 ? '' : 's'}.',
      ),
    );
  }

  // Sub-mix count per mix presentation.
  final overSubMixes = mixes
      .where((m) => m.subMixes.length > profile.maxSubMixesPerMix)
      .length;
  if (overSubMixes > 0) {
    issues.add(
      ProfileConflict(
        kind: ProfileConflictKind.tooManySubMixes,
        shortLabel: 'sub-mixes',
        message:
            '$overSubMixes mix presentation'
            '${overSubMixes == 1 ? '' : 's'} exceed '
            '${profile.maxSubMixesPerMix} sub-mix'
            '${profile.maxSubMixesPerMix == 1 ? '' : 'es'}.',
      ),
    );
  }

  // Audio element references per mix presentation (distinct included
  // elements across the mix's sub-mixes). `maxAudioElements` doubles as
  // the per-MP reference cap: it equals the per-MP audio element limit
  // for every profile in the matrix. Split into its own field if that
  // ever diverges.
  final overRefs = mixes.where((m) {
    final ids = <int>{};
    for (final sm in m.subMixes) {
      for (final s in sm.elementSettings) {
        if (s.included) ids.add(s.elementId);
      }
    }
    return ids.length > profile.maxAudioElements;
  }).length;
  if (overRefs > 0) {
    issues.add(
      ProfileConflict(
        kind: ProfileConflictKind.tooManyElementRefs,
        shortLabel: 'refs in $overRefs MP',
        message:
            '$overRefs mix presentation${overRefs == 1 ? '' : 's'} '
            'reference more than ${profile.maxAudioElements} audio '
            'element${profile.maxAudioElements == 1 ? '' : 's'}.',
      ),
    );
  }

  // Output (loudness) layouts the profile predates.
  final badSystems = <String>{};
  for (final m in mixes) {
    for (final sm in m.subMixes) {
      for (final layout in sm.layouts) {
        if (!profileAllowsSoundSystem(profile, layout.soundSystem)) {
          badSystems.add(layout.soundSystem.uiLabel);
        }
      }
    }
  }
  if (badSystems.isNotEmpty) {
    final list = (badSystems.toList()..sort()).join(' / ');
    issues.add(
      ProfileConflict(
        kind: ProfileConflictKind.mixLayoutNotAllowed,
        shortLabel: 'no $list',
        message:
            '${profile.label} does not support the $list output '
            'layout${badSystems.length == 1 ? '' : 's'}.',
      ),
    );
  }

  // Per-reference RenderingConfig (§3.7) values that the profile predates.
  // A channel-based Binaural element's rendering config is locked to Stereo
  // in the UI and forced to defaults via effectiveHeadphonesMode, so a
  // leftover value on its reference is unresolvable by the user — exclude it
  // so we never raise a conflict the locked control offers no way to fix.
  final refs = <({MixElementSettings settings, AudioElement element})>[];
  for (final m in mixes) {
    for (final sm in m.subMixes) {
      for (final s in sm.elementSettings) {
        if (!s.included) continue;
        final el = byId[s.elementId];
        if (el == null || el.isChannelBasedBinaural) continue;
        refs.add((settings: s, element: el));
      }
    }
  }

  // Headphones rendering mode.
  final badModes = <String>{};
  for (final r in refs) {
    final mode = r.settings.effectiveHeadphonesMode(r.element);
    if (!profileAllowsHeadphonesMode(profile, mode)) {
      badModes.add(mode.label);
    }
  }
  if (badModes.isNotEmpty) {
    issues.add(
      ProfileConflict(
        kind: ProfileConflictKind.headphonesModeNotAllowed,
        shortLabel: 'no head-locked',
        message:
            '${profile.label} does not define headphones rendering mode '
            '${(badModes.toList()..sort()).join(' / ')} '
            '(head-locked binaural is v2.0.0 only); reset the affected '
            'element references.',
      ),
    );
  }

  // Binaural filter profile (a v2.0.0 field).
  if (!profileAllowsBinauralFilterProfile(profile)) {
    final withFilter = refs
        .where((r) => r.settings.binauralProfile != BinauralProfile.ambient)
        .length;
    if (withFilter > 0) {
      issues.add(
        ProfileConflict(
          kind: ProfileConflictKind.binauralFilterNotAllowed,
          shortLabel: 'no binaural filter',
          message:
              '${profile.label} predates binaural_filter_profile (a '
              'v2.0.0 field); $withFilter element reference'
              '${withFilter == 1 ? '' : 's'} would lose a non-default value.',
        ),
      );
    }
  }

  return issues;
}
