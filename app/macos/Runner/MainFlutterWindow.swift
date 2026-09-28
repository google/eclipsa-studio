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

import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Retains the AVFoundation video plugin for the window's lifetime (issue
  // ES-249, step 3). The plugin owns the `eclipsa/avf_video` method channel
  // and the active native player.
  var avfVideo: AvfVideoPlugin?

  // Retains the FFmpeg-in-engine video texture bridge (issue ES-249, step 5).
  // The plugin owns the `eclipsa/ffmpeg_video` channel and vends the engine's
  // decoded CVPixelBuffers as a FlutterTexture (zero-copy HW path).
  var ffmpegVideo: FfmpegVideoPlugin?

  // Retains the atomic file writer for session saves (ES-840). The plugin
  // owns the `eclipsa/atomic_file` method channel.
  var atomicFile: AtomicFilePlugin?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Hide the native titlebar and let Flutter content extend to the
    // top edge. The traffic-light buttons stay and float over the
    // Dart-side WindowTitlebar, which supplies the title text, drag
    // region, and theming (VS Code style). Done here rather than via
    // window_manager so the first frame never flashes a native bar.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Register the AVFoundation video controller on its own method channel
    // (not a pub plugin, so it isn't in GeneratedPluginRegistrant).
    let avfRegistrar = flutterViewController.registrar(forPlugin: "AvfVideo")
    avfVideo = AvfVideoPlugin(
      textures: avfRegistrar.textures,
      messenger: avfRegistrar.messenger)

    // Register the FFmpeg-in-engine texture bridge on its own channel too.
    let ffmpegRegistrar = flutterViewController.registrar(
      forPlugin: "FfmpegVideo")
    ffmpegVideo = FfmpegVideoPlugin(
      textures: ffmpegRegistrar.textures,
      messenger: ffmpegRegistrar.messenger)

    let atomicFileRegistrar = flutterViewController.registrar(
      forPlugin: "AtomicFile")
    atomicFile = AtomicFilePlugin(messenger: atomicFileRegistrar.messenger)

    super.awakeFromNib()
  }
}
