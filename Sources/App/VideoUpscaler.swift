// Enhancing the picture: each new frame is turned into RGB, cleaned of the stream's compression
// artifacts (blocking, ringing and the shimmer around edges, smoothed by an edge-preserving
// filter that leaves real detail alone, and dithered against banding), then enlarged to the size
// it's shown at by MetalFX's spatial scaler (sharper edges and detail than the plain stretch the
// system does), and drawn over the regular picture. The clean-up comes first so MetalFX sharpens
// the picture, not its artifacts; it's strongest for small renditions (where Twitch's bitrate
// shows most) and light at 1080p. Only when the picture is shown bigger than it is: smaller,
// the system's own picture shows.
//
// Frames come from the Apple player through a video output. The low-latency player has no way to
// hand them out; it draws through a sample-buffer layer, which (on iOS 17.4 and later) can say
// which frame it's showing, so that's used when it can be found.

import AVFoundation
import CoreVideo
import Metal
import MetalKit
#if canImport(MetalFX)
  import MetalFX
#else
  // The iOS Simulator has no MetalFX (the screenshot job builds for it): stand-ins that never
  // make a scaler, so upscaling just stays off there.
  final class MTLFXSpatialScaler {
    var colorTexture: MTLTexture?
    var outputTexture: MTLTexture?
    var inputContentWidth = 0
    var inputContentHeight = 0
    var outputWidth = 0
    var outputHeight = 0
    var colorTextureUsage: MTLTextureUsage = []
    var outputTextureUsage: MTLTextureUsage = []
    func encode(commandBuffer: MTLCommandBuffer) {}
  }
  enum MTLFXSpatialScalerColorProcessingMode { case perceptual }
  final class MTLFXSpatialScalerDescriptor {
    var inputWidth = 0
    var inputHeight = 0
    var outputWidth = 0
    var outputHeight = 0
    var colorTextureFormat: MTLPixelFormat = .invalid
    var outputTextureFormat: MTLPixelFormat = .invalid
    var colorProcessingMode: MTLFXSpatialScalerColorProcessingMode = .perceptual
    func makeSpatialScaler(device: MTLDevice) -> MTLFXSpatialScaler? { nil }
  }
#endif
import SwiftUI
import UIKit
import simd
import VideoToolbox

/// Where the upscaler gets the picture from.
protocol UpscaleFrameSource: AnyObject {
  /// The frame to show now, or nil when there's no new one.
  func currentFrame() -> CVPixelBuffer?
}

/// What the stats overlay says about upscaling (main thread).
enum UpscaleMonitor {
  static var status = "off"
}

/// The Apple player's frames, from a video output on whatever it's playing.
final class PlayerItemFrames: UpscaleFrameSource {
  private weak var player: AVPlayer?
  private weak var item: AVPlayerItem?
  private var output: AVPlayerItemVideoOutput?

  init(player: AVPlayer) {
    self.player = player
  }

  func currentFrame() -> CVPixelBuffer? {
    guard let current = player?.currentItem else { return nil }
    if current !== item { attach(to: current) }
    guard let output else { return nil }
    let time = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: time) else { return nil }
    return output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
  }

  private func attach(to newItem: AVPlayerItem) {
    if let output, let item { item.remove(output) }
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    newItem.add(output)
    self.output = output
    item = newItem
  }
}

/// The picture Kestrel's own player is showing (whatever layer it's on just now).
final class EngineFrames: UpscaleFrameSource {
  private weak var engine: KestrelEngine?
  init(engine: KestrelEngine) { self.engine = engine }
  func isFor(_ other: KestrelEngine) -> Bool { engine === other }
  // (Asked from the view's drawing, which runs on the main thread, as the player does.)
  func currentFrame() -> CVPixelBuffer? { MainActor.assumeIsolated { engine?.displayedFrame() } }
}

/// The frame a sample-buffer layer is showing (how the low-latency player draws), found inside
/// the player's own layer.
final class DisplayedFrames: UpscaleFrameSource {
  private let root: () -> CALayer?
  private weak var displayLayer: AVSampleBufferDisplayLayer?
  private var lastSearch = Date.distantPast

  init(root: @escaping () -> CALayer?) {
    self.root = root
  }

  /// False when the player doesn't draw through a sample-buffer layer this can read.
  private(set) var available = true

  func currentFrame() -> CVPixelBuffer? {
    guard #available(iOS 17.4, *) else {
      available = false
      return nil
    }
    if displayLayer == nil, Date().timeIntervalSince(lastSearch) > 1, let root = root() {
      lastSearch = Date()
      displayLayer = Self.find(in: root)
      available = displayLayer != nil
    }
    return displayLayer?.sampleBufferRenderer.displayedPixelBuffer()
  }

  private static func find(in layer: CALayer) -> AVSampleBufferDisplayLayer? {
    if let found = layer as? AVSampleBufferDisplayLayer { return found }
    for sublayer in layer.sublayers ?? [] {
      if let found = find(in: sublayer) { return found }
    }
    return nil
  }
}

/// Draws the upscaled picture into an MTKView.
final class UpscaleRenderer: NSObject, MTKViewDelegate {
  private weak var source: UpscaleFrameSource?
  private var fill = false
  private weak var view: MTKView?

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private var textureCache: CVMetalTextureCache?
  private let yuvPipeline: MTLRenderPipelineState
  private let copyPipeline: MTLRenderPipelineState
  private let cleanPipeline: MTLRenderPipelineState
  private let presentPipeline: MTLRenderPipelineState

  private struct ScalerSize: Equatable {
    var inputWidth: Int
    var inputHeight: Int
    var outputWidth: Int
    var outputHeight: Int
  }
  private var spatialScaler: MTLFXSpatialScaler?
  private var scalerSize: ScalerSize?
  private var rgbTexture: MTLTexture?
  private var cleanTexture: MTLTexture?
  private var outputTexture: MTLTexture?
  private var lastFrame: CVPixelBuffer?
  private var lastDrawableSize = CGSize.zero
  private var needsRedraw = false
  private var showing = false

  init?(view: MTKView) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(source: Self.shaders, options: nil),
      let vertex = library.makeFunction(name: "kestrelFullscreen"),
      let yuv = library.makeFunction(name: "kestrelYUV"),
      let copy = library.makeFunction(name: "kestrelCopy"),
      let clean = library.makeFunction(name: "kestrelClean"),
      let present = library.makeFunction(name: "kestrelPresent")
    else { return nil }
    func pipeline(_ fragment: MTLFunction, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = vertex
      descriptor.fragmentFunction = fragment
      descriptor.colorAttachments[0].pixelFormat = format
      return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    guard let yuvPipeline = pipeline(yuv, .bgra8Unorm), let copyPipeline = pipeline(copy, .bgra8Unorm),
      let cleanPipeline = pipeline(clean, .bgra8Unorm), let presentPipeline = pipeline(present, .bgra8Unorm)
    else { return nil }
    self.device = device
    self.queue = queue
    self.yuvPipeline = yuvPipeline
    self.copyPipeline = copyPipeline
    self.cleanPipeline = cleanPipeline
    self.presentPipeline = presentPipeline
    self.view = view
    super.init()
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    view.device = device
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.clearColor = MTLClearColorMake(0, 0, 0, 1)
    view.preferredFramesPerSecond = 60
    view.enableSetNeedsDisplay = false
    view.isPaused = false
    view.delegate = self
  }

  func update(source: UpscaleFrameSource?, fill: Bool) {
    if source !== self.source || fill != self.fill { needsRedraw = true }
    self.source = source
    self.fill = fill
    if source == nil { show(false, status: "no picture") }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    needsRedraw = true
  }

  func draw(in view: MTKView) {
    let size = view.drawableSize
    if size != lastDrawableSize {
      lastDrawableSize = size
      needsRedraw = true
    }
    var frame = source?.currentFrame()
    if frame == nil, needsRedraw { frame = lastFrame }
    guard let frame else {
      if let displayed = source as? DisplayedFrames, !displayed.available {
        show(false, status: "not available with the low-latency player")
      }
      if source is EngineFrames, !Self.canReadEngine { show(false, status: "needs iOS 17.4 or later") }
      return
    }
    if let lastFrame, frame === lastFrame, !needsRedraw { return }
    lastFrame = frame
    needsRedraw = false
    render(frame, in: view)
  }

  // MARK: Rendering

  /// Frames in a form Metal can't read (the decoder's own compressed formats, which is what Kestrel's
  /// player's frames are on a device): copied by VideoToolbox into plain 4:2:0 frames first. (Left
  /// as they were, the picture enhancer couldn't use them: "a format it can't use".)
  private var transfer: VTPixelTransferSession?
  private var plainPool: CVPixelBufferPool?
  private var plainPoolSize = CGSize.zero

  private static let readable: Set<OSType> = [
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_32BGRA,
  ]

  private func readable(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
    if Self.readable.contains(CVPixelBufferGetPixelFormatType(frame)) { return frame }
    let width = CVPixelBufferGetWidth(frame)
    let height = CVPixelBufferGetHeight(frame)
    if transfer == nil { VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer) }
    if plainPool == nil || plainPoolSize != CGSize(width: width, height: height) {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
        kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
      ]
      plainPool = nil
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &plainPool)
      plainPoolSize = CGSize(width: width, height: height)
    }
    guard let transfer, let plainPool else { return nil }
    var plain: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, plainPool, &plain)
    guard let plain, VTPixelTransferSessionTransferImage(transfer, from: frame, to: plain) == noErr else { return nil }
    // (Its colour matrix kept, for the conversion to RGB.)
    if let matrix = CVBufferCopyAttachment(frame, kCVImageBufferYCbCrMatrixKey, nil) {
      CVBufferSetAttachment(plain, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    }
    return plain
  }

  private func render(_ original: CVPixelBuffer, in view: MTKView) {
    guard let frame = readable(original) else {
      show(false, status: "this player's frames can't be read (\(Self.fourCC(CVPixelBufferGetPixelFormatType(original))))")
      return
    }
    let width = CVPixelBufferGetWidth(frame)
    let height = CVPixelBufferGetHeight(frame)
    let drawable = view.drawableSize
    guard width > 0, height > 0, drawable.width > 0, drawable.height > 0 else { return }
    let target = Self.targetRect(video: CGSize(width: width, height: height), in: drawable, fill: fill)
    // Only when it's shown bigger than it is: smaller, the system's own picture (scaled down far
    // better than a plain stretch here, which shimmered) shows as it is.
    let enlarge = target.width > CGFloat(width) * 1.1
    guard enlarge else {
      show(false, status: "not needed (\(width)×\(height) is already sharp at this size)")
      return
    }
    let outputWidth = min(Int(target.width.rounded()), 8192)
    let outputHeight = min(Int(target.height.rounded()), 8192)
    let scaler = enlarge ? makeScaler(inputWidth: width, inputHeight: height, outputWidth: outputWidth, outputHeight: outputHeight) : nil
    let scalerUsage = scaler?.colorTextureUsage ?? []
    guard let rgb = texture(&rgbTexture, width: width, height: height, usage: [.renderTarget, .shaderRead]),
      let cleaned = texture(&cleanTexture, width: width, height: height, usage: scalerUsage.union([.renderTarget, .shaderRead])),
      let commandBuffer = queue.makeCommandBuffer()
    else {
      show(false, status: "not supported on this device")
      return
    }

    // 1. The frame as RGB.
    var keep: [CVMetalTexture] = []
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = rgb
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
    let format = CVPixelBufferGetPixelFormatType(frame)
    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
      let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
      guard let luma = texture(of: frame, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, keep: &keep),
        let chroma = texture(of: frame, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, keep: &keep)
      else {
        encoder.endEncoding()
        show(false, status: "this player's frames can't be read")
        return
      }
      let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
      var conversion = Self.yuvToRGB(fullRange: fullRange, bt601: Self.isBT601(frame))
      encoder.setRenderPipelineState(yuvPipeline)
      encoder.setFragmentTexture(luma, index: 0)
      encoder.setFragmentTexture(chroma, index: 1)
      encoder.setFragmentBytes(&conversion, length: MemoryLayout<simd_float4x4>.stride, index: 0)
    case kCVPixelFormatType_32BGRA:
      guard let picture = texture(of: frame, plane: 0, format: .bgra8Unorm, keep: &keep) else {
        encoder.endEncoding()
        show(false, status: "this player's frames can't be read")
        return
      }
      encoder.setRenderPipelineState(copyPipeline)
      encoder.setFragmentTexture(picture, index: 0)
    default:
      encoder.endEncoding()
      show(false, status: "this player's frames are in a format it can't use (\(Self.fourCC(format)))")
      return
    }
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    // 2. Its compression artifacts cleaned up, as strongly as its size calls for.
    let cleanPass = MTLRenderPassDescriptor()
    cleanPass.colorAttachments[0].texture = cleaned
    cleanPass.colorAttachments[0].loadAction = .dontCare
    cleanPass.colorAttachments[0].storeAction = .store
    guard let cleaner = commandBuffer.makeRenderCommandEncoder(descriptor: cleanPass) else { return }
    var settings = Self.cleanUp(height: height, width: width)
    cleaner.setRenderPipelineState(cleanPipeline)
    cleaner.setFragmentTexture(rgb, index: 0)
    cleaner.setFragmentBytes(&settings, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
    cleaner.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    cleaner.endEncoding()

    // 3. MetalFX enlarges it (when it's shown bigger and the device can).
    var shown: MTLTexture = cleaned
    if let scaler, let output = texture(
      &outputTexture, width: scaler.outputWidth, height: scaler.outputHeight, usage: scaler.outputTextureUsage.union(.shaderRead))
    {
      scaler.colorTexture = cleaned
      scaler.inputContentWidth = width
      scaler.inputContentHeight = height
      scaler.outputTexture = output
      scaler.encode(commandBuffer: commandBuffer)
      shown = output
    }

    // 4. Onto the screen, fitted (or filling) like the regular picture.
    guard let drawableTexture = view.currentDrawable, let screenPass = view.currentRenderPassDescriptor,
      let presenter = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass)
    else { return }
    var rect = SIMD4<Float>(Float(target.minX), Float(target.minY), Float(target.width), Float(target.height))
    presenter.setRenderPipelineState(presentPipeline)
    presenter.setFragmentTexture(shown, index: 0)
    presenter.setFragmentBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
    presenter.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    presenter.endEncoding()
    commandBuffer.present(drawableTexture)
    commandBuffer.addCompletedHandler { _ in _ = keep }
    commandBuffer.commit()
    let size = "\(width)×\(height)"
    show(
      true,
      status: shown === cleaned
        ? "\(size) cleaned up" + (enlarge ? " (no MetalFX here)" : "")
        : "\(size) cleaned up → \(shown.width)×\(shown.height) (MetalFX)")
  }

  /// How strongly a picture's cleaned up, by its size: [strength, how far apart colours still
  /// count as the same surface, reach in pixels, 0] and the size of one pixel. Small renditions
  /// are where Twitch's bitrate shows most (blocks, smears); at 1080p it's a light touch.
  static func cleanUp(height: Int, width: Int) -> (SIMD4<Float>, SIMD4<Float>) {
    // (Gentle: only the faint speckle and blocking of compression, a few levels apart, is
    // evened out; anything more is detail and stays. Stronger, it smeared the picture.)
    let (strength, similar, reach): (Float, Float, Float) =
      switch height {
      case ..<400: (0.65, 0.07, 1)
      case ..<600: (0.55, 0.06, 1)
      case ..<800: (0.4, 0.045, 1)
      case ..<1200: (0.25, 0.035, 1)
      default: (0.15, 0.03, 1)
      }
    return (SIMD4(strength, similar, reach, 0), SIMD4(1 / Float(width), 1 / Float(height), 0, 0))
  }

  /// The spatial scaler for these sizes (kept while they stay the same). Some devices only go so
  /// far in one step: then it enlarges as far as it can and the last bit is a plain stretch.
  private func makeScaler(inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) -> MTLFXSpatialScaler? {
    let size = ScalerSize(inputWidth: inputWidth, inputHeight: inputHeight, outputWidth: outputWidth, outputHeight: outputHeight)
    if size == scalerSize, let spatialScaler { return spatialScaler }
    // The whole way, else 2× (and the rest stretched when it's drawn).
    let twice = (width: min(outputWidth, inputWidth * 2), height: min(outputHeight, inputHeight * 2))
    for (width, height) in [(outputWidth, outputHeight), twice] {
      let descriptor = MTLFXSpatialScalerDescriptor()
      descriptor.inputWidth = inputWidth
      descriptor.inputHeight = inputHeight
      descriptor.outputWidth = width
      descriptor.outputHeight = height
      descriptor.colorTextureFormat = .bgra8Unorm
      descriptor.outputTextureFormat = .bgra8Unorm
      descriptor.colorProcessingMode = .perceptual
      if let made = descriptor.makeSpatialScaler(device: device) {
        spatialScaler = made
        scalerSize = size
        return made
      }
    }
    spatialScaler = nil
    scalerSize = nil
    return nil
  }

  private func texture(_ slot: inout MTLTexture?, width: Int, height: Int, usage: MTLTextureUsage) -> MTLTexture? {
    if let existing = slot, existing.width == width, existing.height == height, existing.usage.contains(usage) { return existing }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = usage
    descriptor.storageMode = .private
    slot = device.makeTexture(descriptor: descriptor)
    return slot
  }

  private func texture(of frame: CVPixelBuffer, plane: Int, format: MTLPixelFormat, keep: inout [CVMetalTexture]) -> MTLTexture? {
    guard let textureCache else { return nil }
    let planar = CVPixelBufferIsPlanar(frame)
    let width = planar ? CVPixelBufferGetWidthOfPlane(frame, plane) : CVPixelBufferGetWidth(frame)
    let height = planar ? CVPixelBufferGetHeightOfPlane(frame, plane) : CVPixelBufferGetHeight(frame)
    var made: CVMetalTexture?
    let result = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, frame, nil, format, width, height, planar ? plane : 0, &made)
    guard result == kCVReturnSuccess, let made, let texture = CVMetalTextureGetTexture(made) else { return nil }
    keep.append(made)
    return texture
  }

  private func show(_ visible: Bool, status: String) {
    if UpscaleMonitor.status != status { UpscaleMonitor.status = status }
    guard visible != showing else { return }
    showing = visible
    view?.alpha = visible ? 1 : 0
  }

  /// A pixel format's four characters, for the stats.
  static func fourCC(_ type: OSType) -> String {
    let bytes = [UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF), UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF)]
    return String(bytes: bytes, encoding: .ascii) ?? "\(type)"
  }

  private static var canReadEngine: Bool {
    if #available(iOS 17.4, *) { return true }
    return false
  }

  // MARK: Geometry and colour

  /// Where the picture goes in the drawable (pixels): fitted, or filling it (cropped).
  static func targetRect(video: CGSize, in area: CGSize, fill: Bool) -> CGRect {
    let scale = fill ? max(area.width / video.width, area.height / video.height) : min(area.width / video.width, area.height / video.height)
    let size = CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
    return CGRect(x: ((area.width - size.width) / 2).rounded(), y: ((area.height - size.height) / 2).rounded(), width: size.width, height: size.height)
  }

  private static func isBT601(_ frame: CVPixelBuffer) -> Bool {
    guard let matrix = CVBufferCopyAttachment(frame, kCVImageBufferYCbCrMatrixKey, nil) else { return false }
    return (matrix as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
  }

  /// [Y, Cb, Cr, 1] → [R, G, B, 1].
  static func yuvToRGB(fullRange: Bool, bt601: Bool) -> simd_float4x4 {
    let ys: Float = fullRange ? 1 : 255 / 219
    let yo: Float = fullRange ? 0 : 16 / 255
    let cs: Float = fullRange ? 1 : 255 / 224
    let co: Float = 128 / 255
    let (rCr, gCb, gCr, bCb): (Float, Float, Float, Float) = bt601 ? (1.402, -0.344136, -0.714136, 1.772) : (1.5748, -0.1873, -0.4681, 1.8556)
    let y = SIMD4<Float>(ys, ys, ys, 0)
    let cb = SIMD4<Float>(0, gCb * cs, bCb * cs, 0)
    let cr = SIMD4<Float>(rCr * cs, gCr * cs, 0, 0)
    let constant = SIMD4<Float>(
      -ys * yo - rCr * cs * co,
      -ys * yo - gCb * cs * co - gCr * cs * co,
      -ys * yo - bCb * cs * co,
      1)
    return simd_float4x4(columns: (y, cb, cr, constant))
  }

  private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut kestrelFullscreen(uint vid [[vertex_id]]) {
      float2 p = float2(float((vid << 1) & 2), float(vid & 2));
      VOut out;
      out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
      out.uv = float2(p.x, 1.0 - p.y);
      return out;
    }

    fragment float4 kestrelYUV(VOut in [[stage_in]], texture2d<float> luma [[texture(0)]],
                               texture2d<float> chroma [[texture(1)]], constant float4x4 &conversion [[buffer(0)]]) {
      constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
      float4 yuv = float4(luma.sample(s, in.uv).r, chroma.sample(s, in.uv).rg, 1.0);
      return float4(saturate((conversion * yuv).rgb), 1.0);
    }

    fragment float4 kestrelCopy(VOut in [[stage_in]], texture2d<float> picture [[texture(0)]]) {
      constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
      return float4(picture.sample(s, in.uv).rgb, 1.0);
    }

    // An edge-preserving smoothing (each neighbour counted as much as its colour is like this
    // pixel's: across a real edge, hardly at all), mixed in by strength. Whole pixels only (in
    // between, the sampling itself blurred), and no dither (it showed as grain).
    fragment float4 kestrelClean(VOut in [[stage_in]], texture2d<float> picture [[texture(0)]],
                                 constant float4 *settings [[buffer(0)]]) {
      constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
      float strength = settings[0].x;
      float similar = settings[0].y;
      float2 step = settings[1].xy * settings[0].z;
      float3 center = picture.sample(s, in.uv).rgb;
      float3 sum = center;
      float total = 1.0;
      float spread = 2.0 * similar * similar;
      for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
          if (x == 0 && y == 0) { continue; }
          float3 near = picture.sample(s, in.uv + float2(x, y) * step).rgb;
          float3 d = near - center;
          float weight = exp(-dot(d, d) / spread) * ((x == 0 || y == 0) ? 1.0 : 0.7);
          sum += near * weight;
          total += weight;
        }
      }
      float3 cleaned = mix(center, sum / total, strength);
      return float4(saturate(cleaned), 1.0);
    }

    fragment float4 kestrelPresent(VOut in [[stage_in]], texture2d<float> picture [[texture(0)]],
                                   constant float4 &rect [[buffer(0)]]) {
      float2 uv = (in.position.xy - rect.xy) / rect.zw;
      if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) { return float4(0.0, 0.0, 0.0, 1.0); }
      constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
      return float4(picture.sample(s, uv).rgb, 1.0);
    }
    """
}

/// The upscaled picture, over the regular one (see the top of this file).
struct UpscaledVideoView: UIViewRepresentable {
  let source: UpscaleFrameSource?
  var fill: Bool

  final class Coordinator {
    var renderer: UpscaleRenderer?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero)
    view.isUserInteractionEnabled = false
    view.isOpaque = true
    view.backgroundColor = .black
    view.alpha = 0
    if let renderer = UpscaleRenderer(view: view) {
      context.coordinator.renderer = renderer
    } else {
      UpscaleMonitor.status = "Metal isn't available"
    }
    return view
  }

  func updateUIView(_ view: MTKView, context: Context) {
    context.coordinator.renderer?.update(source: source, fill: fill)
  }

  static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
    view.isPaused = true
    view.delegate = nil
    coordinator.renderer = nil
    UpscaleMonitor.status = "off"
  }
}
