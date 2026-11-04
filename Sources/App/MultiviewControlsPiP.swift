// Every multi-view stream in one Picture in Picture window, with the window's own play and pause
// (Kestrel's player, Settings › Playback › Playback controls on). The video-call kind of window
// that moves the streams' own pictures in has no controls, so here each stream's decoded
// pictures are drawn together into one picture, laid out as on the multi-view screen, about 30
// times a second, and that is what the window plays.

import AVKit
import CoreImage
import UIKit

@MainActor
final class MultiviewControlsPiP: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  private weak var model: MultiviewModel?
  private let layer = AVSampleBufferDisplayLayer()
  private var controller: AVPictureInPictureController?
  private weak var source: UIView?
  private var enabled = false
  private(set) var isActive = false
  /// Started with the button: shown as soon as iOS can.
  private var wanted = false
  private var possibleObservation: NSKeyValueObservation?
  private var timer: DispatchSourceTimer?
  /// Each stream's newest pictures (a few, to show the one due now).
  private var frames: [String: [(image: CVImageBuffer, time: CMTime)]] = [:]
  private var hooked: [String: KestrelEngine] = [:]
  /// Each picture's place as a share of the whole (as on the multi-view screen).
  private var shares: [String: CGRect] = [:]
  private var outputSize = CGSize(width: 1280, height: 720)
  private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
  private var pool: CVPixelBufferPool?
  private var poolSize = CGSize.zero
  private var format: CMVideoFormatDescription?
  private var lastDrawn: [String: CMTime] = [:]
  private var idleTicks = 0

  init(model: MultiviewModel) {
    self.model = model
    super.init()
    layer.videoGravity = .resizeAspect
    layer.backgroundColor = UIColor.black.cgColor
  }

  // MARK: Setup

  /// On while multi-view is on screen with its streams on Kestrel's player.
  func setEnabled(_ on: Bool, source: UIView?) {
    let changed = on != enabled || source !== self.source
    enabled = on
    self.source = source
    guard changed, !isActive else { return }
    possibleObservation = nil
    controller?.delegate = nil
    controller = nil
    stopDrawing()
    layer.removeFromSuperlayer()
    guard on, let source, AVPictureInPictureController.isPictureInPictureSupported() else {
      unhookAll()
      return
    }
    // Behind the pictures on screen (the window grows out of here), drawn into all the time so the
    // window can open by itself when the app is left.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = source.bounds
    source.layer.insertSublayer(layer, at: 0)
    CATransaction.commit()
    let pip = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
    pip.canStartPictureInPictureAutomaticallyFromInline = true
    pip.delegate = self
    possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] pip, _ in
      guard pip.isPictureInPicturePossible, let owner = self else { return }
      Task { @MainActor in
        guard owner.wanted, let current = owner.controller, !current.isPictureInPictureActive else { return }
        owner.wanted = false
        current.startPictureInPicture()
      }
    }
    controller = pip
    sync()
    startDrawing()
  }

  /// The pictures' places on the multi-view screen.
  func setLayout(_ rects: [String: CGRect], in size: CGSize) {
    guard size.width > 0, size.height > 0, !rects.isEmpty else { return }
    let pictures = rects.mapValues(StreamPictures.picture(in:))
    let box = pictures.values.reduce(CGRect.null) { $0.union($1) }
    guard box.width > 0, box.height > 0 else { return }
    shares = pictures.mapValues {
      CGRect(
        x: ($0.minX - box.minX) / box.width, y: ($0.minY - box.minY) / box.height, width: $0.width / box.width,
        height: $0.height / box.height)
    }
    // The window the shape of the box around them; sharp enough for a big window, even sizes.
    let scale = 1280 / max(box.width, box.height)
    outputSize = CGSize(width: (box.width * scale / 2).rounded() * 2, height: (box.height * scale / 2).rounded() * 2)
  }

  /// The streams to draw (added or removed), each decoding here so its pictures can be drawn.
  func sync() {
    guard let model, enabled || isActive else { return }
    let current = Dictionary(uniqueKeysWithValues: model.tiles.compactMap { tile in tile.player.kestrelEngine.map { (tile.id, $0) } })
    for (id, engine) in hooked where current[id] !== engine {
      engine.onPicture = nil
      engine.setDecodeHere(false)
      hooked[id] = nil
      frames[id] = nil
    }
    for (id, engine) in current where hooked[id] == nil {
      engine.setDecodeHere(true)
      engine.onPicture = { [weak self] image, time in self?.received(id, image, time) }
      hooked[id] = engine
    }
  }

  private func unhookAll() {
    for engine in hooked.values {
      engine.onPicture = nil
      engine.setDecodeHere(false)
    }
    hooked = [:]
    frames = [:]
    lastDrawn = [:]
  }

  func toggle() {
    guard let controller else { return }
    if controller.isPictureInPictureActive {
      controller.stopPictureInPicture()
    } else if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
    } else {
      wanted = true
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        self?.wanted = false
      }
    }
  }

  func stop() { controller?.stopPictureInPicture() }

  /// Paused or played from elsewhere: the window's button follows.
  func playbackChanged() { controller?.invalidatePlaybackState() }

  // MARK: Drawing

  private func received(_ id: String, _ image: CVImageBuffer, _ time: CMTime) {
    var list = frames[id] ?? []
    list.append((image, time))
    if list.count > 8 { list.removeFirst(list.count - 8) }
    frames[id] = list
  }

  private func startDrawing() {
    guard timer == nil else { return }
    // A dispatch timer, not a display link: it keeps going in the background, where the window is.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
    timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.draw() } }
    timer.resume()
    self.timer = timer
  }

  private func stopDrawing() {
    timer?.cancel()
    timer = nil
  }

  /// The picture each stream shows now: its newest one due by its clock.
  private func current(_ id: String) -> CVImageBuffer? {
    guard var list = frames[id], !list.isEmpty, let engine = hooked[id] else { return nil }
    let now = CMTimeAdd(engine.clockTime, CMTime(value: 1, timescale: 60))
    var pick = 0
    for (index, frame) in list.enumerated() where CMTimeCompare(frame.time, now) <= 0 { pick = index }
    if pick > 0 { list.removeFirst(pick) }
    frames[id] = list
    lastDrawn[id] = list.first?.time
    return list.first?.image
  }

  private var ticks = 0

  private func draw() {
    ticks += 1
    // (Streams whose player came up since: hooked in.)
    if ticks % 30 == 0 { sync() }
    guard let source else { return }
    if layer.superlayer != nil, layer.frame != source.bounds {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.frame = source.bounds
      CATransaction.commit()
    }
    let size = outputSize
    let extent = CGRect(origin: .zero, size: size)
    var picture = CIImage(color: .black).cropped(to: extent)
    var anything = false
    let previous = lastDrawn
    for (id, share) in shares {
      guard let image = current(id) else { continue }
      anything = true
      let frame = CIImage(cvImageBuffer: image)
      let place = CGRect(
        x: share.minX * size.width, y: (1 - share.maxY) * size.height, width: share.width * size.width,
        height: share.height * size.height)
      let fitted = AVMakeRect(aspectRatio: frame.extent.size, insideRect: place)
      let scale = CGAffineTransform(scaleX: fitted.width / frame.extent.width, y: fitted.height / frame.extent.height)
        .concatenating(CGAffineTransform(translationX: fitted.minX, y: fitted.minY))
      picture = frame.transformed(by: scale).composited(over: picture)
    }
    // Nothing new to show: drawn again only now and then (the window keeps its last picture).
    if lastDrawn == previous {
      idleTicks += 1
      if idleTicks % 15 != 0 { return }
    } else {
      idleTicks = 0
    }
    guard anything || idleTicks % 15 == 0, let buffer = makeBuffer(size) else { return }
    context.render(picture, to: buffer, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
    enqueue(buffer)
  }

  private func makeBuffer(_ size: CGSize) -> CVPixelBuffer? {
    if pool == nil || poolSize != size {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
      ]
      var created: CVPixelBufferPool?
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
      pool = created
      poolSize = size
      format = nil
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    return buffer
  }

  private func enqueue(_ buffer: CVPixelBuffer) {
    if format == nil {
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
    }
    guard let format else { return }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
    guard let sample else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush() }
    layer.enqueue(sample)
  }

  // MARK: Window

  nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    MainActor.assumeIsolated {
      guard !isActive, let model else { return }
      isActive = true
      model.pictureInPictureChanged(true)
      ActivityLog.shared.add("Multi-view in Picture in Picture (with controls): \(model.tiles.count) streams together")
    }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    MainActor.assumeIsolated { ended() }
  }

  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
  ) {
    let message = error.localizedDescription
    Task { @MainActor in
      ActivityLog.shared.add("Multi-view couldn't go into Picture in Picture: \(message)")
      self.ended()
    }
  }

  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }

  private func ended() {
    guard isActive else { return }
    isActive = false
    model?.pictureInPictureChanged(false)
    if !enabled {
      stopDrawing()
      unhookAll()
    }
  }

  // MARK: Play and pause

  nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    MainActor.assumeIsolated {
      ActivityLog.shared.add(playing ? "Multi-view Picture in Picture: play" : "Multi-view Picture in Picture: pause")
      model?.setPaused(!playing, keepWindow: true)
    }
  }

  nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    // Live: an unbounded range shows the window's live controls.
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
    MainActor.assumeIsolated { model?.paused ?? false }
  }

  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}
