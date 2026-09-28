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

import 'package:eclipsa_studio/video/video_backend_kind.dart';
import 'package:flutter_test/flutter_test.dart';

// Pure unit tests for the platform-aware backend-selection logic (issues ES-249,
// ES-262). These assert today's state: AVFoundation, ffmpegEngine and
// mediaFoundation are all implemented; AVFoundation is macOS-only and
// mediaFoundation Windows-only (ffmpegEngine cross-platform); macOS `auto`
// resolves to AVFoundation and Windows `auto` to Media Foundation; and
// unsupported / wrong-OS kinds fall back to ffmpegEngine (the hard fallback).
// When a backend's `implemented` flag, supported OS, or the per-platform
// default changes, update the expectations below alongside it. The retired
// backends (mediaKit, fvp) have no enum arm; their names are covered only as
// stale preference values, which fall through to auto.
void main() {
  group('enum names are stable (used as preference values)', () {
    test('names round-trip via .name', () {
      expect(VideoBackendKind.auto.name, 'auto');
      expect(VideoBackendKind.avFoundation.name, 'avFoundation');
      expect(VideoBackendKind.ffmpegEngine.name, 'ffmpegEngine');
      expect(VideoBackendKind.mediaFoundation.name, 'mediaFoundation');
      expect(VideoBackendKind.stillImage.name, 'stillImage');
    });
  });

  group('metadata', () {
    test('every kind is implemented', () {
      for (final k in VideoBackendKind.values) {
        expect(k.implemented, isTrue, reason: k.name);
      }
    });

    test('the hard fallback is implemented and cross-platform', () {
      // Every fallback site (resolveBackendKind, the provider, the pop-out)
      // degrades to kHardFallbackBackend, so it MUST construct on both
      // platforms. If you ever repoint it, its replacement has to satisfy
      // this — a single-OS backend as the fallback would strand the other.
      expect(kHardFallbackBackend.implemented, isTrue);
      expect(
        kHardFallbackBackend.supportedOs,
        containsAll(TargetOs.values),
        reason: kHardFallbackBackend.name,
      );
    });

    test(
      'AVFoundation macOS-only, MediaFoundation Windows-only, rest both',
      () {
        expect(VideoBackendKind.avFoundation.supportedOs, {TargetOs.macos});
        expect(VideoBackendKind.mediaFoundation.supportedOs, {
          TargetOs.windows,
        });
        for (final k in [
          VideoBackendKind.auto,
          VideoBackendKind.ffmpegEngine,
          VideoBackendKind.stillImage,
        ]) {
          expect(k.supportedOs, {
            TargetOs.macos,
            TargetOs.windows,
          }, reason: k.name);
        }
      },
    );

    test('every kind has a non-empty label', () {
      for (final k in VideoBackendKind.values) {
        expect(k.label, isNotEmpty, reason: k.name);
      }
    });

    test('only stillImage is not user-selectable', () {
      // stillImage is chosen by file type at load time (ES-192), never by the
      // user — the selector and preference paths must all exclude it.
      for (final k in VideoBackendKind.values) {
        expect(
          k.userSelectable,
          k != VideoBackendKind.stillImage,
          reason: k.name,
        );
      }
    });
  });

  group('resolveAuto', () {
    test('macOS defaults to AVFoundation, Windows to Media Foundation', () {
      expect(resolveAuto(TargetOs.macos), VideoBackendKind.avFoundation);
      expect(resolveAuto(TargetOs.windows), VideoBackendKind.mediaFoundation);
    });
  });

  group('resolveBackendKind', () {
    test('auto maps to the per-platform default', () {
      expect(
        resolveBackendKind(VideoBackendKind.auto, TargetOs.macos),
        VideoBackendKind.avFoundation,
      );
      expect(
        resolveBackendKind(VideoBackendKind.auto, TargetOs.windows),
        VideoBackendKind.mediaFoundation,
      );
    });

    test('implemented cross-platform kinds resolve to themselves', () {
      for (final os in TargetOs.values) {
        expect(
          resolveBackendKind(VideoBackendKind.ffmpegEngine, os),
          VideoBackendKind.ffmpegEngine,
          reason: os.name,
        );
      }
    });

    test('native backends resolve on their OS, fall back on the other', () {
      // AVFoundation is macOS-only; Media Foundation Windows-only. Selected on
      // the wrong OS (a stale preference), each degrades to the hard fallback.
      expect(
        resolveBackendKind(VideoBackendKind.avFoundation, TargetOs.macos),
        VideoBackendKind.avFoundation,
      );
      expect(
        resolveBackendKind(VideoBackendKind.avFoundation, TargetOs.windows),
        kHardFallbackBackend,
      );
      expect(
        resolveBackendKind(VideoBackendKind.mediaFoundation, TargetOs.windows),
        VideoBackendKind.mediaFoundation,
      );
      expect(
        resolveBackendKind(VideoBackendKind.mediaFoundation, TargetOs.macos),
        kHardFallbackBackend,
      );
    });
  });

  group('availableBackendKinds', () {
    test('macOS: auto, then the default (AVFoundation), then FFmpeg', () {
      expect(availableBackendKinds(TargetOs.macos), [
        VideoBackendKind.auto,
        VideoBackendKind.avFoundation,
        VideoBackendKind.ffmpegEngine,
      ]);
    });

    test('Windows: auto, then the default (Media Foundation), then FFmpeg', () {
      expect(availableBackendKinds(TargetOs.windows), [
        VideoBackendKind.auto,
        VideoBackendKind.mediaFoundation,
        VideoBackendKind.ffmpegEngine,
      ]);
    });

    test('the platform default leads (after auto) on each OS', () {
      for (final os in TargetOs.values) {
        final list = availableBackendKinds(os);
        expect(list.first, VideoBackendKind.auto);
        expect(list[1], resolveAuto(os), reason: 'default leads on ${os.name}');
      }
    });

    test(
      'a backend never appears in the list for the OS it does not support',
      () {
        expect(
          availableBackendKinds(TargetOs.macos),
          isNot(contains(VideoBackendKind.mediaFoundation)),
        );
        expect(
          availableBackendKinds(TargetOs.windows),
          isNot(contains(VideoBackendKind.avFoundation)),
        );
      },
    );
  });

  group('videoBackendFromName (startup seed)', () {
    test('null / unknown name resolves to auto', () {
      expect(videoBackendFromName(null, TargetOs.macos), VideoBackendKind.auto);
      expect(
        videoBackendFromName('nonsense', TargetOs.macos),
        VideoBackendKind.auto,
      );
    });

    test('a retired backend name in stale prefs degrades to auto', () {
      // The mediaKit and fvp backends were retired and have no enum arm;
      // a preference written by an older build must fall back cleanly,
      // with no migration code.
      for (final os in TargetOs.values) {
        expect(
          videoBackendFromName('mediaKit', os),
          VideoBackendKind.auto,
          reason: 'mediaKit on ${os.name}',
        );
        expect(
          videoBackendFromName('fvp', os),
          VideoBackendKind.auto,
          reason: 'fvp on ${os.name}',
        );
      }
    });

    test('implemented + supported name resolves to itself', () {
      expect(
        videoBackendFromName('avFoundation', TargetOs.macos),
        VideoBackendKind.avFoundation,
      );
      expect(
        videoBackendFromName('mediaFoundation', TargetOs.windows),
        VideoBackendKind.mediaFoundation,
      );
    });

    test(
      'a native backend name carried to the wrong OS falls back to auto',
      () {
        expect(
          videoBackendFromName('avFoundation', TargetOs.windows),
          VideoBackendKind.auto,
        );
        expect(
          videoBackendFromName('mediaFoundation', TargetOs.macos),
          VideoBackendKind.auto,
        );
      },
    );

    test('stillImage never reaches the user-facing selection paths', () {
      // Not offered in the selector, rejected as a stale preference value,
      // and degraded by resolveBackendKind if it ever arrives as a
      // "selection" — it is only ever instantiated directly by file type.
      for (final os in TargetOs.values) {
        expect(
          availableBackendKinds(os),
          isNot(contains(VideoBackendKind.stillImage)),
          reason: os.name,
        );
        expect(
          videoBackendFromName('stillImage', os),
          VideoBackendKind.auto,
          reason: os.name,
        );
        expect(
          resolveBackendKind(VideoBackendKind.stillImage, os),
          kHardFallbackBackend,
          reason: os.name,
        );
      }
    });

    test('ffmpegEngine name resolves to itself on both platforms', () {
      expect(
        videoBackendFromName('ffmpegEngine', TargetOs.macos),
        VideoBackendKind.ffmpegEngine,
      );
      expect(
        videoBackendFromName('ffmpegEngine', TargetOs.windows),
        VideoBackendKind.ffmpegEngine,
      );
    });
  });
}
