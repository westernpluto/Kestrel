import SwiftUI
import UIKit

/// Shared memory cache for thumbnails, avatars, emotes and badges.
final class ImageCache: @unchecked Sendable {
  static let shared = ImageCache()

  private let cache = NSCache<NSURL, UIImage>()
  private let lock = NSLock()
  private var waiting: [URL: [(UIImage?) -> Void]] = [:]
  private let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 150 << 20)
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    configuration.httpMaximumConnectionsPerHost = 8
    return URLSession(configuration: configuration)
  }()

  init() {
    cache.totalCostLimit = 120 << 20
  }

  func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

  func clear() {
    cache.removeAllObjects()
    session.configuration.urlCache?.removeAllCachedResponses()
  }

  /// Completion is called on the main queue.
  func load(_ url: URL, scale: CGFloat = 2, completion: @escaping (UIImage?) -> Void) {
    if let image = cached(url) {
      completion(image)
      return
    }
    lock.lock()
    if waiting[url] != nil {
      waiting[url]?.append(completion)
      lock.unlock()
      return
    }
    waiting[url] = [completion]
    lock.unlock()
    session.dataTask(with: url) { [weak self] data, _, _ in
      guard let self else { return }
      var image = data.flatMap { UIImage(data: $0, scale: scale) }
      if let decoded = image {
        // Decode now (off the main thread) so scrolling stays smooth.
        image = decoded.preparingForDisplay() ?? decoded
        let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
        self.cache.setObject(image!, forKey: url as NSURL, cost: cost)
      }
      self.lock.lock()
      let callbacks = self.waiting.removeValue(forKey: url) ?? []
      self.lock.unlock()
      DispatchQueue.main.async { callbacks.forEach { $0(image) } }
    }.resume()
  }
}

final class RemoteImageLoader: ObservableObject {
  @Published var image: UIImage?
  private var url: URL?

  func load(_ url: URL?) {
    guard url != self.url else { return }
    self.url = url
    guard let url else {
      image = nil
      return
    }
    if let cached = ImageCache.shared.cached(url) {
      image = cached
      return
    }
    image = nil
    ImageCache.shared.load(url, scale: 1) { [weak self] image in
      guard let self, self.url == url else { return }
      self.image = image
    }
  }
}

struct RemoteImage: View {
  let url: URL?
  var contentMode: ContentMode = .fill
  @StateObject private var loader = RemoteImageLoader()

  var body: some View {
    ZStack {
      Color(white: 0.14)
      if let image = loader.image {
        Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
      }
    }
    .clipped()
    .onAppear { loader.load(url) }
    .onChange(of: url) { loader.load($0) }
  }
}

struct Avatar: View {
  let url: String?
  var size: CGFloat = 36

  var body: some View {
    RemoteImage(url: TwitchAPI.image(url, width: 150, height: 150))
      .frame(width: size, height: size)
      .clipShape(Circle())
  }
}
