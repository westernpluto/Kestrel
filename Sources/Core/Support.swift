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

  /// - Parameter givesWay: downloads that give way to others on a busy connection (iOS's
  ///   background network class): a recording, beside the stream being watched.
  /// - Parameter liveVideo: a live stream's playlists (iOS gives them the Wi-Fi's video priority).
  init(timeout: TimeInterval = 10, proxy: HTTPProxy? = nil, givesWay: Bool = false, liveVideo: Bool = false) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    if givesWay { configuration.networkServiceType = .background }
    #if canImport(Darwin)
      if liveVideo, !givesWay { configuration.networkServiceType = .responsiveAV }
    #endif
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

  /// A session lives (and keeps its delegate) until it's invalidated: let go of here, once what's
  /// under way has finished. Every client made (each chat opened, each try at an emote list) kept
  /// its session, connections and all, for as long as the app ran.
  deinit {
    session.finishTasksAndInvalidate()
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
    /// The address Twitch saw the request come from (a proxy's, when it went through one).
    var userIP: String? = nil
  }

  var info: Info? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { return nil }
    func flag(_ key: String) -> Bool? { (object[key] as? NSNumber)?.boolValue }
    let userID = object["user_id"]
    let signedIn = !(userID == nil || userID is NSNull || (userID as? String)?.isEmpty == true)
    let restricted = ((object["chansub"] as? [String: Any])?["restricted_bitrates"] as? [String]) ?? []
    return Info(
      showAds: flag("show_ads"), hideAds: flag("hide_ads"), serverAds: flag("server_ads"), turbo: flag("turbo"),
      subscriber: flag("subscriber"), signedIn: signedIn, restrictedBitrates: restricted,
      userIP: (object["user_ip"] as? String).flatMap { $0.isEmpty ? nil : $0 })
  }

  /// When Twitch stops accepting it (the token value says), if it says.
  var expires: Date? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
      let seconds = (object["expires"] as? NSNumber)?.doubleValue, seconds > 0
    else { return nil }
    return Date(timeIntervalSince1970: seconds)
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
  /// Whether the signed-in account is subscribed to the channel (nil: not signed in, or it
  /// couldn't be told).
  func subscribed(to login: String) async -> Bool?
  /// A session asked for the way twitch.tv itself asks, with its integrity proof: Twitch didn't
  /// count a subscription without it ("subscriber no"). Nil when that can't be had (not signed
  /// in, no proof in time) or didn't help on this channel lately.
  func verifiedStreamToken(login: String, playerType: String, platform: String) async -> PlaybackToken?
  /// The session twitch.tv's own player gets on the channel's page (nil: none in time, or it
  /// didn't help on this channel lately).
  func siteStreamToken(login: String) async -> PlaybackToken?
}

extension PlaybackTokenProvider {
  func subscribed(to login: String) async -> Bool? { nil }
  func verifiedStreamToken(login: String, playerType: String, platform: String) async -> PlaybackToken? { nil }
  func siteStreamToken(login: String) async -> PlaybackToken? { nil }
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

// MARK: - Learned response times

/// How long answers take, learned as they come, the way TCP learns when to give up on a packet: a
/// smoothed time and how much it varies. `late` is past what nearly every answer takes on this
/// connection now (fixed waits were too long on a fast connection and too short on a slow one).
final class ResponseTimer: @unchecked Sendable {
  private let lock = NSLock()
  private var smoothed: Double?
  private var spread: Double = 0

  init() {}

  func add(_ seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    if let current = smoothed {
      spread = 0.75 * spread + 0.25 * abs(current - seconds)
      smoothed = 0.875 * current + 0.125 * seconds
    } else {
      smoothed = seconds
      spread = seconds / 2
    }
  }

  /// The time after which an answer is late: `initial` until one has come; never under `floor` or
  /// over `ceiling`.
  func late(floor: Double, ceiling: Double, initial: Double) -> Double {
    lock.lock()
    defer { lock.unlock() }
    guard let smoothed else { return initial }
    return min(ceiling, max(floor, smoothed + 4 * spread))
  }
}
