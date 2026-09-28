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

// FFmpeg-in-engine video texture bridge for Eclipsa Studio (issue ES-249,
// step 5 — zero-copy texture phase).
//
// Unlike AvfVideoController, this side does NOT decode. The C++ engine decodes
// with VideoToolbox and produces a BGRA CVPixelBuffer per frame (IOSurface-
// backed); its address is handed through Dart to `present`. We register a
// FlutterTexture, adopt each incoming buffer, and notify Flutter, so the
// picture is sampled on the GPU with no readback — the zero-copy path the
// software `RawImage` fallback in `FfmpegEngineBackend` replaces when a HW
// surface is available.
//
// Wired into the Runner target (project.pbxproj) and registered on the
// `eclipsa/ffmpeg_video` channel in both the main window (MainFlutterWindow)
// and pop-out sub-windows (AppDelegate.setOnWindowCreatedCallback), mirroring
// AvfVideoController so the FFmpeg backend can run in either window.

import CoreImage
import CoreVideo
import FlutterMacOS
import Metal

/// Owns the method channel and the single active texture sink.
final class FfmpegVideoPlugin: NSObject {
  private let textures: FlutterTextureRegistry
  private let channel: FlutterMethodChannel
  private var sink: FfmpegVideoTexture?

  init(textures: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
    self.textures = textures
    self.channel = FlutterMethodChannel(
      name: "eclipsa/ffmpeg_video", binaryMessenger: messenger)
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
    case "create":
      sink?.dispose()
      let s = FfmpegVideoTexture(textures: textures)
      sink = s
      result(["textureId": s.register()])
    case "present":
      // The engine handed Dart a CVPixelBufferRef with a +1 retain; adopt it
      // here (takeRetainedValue balances that retain) and publish it. Adopting
      // even when there is no live sink still balances the retain — the local
      // `buffer` is released by ARC — so a teardown race can't leak.
      guard let addr = (args?["buffer"] as? NSNumber)?.uint64Value,
        let ptr = UnsafeRawPointer(bitPattern: UInt(addr))
      else {
        result(
          FlutterError(
            code: "bad_args", message: "buffer address required", details: nil))
        return
      }
      let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(ptr).takeRetainedValue()
      sink?.present(buffer)
      result(nil)
    case "dispose":
      sink?.dispose()
      sink = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// A FlutterTexture that vends externally-decoded CVPixelBuffers, converting
/// them to the BGRA layout Flutter samples.
final class FfmpegVideoTexture: NSObject, FlutterTexture {
  private let textures: FlutterTextureRegistry

  // `latest` is written by `present` on the platform thread and read by
  // `copyPixelBuffer` on the raster thread; guard it (and the id) with a lock.
  private let lock = NSLock()
  private var textureId: Int64 = -1
  private var latest: CVPixelBuffer?
  private var disposed = false

  // GPU (Metal-backed) colour conversion. VideoToolbox decodes to NV12, which
  // Flutter's pixel-buffer texture can't sample; CoreImage converts to BGRA on
  // the GPU with no CPU readback (and applies the correct YCbCr->RGB matrix /
  // range). Touched only from `present` (serialized by the backend).
  private let ciContext: CIContext = {
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }
    return CIContext(options: [.cacheIntermediates: false])
  }()
  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  func register() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    textureId = textures.register(self)
    return textureId
  }

  /// Publish the newest frame. Converts [src] to BGRA (no-op if it already is),
  /// then retains the result as `latest` (releasing the previous frame); dropped
  /// if already disposed.
  func present(_ src: CVPixelBuffer) {
    let frame = convertToBGRA(src) ?? src
    lock.lock()
    if disposed {
      lock.unlock()
      return  // ARC releases the buffers, balancing the adopted retain.
    }
    latest = frame
    let id = textureId
    lock.unlock()
    if id >= 0 { textures.textureFrameAvailable(id) }
  }

  /// Render [src] into a pooled BGRA CVPixelBuffer via CoreImage, or return it
  /// unchanged when it is already BGRA. Returns nil on allocation failure (the
  /// caller falls back to the source buffer).
  private func convertToBGRA(_ src: CVPixelBuffer) -> CVPixelBuffer? {
    if CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA {
      return src
    }
    let w = CVPixelBufferGetWidth(src)
    let h = CVPixelBufferGetHeight(src)
    guard let pool = bgraPool(width: w, height: h) else { return nil }
    var out: CVPixelBuffer?
    guard
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
      let dst = out
    else { return nil }
    ciContext.render(CIImage(cvPixelBuffer: src), to: dst)
    return dst
  }

  /// A BGRA, Metal/IOSurface-backed pixel-buffer pool for [width]x[height],
  /// rebuilt when the dimensions change.
  private func bgraPool(width: Int, height: Int) -> CVPixelBufferPool? {
    if pool != nil, poolWidth == width, poolHeight == height { return pool }
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var newPool: CVPixelBufferPool?
    guard
      CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &newPool)
        == kCVReturnSuccess
    else { return nil }
    pool = newPool
    poolWidth = width
    poolHeight = height
    return newPool
  }

  // FlutterTexture: hand Flutter the most recently published frame. Flutter
  // owns the returned +1 and releases it after sampling.
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buf = latest else { return nil }
    return Unmanaged.passRetained(buf)
  }

  func dispose() {
    lock.lock()
    let id = textureId
    textureId = -1
    disposed = true
    latest = nil
    lock.unlock()
    if id >= 0 { textures.unregisterTexture(id) }
  }
}
