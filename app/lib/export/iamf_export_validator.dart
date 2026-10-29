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

import '../state.dart' show AudioElement;
import 'iamf_export_config.dart';
import 'iamf_format_maps.dart'
    show expandedLoudspeakerLayoutName, loudspeakerLayoutName;
import 'iamf_profile_rules.dart' show ProfileConflictKind, profileConflicts;

/// Check whether the given config can be exported. Returns a list of
/// issues — errors block export, warnings inform the user.
///
/// [muxToMp4] is true when the deliverable is an MP4 (IAMF muxed with the
/// session video) rather than a bare `.iamf`; it gates the profiles the MP4
/// muxer can carry (see [_checkMuxTarget]).
///
/// Intentionally pure (no Riverpod, no file I/O) so it is trivially
/// unit-testable.
ExportValidationResult validateIamfExport(
  IamfExportConfig config, {
  bool muxToMp4 = false,
}) {
  final issues = <ExportIssue>[];

  _checkSessionShape(config, issues);
  _checkProfileCapacity(config, issues);
  _checkMuxTarget(config, muxToMp4, issues);
  _checkElementShape(config, issues);

  return ExportValidationResult(issues);
}

// ── Mux target ──────────────────────────────────────────────────────────

/// The highest profile index the MP4 muxer (libgpac) can carry. Profiles
/// 0/1/2 (Simple/Base/Base-Enhanced) are the ratified ones GPAC's IAMF
/// reframer accepts; 3/4/5 (the v2.0.0-draft Base-Advanced/Advanced-1/
/// Advanced-2) are rejected as non-compliant. Verified empirically by
/// `engine/test/iamf_gpac_limits_test.cc`.
const int _maxMp4ProfileIndex = 2;

/// MP4 export muxes the encoded `.iamf` into an ISOBMFF container via libgpac,
/// which only accepts the ratified profiles. Catch a draft profile here so the
/// export is blocked up front rather than after the (expensive) bounce +
/// encode, where it currently surfaces as a late "MP4 mux failed" error. Bare
/// `.iamf` export has no such limit, so this check is target-specific.
void _checkMuxTarget(IamfExportConfig c, bool muxToMp4, List<ExportIssue> out) {
  if (!muxToMp4 || c.profile.profileIndex <= _maxMp4ProfileIndex) return;
  out.add(
    ExportIssue(
      severity: ExportSeverity.error,
      code: ExportIssueCode.profileCannotMuxToMp4,
      message:
          'Profile "${c.profile.label}" can\'t be exported to MP4. MP4 export '
          'supports only the Simple, Base, and Base-Enhanced profiles. Export '
          'as an IAMF file instead, or pick one of those profiles.',
    ),
  );
}

// ── Session shape ───────────────────────────────────────────────────────

void _checkSessionShape(IamfExportConfig c, List<ExportIssue> out) {
  if (c.elements.isEmpty) {
    out.add(
      const ExportIssue(
        severity: ExportSeverity.error,
        code: ExportIssueCode.sessionNoElements,
        message: 'Session has no audio elements to export.',
      ),
    );
  }
  if (c.mixes.isEmpty) {
    out.add(
      const ExportIssue(
        severity: ExportSeverity.error,
        code: ExportIssueCode.sessionNoMixes,
        message: 'Session has no mix presentations.',
      ),
    );
  }
}

// ── Profile capacity ────────────────────────────────────────────────────

/// Maps a rule-engine [ProfileConflictKind] to the stable export issue code
/// the UI and logs key on. Exhaustive (a `switch` expression) so adding a
/// conflict kind to the engine forces a deliberate mapping here rather than
/// silently going uncoded.
String _codeForConflict(ProfileConflictKind kind) => switch (kind) {
  ProfileConflictKind.tooManyElements => ExportIssueCode.profileTooManyElements,
  ProfileConflictKind.tooManyChannels => ExportIssueCode.profileTooManyChannels,
  ProfileConflictKind.objectNotAllowed =>
    ExportIssueCode.profileObjectsNotAllowed,
  ProfileConflictKind.mixedTypesNotAllowed =>
    ExportIssueCode.profileMixedTypesNotAllowed,
  ProfileConflictKind.objectMixedWithOtherTypes =>
    ExportIssueCode.profileObjectMixedWithOtherTypes,
  ProfileConflictKind.firstMixNotObjectOnly =>
    ExportIssueCode.profileFirstMixNotObjectOnly,
  ProfileConflictKind.elementLayoutNotAllowed =>
    ExportIssueCode.profileElementLayoutNotAllowed,
  ProfileConflictKind.tooManyElementRefs =>
    ExportIssueCode.profileTooManyElementRefs,
  ProfileConflictKind.tooManySubMixes => ExportIssueCode.profileTooManySubMixes,
  ProfileConflictKind.mixLayoutNotAllowed =>
    ExportIssueCode.profileMixLayoutNotAllowed,
  ProfileConflictKind.headphonesModeNotAllowed =>
    ExportIssueCode.profileHeadphonesModeNotAllowed,
  ProfileConflictKind.binauralFilterNotAllowed =>
    ExportIssueCode.profileBinauralFilterNotAllowed,
};

void _checkProfileCapacity(IamfExportConfig c, List<ExportIssue> out) {
  // Single source of truth: the pure rule engine computes every way the pool
  // and mixes violate the target profile — element / channel / sub-mix /
  // element-reference counts, object & mixed-type rules, expanded element
  // layouts, mix output layouts, headphones mode and binaural filter. The
  // validator just surfaces them as export errors so loaded/older sessions
  // and any UI-bypass are still caught (matching the selection-time gating).
  for (final conflict in profileConflicts(
    elements: c.elements,
    mixes: c.mixes,
    profile: c.profile,
  )) {
    out.add(
      ExportIssue(
        severity: ExportSeverity.error,
        code: _codeForConflict(conflict.kind),
        message: conflict.message,
      ),
    );
  }

  // Codec Config OBU count — not modeled by the rule engine. Opus emits a
  // single shared config; LPCM dedups on source codec strings, matching
  // UserMetadataBuilder._codecConfigKey.
  final codecs = c.codec == IamfCodec.opus
      ? const {'OPUS'}
      : c.elements.map((e) => e.codec).toSet();
  if (codecs.length > c.profile.maxCodecConfigs) {
    out.add(
      ExportIssue(
        severity: ExportSeverity.error,
        code: ExportIssueCode.profileTooManyCodecConfigs,
        message:
            'Profile ${c.profile.label} allows '
            '${c.profile.maxCodecConfigs} codec config(s); session uses '
            '${codecs.length} (${(codecs.toList()..sort()).join(", ")}).',
      ),
    );
  }
}

// ── Element shape ───────────────────────────────────────────────────────

void _checkElementShape(IamfExportConfig c, List<ExportIssue> out) {
  for (final e in c.elements) {
    if (e.wavPath == null || e.wavPath!.isEmpty) {
      out.add(
        ExportIssue(
          severity: ExportSeverity.error,
          code: ExportIssueCode.elementMissingWav,
          message: 'Element "${e.name}" has no WAV source assigned.',
        ),
      );
      continue;
    }

    // Layouts we cannot map to an IAMF SS convention or ambisonics order
    // yet (e.g. "Custom(Nch)", unexpected strings).
    if (e.type == 'Channel' && !_isMappableChannelLayout(e.layout)) {
      out.add(
        ExportIssue(
          severity: ExportSeverity.error,
          code: ExportIssueCode.elementLayoutUnmappable,
          message:
              'Element "${e.name}" uses layout "${e.layout}", which cannot '
              'yet be mapped to an IAMF loudspeaker layout.',
        ),
      );
    }

    // WAV channel count vs declared layout.
    final declared = channelCountForLayout(e);
    final actual = e.wavInfo?.channels;
    if (actual != null && actual != declared) {
      out.add(
        ExportIssue(
          severity: ExportSeverity.warning,
          code: ExportIssueCode.elementChannelMismatch,
          message:
              'Element "${e.name}": WAV has $actual channels but layout '
              '"${e.layout}" expects $declared. iamf-tools may reject the '
              'encode unless inputRouting compensates.',
        ),
      );
    }
  }
}

// ── Layout helpers ──────────────────────────────────────────────────────

/// Channel count implied by an element's declared layout. Mirrors the
/// helper in `renderer_view.dart` but lives here to keep the validator
/// free of UI imports. Any drift will show up as
/// ELEMENT_CHANNEL_MISMATCH warnings during validation.
int channelCountForLayout(AudioElement e) {
  if (e.type == 'Scene') {
    final n = e.ambisonicsOrder;
    return (n + 1) * (n + 1); // 1OA=4, 2OA=9, 3OA=16, 4OA=25
  }
  if (e.type == 'Object') return e.isDual ? 2 : 1;
  return _channelCountForChannelLayout(e.layout);
}

int _channelCountForChannelLayout(String layout) {
  final l = layout.toLowerCase();
  if (l == 'mono') return 1;
  if (l == 'stereo' || l == 'binaural') return 2;
  if (l == '9.1.6') return 16;
  if (l == '7.1.5.4') return 17; // matches LoudspeakerLayout.channelCount
  if (l == '10.2.9.3') return 24;
  if (l == '7.1.4') return 12;
  if (l == '7.1.2') return 10;
  if (l == '7.1') return 8;
  if (l == '5.1.4') return 10;
  if (l == '5.1.2') return 8;
  if (l == '5.1') return 6;
  if (l == '3.1.2') return 6;
  // Custom(Nch)
  final m = RegExp(r'^custom\((\d+)ch\)$').firstMatch(l);
  if (m != null) return int.parse(m.group(1)!);
  return 0; // unmappable
}

bool _isMappableChannelLayout(String layout) {
  // "Mappable" means the textproto builder can emit a loudspeaker_layout for
  // it: either a standard LoudspeakerLayout or a fully-supported expanded
  // layout. Kept in lockstep with user_metadata_builder.dart so a layout that
  // passes validation never throws mid-export (e.g. 7.1.5.4, an expanded
  // layout with a valid enum but no render/label support yet, is blocked
  // up front rather than after the bounce + loudness phases).
  return loudspeakerLayoutName(layout) != null ||
      expandedLoudspeakerLayoutName(layout) != null;
}
