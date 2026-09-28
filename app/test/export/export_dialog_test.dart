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

// Widget tests for the Export dialog's gating (ES-507): validation
// disables Export and names the blocking issue, and the synchronous
// re-entrancy guard on Export arms one run per click even when the
// button, or the Enter shortcut, is hit again before the first click's
// save panel has answered. The guarded tests drive the real engine
// dylib, since validation blocks Export outright without one; they
// skip when it is not built (CI builds it before `flutter test`; run
// `./build.sh engine` locally).
//
// The save panel is replaced by a fake platform implementation whose
// future the test completes by hand, so the window between the click
// and the panel's answer is held open for as long as the assertions
// need. The measure and encode phases are not started here: a chosen
// path is never returned, so no export runs.

import 'dart:async';
import 'dart:io';

import 'package:eclipsa_studio/export/iamf_export_dialog.dart';
import 'package:eclipsa_studio/ffi_bridge.dart';
import 'package:eclipsa_studio/meters/meter_provider.dart'
    show eclipsaStudioEngineProvider;
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/video/video_provider.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart' show WavInfo;
import 'package:eclipsa_studio/widgets/app_button.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:file_picker/file_picker.dart' show FileType;
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../support/engine_dylib.dart';
import '../support/session_env.dart';

/// Stands in for the native save panel. Every call is counted and left
/// pending until the test answers [last]. The completer is created
/// inside the call, in the test's fake-async zone: a completer made in
/// `setUp` lives in the outer zone, and completing it there schedules
/// the dialog's continuation on the real event loop, which a widget
/// test never runs.
class _FakeSavePanel extends FilePickerPlatform {
  int calls = 0;
  Completer<String?>? last;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) {
    calls++;
    return (last = Completer<String?>()).future;
  }

  /// Answers the pending panel as dismissed.
  void dismiss() => last!.complete(null);
}

/// A loaded session video at [path] with no backend behind it.
class _FakeVideo extends VideoNotifier {
  _FakeVideo(this.path);

  final String path;

  @override
  VideoState build() => VideoState(filePath: path);
}

VoidCallback? _onPressedOf(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label)).onPressed;

Future<void> _pumpDialog(
  WidgetTester tester,
  ProviderContainer container,
) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: IamfExportDialog()),
    ),
  );
  // initState defers the engine pause, the default output path and the
  // first validation to a post-frame callback.
  await tester.pump();
  await tester.pump();
}

void main() {
  late Directory tmp;
  late _FakeSavePanel panel;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('eclipsa_studio_export_dialog');
    PathProviderPlatform.instance = FakePathProvider(tmp.path);
    panel = _FakeSavePanel();
    FilePickerPlatform.instance = panel;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('without the engine, validation blocks Export', (tester) async {
    final container = ProviderContainer(
      overrides: [eclipsaStudioEngineProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await _pumpDialog(tester, container);

    expect(find.text('Audio engine not available.'), findsOneWidget);
    expect(_onPressedOf(tester, 'Export'), isNull);
    expect(_onPressedOf(tester, 'Cancel'), isNotNull);
  });

  testWidgets('switching to MP4 does not target the session video', (
    tester,
  ) async {
    // Untitled.mp4 is the session video in the last export folder, and
    // there is no Untitled.iamf: the IAMF default is Untitled.iamf, and
    // the MP4 path must skip the video's name (ES-846).
    final video = File('${tmp.path}/Untitled.mp4')..createSync();
    final container = ProviderContainer(
      overrides: [
        eclipsaStudioEngineProvider.overrideWithValue(null),
        videoProvider.overrideWith(() => _FakeVideo(video.path)),
      ],
    );
    addTearDown(container.dispose);
    container.read(lastExportDirProvider.notifier).restore(tmp.path);
    await _pumpDialog(tester, container);
    expect(find.text('${tmp.path}/Untitled.iamf'), findsOneWidget);

    await tester.tap(find.text('MP4 video'));
    await tester.pump();
    expect(find.text('${tmp.path}/Untitled-01.mp4'), findsOneWidget);
    expect(video.lengthSync(), 0);
  });

  group('with the engine', () {
    late EclipsaStudioEngine engine;
    late ProviderContainer container;

    /// Opens the real engine and a container around it. Returns false
    /// (and marks the test skipped) when the dylib is not built.
    Future<bool> openEngine() async {
      final dylib = engineDylibOrSkip();
      if (dylib == null) return false;
      useEngineDylib(dylib);
      engine = EclipsaStudioEngine();
      addTearDown(engine.shutdown);
      expect(engine.init(), 0, reason: 'engine init failed');
      container = ProviderContainer(
        overrides: [eclipsaStudioEngineProvider.overrideWithValue(engine)],
      );
      addTearDown(container.dispose);
      return true;
    }

    /// Unmounts the dialog, then shuts the engine down before the test
    /// body returns: its timers were created in the fake-async zone,
    /// and the binding fails a test that ends with such a timer
    /// pending. Shutdown waits one zero-length timer before closing its
    /// log callback, so fake time is advanced to fire it. The teardown
    /// registered in [openEngine] is then a no-op.
    Future<void> closeEngine(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      unawaited(engine.shutdown());
      await tester.pump(const Duration(milliseconds: 1));
    }

    /// One stereo channel element on a real WAV, and an export folder,
    /// so validation passes and the default output path is set.
    void loadValidSession() {
      final wav = File('${tmp.path}/bed.wav')
        ..writeAsBytesSync(wavBytes(channels: 2));
      container.read(workspaceModeProvider.notifier).enterCreator();
      container.read(elementsProvider.notifier).set([
        AudioElement(
          id: 1,
          name: 'Bed',
          type: 'Channel',
          layout: 'Stereo',
          codec: 'LPCM',
          color: 0xFF000000,
          wavPath: wav.path,
          wavInfo: const WavInfo(
            channels: 2,
            sampleRate: 48000,
            bitsPerSample: 16,
            audioFormat: 1,
            dataOffset: 44,
            dataSize: 4800 * 2 * 2,
            totalSamples: 4800,
          ),
        ),
      ]);
      container.read(lastExportDirProvider.notifier).restore(tmp.path);
    }

    testWidgets('an empty session blocks Export and says why', (tester) async {
      if (!await openEngine()) return;
      await _pumpDialog(tester, container);

      expect(
        find.text('Session has no audio elements to export.'),
        findsOneWidget,
      );
      expect(_onPressedOf(tester, 'Export'), isNull);
      await closeEngine(tester);
    });

    testWidgets('a valid session enables Export', (tester) async {
      if (!await openEngine()) return;
      loadValidSession();
      await _pumpDialog(tester, container);

      expect(_onPressedOf(tester, 'Export'), isNotNull);
      expect(find.textContaining(tmp.path), findsWidgets);
      await closeEngine(tester);
    });

    testWidgets('two clicks before the save panel answers open it once', (
      tester,
    ) async {
      if (!await openEngine()) return;
      loadValidSession();
      await _pumpDialog(tester, container);

      final export = find.widgetWithText(AppButton, 'Export');
      await tester.tap(export);
      await tester.tap(export);
      expect(panel.calls, 1, reason: 'the second click must be a no-op');

      // Dismissing the panel releases the guard: the next click opens
      // the panel again.
      panel.dismiss();
      await tester.pump();
      await tester.tap(export);
      expect(panel.calls, 2, reason: 'a dismissed panel re-arms Export');
      panel.dismiss();
      await tester.pump();
      await closeEngine(tester);
    });

    testWidgets('Enter opens the save panel and shares the guard', (
      tester,
    ) async {
      if (!await openEngine()) return;
      loadValidSession();
      await _pumpDialog(tester, container);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(panel.calls, 1, reason: 'Enter must open the save panel');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.tap(find.widgetWithText(AppButton, 'Export'));
      expect(panel.calls, 1, reason: 'Enter and a click are no-ops meanwhile');

      panel.dismiss();
      await tester.pump();
      await closeEngine(tester);
    });
  });
}
