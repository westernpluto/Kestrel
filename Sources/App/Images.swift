import ImageIO
import SwiftUI
import UIKit

/// Loads, decodes (including animated GIF/WebP/APNG) and caches images: avatars, thumbnails,
/// emotes, badges.
///
/// Busy chat asks for dozens of emotes at once, many of them animated (every frame decoded up
/// front, so all copies on screen can share them). Decoding runs a few at a time, and an animated
/// picture's first frame is handed out straight away while the rest decode at lower priority: every
/// emote shows up quickly and starts moving a moment later, instead of all of them waiting on the
/// biggest animations.
final class ImagePipeline: @unchecked Sendable {
  static let shared = ImagePipeline()

  private let cache = NSCache<NSString, UIImage>()
  private let lock = NSLock()
  private var waiting: [String: [(UIImage?) -> Void]] = [:]
  /// Cached as a first frame, with the whole animation still decoding.
  private var upgrading: Set<String> = []
  private var failuresLogged: Set<String> = []
  /// Stills and first frames: what's on screen waits for these. Newest first: in busy chat,
  /// pictures for messages already scrolled away queued ahead of the ones just arriving (first in,
  /// first out), and the emotes in view could wait for seconds or not show before they'd gone.
  private var decodeStack: [(key: String, job: () -> Void)] = []
  private var decoding = 0
  private let decoders = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

  private func scheduleDecode(key: String, _ job: @escaping () -> Void) {
    lock.lock()
    decodeStack.append((key, job))
    // (Far behind: the oldest are dropped, their messages long gone. Nobody's left waiting on
    // them: asked for again, they're fetched (from the disk cache) and decoded afresh.)
    if decodeStack.count > 300 {
      for dropped in decodeStack.prefix(decodeStack.count - 300) {
        waiting.removeValue(forKey: dropped.key)
        upgrading.remove(dropped.key)
      }
      decodeStack.removeFirst(decodeStack.count - 300)
    }
    lock.unlock()
    runDecodes()
  }

  private func runDecodes() {
    lock.lock()
    var jobs: [() -> Void] = []
    while decoding < decoders, let next = decodeStack.popLast() {
      decoding += 1
      jobs.append(next.job)
    }
    lock.unlock()
    for job in jobs {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        job()
        guard let self else { return }
        self.lock.lock()
        self.decoding -= 1
        self.lock.unlock()
        self.runDecodes()
      }
    }
  }
  /// Whole animations, on their own two threads: opening the emote picker on a channel with
  /// hundreds of animated emotes used to fill every decoding thread with long animations, and the
  /// first frames of the emotes in view queued up behind them.
  private let animationQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "kestrel.images.animations"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 3
    return queue
  }()
  private let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = URLCache(memoryCapacity: 24 << 20, diskCapacity: 250 << 20)
    configuration.requestCachePolicy = .useProtocolCachePolicy
    configuration.httpMaximumConnectionsPerHost = 16
    configuration.timeoutIntervalForRequest = 20
    configuration.httpAdditionalHeaders = [
      "User-Agent": Browser.userAgent,
      "Accept": "image/webp,image/apng,image/png,image/gif,image/jpeg,image/*;q=0.8,*/*;q=0.5",
    ]
    return URLSession(configuration: configuration)
  }()

  init() {
    cache.totalCostLimit = 256 << 20
  }

  private static func key(_ url: URL, _ maxPixels: CGFloat?) -> String {
    maxPixels.map { "\(url.absoluteString)#\(Int($0))" } ?? url.absoluteString
  }

  /// The picture if it's in memory (for an animation still decoding: its first frame).
  func cached(_ url: URL, maxPixels: CGFloat? = nil) -> UIImage? {
    cache.object(forKey: Self.key(url, maxPixels) as NSString)
  }

  /// Only the first frame is in memory so far; `load` hands out the whole animation when it's ready.
  func isUpgrading(_ url: URL, maxPixels: CGFloat? = nil) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return upgrading.contains(Self.key(url, maxPixels))
  }

  func clear() {
    cache.removeAllObjects()
    session.configuration.urlCache?.removeAllCachedResponses()
    lock.lock()
    failuresLogged = []
    lock.unlock()
  }

  /// - Parameters:
  ///   - maxPixels: downsample so the longer side is at most this many pixels.
  ///   - fallback: tried when `url` fails (e.g. the original size of a resized Twitch image).
  ///   - completion: called on the main queue, or straight away when it's in memory. For an
  ///     animated picture it can be called twice: with the first frame, then the animation.
  func load(_ url: URL, maxPixels: CGFloat? = nil, fallback: URL? = nil, completion: @escaping (UIImage?) -> Void) {
    let key = Self.key(url, maxPixels)
    lock.lock()
    let image = cache.object(forKey: key as NSString)
    if let image, !upgrading.contains(key) {
      lock.unlock()
      completion(image)
      return
    }
    if waiting[key] != nil {
      waiting[key]?.append(completion)
      lock.unlock()
      if let image { completion(image) }
      return
    }
    waiting[key] = [completion]
    lock.unlock()
    fetch(url, maxPixels: maxPixels, fallback: fallback, attempt: 1, key: key)
  }

  /// Hands a picture to everyone waiting for it: `final` ends the wait (else it's a first frame,
  /// with the whole animation to come).
  private func deliver(_ key: String, _ image: UIImage?, final: Bool) {
    lock.lock()
    var picture = image
    if let image {
      cache.setObject(image, forKey: key as NSString, cost: Self.cost(image))
    } else if final {
      // The animation didn't decode: keep the first frame if there is one.
      picture = cache.object(forKey: key as NSString)
    }
    let callbacks: [(UIImage?) -> Void]
    if final {
      callbacks = waiting.removeValue(forKey: key) ?? []
      upgrading.remove(key)
    } else {
      callbacks = waiting[key] ?? []
      upgrading.insert(key)
    }
    lock.unlock()
    DispatchQueue.main.async { callbacks.forEach { $0(picture) } }
  }

  private func fetch(_ url: URL, maxPixels: CGFloat?, fallback: URL?, attempt: Int, key: String) {
    let task = session.dataTask(with: url) { [weak self] data, response, error in
      guard let self else { return }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if let data, (200..<300).contains(status) {
        self.decode(data, maxPixels: maxPixels, key: key, url: url, mimeType: response?.mimeType)
        return
      }
      // Retry network hiccups once; then try the fallback address.
      if status == 0 || status >= 500, attempt < 2 {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
          self.fetch(url, maxPixels: maxPixels, fallback: fallback, attempt: attempt + 1, key: key)
        }
        return
      }
      if let fallback, fallback != url {
        self.fetch(fallback, maxPixels: maxPixels, fallback: nil, attempt: 1, key: key)
        return
      }
      self.logFailure(url, status == 0 ? (error?.localizedDescription ?? "no response") : "HTTP \(status)")
      self.deliver(key, nil, final: true)
    }
    // Small pictures (emotes, badges) first: they're what chat is waiting on.
    if let maxPixels, maxPixels <= 160 { task.priority = URLSessionTask.highPriority }
    task.resume()
  }

  private func decode(_ data: Data, maxPixels: CGFloat?, key: String, url: URL, mimeType: String?) {
    scheduleDecode(key: key) { [weak self] in
      guard let self else { return }
      guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        CGImageSourceGetCount(source) > 1
      else {
        let image = Self.decode(data, maxPixels: maxPixels)
        if image == nil { self.logFailure(url, "couldn't decode \(data.count) bytes (\(mimeType ?? "?"))") }
        self.deliver(key, image, final: true)
        return
      }
      // Animated: its first frame now, the whole animation once the frames are decoded.
      if let frame = Self.frame(source, 0, maxPixels: maxPixels) {
        self.deliver(key, UIImage(cgImage: frame, scale: 2, orientation: .up), final: false)
      }
      let rest = BlockOperation { [weak self] in
        self?.deliver(key, Self.decode(data, maxPixels: maxPixels), final: true)
      }
      self.animationQueue.addOperation(rest)
    }
  }

  /// One activity-log line per host, so a broken image source is visible without flooding.
  private func logFailure(_ url: URL, _ reason: String) {
    let host = url.host ?? "?"
    lock.lock()
    let first = failuresLogged.insert(host).inserted
    lock.unlock()
    if first { ActivityLog.shared.add("Images from \(host) failed: \(reason) (\(url.absoluteString))") }
  }

  private static func cost(_ image: UIImage) -> Int {
    let frames = Set((image.images ?? [image]).map(ObjectIdentifier.init)).count
    return Int(image.size.width * image.size.height * image.scale * image.scale * 4) * max(1, frames)
  }

  private static func thumbnailOptions(_ maxPixels: CGFloat?) -> CFDictionary {
    [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels ?? 2048,
    ] as CFDictionary
  }

  private static func frame(_ source: CGImageSource, _ index: Int, maxPixels: CGFloat?) -> CGImage? {
    CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions(maxPixels))
      ?? CGImageSourceCreateImageAtIndex(source, index, nil)
  }

  /// Decodes still and animated images with ImageIO.
  static func decode(_ data: Data, maxPixels: CGFloat?) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
      return UIImage(data: data)
    }
    let count = CGImageSourceGetCount(source)
    guard count > 1 else {
      return frame(source, 0, maxPixels: maxPixels).map { UIImage(cgImage: $0, scale: 2, orientation: .up) } ?? UIImage(data: data)
    }
    // Animated: lay frames on a 20 ms grid so each keeps its own delay. Long animations keep
    // every second (or third…) frame, holding each for the ones skipped: at emote size that
    // looks the same and decodes several times faster.
    let limit = min(count, 400)
    // (At most 60 different frames: each is a whole picture in memory, and busy chat's animated
    // emotes pushed each other out of the cache, to be fetched and decoded again and again.)
    let step = max(1, Int((Double(limit) / 60).rounded(.up)))
    var frames: [UIImage] = []
    var total: Double = 0
    for index in stride(from: 0, to: limit, by: step) {
      guard let image = frame(source, index, maxPixels: maxPixels) else { continue }
      var delay = 0.0
      for skipped in index..<min(index + step, limit) { delay += frameDelay(source, skipped) }
      total += delay
      let still = UIImage(cgImage: image, scale: 2, orientation: .up)
      for _ in 0..<max(1, Int((delay / 0.02).rounded())) { frames.append(still) }
      if frames.count > 1500 { break }
    }
    guard !frames.isEmpty else { return UIImage(data: data) }
    return UIImage.animatedImage(with: frames, duration: total > 0 ? total : Double(frames.count) * 0.05)
  }

  private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
    let dictionaries: [(CFString, CFString, CFString)] = [
      (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
      (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
      ("{WebP}" as CFString, "UnclampedDelayTime" as CFString, "DelayTime" as CFString),
    ]
    for (dictionaryKey, unclamped, clamped) in dictionaries {
      guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
      let value = (dictionary[unclamped] as? NSNumber)?.doubleValue ?? (dictionary[clamped] as? NSNumber)?.doubleValue ?? 0.1
      return value < 0.02 ? 0.1 : value  // browsers treat tiny delays as 100 ms
    }
    return 0.1
  }
}

/// UIImageView-backed image for SwiftUI (so animated images play). It never takes touches: a
/// picture inside a button used to swallow the tap, so only the badges on it opened anything.
struct CachedImage: View {
  let url: URL?
  var maxPixels: CGFloat? = nil
  var fallback: URL? = nil
  var contentMode: UIView.ContentMode = .scaleAspectFill
  var placeholder: UIColor? = UIColor(white: 0.14, alpha: 1)

  var body: some View {
    CachedImageView(url: url, maxPixels: maxPixels, fallback: fallback, contentMode: contentMode, placeholder: placeholder)
      .allowsHitTesting(false)
  }
}

struct CachedImageView: UIViewRepresentable {
  let url: URL?
  var maxPixels: CGFloat? = nil
  var fallback: URL? = nil
  var contentMode: UIView.ContentMode = .scaleAspectFill
  var placeholder: UIColor? = UIColor(white: 0.14, alpha: 1)

  func makeUIView(context: Context) -> LoadingImageView {
    let view = LoadingImageView()
    view.isUserInteractionEnabled = false
    view.contentMode = contentMode
    view.clipsToBounds = true
    view.backgroundColor = placeholder
    for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
      view.setContentHuggingPriority(.defaultLow, for: axis)
      view.setContentCompressionResistancePriority(.defaultLow, for: axis)
    }
    return view
  }

  func updateUIView(_ view: LoadingImageView, context: Context) {
    view.contentMode = contentMode
    view.load(url, maxPixels: maxPixels, fallback: fallback)
  }
}

final class LoadingImageView: UIImageView {
  private var current: URL?
  /// An animated picture plays on this layer, driven by Core Animation itself: UIImageView only
  /// started an animated image if animations happened to be on when it was set, which they
  /// weren't for chat rows added in a burst, so in busy chats emotes often sat still.
  private var framesLayer: CALayer?
  private var animatedPicture: UIImage?
  private static let framesKey = "kestrel.frames"

  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }

  override var contentMode: UIView.ContentMode {
    didSet { framesLayer?.contentsGravity = Self.gravity(contentMode) }
  }

  func load(_ url: URL?, maxPixels: CGFloat?, fallback: URL?) {
    guard url != current else { return }
    current = url
    guard let url else {
      show(nil)
      return
    }
    if let cached = ImagePipeline.shared.cached(url, maxPixels: maxPixels) {
      show(cached)
      // Only its first frame so far: the animation follows.
      guard ImagePipeline.shared.isUpgrading(url, maxPixels: maxPixels) else { return }
      ImagePipeline.shared.load(url, maxPixels: maxPixels, fallback: fallback) { [weak self] image in
        guard let self, self.current == url, let image, image !== self.shownPicture else { return }
        self.show(image)
      }
      return
    }
    show(nil)
    ImagePipeline.shared.load(url, maxPixels: maxPixels, fallback: fallback) { [weak self] image in
      guard let self, self.current == url, image == nil || image !== self.shownPicture else { return }
      if self.shownPicture == nil {
        UIView.transition(with: self, duration: 0.15, options: .transitionCrossDissolve) { self.show(image) }
      } else if let image {
        // The animation taking over from its first frame: no fade (it starts on the same frame).
        self.show(image)
      }
    }
  }

  /// What's on screen (the first frame of an animation until the animation arrives).
  private(set) var shownPicture: UIImage?

  /// Shows a picture; an animated one plays by itself for as long as it's on screen.
  private func show(_ picture: UIImage?) {
    shownPicture = picture
    guard let picture, let frames = picture.images, frames.count > 1 else {
      animatedPicture = nil
      if let framesLayer {
        framesLayer.removeAnimation(forKey: Self.framesKey)
        framesLayer.contents = nil
        framesLayer.isHidden = true
      }
      image = picture
      return
    }
    image = nil
    animatedPicture = picture
    let frameLayer = framesLayer ?? makeFramesLayer()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    frameLayer.isHidden = false
    frameLayer.frame = bounds
    frameLayer.contentsScale = picture.scale
    frameLayer.contents = frames.first?.cgImage
    CATransaction.commit()
    startFrames()
  }

  private func makeFramesLayer() -> CALayer {
    let frameLayer = CALayer()
    frameLayer.contentsGravity = Self.gravity(contentMode)
    frameLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
    layer.addSublayer(frameLayer)
    framesLayer = frameLayer
    return frameLayer
  }

  /// (Re)starts the animation, in step with every other copy of the same picture on screen (as
  /// browsers do), only while the view is in a window.
  private func startFrames() {
    guard let frameLayer = framesLayer, let picture = animatedPicture else { return }
    frameLayer.removeAnimation(forKey: Self.framesKey)
    guard window != nil, let animation = Self.frameAnimation(for: picture) else { return }
    let now = CACurrentMediaTime()
    animation.beginTime = frameLayer.convertTime(now, from: nil) - now.truncatingRemainder(dividingBy: animation.duration)
    frameLayer.add(animation, forKey: Self.framesKey)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      framesLayer?.removeAnimation(forKey: Self.framesKey)
    } else if animatedPicture != nil, framesLayer?.animation(forKey: Self.framesKey) == nil {
      startFrames()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let framesLayer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    framesLayer.frame = bounds
    CATransaction.commit()
  }

  private static func gravity(_ mode: UIView.ContentMode) -> CALayerContentsGravity {
    switch mode {
    case .scaleAspectFit: return .resizeAspect
    case .scaleAspectFill: return .resizeAspectFill
    case .scaleToFill: return .resize
    default: return .center
    }
  }

  private static let templateKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

  /// The frames of an animated picture as a Core Animation keyframe animation: each frame held
  /// for its own delay (repeats from decoding are merged), looping forever. Made once per picture.
  static func frameAnimation(for picture: UIImage) -> CAKeyframeAnimation? {
    if let made = objc_getAssociatedObject(picture, templateKey) as? CAKeyframeAnimation {
      return made.copy() as? CAKeyframeAnimation
    }
    guard let frames = picture.images, frames.count > 1, picture.duration > 0 else { return nil }
    var values: [CGImage] = []
    var keyTimes: [NSNumber] = []
    var previous: UIImage?
    for (index, frame) in frames.enumerated() {
      if let previous, previous === frame { continue }
      previous = frame
      guard let cgImage = frame.cgImage else { continue }
      values.append(cgImage)
      keyTimes.append(NSNumber(value: Double(index) / Double(frames.count)))
    }
    guard values.count > 1 else { return nil }
    keyTimes[0] = 0
    keyTimes.append(1)
    let animation = CAKeyframeAnimation(keyPath: "contents")
    animation.values = values
    animation.keyTimes = keyTimes
    animation.calculationMode = .discrete
    animation.duration = picture.duration
    animation.repeatCount = .infinity
    // Kept through the app going to the background and back.
    animation.isRemovedOnCompletion = false
    objc_setAssociatedObject(picture, templateKey, animation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return animation.copy() as? CAKeyframeAnimation
  }
}

/// Kept for screens that only need a still picture.
struct RemoteImage: View {
  let url: URL?
  var contentMode: ContentMode = .fill
  var maxPixels: CGFloat? = nil

  var body: some View {
    CachedImage(url: url, maxPixels: maxPixels, contentMode: contentMode == .fill ? .scaleAspectFill : .scaleAspectFit)
  }
}

struct Avatar: View {
  let url: String?
  var size: CGFloat = 36

  var body: some View {
    // Profile pictures exist in a few fixed sizes; if the resized one is missing, use the original.
    CachedImage(
      url: TwitchAPI.image(url, width: 150, height: 150), maxPixels: size * 3,
      fallback: url.flatMap(URL.init(string:)))
      .frame(width: size, height: size)
      .clipShape(Circle())
  }
}
