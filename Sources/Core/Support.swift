import Dispatch
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - HTTP

protocol HTTPClient: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

enum Browser {
  /// Twitch's GQL rejects some requests that don't look like a browser (streamlink #6574).
  static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
}

final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
  let session: URLSession

  init(timeout: TimeInterval = 10) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpMaximumConnectionsPerHost = 6
    session = URLSession(configuration: configuration)
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let holder = CancellableTaskHolder()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
        let task = session.dataTask(with: request) { data, response, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let http = response as? HTTPURLResponse {
            continuation.resume(returning: (data ?? Data(), http))
          } else {
            continuation.resume(throwing: URLError(.badServerResponse))
          }
        }
        holder.set(task)
        task.resume()
      }
    } onCancel: {
      holder.cancel()
    }
  }
}

private final class CancellableTaskHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionTask?
  private var cancelled = false

  func set(_ task: URLSessionTask) {
    lock.lock()
    self.task = task
    let shouldCancel = cancelled
    lock.unlock()
    if shouldCancel { task.cancel() }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let task = self.task
    lock.unlock()
    task?.cancel()
  }
}

// MARK: - One-shot signal with timeouts

/// A broadcast signal that async code can wait on, with a timeout per waiter.
final class OneShotSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  var hasFired: Bool {
    lock.lock()
    defer { lock.unlock() }
    return fired
  }

  func fire() {
    lock.lock()
    fired = true
    let all = waiters
    waiters = [:]
    lock.unlock()
    for continuation in all.values { continuation.resume() }
  }

  func wait(timeout: TimeInterval) async {
    let id = UUID()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if fired {
        lock.unlock()
        continuation.resume()
        return
      }
      waiters[id] = continuation
      lock.unlock()
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
        self?.resume(id)
      }
    }
  }

  private func resume(_ id: UUID) {
    lock.lock()
    let continuation = waiters.removeValue(forKey: id)
    lock.unlock()
    continuation?.resume()
  }
}

// MARK: - Activity log

final class ActivityLog: @unchecked Sendable {
  static let shared = ActivityLog()

  struct Entry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
  }

  private let lock = NSLock()
  private var entries: [Entry] = []
  var echo = false
  var onChange: (@Sendable () -> Void)?

  func add(_ message: String) {
    lock.lock()
    entries.append(Entry(date: Date(), message: message))
    if entries.count > 400 { entries.removeFirst(entries.count - 400) }
    let callback = onChange
    lock.unlock()
    if echo { print("[log] \(message)") }
    callback?()
  }

  var all: [Entry] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }

  var messages: [String] { all.map(\.message) }

  func clear() {
    lock.lock()
    entries.removeAll()
    lock.unlock()
    onChange?()
  }
}

// MARK: - Usher URLs

struct PlaybackToken: Equatable, Sendable {
  var value: String
  var signature: String
}

protocol PlaybackTokenProvider: Sendable {
  func streamToken(login: String, playerType: String, platform: String) async throws -> PlaybackToken
}

enum Usher {
  static func percentEncode(_ string: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
  }

  private static func build(_ path: String, _ params: [(String, String)]) -> URL {
    let query = params.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
    return URL(string: "https://usher.ttvnw.net\(path)?\(query)")!
  }

  private static func common(codecs: String) -> [(String, String)] {
    [
      ("allow_source", "true"),
      ("allow_audio_only", "true"),
      ("playlist_include_framerate", "true"),
      ("platform", "web"),
      ("supported_codecs", codecs),
      ("p", String(Int.random(in: 0..<9_999_999))),
    ]
  }

  static func live(login: String, token: PlaybackToken, codecs: String, lowLatency: Bool) -> URL {
    var params = common(codecs: codecs)
    if lowLatency { params.append(("fast_bread", "true")) }
    // Enhanced Broadcasting channels list extra renditions (e.g. 1440p HEVC) per group.
    params.append(("multigroup_video", "true"))
    params.append(("sig", token.signature))
    params.append(("token", token.value))
    return build("/api/v2/channel/hls/\(login.lowercased()).m3u8", params)
  }

  static func vod(id: String, token: PlaybackToken, codecs: String) -> URL {
    var params = common(codecs: codecs)
    params.append(("nauthsig", token.signature))
    params.append(("nauth", token.value))
    params.append(("sig", token.signature))
    params.append(("token", token.value))
    return build("/vod/v2/\(id).m3u8", params)
  }

  static func playlistRequest(_ url: URL, timeout: TimeInterval = 6) -> URLRequest {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://player.twitch.tv", forHTTPHeaderField: "Referer")
    request.setValue("https://player.twitch.tv", forHTTPHeaderField: "Origin")
    return request
  }
}
