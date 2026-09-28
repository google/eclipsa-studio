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

// AVFoundation video backend for Eclipsa Studio (issue ES-249, step 3).
//
// Pull-based preview: an AVPlayerItemVideoOutput driven by zero-tolerance
// seek-then-pull. The Dart `AvFoundationBackend` calls `renderAt(seconds)`
// each tick; we seek the item to that exact time, copy the decoded pixel
// buffer, and hand it to Flutter as a texture frame. There is no playback
// rate — the engine clock drives every frame, so A/V stays locked with no
// drift loop. Only the video track is added to the item, so the IAMF audio
// bitstream is never decoded (ES-219 avoided structurally).
//
// Wired into the Runner target (project.pbxproj) and registered in
// `MainFlutterWindow.awakeFromNib` on the `eclipsa/avf_video` channel.
// Validated on-device (macOS): first-frame-on-load, transport-driven
// playback, frame-accurate scrub/seek, loop wrap, ProRes / HEVC-4K / H.264
// decode, and clean teardown on quit and mid-playback. Selectable in
// Settings → Video backend, and the macOS default that `auto` resolves to
// (see `resolveAuto` in video_backend_kind.dart).

import AVFoundation
import Cocoa
import FlutterMacOS

/// Owns the method channel and the single active player.
final class AvfVideoPlugin: NSObject {
  private let textures: FlutterTextureRegistry
  private let channel: FlutterMethodChannel
  private var player: AvfVideoPlayer?

  init(textures: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
    self.textures = textures
    self.channel = FlutterMethodChannel(
      name: "eclipsa/avf_video", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "load":
      guard let path = args?["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path required", details: nil))
        return
      }
      player?.dispose()
      let p = AvfVideoPlayer(textures: textures)
      // Forward async player failures (post-load) to the Dart backend's
      // 'error' handler; load-time failures reply through `result` below.
      p.onError = { [weak self] message in
        self?.channel.invokeMethod("error", arguments: message)
      }
      player = p
      p.load(path: path) { meta, error in
        if let error = error {
          result(FlutterError(code: "load_failed", message: error, details: nil))
        } else {
          result(meta)
        }
      }
    case "renderAt":
      guard let seconds = args?["seconds"] as? Double else {
        result(FlutterError(code: "bad_args", message: "seconds required", details: nil))
        return
      }
      player?.renderAt(seconds: seconds)
      result(nil)
    case "setPlaying":
      player?.setPlaying(args?["playing"] as? Bool ?? false)
      result(nil)
    case "unload", "dispose":
      player?.dispose()
      player = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// One AVFoundation-backed video, exposed to Flutter as a texture.
final class AvfVideoPlayer: NSObject, FlutterTexture,
  AVPlayerItemOutputPullDelegate
{
  private let textures: FlutterTextureRegistry
  private let player = AVPlayer()
  private var output: AVPlayerItemVideoOutput?
  private var item: AVPlayerItem?

  /// Reports an async playback failure (the item reaching `.failed` after a
  /// successful load) to the plugin, which forwards it to Dart. Called on the
  /// main thread. Set before `load`.
  var onError: ((String) -> Void)?

  // State touched from both the main thread and AVFoundation's internal
  // queues / the output delegate queue — guarded by `stateLock`.
  private let stateLock = NSLock()
  private var textureId: Int64 = -1
  private var latestBuffer: CVPixelBuffer?
  private var disposed = false

  /// The most recent time requested by [renderAt]. Re-rendered once the item
  /// reaches `.readyToPlay` (see [statusObs]) so a frame still appears when
  /// renderAt fired before the item was ready — e.g. a fast backend switch
  /// onto a large 4K clip, where a single paused render would otherwise miss
  /// and leave a black texture until the transport next moves.
  private var lastRequestedSeconds: Double = 0
  /// KVO on the item's status; drives the deferred first render and surfaces
  /// a later transition to `.failed` through [onError]. Torn down on failure
  /// or dispose(). Touched only on the main thread.
  private var statusObs: NSKeyValueObservation?
  /// Whether the deferred first render has run (main thread only) — the
  /// observation outlives it so `.failed` keeps being watched.
  private var deferredRenderDone = false

  private let outputQueue = DispatchQueue(label: "com.eclipsa.avf.output")

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
    player.actionAtItemEnd = .pause
    // Engine clock drives frames; the AVPlayer never free-runs.
    player.rate = 0
  }

  func load(
    path: String, completion: @escaping ([String: Any]?, String?) -> Void
  ) {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let keys = ["tracks", "duration"]
    asset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
      guard let self = self else {
        // The player was deallocated while the asset was resolving (disposed
        // or replaced mid-load). Still reply, or the Dart-side await on
        // "load" hangs forever.
        DispatchQueue.main.async { completion(nil, "disposed during load") }
        return
      }
      var err: NSError?
      guard asset.statusOfValue(forKey: "tracks", error: &err) == .loaded,
        asset.statusOfValue(forKey: "duration", error: nil) == .loaded,
        let videoTrack = asset.tracks(withMediaType: .video).first
      else {
        DispatchQueue.main.async {
          completion(nil, err?.localizedDescription ?? "no video track")
        }
        return
      }

      // Compose with ONLY the video track so no audio decoder is created
      // (the embedded IAMF stream has none — ES-219).
      //
      // Use the video *track's* time range, not the container duration: on a
      // muxed master whose audio outlasts the picture, asset.duration is the
      // longest track, overshooting the last frame (ES-459). Fall back to the
      // container duration if the track reports a non-numeric range.
      let composition = AVMutableComposition()
      let trackRange = videoTrack.timeRange
      // Anchor at zero and run through the track's end: byte-identical to
      // the track range when its start is zero (the normal case) and immune
      // to a picture-shift if a source ever reports a non-zero start.
      let range =
        trackRange.duration.isNumeric && trackRange.duration > .zero
        ? CMTimeRange(start: .zero, duration: trackRange.end)
        : CMTimeRange(start: .zero, duration: asset.duration)
      guard
        let compTrack = composition.addMutableTrack(
          withMediaType: .video,
          preferredTrackID: kCMPersistentTrackID_Invalid)
      else {
        DispatchQueue.main.async {
          completion(nil, "could not create composition track")
        }
        return
      }
      do {
        try compTrack.insertTimeRange(range, of: videoTrack, at: .zero)
      } catch {
        // A silent failure here yields an empty item and a black texture —
        // surface it so the Dart side reports a real error.
        DispatchQueue.main.async {
          completion(nil, "insert video track failed: \(error)")
        }
        return
      }

      let item = AVPlayerItem(asset: composition)
      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String:
          Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
      output.setDelegate(self, queue: self.outputQueue)
      item.add(output)

      DispatchQueue.main.async {
        self.stateLock.lock()
        if self.disposed {
          self.stateLock.unlock()
          // Disposed while the asset was still resolving. Registering a
          // texture here would retain self via the registry with nothing left
          // to unregister it — leaking the player + a zombie texture — so bail.
          completion(nil, "disposed during load")
          return
        }
        self.item = item
        self.output = output
        self.textureId = self.textures.register(self)
        let texId = self.textureId
        self.stateLock.unlock()
        self.player.replaceCurrentItem(with: item)
        self.player.rate = 0

        // Render the latest-requested frame as soon as the item can vend
        // one. Without this, a renderAt issued before the item is ready
        // (common right after a backend switch) leaves a black texture.
        // The observation stays alive after that first render so a later
        // transition to `.failed` (a decode error mid-playback) reaches
        // [onError] instead of silently freezing the picture.
        self.statusObs = item.observe(\.status, options: [.new, .initial]) {
          [weak self] observed, _ in
          guard let self = self else { return }
          let status = observed.status
          guard status == .readyToPlay || status == .failed else { return }
          let message = observed.error?.localizedDescription
          DispatchQueue.main.async {
            self.stateLock.lock()
            let t = self.lastRequestedSeconds
            let alive = !self.disposed
            self.stateLock.unlock()
            if status == .failed {
              self.statusObs?.invalidate()
              self.statusObs = nil
              if alive { self.onError?(message ?? "video decoder failed") }
              return
            }
            if alive && !self.deferredRenderDone {
              self.deferredRenderDone = true
              self.renderAt(seconds: t)
            }
          }
        }

        // The display size: the stored size with the track's rotation
        // applied. A flipped transform is drawn unrotated (see
        // quarterTurns), so it keeps the stored size.
        let transform = videoTrack.preferredTransform
        let flipped = transform.a * transform.d - transform.b * transform.c < 0
        let size =
          flipped
          ? videoTrack.naturalSize
          : videoTrack.naturalSize.applying(transform)
        var reply: [String: Any] = [
          "textureId": texId,
          "durationMs": Self.ms(range.duration),
          "width": Int(abs(size.width)),
          "height": Int(abs(size.height)),
          "fps": Double(videoTrack.nominalFrameRate),
          // width/height above are the display size; the pixel buffers stay
          // unrotated, so Dart turns the texture by this much (ES-796).
          "quarterTurns": Self.quarterTurns(videoTrack.preferredTransform),
          // Container (movie) duration — may exceed durationMs on a muxed
          // master whose audio outlasts the picture (ES-459 / ES-462).
          "containerDurationMs": Self.ms(asset.duration),
        ]
        if let fmt = videoTrack.formatDescriptions.first {
          // Force cast on purpose: formatDescriptions is an untyped NSArray
          // and a conditional downcast to a CoreFoundation type is a compile
          // error ("will always succeed") — the cast cannot trap.
          let desc = fmt as! CMFormatDescription
          if let codec = Self.codecName(
            CMFormatDescriptionGetMediaSubType(desc))
          {
            reply["codec"] = codec
          }
          if let transfer = Self.transferName(desc) {
            reply["colorTransfer"] = transfer
          }
          if let primaries = Self.primariesName(desc) {
            reply["colorPrimaries"] = primaries
          }
        }
        if videoTrack.estimatedDataRate > 0 {
          reply["bitRate"] = Int(videoTrack.estimatedDataRate)
        }
        completion(reply, nil)
      }
    }
  }

  /// Clockwise quarter turns (0-3) in a track's preferredTransform. The
  /// transform works in AVFoundation's y-down coordinates, where a positive
  /// angle turns clockwise: a portrait phone recording carries
  /// (a: 0, b: 1, c: -1, d: 0), which is 1. A flipped transform (negative
  /// determinant) returns 0, as the engine's FFmpeg decoder does: there is no
  /// mirror transform on the Dart side, and atan2 reads a horizontal flip as
  /// a 180-degree turn.
  private static func quarterTurns(_ t: CGAffineTransform) -> Int {
    if t.a * t.d - t.b * t.c < 0 { return 0 }
    let turns = Int((atan2(t.b, t.a) / (.pi / 2)).rounded())
    return ((turns % 4) + 4) % 4
  }

  /// Milliseconds for a CMTime, 0 (= unresolved on the Dart side) when the
  /// time is non-numeric — `Int(NaN)` would kill the process.
  private static func ms(_ t: CMTime) -> Int {
    guard t.isNumeric else { return 0 }
    return Int((CMTimeGetSeconds(t) * 1000.0).rounded())
  }

  /// Display name for a video codec fourcc, e.g. `HEVC (hvc1)`; unmapped
  /// printable fourccs show raw. Nil for non-fourcc subtypes (uncompressed
  /// tracks report numeric CVPixelFormatType codes with unprintable bytes),
  /// mirroring the Windows backend's omit-when-unknown contract.
  private static func codecName(_ code: FourCharCode) -> String? {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
      let cc = String(bytes: bytes, encoding: .ascii)
    else { return nil }
    switch cc {
    case "avc1", "avc3": return "H.264 (\(cc))"
    case "hvc1", "hev1": return "HEVC (\(cc))"
    case "vp09": return "VP9 (vp09)"
    case "av01": return "AV1 (av01)"
    case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x":
      return "ProRes (\(cc))"
    case "mp4v": return "MPEG-4 (mp4v)"
    default: return cc
    }
  }

  /// A CFString-valued format-description extension as a Swift String.
  private static func extensionString(
    _ desc: CMFormatDescription, _ key: CFString
  ) -> String? {
    CMFormatDescriptionGetExtension(desc, extensionKey: key) as? String
  }

  /// Transfer-function display name (e.g. `PQ (HDR10)`), or nil when the
  /// format description carries no transfer extension. Unmapped values
  /// show the raw CoreMedia constant.
  private static func transferName(_ desc: CMFormatDescription) -> String? {
    guard
      let transfer = extensionString(
        desc, kCMFormatDescriptionExtension_TransferFunction)
    else { return nil }
    let names: [String: String] = [
      kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String:
        "PQ (HDR10)",
      kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String: "HLG",
      kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String: "BT.709",
      kCMFormatDescriptionTransferFunction_ITU_R_2020 as String: "BT.2020",
    ]
    return names[transfer] ?? transfer
  }

  /// Color-primaries display name (e.g. `BT.2020`), or nil when absent.
  private static func primariesName(_ desc: CMFormatDescription) -> String? {
    guard
      let primaries = extensionString(
        desc, kCMFormatDescriptionExtension_ColorPrimaries)
    else { return nil }
    let names: [String: String] = [
      kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String: "BT.2020",
      kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String: "BT.709",
      kCMFormatDescriptionColorPrimaries_P3_D65 as String: "P3-D65",
    ]
    return names[primaries] ?? primaries
  }

  /// Render the exact frame for [seconds]: zero-tolerance (frame-accurate)
  /// seek, then ask the output to notify us once it has decoded data for the
  /// new position. The notification path is used rather than a synchronous
  /// `copyPixelBuffer` because on a paused (rate == 0) player the output is
  /// not being clocked, so the buffer is rarely ready the instant the seek
  /// completes — see ES-249 / the AVPlayerItemOutputPullDelegate docs.
  func renderAt(seconds: Double) {
    stateLock.lock()
    lastRequestedSeconds = seconds
    let isDisposed = disposed
    stateLock.unlock()
    if isDisposed { return }
    guard let output = output else { return }
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
      finished in
      guard finished else { return }
      // Wake the delegate; `outputMediaDataWillChange` does the copy. The
      // seek may be superseded by a newer one (finished == false) during a
      // fast scrub / per-tick playback sync — that's expected; the latest
      // seek delivers the frame. `output` is captured for the callback's
      // lifetime only (no retain cycle: the closure is owned by the seek).
      output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0)
    }
  }

  // AVPlayerItemOutputPullDelegate — the output has data to vend (runs on
  // `outputQueue`). Copy the frame for the current item time and publish it.
  func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
    // Runs on `outputQueue`, concurrently with dispose() on main. Read the
    // output/item references out under the lock (and bail if disposed) so a
    // teardown can't release them mid-use — the locals keep them alive for
    // the duration of this call.
    stateLock.lock()
    if disposed {
      stateLock.unlock()
      return
    }
    guard let output = output, let item = item else {
      stateLock.unlock()
      return
    }
    let texId = textureId
    stateLock.unlock()
    let itemTime = item.currentTime()
    guard output.hasNewPixelBuffer(forItemTime: itemTime),
      let buf = output.copyPixelBuffer(
        forItemTime: itemTime, itemTimeForDisplay: nil)
    else { return }
    stateLock.lock()
    if disposed {
      stateLock.unlock()
      return
    }
    latestBuffer = buf
    stateLock.unlock()
    if texId >= 0 {
      textures.textureFrameAvailable(texId)
    }
  }

  /// Pull-based, so "playing" is informational only — frames come from
  /// renderAt either way. Kept so the native side can later opt into
  /// AVPlayer-driven playback if that proves smoother than per-tick seeks.
  func setPlaying(_ playing: Bool) {
    _ = playing
    player.rate = 0
  }

  // FlutterTexture: hand Flutter the most recently pulled frame.
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let buf = latestBuffer else { return nil }
    return Unmanaged.passRetained(buf)
  }

  func dispose() {
    statusObs?.invalidate()
    statusObs = nil
    stateLock.lock()
    let texId = textureId
    textureId = -1
    disposed = true
    latestBuffer = nil
    // Nil these under the lock: outputMediaDataWillChange reads them on
    // `outputQueue`, so an unsynchronized release here would be a data race.
    item = nil
    output = nil
    stateLock.unlock()
    if texId >= 0 {
      textures.unregisterTexture(texId)
    }
    player.replaceCurrentItem(with: nil)
  }
}
