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

import 'package:path/path.dart' as p;

import '../state.dart' show AudioElement, Mix, IamfProfile;

/// Default IAMF codec frame size. iamf-tools' CLI uses 1024 for LPCM by
/// default; we match until we expose this as a session preference.
const int kDefaultFramesPerCodedBlock = 1024;

/// Opus frame size: fixed at 960 samples (20 ms at 48 kHz), the IAMF
/// ecosystem's standard Opus cadence. The LPCM frame-size options do
/// not apply to Opus.
const int kOpusFramesPerCodedBlock = 960;

/// libopus encoder lookahead in samples at 48 kHz (the rate IAMF Opus
/// streams operate at), as iamf-tools' encoder reports via
/// `GetEncoderDelay()` and stamps into the Codec Config's `pre_skip`.
/// Used by [exportPadTarget] to keep the end trim spec-legal (ES-485).
const int kOpusEncoderDelay = 312;

/// Default Opus `target_bitrate_per_channel` (bits/s). Coupled pairs
/// get twice this (iamf-tools' `coupling_rate_adjustment` stays at its
/// 1.0 default), so the total stream bitrate is simply
/// per-channel rate x total channel count.
const int kDefaultOpusBitratePerChannel = 64000;

/// Per-channel bitrates offered in the export dialog (bits/s).
const List<int> kOpusBitratePerChannelOptions = [
  32000,
  48000,
  64000,
  96000,
  128000,
];

/// IAMF codecs exposed on the export path. Export codecs are LPCM and
/// Opus only; AAC-LC and FLAC are out of scope for authoring. Playback
/// (decode) accepts all four IAMF v1.x codecs.
enum IamfCodec {
  lpcm('LPCM', 'Uncompressed PCM (lossless).'),
  opus('Opus', 'Lossy compression at 48 kHz for smaller deliverables.');

  final String label;
  final String description;
  const IamfCodec(this.label, this.description);
}

/// Default LPCM bit depth for the encoder. Matches what Eclipsa Studio writes
/// for new sessions when the source material's bit depth is unknown.
const int kDefaultBitDepth = 24;

/// IAMF target sample rate — a property of the deliverable, decoupled
/// from whatever rate the engine/device happens to run at. 48 kHz is
/// the IAMF ecosystem standard; sources at other rates are resampled
/// by the bounce stage, and 48 kHz sources pass through untouched.
const int kIamfTargetSampleRate = 48000;

/// Inputs to the IAMF exporter. Constructed once per export job from the
/// session state; consumed by [validateIamfExport] and
/// `UserMetadataBuilder`.
class IamfExportConfig {
  /// IAMF profile selected for the session.
  final IamfProfile profile;

  /// IAMF target sample rate in Hz ([kIamfTargetSampleRate]). The
  /// Codec Config OBU, every bounced WAV, and the loudness measurement
  /// pass all run at this rate.
  final int sampleRate;

  /// Bit depth written to the IAMF codec config (LPCM only; ignored
  /// for Opus).
  final int bitDepth;

  /// iamf-tools `num_samples_per_frame`. Must be
  /// [kOpusFramesPerCodedBlock] when [codec] is [IamfCodec.opus].
  final int framesPerCodedBlock;

  /// Codec written to the IAMF codec config OBU(s).
  final IamfCodec codec;

  /// Opus `target_bitrate_per_channel` in bits/s (Opus only).
  final int opusBitratePerChannel;

  /// Session audio elements, in UI order.
  final List<AudioElement> elements;

  /// Session mix presentations, in UI order. All are emitted.
  final List<Mix> mixes;

  /// Mapping from element id → unique basename. The basename is the
  /// `audio_frame_metadata.wav_filename` join key in the textproto
  /// (which the push encoder resolves element ids/labels through).
  /// Keyed per element so elements sharing one source WAV still get
  /// distinct join keys — see [uniqueWavBasenames].
  final Map<int, String> wavBasenames;

  /// Target `.iamf` output path. Parent directory must exist.
  final String outputPath;

  /// Common target length (in frames, per channel) that every bounced
  /// WAV is padded to — computed by [exportPadTarget]: a whole multiple
  /// of [framesPerCodedBlock] for LPCM, a multiple minus
  /// [kOpusEncoderDelay] for Opus (ES-485). 0 means no padding.
  final int paddedFrames;

  /// Longest source-WAV length across all elements, expressed in
  /// TARGET-rate frames (source lengths are converted by
  /// sourceRate → [sampleRate] before taking the max). When
  /// [paddedFrames] > this value, iamf-tools `samples_to_trim_at_end`
  /// = paddedFrames - longestSourceFrames — the same value for every
  /// substream. 0 disables the shared-trim calculation. For a
  /// video-clamped MP4 export ([isPartialRange]) this is the clamped
  /// length, not the true longest source — see [effectiveExportFrames].
  final int longestSourceFrames;

  /// True when the exported audio covers less than the full session
  /// timeline — the MP4 target clamps the render to the video length
  /// (ES-457), so nothing ships that the muxer's edit list would never
  /// play. Forces the loudness measure pass (cached full-timeline
  /// measurements cannot serve a partial timeline) and blocks
  /// persisting the partial measurements back into the session.
  final bool isPartialRange;

  const IamfExportConfig({
    required this.profile,
    required this.sampleRate,
    required this.elements,
    required this.mixes,
    required this.wavBasenames,
    required this.outputPath,
    this.bitDepth = kDefaultBitDepth,
    this.framesPerCodedBlock = kDefaultFramesPerCodedBlock,
    this.codec = IamfCodec.lpcm,
    this.opusBitratePerChannel = kDefaultOpusBitratePerChannel,
    this.paddedFrames = 0,
    this.longestSourceFrames = 0,
    this.isPartialRange = false,
  }) : assert(
         codec != IamfCodec.opus ||
             framesPerCodedBlock == kOpusFramesPerCodedBlock,
         'Opus requires framesPerCodedBlock == $kOpusFramesPerCodedBlock',
       );

  /// The join-key basename for the element [elementId] — the single
  /// place this is computed. The textproto builder writes it as
  /// `audio_frame_metadata.wav_filename` and the push-export elements
  /// carry the same value, so the engine's join always resolves; a
  /// drift between the two would fail the encode with "no
  /// audio_frame_metadata" (-12). Keyed per element (not per source
  /// WAV) so elements sharing one file keep distinct join keys and
  /// distinct audio_element_ids. [wavBasenames] covers every element
  /// with a source WAV, so the [wavPath] fallback is defensive only.
  String basenameFor(int elementId, String wavPath) =>
      wavBasenames[elementId] ?? p.basename(wavPath);
}

/// Length an export will actually render, in TARGET-rate frames, given
/// the full audio length [longestFrames] and the session video length
/// [videoFrames] (0 = no video / unknown yet). The MP4 target
/// ([isMp4]) clamps to the video end (ES-457) so no audio ships that the
/// muxer's edit list would never play — and so loudness is measured
/// over exactly what a viewer hears. Audio shorter than the video is
/// left alone (silence under the remaining picture). IAMF-only always
/// exports the full timeline.
int effectiveExportFrames({
  required int longestFrames,
  required int videoFrames,
  required bool isMp4,
}) {
  if (!isMp4) return longestFrames;
  return videoFrames > 0 && videoFrames < longestFrames
      ? videoFrames
      : longestFrames;
}

/// Common pad target for the export, in TARGET-rate frames: every
/// element is padded to this length and `samples_to_trim_at_end` is
/// the alignment pad (target − [lengthFrames]).
///
/// LPCM aligns [lengthFrames] up to the next coded-frame multiple.
/// Opus must account for the encoder delay: iamf-tools prepends and
/// start-trims the [kOpusEncoderDelay] lookahead samples, which shifts
/// the substream off the frame grid and turns the shift remainder into
/// extra end-trim padding. If the declared trim plus that padding
/// reaches a full frame, the encode is rejected ("the spec disallows
/// trimming multiple frames from the end", ES-485) — so for Opus the
/// target aligns `length + delay` to the grid instead, zeroing the
/// delay padding and leaving only the < 1-frame alignment trim.
int exportPadTarget({
  required int lengthFrames,
  required int framesPerCodedBlock,
  required IamfCodec codec,
}) {
  if (lengthFrames <= 0 || framesPerCodedBlock <= 0) return 0;
  final delay = codec == IamfCodec.opus ? kOpusEncoderDelay : 0;
  final gross = lengthFrames + delay;
  final aligned =
      ((gross + framesPerCodedBlock - 1) ~/ framesPerCodedBlock) *
      framesPerCodedBlock;
  return aligned - delay;
}

enum ExportSeverity { error, warning }

/// Stable machine-readable codes for export issues. UI can key on these
/// to render structured guidance; logs use them for grep-ability.
class ExportIssueCode {
  static const profileObjectsNotAllowed = 'PROFILE_OBJECTS_NOT_ALLOWED';
  static const profileTooManyElements = 'PROFILE_TOO_MANY_ELEMENTS';
  static const profileTooManyChannels = 'PROFILE_TOO_MANY_CHANNELS';
  static const profileTooManySubMixes = 'PROFILE_TOO_MANY_SUBMIXES';
  static const profileTooManyElementRefs = 'PROFILE_TOO_MANY_ELEMENT_REFS';
  static const profileMixedTypesNotAllowed = 'PROFILE_MIXED_TYPES_NOT_ALLOWED';
  static const profileElementLayoutNotAllowed =
      'PROFILE_ELEMENT_LAYOUT_NOT_ALLOWED';
  static const profileMixLayoutNotAllowed = 'PROFILE_MIX_LAYOUT_NOT_ALLOWED';
  static const profileHeadphonesModeNotAllowed =
      'PROFILE_HEADPHONES_MODE_NOT_ALLOWED';
  static const profileBinauralFilterNotAllowed =
      'PROFILE_BINAURAL_FILTER_NOT_ALLOWED';
  static const profileTooManyCodecConfigs = 'PROFILE_TOO_MANY_CODEC_CONFIGS';
  static const profileCannotMuxToMp4 = 'PROFILE_CANNOT_MUX_TO_MP4';
  static const elementMissingWav = 'ELEMENT_MISSING_WAV';
  static const elementLayoutUnmappable = 'ELEMENT_LAYOUT_UNMAPPABLE';
  static const elementChannelMismatch = 'ELEMENT_CHANNEL_MISMATCH';
  static const sessionNoMixes = 'SESSION_NO_MIXES';
  static const sessionNoElements = 'SESSION_NO_ELEMENTS';
  static const engineUnavailable = 'ENGINE_UNAVAILABLE';

  ExportIssueCode._();
}

class ExportIssue {
  final ExportSeverity severity;

  /// Stable code (see [ExportIssueCode]).
  final String code;

  /// User-facing description. Safe to surface directly in the dialog.
  final String message;

  const ExportIssue({
    required this.severity,
    required this.code,
    required this.message,
  });

  @override
  String toString() => '[$severity $code] $message';
}

class ExportValidationResult {
  final List<ExportIssue> issues;

  const ExportValidationResult(this.issues);

  List<ExportIssue> get errors =>
      issues.where((i) => i.severity == ExportSeverity.error).toList();

  List<ExportIssue> get warnings =>
      issues.where((i) => i.severity == ExportSeverity.warning).toList();

  /// True when no errors are present. Warnings do not block export.
  bool get canExport => errors.isEmpty;
}
