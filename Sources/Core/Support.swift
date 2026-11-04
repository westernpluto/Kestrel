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

/// An HTTP(S) proxy, e.g. one in a country where Twitch doesn't run ads.
struct HTTPProxy: Equatable, Sendable {
  var host: String
  var port: Int
  var username: String?
  var password: String?

  var description: String { "\(host):\(port)" }
}

final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
  let session: URLSession
  let proxy: HTTPProxy?

  init(timeout: TimeInterval = 10, proxy: HTTPProxy? = nil) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpMaximumConnectionsPerHost = 6
    self.proxy = proxy
    var delegate: ProxyCredentials?
    if let proxy {
      configuration.connectionProxyDictionary = [
        "HTTPEnable": 1, "HTTPProxy": proxy.host, "HTTPPort": proxy.port,
        "HTTPSEnable": 1, "HTTPSProxy": proxy.host, "HTTPSPort": proxy.port,
      ]
      if let username = proxy.username, !username.isEmpty {
        delegate = ProxyCredentials(URLCredential(user: username, password: proxy.password ?? "", persistence: .forSession))
      }
    }
    session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
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

/// Answers a proxy's request for a username and password.
private final class ProxyCredentials: NSObject, URLSessionTaskDelegate {
  let credential: URLCredential
  init(_ credential: URLCredential) { self.credential = credential }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.isProxy(), challenge.previousFailureCount == 0 {
      completionHandler(.useCredential, credential)
    } else {
      completionHandler(.performDefaultHandling, nil)
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

  /// What Twitch decided for this playback session (the token value is JSON).
  struct Info: Equatable, Sendable {
    var showAds: Bool?
    var hideAds: Bool?
    var serverAds: Bool?
    var turbo: Bool?
    var subscriber: Bool?
    var signedIn: Bool
    var restrictedBitrates: [String]
  }

  var info: Info? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { return nil }
    func flag(_ key: String) -> Bool? { (object[key] as? NSNumber)?.boolValue }
    let userID = object["user_id"]
    let signedIn = !(userID == nil || userID is NSNull || (userID as? String)?.isEmpty == true)
    let restricted = ((object["chansub"] as? [String: Any])?["restricted_bitrates"] as? [String]) ?? []
    return Info(
      showAds: flag("show_ads"), hideAds: flag("hide_ads"), serverAds: flag("server_ads"), turbo: flag("turbo"),
      subscriber: flag("subscriber"), signedIn: signedIn, restrictedBitrates: restricted)
  }

  /// One line for the activity log.
  var summary: String {
    guard let info else { return "Twitch session details unavailable" }
    var parts: [String] = [info.signedIn ? "signed in" : "not signed in"]
    if info.turbo == true { parts.append("Turbo") }
    if info.subscriber == true { parts.append("subscriber") }
    let ads = info.hideAds == true || info.showAds == false ? "no ads" : "ads possible"
    var line = "Twitch session: \(ads) (\(parts.joined(separator: ", ")))"
    if !info.restrictedBitrates.isEmpty { line += "; subscriber-only qualities: \(info.restrictedBitrates.joined(separator: ", "))" }
    return line
  }
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

/// A value shared between threads, behind a lock.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) { stored = value }

  var value: Value {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      stored = newValue
      lock.unlock()
    }
  }
}
