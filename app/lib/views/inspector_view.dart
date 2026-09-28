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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../logging/log.dart';
import '../playback/iamf_probe_full.dart';
import '../playback/playback_session.dart';
import '../state.dart';
import '../theme.dart';
import '../util/time_format.dart';
import '../video/video_provider.dart';
import '../widgets/eyebrow_label.dart';

/// Playback-mode Inspector tab. Shows a deep descriptor-OBU dump of
/// the currently-open IAMF file: profile / codec configs / audio
/// elements (scalable layers, ambisonics modes, params) / mix
/// presentations (sub-mixes with loudness annotations and tags).
/// Mirrors the iamf-inspector browser tool's coverage so the same
/// metadata is visible inside Eclipsa Studio.
class InspectorView extends ConsumerWidget {
  const InspectorView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Inspector subtree is built largely from `const` leaves, so parent
    // rebuilds short-circuit at Element.updateChild. Watch theme + font
    // mode here and drop `const` from the canonical-arg call sites
    // below so theme/font switches propagate down.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final session = ref.watch(playbackSessionProvider);
    return Container(
      color: T.bgBase,
      child: session == null ? _EmptyState() : _Body(session: session),
    );
  }
}

// ---------------------------------------------------------------------------
// Lazy full-probe provider
// ---------------------------------------------------------------------------
//
// Triggered by the Inspector view; runs the full descriptor probe on a
// background isolate. Keyed by `path` so navigating between files
// re-runs the probe naturally. Cached for the lifetime of the
// PlaybackSession (cleared when the user returns to landing).

final _fullProbeProvider = FutureProvider.family<IamfFullProbe, String>((
  ref,
  path,
) async {
  final stopwatch = Stopwatch()..start();
  final probe = await probeIamfFull(path);
  stopwatch.stop();
  Log.i(
    LogCat.app,
    'inspector probe: ${stopwatch.elapsedMilliseconds}ms ok=${probe.ok} '
    'codec_configs=${probe.codecConfigs.length} '
    'aes=${probe.audioElements.length} '
    'mps=${probe.mixPresentations.length}',
  );
  return probe;
});

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'No file loaded. Return to landing and open an IAMF for QC.',
        style: TextStyle(color: T.textTertiary, fontSize: T.fontBody),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.session});
  final PlaybackSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fullProbe = ref.watch(_fullProbeProvider(session.path));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(session: session),
              const SizedBox(height: 20),
              fullProbe.when(
                loading: () => _ProbingPlaceholder(),
                error: (e, st) => _ProbeError(error: '$e'),
                data: (probe) => probe.ok
                    ? _RichBody(session: session, probe: probe)
                    : _ProbeError(error: probe.errorMessage ?? 'unknown'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProbingPlaceholder extends StatelessWidget {
  const _ProbingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(T.purple),
              ),
            ),
            const SizedBox(height: 16),
            Text('Reading IAMF descriptors…', style: T.styleBodySecondary),
          ],
        ),
      ),
    );
  }
}

class _ProbeError extends StatelessWidget {
  const _ProbeError({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: T.meterRed.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: T.meterRed.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: T.meterRed, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text('Probe failed: $error', style: T.styleBody)),
        ],
      ),
    );
  }
}

class _RichBody extends StatelessWidget {
  const _RichBody({required this.session, required this.probe});
  final PlaybackSession session;
  final IamfFullProbe probe;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Video Track sits above the IAMF descriptor dump for a QC .mp4:
        // the picture is the first thing to confirm. Collapses to nothing
        // for a bare .iamf or before mpv resolves any metadata.
        _VideoTrackSection(session: session),
        _ProfileSection(probe: probe),
        if (probe.codecConfigs.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionTitle('Codec Configs', count: probe.codecConfigs.length),
          for (final c in probe.codecConfigs) _CodecConfigCard(config: c),
        ],
        if (probe.audioElements.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionTitle('Audio Elements', count: probe.audioElements.length),
          for (final ae in probe.audioElements) _AudioElementCard(ae: ae),
        ],
        if (probe.mixPresentations.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionTitle(
            'Mix Presentations',
            count: probe.mixPresentations.length,
          ),
          _MixPresentationsBlock(session: session, probe: probe),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Video Track (QC .mp4 only)
// ---------------------------------------------------------------------------
//
// Only an IAMF-in-MP4 deliverable carries a picture; a bare .iamf renders
// nothing here. The fields come from the muted video backend, resolved
// asynchronously — the section is reactive so it fills in as the decoder
// reports resolution / fps / duration. Audio detail is intentionally
// omitted: the authoritative codec/channel info already lives in the Codec
// Configs and Audio Elements sections above, and the video decoder's view
// of the IAMF track would only duplicate or contradict it.

class _VideoTrackSection extends ConsumerWidget {
  const _VideoTrackSection({required this.session});
  final PlaybackSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (p.extension(session.path).toLowerCase() != '.mp4') {
      return const SizedBox.shrink();
    }
    final video = ref.watch(videoProvider);

    // A container running longer than the picture (a muxed master whose
    // audio track outlasts the video — ES-459) is worth flagging; equal (or
    // within a frame of equal) durations are the boring common case and the
    // row stays hidden. One frame at 24 fps ≈ 42 ms; 50 ms covers the
    // rounding slack when fps is unknown.
    final frameMs = (video.fps != null && video.fps! > 0)
        ? 1000.0 / video.fps!
        : 50.0;
    final mismatch =
        video.duration != null &&
        video.containerDuration != null &&
        (video.containerDuration!.inMilliseconds -
                    video.duration!.inMilliseconds)
                .abs() >
            frameMs;

    final rows = <_KvRow>[
      if (video.codec != null) _KvRow('Codec', video.codec!),
      if (video.videoWidth != null && video.videoHeight != null)
        _KvRow('Resolution', '${video.videoWidth} × ${video.videoHeight}'),
      if (video.fps != null && video.fps! > 0)
        _KvRow('Frame rate', '${video.fps!.toStringAsFixed(3)} fps'),
      if (video.duration != null)
        _KvRow(
          'Duration',
          formatDuration(video.duration!.inMilliseconds / 1000.0),
        ),
      if (mismatch)
        _KvRow(
          'Container duration',
          formatDuration(video.containerDuration!.inMilliseconds / 1000.0),
        ),
      if (video.bitRateBps != null)
        _KvRow('Bit rate', _formatBitRate(video.bitRateBps!)),
      if (video.colorInfo != null) _KvRow('Color', video.colorInfo!),
    ];
    // Nothing resolved yet (or no video loaded) — stay collapsed.
    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle('Video Track'),
        _Card(child: _KvList(rows)),
        const SizedBox(height: 24),
      ],
    );
  }

  /// `12.4 Mb/s` from 1 Mb/s up, `640 kb/s` below.
  static String _formatBitRate(int bps) {
    if (bps >= 1000000) {
      return '${(bps / 1000000).toStringAsFixed(1)} Mb/s';
    }
    return '${(bps / 1000).round()} kb/s';
  }
}

// ---------------------------------------------------------------------------
// Header (file overview)
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.session});
  final PlaybackSession session;

  @override
  Widget build(BuildContext context) {
    final r = session.report;
    final name = p.basename(session.path);
    // Prefer the engine-session totals (authoritative, updated when the
    // upstream lazy temporal-unit scan finishes) over the thin probe's
    // duration: the thin probe runs descriptors-only for speed, so its
    // `durationSeconds` is only set when the codec carries a usable total
    // in its descriptors (FLAC STREAMINFO) and is null otherwise (Opus /
    // LPCM). While neither is available, `session.totalFrames` is 0 —
    // show "Computing…" so the user knows the reading is on the way.
    final liveSr = session.sampleRate;
    final liveFrames = session.totalFrames;
    final String durationText;
    if (liveSr > 0 && liveFrames > 0) {
      durationText = formatDuration(liveFrames / liveSr);
    } else if (r.durationSeconds != null) {
      durationText = formatDuration(r.durationSeconds!);
    } else {
      // Upstream's lazy temporal-unit scan runs on a worker thread.
      // It typically completes within a minute or two of opening; the
      // header refreshes when `playbackSession.totalFrames` updates.
      durationText = 'Computing…';
    }
    final sampleRateValue = liveSr > 0
        ? '$liveSr Hz'
        : (r.sampleRate == 0 ? '—' : '${r.sampleRate} Hz');
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: T.decoCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: TextStyle(
              color: T.textPrimary,
              fontSize: T.fontHeading,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            session.path,
            style: TextStyle(color: T.textTertiary, fontSize: T.fontSmall),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              _MetaItem(label: 'Container', value: 'IAMF'),
              _MetaItem(label: 'Sample rate', value: sampleRateValue),
              _MetaItem(label: 'Duration', value: durationText),
              _MetaItem(
                label: 'Audio elements',
                value: '${r.audioElements.length}',
              ),
              _MetaItem(
                label: 'Mix presentations',
                value: '${r.mixPresentations.length}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Profile section
// ---------------------------------------------------------------------------

class _ProfileSection extends StatelessWidget {
  const _ProfileSection({required this.probe});
  final IamfFullProbe probe;

  @override
  Widget build(BuildContext context) {
    final rows = <_KvRow>[
      _KvRow(
        'Primary profile',
        probe.primaryProfile,
        glossary:
            'Primary profile this IA Sequence complies with. '
            'Parsers should discard the sequence if they do not '
            'support it.',
      ),
      if (probe.additionalProfile.isNotEmpty &&
          probe.additionalProfile != probe.primaryProfile)
        _KvRow(
          'Additional profile',
          probe.additionalProfile,
          glossary:
              'Additional profile the sequence complies with. '
              'Equal to primary_profile when the sequence only '
              'complies with the primary.',
        ),
      _KvRow(
        'Descriptor bytes',
        _intStr(probe.descriptorBytesConsumed),
        glossary: 'Bytes of the file consumed while parsing descriptor OBUs.',
      ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionTitle('Profile'),
          _Card(child: _KvList(rows)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Codec config card
// ---------------------------------------------------------------------------

class _CodecConfigCard extends StatelessWidget {
  const _CodecConfigCard({required this.config});
  final IamfCodecConfig config;

  @override
  Widget build(BuildContext context) {
    final summary = <_KvRow>[
      _KvRow('Output sample rate', '${_intStr(config.outputSampleRate)} Hz'),
      if (config.inputSampleRate != config.outputSampleRate)
        _KvRow('Input sample rate', '${_intStr(config.inputSampleRate)} Hz'),
      _KvRow(
        'Frame size',
        '${_intStr(config.numSamplesPerFrame)} samples',
        glossary:
            'Frame length, in samples, of the audio frames '
            'produced by this codec config.',
      ),
      _KvRow(
        'Audio roll distance',
        '${config.audioRollDistance} frames',
        glossary:
            'Frames of roll-back the decoder needs on seek. Negative '
            'values mean N prior frames are required before the current '
            'frame decodes cleanly.',
      ),
      _KvRow(
        'Bit depth for loudness',
        '${config.bitDepthToMeasureLoudness} bit',
        glossary:
            'Bit depth used for the loudness measurement reference '
            'signal. Not the PCM bit depth of the stream.',
      ),
    ];
    final children = <Widget>[_KvList(summary)];
    if (config.opus != null) children.add(_OpusBlock(opus: config.opus!));
    if (config.lpcm != null) children.add(_LpcmBlock(lpcm: config.lpcm!));
    if (config.aac != null) children.add(_AacBlock(aac: config.aac!));
    if (config.flac != null) children.add(_FlacBlock(flac: config.flac!));

    return _Card(
      title: config.codecId,
      subtitle: 'id ${config.id}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _OpusBlock extends StatelessWidget {
  const _OpusBlock({required this.opus});
  final IamfOpusConfig opus;

  @override
  Widget build(BuildContext context) {
    return _Subcard(
      title: 'Opus decoder config',
      child: _KvList([
        _KvRow('Version', '${opus.version}'),
        _KvRow('Output channels', '${opus.outputChannelCount}'),
        _KvRow(
          'Pre-skip',
          '${_intStr(opus.preSkip)} samples',
          glossary:
              'Opus encoder pre-roll — samples to discard from '
              'the beginning of the decoded stream.',
        ),
        _KvRow('Input sample rate', '${_intStr(opus.inputSampleRate)} Hz'),
        _KvRow(
          'Output gain',
          '${(opus.outputGain / 256).toStringAsFixed(1)} dB',
        ),
        _KvRow(
          'Mapping family',
          '${opus.mappingFamily}',
          glossary:
              'Opus channel mapping family: 0 = RTP, 1 = Vorbis, '
              '255 = undefined.',
        ),
      ]),
    );
  }
}

class _LpcmBlock extends StatelessWidget {
  const _LpcmBlock({required this.lpcm});
  final IamfLpcmConfig lpcm;

  @override
  Widget build(BuildContext context) {
    return _Subcard(
      title: 'LPCM decoder config',
      child: _KvList([
        _KvRow('Sample format', lpcm.sampleFormat),
        _KvRow('Sample size', '${lpcm.sampleSize} bit'),
        _KvRow('Sample rate', '${_intStr(lpcm.sampleRate)} Hz'),
      ]),
    );
  }
}

class _AacBlock extends StatelessWidget {
  const _AacBlock({required this.aac});
  final IamfAacConfig aac;

  @override
  Widget build(BuildContext context) {
    return _Subcard(
      title: 'AAC decoder config',
      child: _KvList([
        _KvRow(
          'Audio Object Type',
          '${aac.audioObjectType}',
          glossary: 'MPEG-4 Audio Object Type (AOT). 2 = AAC LC.',
        ),
        _KvRow(
          'Object Type Indication',
          '0x${aac.objectTypeIndication.toRadixString(16).toUpperCase().padLeft(2, '0')}',
          glossary:
              'MPEG-4 Object Type Indication (OTI) — legacy '
              'stream identifier. 0x40 indicates MPEG-4 Audio.',
        ),
        _KvRow(
          'Stream type',
          '${aac.streamType}',
          glossary: 'MPEG-4 stream type (5 = audio stream).',
        ),
        _KvRow(
          'Sample frequency index',
          aac.sampleFrequencyIndex,
          glossary:
              'Index into the MPEG-4 sampling-frequency '
              'table; 0xF (escape) means an explicit rate is carried '
              'in the decoder-specific info.',
        ),
        _KvRow(
          'Channel configuration',
          '${aac.channelConfiguration}',
          glossary:
              'MPEG-4 program_config_element shorthand (1 = mono, '
              '2 = stereo, …).',
        ),
        _KvRow('Average bit rate', '${_intStr(aac.averageBitRate)} bps'),
        _KvRow('Max bit rate', '${_intStr(aac.maxBitrate)} bps'),
        _KvRow('Buffer size', '${_intStr(aac.bufferSizeDb)} bytes'),
        _KvRow('Upstream', aac.upstream ? 'yes' : 'no'),
      ]),
    );
  }
}

class _FlacBlock extends StatelessWidget {
  const _FlacBlock({required this.flac});
  final IamfFlacConfig flac;

  @override
  Widget build(BuildContext context) {
    final info = flac.streamInfo;
    final children = <Widget>[];
    if (info != null) {
      children.add(
        _KvList([
          if (info.sampleRate != null)
            _KvRow('Sample rate', '${_intStr(info.sampleRate!)} Hz'),
          if (info.numberOfChannels != null)
            _KvRow('Channels', '${info.numberOfChannels}'),
          if (info.bitsPerSample != null)
            _KvRow('Bits per sample', '${info.bitsPerSample} bit'),
          if (info.minimumBlockSize != null)
            _KvRow(
              'Min block size',
              '${_intStr(info.minimumBlockSize!)} samples',
            ),
          if (info.maximumBlockSize != null)
            _KvRow(
              'Max block size',
              '${_intStr(info.maximumBlockSize!)} samples',
            ),
          if (info.minimumFrameSize != null)
            _KvRow(
              'Min frame size',
              '${_intStr(info.minimumFrameSize!)} bytes',
            ),
          if (info.maximumFrameSize != null)
            _KvRow(
              'Max frame size',
              '${_intStr(info.maximumFrameSize!)} bytes',
            ),
          if (info.totalSamplesInStream != null &&
              info.totalSamplesInStream! > 0)
            _KvRow('Total samples', _intStr(info.totalSamplesInStream!)),
        ]),
      );
    }
    final others = flac.metadataBlocks.where((b) => !b.isStreamInfo).toList();
    if (others.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Other metadata blocks: ${others.map((b) => b.blockType).join(', ')}',
            style: TextStyle(color: T.textTertiary, fontSize: T.fontSmall),
          ),
        ),
      );
    }
    return _Subcard(
      title: 'FLAC decoder config',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Audio element card
// ---------------------------------------------------------------------------

class _AudioElementCard extends StatelessWidget {
  const _AudioElementCard({required this.ae});
  final IamfAudioElement ae;

  @override
  Widget build(BuildContext context) {
    final summary = <_KvRow>[
      _KvRow('Codec config', '${ae.codecConfigId}'),
      _KvRow('Substreams', '${ae.numSubstreams}'),
      if (ae.substreamIds.isNotEmpty)
        _KvRow('Substream ids', '[${ae.substreamIds.join(', ')}]'),
      if (ae.channelLayout != null)
        _KvRow(
          'Top-level layout',
          ae.channelLayout!,
          glossary:
              'Channel layout reconstructed from this Channel Group '
              '(Mono / Stereo / 5.1 / 7.1 / 3.1.2 / 7.1.4 / Binaural / '
              'Expanded).',
        ),
      if (ae.ambisonicsOrder != null)
        _KvRow(
          'Ambisonics',
          '${ae.ambisonicsOrder}OA · ${ae.ambisonicsChannels ?? '?'} ch',
        ),
    ];

    final children = <Widget>[_KvList(summary)];
    for (var i = 0; i < ae.scalableLayers.length; i++) {
      children.add(_ScalableLayerBlock(layer: ae.scalableLayers[i], index: i));
    }
    if (ae.ambisonics != null) {
      children.add(_AmbisonicsBlock(ambi: ae.ambisonics!));
    }
    if (ae.params.isNotEmpty) children.add(_ParamsBlock(params: ae.params));

    return _Card(
      title: 'Audio Element',
      subtitle: 'id ${ae.id} · ${ae.type}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _ScalableLayerBlock extends StatelessWidget {
  const _ScalableLayerBlock({required this.layer, required this.index});
  final IamfScalableLayer layer;
  final int index;

  @override
  Widget build(BuildContext context) {
    final rows = <_KvRow>[
      _KvRow(
        'Loudspeaker layout',
        layer.loudspeakerLayout,
        glossary:
            'Channel layout reconstructed from this Channel '
            'Group (Mono / Stereo / 5.1 / 7.1 / 3.1.2 / 7.1.4 / '
            'Binaural / Expanded).',
      ),
      if (layer.expandedLoudspeakerLayout != null)
        _KvRow(
          'Expanded layout',
          layer.expandedLoudspeakerLayout!,
          glossary:
              'Present only when num_layers = 1 and '
              'loudspeaker_layout = 15. Selects an expanded '
              'configuration such as 9.1.6 or 7.1.5.4.',
        ),
      _KvRow('Substreams', '${layer.substreamCount}'),
      _KvRow(
        'Coupled substreams',
        '${layer.coupledSubstreamCount}',
        glossary:
            'Substreams in this Channel Group carrying a stereo-coded pair.',
      ),
      _KvRow(
        'Output gain info',
        layer.outputGainIsPresentFlag ? 'present' : 'absent',
      ),
      _KvRow(
        'Recon gain info',
        layer.reconGainIsPresentFlag ? 'present' : 'absent',
        glossary:
            '1 = recon gain information is carried in '
            'recon_gain_info_parameter_data for this Channel Group.',
      ),
    ];
    if (layer.outputGainIsPresentFlag) {
      final bits = <String>[];
      for (var i = 0; i < 6; i++) {
        if (((layer.outputGainFlag >> i) & 1) == 1) bits.add('ch$i');
      }
      rows.add(
        _KvRow(
          'Output gain channels',
          bits.isEmpty ? '(none)' : bits.join(', '),
          glossary:
              '6-bit mask — each bit set means output_gain is '
              'applied to the corresponding mixed channel.',
        ),
      );
      rows.add(
        _KvRow(
          'Output gain',
          '${(layer.outputGain / 256).toStringAsFixed(1)} dB',
        ),
      );
    }
    return _Subcard(title: 'Scalable layer $index', child: _KvList(rows));
  }
}

class _AmbisonicsBlock extends StatelessWidget {
  const _AmbisonicsBlock({required this.ambi});
  final IamfAmbisonics ambi;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      _KvList([
        _KvRow(
          'Mode',
          ambi.mode,
          glossary:
              'MONO — each ambisonics channel is its own mono '
              'substream (required for LPCM). PROJECTION — channels '
              'are linearly projected into a mix of coupled-stereo '
              'and mono substreams before coding.',
        ),
        if (ambi.order != null) _KvRow('Order', '${ambi.order}OA'),
      ]),
    ];
    if (ambi.mono != null) {
      final m = ambi.mono!;
      children.add(
        _KvList([
          _KvRow('Output channels', '${m.outputChannelCount}'),
          _KvRow('Substreams', '${m.substreamCount}'),
        ]),
      );
      if (m.channelMapping.isNotEmpty) {
        children.add(
          _DetailsList(
            summary: 'Channel mapping (${m.channelMapping.length})',
            body: '[${m.channelMapping.join(', ')}]',
          ),
        );
      }
    }
    if (ambi.projection != null) {
      final p = ambi.projection!;
      children.add(
        _KvList([
          _KvRow('Output channels', '${p.outputChannelCount}'),
          _KvRow('Substreams', '${p.substreamCount}'),
          _KvRow('Coupled substreams', '${p.coupledSubstreamCount}'),
        ]),
      );
      if (p.demixingMatrix.isNotEmpty) {
        children.add(
          _DetailsList(
            summary: 'Demixing matrix (${p.demixingMatrix.length} coeffs)',
            body: '[${p.demixingMatrix.join(', ')}]',
          ),
        );
      }
    }
    return _Subcard(
      title: 'Ambisonics',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _ParamsBlock extends StatelessWidget {
  const _ParamsBlock({required this.params});
  final List<IamfAudioElementParam> params;

  @override
  Widget build(BuildContext context) {
    return _Subcard(
      title: 'Params',
      child: _KvTable(
        headers: const [
          'Type',
          'Param ID',
          'Rate',
          'Def. mode',
          'Duration',
          'Subblock',
        ],
        rows: [
          for (final p in params)
            [
              p.paramType,
              _intStr(p.parameterId),
              _intStr(p.parameterRate),
              '${p.paramDefinitionMode}',
              _intStr(p.duration),
              _intStr(p.constantSubblockDuration),
            ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mix presentations
// ---------------------------------------------------------------------------

/// Read-only detail for every mix presentation in the file. Switching
/// the active presentation lives in the Topbar's mix selector; the
/// SELECTED pill here just mirrors that selection — everything else in
/// this block is a bitstream fact, so the pill's label and tooltip
/// must say it's app-side state, not a file property (ES-331).
class _MixPresentationsBlock extends StatelessWidget {
  const _MixPresentationsBlock({required this.session, required this.probe});
  final PlaybackSession session;
  final IamfFullProbe probe;

  @override
  Widget build(BuildContext context) {
    final mps = probe.mixPresentations;
    // Guard locally rather than relying on the call-site emptiness
    // check — clamp(0, -1) throws on an empty list.
    if (mps.isEmpty) return const SizedBox.shrink();
    final activeIndex = session.activeMixIndex.clamp(0, mps.length - 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < mps.length; i++)
          _MixPresentationCard(mp: mps[i], index: i, active: i == activeIndex),
      ],
    );
  }
}

class _MixPresentationCard extends StatelessWidget {
  const _MixPresentationCard({
    required this.mp,
    required this.index,
    required this.active,
  });
  final IamfMixPresentation mp;
  final int index;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final summary = <_KvRow>[
      _KvRow('ID', '${mp.id}'),
      _KvRow('Label count', '${mp.countLabel}'),
      _KvRow('Sub-mixes', '${mp.numSubMixes}'),
    ];
    final children = <Widget>[_KvList(summary)];
    if (mp.annotations.isNotEmpty) {
      children.add(
        _Subcard(
          title: 'Annotations',
          child: _KvTable(
            headers: const ['Language', 'Label'],
            rows: [
              for (final a in mp.annotations)
                [a.language.isEmpty ? '(unspecified)' : a.language, a.label],
            ],
          ),
        ),
      );
    }
    if (mp.tags.isNotEmpty) {
      children.add(
        _Subcard(
          title: 'Tags',
          child: _KvTable(
            headers: const ['Name', 'Value'],
            rows: [
              for (final t in mp.tags) [t.tagName, t.tagValue],
            ],
          ),
        ),
      );
    }
    for (var i = 0; i < mp.subMixes.length; i++) {
      children.add(_SubMixBlock(sm: mp.subMixes[i], index: i));
    }

    final ann = mp.annotations.isEmpty ? '' : mp.annotations.first.label;
    final title = ann.isNotEmpty ? ann : 'Mix Presentation ${index + 1}';
    final subtitle =
        'id ${mp.id} · ${mp.numSubMixes} sub-mix${mp.numSubMixes == 1 ? '' : 'es'}';

    return _Card(
      title: title,
      subtitle: subtitle,
      trailing: active
          ? Tooltip(
              message:
                  'Currently selected for monitoring, not a property '
                  'of the file. Change it in the mix selector in the '
                  'top bar.',
              child: _Pill(label: 'SELECTED', color: T.purple),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _SubMixBlock extends StatelessWidget {
  const _SubMixBlock({required this.sm, required this.index});
  final IamfSubMix sm;
  final int index;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      _Subtitle('Audio elements (${sm.audioElements.length})'),
      for (final a in sm.audioElements) _SubMixAeBlock(a: a),
      const SizedBox(height: 8),
      _Subtitle('Output mix gain'),
      _Subcard(
        child: _MixGainBlock(g: sm.outputMixGain, label: 'Output mix'),
      ),
      const SizedBox(height: 8),
      _Subtitle('Layouts (${sm.layouts.length})'),
      for (var i = 0; i < sm.layouts.length; i++)
        _LayoutBlock(l: sm.layouts[i], index: i),
    ];
    return _Subcard(
      title: 'Sub-mix $index',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _SubMixAeBlock extends StatelessWidget {
  const _SubMixAeBlock({required this.a});
  final IamfSubMixAudioElement a;

  @override
  Widget build(BuildContext context) {
    final isBinaural =
        a.headphonesRenderingMode != 'stereo' &&
        a.headphonesRenderingMode.startsWith('binaural');
    final rows = <_KvRow>[
      _KvRow('Audio element ID', '${a.audioElementId}'),
      if (a.localizedElementAnnotations.isNotEmpty)
        _KvRow('Localized labels', a.localizedElementAnnotations.join(' / ')),
      _KvRow(
        'Headphones rendering',
        a.headphonesRenderingMode,
        glossary:
            '0 = render channel-based to Stereo when on headphones. '
            '1 = binaural. 2 = binaural world-locked. 3 = reserved.',
      ),
      if (isBinaural)
        _KvRow(
          'Binaural filter profile',
          a.binauralFilterProfile,
          glossary:
              'Filter profile hint for the binaural renderer: '
              'ambient · direct · reverberant · reserved.',
        ),
    ];
    return _Subcard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _KvList(rows),
          _MixGainBlock(g: a.elementMixGain, label: 'Element mix'),
        ],
      ),
    );
  }
}

class _MixGainBlock extends StatelessWidget {
  const _MixGainBlock({required this.g, required this.label});
  final IamfMixGain g;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = g.paramDefinition;
    return _KvList([
      _KvRow(
        '$label gain',
        '${g.defaultMixGain.toStringAsFixed(1)} dB',
        glossary: 'Default mix-gain value in dB. Stored as signed Q7.8.',
      ),
      _KvRow('Param ID', _intStr(p.parameterId)),
      _KvRow('Param rate', _intStr(p.parameterRate)),
      _KvRow(
        'Definition mode',
        '${p.paramDefinitionMode}',
        glossary:
            '0 = duration / num_subblocks / '
            'constant_subblock_duration / subblock_duration are '
            'specified here; 1 = they live in each Parameter Block OBU.',
      ),
      if (p.duration > 0) _KvRow('Duration', '${_intStr(p.duration)} samples'),
      if (p.constantSubblockDuration > 0)
        _KvRow(
          'Subblock duration',
          '${_intStr(p.constantSubblockDuration)} samples',
        ),
    ]);
  }
}

class _LayoutBlock extends StatelessWidget {
  const _LayoutBlock({required this.l, required this.index});
  final IamfMixPresentationLayout l;
  final int index;

  @override
  Widget build(BuildContext context) {
    final name = l.soundSystem ?? l.layoutType;
    // The layout_type parenthetical carries information only when it is
    // NOT the common loudspeaker convention (e.g. binaural, reserved);
    // repeating `loudspeakers_ss_convention` on every card is noise.
    // When soundSystem is absent the name already IS the layout type.
    final showType =
        l.soundSystem != null &&
        l.layoutType.toLowerCase() != 'loudspeakers_ss_convention';
    return _Subcard(
      title: 'Layout $index · $name${showType ? ' (${l.layoutType})' : ''}',
      child: _LoudnessBlock(loud: l.loudness),
    );
  }
}

class _LoudnessBlock extends StatelessWidget {
  const _LoudnessBlock({required this.loud});
  final IamfLoudness loud;

  @override
  Widget build(BuildContext context) {
    final rows = <_KvRow>[
      _KvRow(
        'Info type',
        '0x${loud.infoType.toRadixString(16).toUpperCase().padLeft(2, '0')}'
            ' · ${_loudnessFlagsLabel(loud)}',
        glossary:
            'Bitmask: bit 0 = true_peak present, '
            'bits 2–7 = layout extensions.',
      ),
      _KvRow(
        'Integrated loudness',
        '${loud.integratedLoudness.toStringAsFixed(1)} LKFS',
        glossary:
            'Program-integrated loudness, LKFS, measured per '
            'ITU-R BS.1770-4 for the layout indicated.',
      ),
      _KvRow(
        'Digital peak',
        '${loud.digitalPeak.toStringAsFixed(1)} dBFS',
        glossary: 'Digital (sampled) peak of the signal, dBFS.',
      ),
      if (loud.truePeak != null)
        _KvRow(
          'True peak',
          '${loud.truePeak!.toStringAsFixed(1)} dBTP',
          glossary:
              'True peak, dBTP (4x oversampled), measured per '
              'ITU-R BS.1770-4. Present only when info_type bit 0 is set.',
        ),
    ];

    return _KvList(rows);
  }
}

String _loudnessFlagsLabel(IamfLoudness l) {
  final parts = <String>[];
  if (l.truePeakPresent) parts.add('true peak');
  if (l.hasLayoutExtension) parts.add('layout ext');
  return parts.isEmpty ? 'integrated only' : parts.join(', ');
}

// ---------------------------------------------------------------------------
// Ancillary
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Generic display primitives — kept inside this file to avoid leaking a
// half-formed "metadata renderer" abstraction into the wider app.
// ---------------------------------------------------------------------------

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label, {this.count});
  final String label;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final text = count == null ? label : '$label ($count)';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: EyebrowLabel(text),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({this.title, this.subtitle, this.trailing, required this.child});
  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: T.decoCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(
                          color: T.textPrimary,
                          fontSize: T.fontBodyL,
                          fontWeight: FontWeight.w600,
                        ),
                        children: [
                          TextSpan(text: title),
                          if (subtitle != null)
                            TextSpan(
                              text: '  ·  $subtitle',
                              style: TextStyle(
                                color: T.textTertiary,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          child,
        ],
      ),
    );
  }
}

class _Subcard extends StatelessWidget {
  const _Subcard({this.title, required this.child});
  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: T.bgBase,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                title!,
                style: TextStyle(
                  color: T.textSecondary,
                  fontSize: T.fontSmall,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          color: T.textTertiary,
          fontSize: T.fontCaption,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _KvRow {
  const _KvRow(this.label, this.value, {this.glossary});
  final String label;
  final String value;
  final String? glossary;
}

class _KvList extends StatelessWidget {
  const _KvList(this.rows);
  final List<_KvRow> rows;

  /// Interior width above which the rows flow into two columns.
  /// Note: with the 1400 px minimum window and the 1100 px content cap,
  /// even the deepest subcard interior measures ~1020 px, so today this
  /// gate always passes and _twoColumnMinRows is the effective switch;
  /// the breakpoint is kept as the guard for any future narrow host.
  static const double _twoColumnBreakpoint = 640;

  /// Minimum rows before a two-column split is worth the eye travel.
  static const int _twoColumnMinRows = 4;

  /// Gutter floor so short-labeled cards don't look cramped
  /// (font-scaled like the labels it bounds).
  static double get _gutterMin => T.fs(120);

  /// Label gutter measured from this list's own longest label, so each
  /// card hugs its content at any font scale instead of carrying a
  /// global 200 px column sized for the longest label anywhere.
  /// Measured with the ambient DefaultTextStyle merged and the
  /// MediaQuery text scaler applied — the rendered Text inherits both,
  /// and a bare-style measurement under-reports (same lesson as
  /// ConsoleSegment.uniformWidth).
  double _gutterWidth(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    var widest = 0.0;
    for (final r in rows) {
      final painter = TextPainter(
        text: TextSpan(
          text: r.label,
          style: base.merge(TextStyle(fontSize: T.fontSmall)),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final w = painter.width;
      painter.dispose();
      if (w > widest) widest = w;
    }
    return math.max(_gutterMin, widest.ceilToDouble());
  }

  Widget _row(_KvRow r, double gutter) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: gutter,
          child: _HintLabel(label: r.label, hint: r.glossary),
        ),
        const SizedBox(width: 12),
        Expanded(child: SelectableText(r.value, style: T.styleBody)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final gutter = _gutterWidth(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumn =
            constraints.maxWidth >= _twoColumnBreakpoint &&
            rows.length >= _twoColumnMinRows;
        if (!twoColumn) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final r in rows) _row(r, gutter)],
          );
        }
        // Column-major split (first half left) so rows keep their
        // top-to-bottom reading order within each column.
        final split = (rows.length + 1) ~/ 2;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final r in rows.sublist(0, split)) _row(r, gutter),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final r in rows.sublist(split)) _row(r, gutter),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HintLabel extends StatelessWidget {
  const _HintLabel({required this.label, this.hint});
  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: TextStyle(
        color: T.textTertiary,
        fontSize: T.fontSmall,
        decoration: hint == null ? null : TextDecoration.underline,
        decorationStyle: TextDecorationStyle.dotted,
        decorationColor: T.textTertiary.withValues(alpha: 0.4),
      ),
    );
    if (hint == null) return text;
    return Tooltip(message: hint!, preferBelow: false, child: text);
  }
}

class _KvTable extends StatelessWidget {
  const _KvTable({required this.headers, required this.rows});
  final List<String> headers;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    return Table(
      border: TableBorder(
        horizontalInside: BorderSide(
          color: T.border.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      columnWidths: {
        for (var i = 0; i < headers.length; i++)
          i: const IntrinsicColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: T.border, width: 1)),
          ),
          children: [for (final h in headers) _cell(h, header: true)],
        ),
        for (final r in rows) TableRow(children: [for (final v in r) _cell(v)]),
      ],
    );
  }

  Widget _cell(String text, {bool header = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Text(
        text,
        style: TextStyle(
          color: header ? T.textTertiary : T.textPrimary,
          fontSize: header ? T.fontCaption : T.fontSmall,
          fontWeight: header ? FontWeight.w600 : FontWeight.w400,
          letterSpacing: header ? 0.5 : 0,
        ),
      ),
    );
  }
}

class _DetailsList extends StatelessWidget {
  const _DetailsList({required this.summary, required this.body});
  final String summary;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        unselectedWidgetColor: T.textTertiary,
        colorScheme: Theme.of(
          context,
        ).colorScheme.copyWith(secondary: T.textSecondary),
      ),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.symmetric(vertical: 4),
        iconColor: T.textTertiary,
        collapsedIconColor: T.textTertiary,
        title: Text(
          summary,
          style: TextStyle(
            color: T.textSecondary,
            fontSize: T.fontSmall,
            fontWeight: FontWeight.w500,
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: T.bgBase,
              borderRadius: BorderRadius.circular(T.radiusSm),
            ),
            child: SelectableText(
              body,
              style: TextStyle(
                color: T.textSecondary,
                fontSize: T.fontMeter,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: T.fontMeter,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: T.textTertiary,
            fontSize: T.fontSmall,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(value, style: T.styleBody),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _intStr(int n) {
  // Quick thousands-separator formatter — Dart's NumberFormat lives in
  // intl which the app doesn't otherwise need.
  final s = n.toString();
  final neg = s.startsWith('-');
  final body = neg ? s.substring(1) : s;
  final buf = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    if (i > 0 && (body.length - i) % 3 == 0) buf.write(',');
    buf.write(body[i]);
  }
  return neg ? '-$buf' : buf.toString();
}
