// Every multi-view stream in one Picture in Picture window, with the window's own play and pause
// (Kestrel's player, Settings › Playback › Playback controls on). The video-call kind of window
// that moves the streams' own pictures in has no controls, so here each stream's decoded
// pictures are drawn together into one 16:9 picture (the streams in the grid that fits it best),
// 60 times a second, and that is what the window plays. The drawing is done off the main thread
// (on it, the app's own work made the timing uneven and the window choppy), and each picture is
// given its own moment on an even 60 a second grid, which the window keeps to.

import AVKit
import CoreImage
import UIKit

/// Each stream's newest decoded pictures and its clock, shared with the drawing queue.
final class PictureStore: @unchecked Sendable {
  private let lock = NSLock()
  private var order: [String] = []
  private var clocks: [String: CMTimebase] = [:]
  private var frames: [String: [(image: CVImageBuffer, time: CMTime)]] = [:]

  func set(order: [String], clocks: [String: CMTimebase]) {
    lock.lock()
    self.order = order
    self.clocks = clocks
    frames = frames.filter { clocks[$0.key] != nil }
    lock.unlock()
  }

  func add(_ id: String, _ image: CVImageBuffer, _ time: CMTime) {
    lock.lock()
    var list = frames[id] ?? []
    list.append((image, time))
    // Pictures are decoded as the video comes in, as far ahead of the one due as there's video in
    // hand (a second or more): all of them are kept until they're due. (Keeping just the newest
    // dozen threw away every one due: the window stood still, then ran a fifth of a second in a
    // rush, over and over.) A limit all the same, in case a stream's clock stops.
    if list.count > 240 { list.removeFirst(list.count - 240) }
    frames[id] = list
    lock.unlock()
  }

  /// For each stream in order: the picture due at `ahead` seconds from now on its clock (the
  /// newest one at or before then), dropping older ones. Nil where none has come yet.
  func due(ahead: Double) -> [CVImageBuffer?] {
    lock.lock()
    defer { lock.unlock() }
    return order.map { id in
      guard let clock = clocks[id], var list = frames[id], !list.isEmpty else { return nil }
      let target = CMTimeAdd(CMTimebaseGetTime(clock), CMTime(seconds: ahead + 1.0 / 240, preferredTimescale: 90_000))
      // The newest one due (in order of showing: decoded in that order).
      var pick = -1
      for (index, frame) in list.enumerated() {
        if CMTimeCompare(frame.time, target) <= 0 { pick = index } else { break }
      }
      // None due yet (just started, or after a jump back): the earliest, until its time comes.
      guard pick >= 0 else { return list.first?.image }
      if pick > 0 { list.removeFirst(pick) }
      frames[id] = list
      return list.first?.image
    }
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return order.count
  }
}

/// Draws the streams together on its own queue and hands the window evenly timed pictures.
final class PictureCompositor: @unchecked Sendable {
  static let size = CGSize(width: 1280, height: 720)
  private static let frameLength = 1.0 / 60
  /// How far ahead each picture is given its moment (time to draw it and for the window to show it
  /// on time).
  private static let lead = 0.05
  let store = PictureStore()
  let layer: AVSampleBufferDisplayLayer
  private let queue = DispatchQueue(label: "kestrel.multiview-pip", qos: .userInteractive)
  private var timer: DispatchSourceTimer?
  private let context = CIContext(options: [.cacheIntermediates: false])
  private var pool: CVPixelBufferPool?
  private var format: CMVideoFormatDescription?
  private let timebase: CMTimebase
  private var nextSlot: Double = 0
  private var lastImages: [ObjectIdentifier?] = []
  private var unchanged = 0

  init(layer: AVSampleBufferDisplayLayer) {
    self.layer = layer
    var made: CMTimebase?
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &made)
    timebase = made!
    CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
    CMTimebaseSetRate(timebase, rate: 1)
    layer.controlTimebase = timebase
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: Int(Self.size.width), kCVPixelBufferHeightKey: Int(Self.size.height),
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
  }

  func start() {
    queue.async { [self] in
      guard timer == nil else { return }
      nextSlot = 0
      // A dispatch timer: it keeps going in the background, where the window is.
      let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
      timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .nanoseconds(500_000))
      timer.setEventHandler { [weak self] in self?.tick() }
      timer.resume()
      self.timer = timer
    }
  }

  func stop() {
    queue.async { [self] in
      timer?.cancel()
      timer = nil
    }
  }

  private func tick() {
    let now = CMTimebaseGetTime(timebase).seconds
    // The next moment on the grid, a little ahead; back on the grid after falling behind, and
    // skipped once when running ahead.
    if nextSlot < now + Self.lead * 0.5 {
      nextSlot = now + Self.lead
    } else if nextSlot > now + Self.lead * 3 {
      return
    }
    let slot = nextSlot
    nextSlot += Self.frameLength
    let images = store.due(ahead: slot - now)
    let ids = images.map { $0.map { ObjectIdentifier($0 as AnyObject) } }
    // Nothing new: drawn again only now and then (the window keeps its last picture meanwhile).
    if ids == lastImages {
      unchanged += 1
      if unchanged % 30 != 0 { return }
    } else {
      unchanged = 0
    }
    lastImages = ids
    guard let buffer = draw(images) else { return }
    enqueue(buffer, at: slot)
  }

  private func draw(_ images: [CVImageBuffer?]) -> CVPixelBuffer? {
    let size = Self.size
    let extent = CGRect(origin: .zero, size: size)
    let places = MultiviewLayout.grid(count: images.count, in: size)
    var picture = CIImage(color: .black).cropped(to: extent)
    for (image, place) in zip(images, places) {
      guard let image else { continue }
      let frame = CIImage(cvImageBuffer: image)
      // (Core Image counts up from the bottom.)
      let flipped = CGRect(x: place.minX, y: size.height - place.maxY, width: place.width, height: place.height)
      let fitted = AVMakeRect(aspectRatio: frame.extent.size, insideRect: flipped)
      let transform = CGAffineTransform(scaleX: fitted.width / frame.extent.width, y: fitted.height / frame.extent.height)
        .concatenating(CGAffineTransform(translationX: fitted.minX, y: fitted.minY))
      picture = frame.transformed(by: transform).composited(over: picture)
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    guard let buffer else { return nil }
    context.render(picture, to: buffer, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())
    return buffer
  }

  private func enqueue(_ buffer: CVPixelBuffer, at slot: Double) {
    if format == nil {
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
    }
    guard let format else { return }
    var timing = CMSampleTimingInfo(
      duration: CMTime(seconds: Self.frameLength, preferredTimescale: 600_000),
      presentationTimeStamp: CMTime(seconds: slot, preferredTimescale: 600_000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
    guard let sample else { return }
    if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush() }
    layer.enqueue(sample)
  }
}

@MainActor
final class MultiviewControlsPiP: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  private weak var model: MultiviewModel?
  private let layer = AVSampleBufferDisplayLayer()
  /// Over it on screen: the window's picture (laid out for 16:9, not as the screen is) showed
  /// through between the streams, a second multi-view behind the first. Covered, it's still on
  /// screen as far as Picture in Picture is concerned, as the single stream's copy is.
  private let cover = CALayer()
  private lazy var compositor = PictureCompositor(layer: layer)
  private var controller: AVPictureInPictureController?
  private weak var source: UIView?
  private var enabled = false
  private(set) var isActive = false
  /// Started with the button: shown as soon as iOS can.
  private var wanted = false
  private var possibleObservation: NSKeyValueObservation?
  private var hooked: [String: KestrelEngine] = [:]
  /// Keeps the hook-ups and the layer's place current (once a second, on the main thread).
  private var upkeep: Timer?

  init(model: MultiviewModel) {
    self.model = model
    super.init()
    layer.videoGravity = .resizeAspect
    layer.backgroundColor = UIColor.black.cgColor
    cover.backgroundColor = UIColor.black.cgColor
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
    cover.removeFromSuperlayer()
    guard on, let source, AVPictureInPictureController.isPictureInPictureSupported() else {
      unhookAll()
      return
    }
    // Behind the pictures on screen (the window grows out of here), drawn into all the time so the
    // window can open by itself when the app is left.
    placeLayer(in: source)
    source.layer.insertSublayer(layer, at: 0)
    source.layer.insertSublayer(cover, above: layer)
    let pip = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
    pip.canStartPictureInPictureAutomaticallyFromInline = true
    // Live: no skipping back and forth (the window showed 10-second skip buttons).
    pip.requiresLinearPlayback = true
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

  /// A 16:9 window, centred over the pictures on screen.
  private func placeLayer(in source: UIView) {
    let bounds = source.bounds
    let frame = AVMakeRect(aspectRatio: PictureCompositor.size, insideRect: bounds)
    guard layer.frame != frame || cover.frame != bounds else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = frame.isEmpty ? bounds : frame
    cover.frame = bounds
    CATransaction.commit()
  }

  /// (The window is always 16:9 now, the streams in the grid that fits it: nothing to take from
  /// the screen's layout.)
  func setLayout(_ rects: [String: CGRect], in size: CGSize) {}

  /// The streams to draw (added or removed), each decoding here so its pictures can be drawn.
  func sync() {
    guard let model, enabled || isActive else { return }
    let current = Dictionary(uniqueKeysWithValues: model.tiles.compactMap { tile in tile.player.kestrelEngine.map { (tile.id, $0) } })
    for (id, engine) in hooked where current[id] !== engine {
      engine.onPicture = nil
      engine.setDecodeHere(false)
      hooked[id] = nil
    }
    let store = compositor.store
    for (id, engine) in current where hooked[id] == nil {
      engine.setDecodeHere(true)
      engine.onPicture = { image, time in store.add(id, image, time) }
      hooked[id] = engine
    }
    let order = model.tiles.map(\.id).filter { current[$0] != nil }
    store.set(order: order, clocks: current.mapValues(\.videoClock))
  }

  private func unhookAll() {
    for engine in hooked.values {
      engine.onPicture = nil
      engine.setDecodeHere(false)
    }
    hooked = [:]
    compositor.store.set(order: [], clocks: [:])
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

  private func startDrawing() {
    compositor.start()
    upkeep?.invalidate()
    upkeep = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        // (Streams whose player came up since: hooked in.)
        self.sync()
        if let source = self.source, self.layer.superlayer != nil { self.placeLayer(in: source) }
        // The window's play/pause button kept showing Play while playing.
        if self.isActive { self.controller?.invalidatePlaybackState() }
      }
    }
  }

  private func stopDrawing() {
    compositor.stop()
    upkeep?.invalidate()
    upkeep = nil
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
