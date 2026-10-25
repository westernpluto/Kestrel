import ImageIO
import SwiftUI
import UIKit

/// Loads, decodes (including animated GIF/WebP/APNG) and caches images: avatars, thumbnails,
/// emotes, badges.
final class ImagePipeline: @unchecked Sendable {
  static let shared = ImagePipeline()

  private let cache = NSCache<NSString, UIImage>()
  private let lock = NSLock()
  private var waiting: [String: [(UIImage?) -> Void]] = [:]
  private var failuresLogged: Set<String> = []
  private let decodeQueue = DispatchQueue(label: "kestrel.images", qos: .userInitiated, attributes: .concurrent)
  private let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = URLCache(memoryCapacity: 24 << 20, diskCapacity: 250 << 20)
    configuration.requestCachePolicy = .useProtocolCachePolicy
    configuration.httpMaximumConnectionsPerHost = 8
    configuration.timeoutIntervalForRequest = 20
    configuration.httpAdditionalHeaders = [
      "User-Agent": Browser.userAgent,
      "Accept": "image/webp,image/apng,image/png,image/gif,image/jpeg,image/*;q=0.8,*/*;q=0.5",
    ]
    return URLSession(configuration: configuration)
  }()

  init() {
    cache.totalCostLimit = 180 << 20
  }

  private static func key(_ url: URL, _ maxPixels: CGFloat?) -> String {
    maxPixels.map { "\(url.absoluteString)#\(Int($0))" } ?? url.absoluteString
  }

  func cached(_ url: URL, maxPixels: CGFloat? = nil) -> UIImage? {
    cache.object(forKey: Self.key(url, maxPixels) as NSString)
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
  ///   - completion: called on the main queue.
  func load(_ url: URL, maxPixels: CGFloat? = nil, fallback: URL? = nil, completion: @escaping (UIImage?) -> Void) {
    let key = Self.key(url, maxPixels)
    if let image = cache.object(forKey: key as NSString) {
      completion(image)
      return
    }
    lock.lock()
    if waiting[key] != nil {
      waiting[key]?.append(completion)
      lock.unlock()
      return
    }
    waiting[key] = [completion]
    lock.unlock()
    fetch(url, maxPixels: maxPixels, fallback: fallback, attempt: 1) { [weak self] image in
      guard let self else { return }
      if let image { self.cache.setObject(image, forKey: key as NSString, cost: Self.cost(image)) }
      self.lock.lock()
      let callbacks = self.waiting.removeValue(forKey: key) ?? []
      self.lock.unlock()
      DispatchQueue.main.async { callbacks.forEach { $0(image) } }
    }
  }

  private func fetch(_ url: URL, maxPixels: CGFloat?, fallback: URL?, attempt: Int, done: @escaping (UIImage?) -> Void) {
    session.dataTask(with: url) { [weak self] data, response, error in
      guard let self else { return }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if let data, (200..<300).contains(status) {
        self.decodeQueue.async {
          if let image = Self.decode(data, maxPixels: maxPixels) {
            done(image)
          } else {
            self.logFailure(url, "couldn't decode \(data.count) bytes (\(response?.mimeType ?? "?"))")
            done(nil)
          }
        }
        return
      }
      // Retry network hiccups once; then try the fallback address.
      if status == 0 || status >= 500, attempt < 2 {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
          self.fetch(url, maxPixels: maxPixels, fallback: fallback, attempt: attempt + 1, done: done)
        }
        return
      }
      if let fallback, fallback != url {
        self.fetch(fallback, maxPixels: maxPixels, fallback: nil, attempt: 1, done: done)
        return
      }
      self.logFailure(url, status == 0 ? (error?.localizedDescription ?? "no response") : "HTTP \(status)")
      done(nil)
    }.resume()
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

  /// Decodes still and animated images with ImageIO.
  static func decode(_ data: Data, maxPixels: CGFloat?) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
      return UIImage(data: data)
    }
    let count = CGImageSourceGetCount(source)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels ?? 2048,
    ]
    func frame(_ index: Int) -> CGImage? {
      CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        ?? CGImageSourceCreateImageAtIndex(source, index, nil)
    }
    guard count > 1 else {
      return frame(0).map { UIImage(cgImage: $0, scale: 2, orientation: .up) } ?? UIImage(data: data)
    }
    // Animated: lay frames on a 20 ms grid so each keeps its own delay.
    var frames: [UIImage] = []
    var total: Double = 0
    for index in 0..<min(count, 400) {
      guard let image = frame(index) else { continue }
      let delay = frameDelay(source, index)
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
      return
    }
    show(nil)
    ImagePipeline.shared.load(url, maxPixels: maxPixels, fallback: fallback) { [weak self] image in
      guard let self, self.current == url else { return }
      UIView.transition(with: self, duration: 0.15, options: .transitionCrossDissolve) { self.show(image) }
    }
  }

  /// Shows a picture; an animated one plays by itself for as long as it's on screen.
  private func show(_ picture: UIImage?) {
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
