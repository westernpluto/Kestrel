// Where a live stream's master playlist comes from: straight from Twitch when it won't show you
// ads (signed in with a sub to the channel, or Turbo), else through an ad-free server, else
// straight from Twitch with Kestrel's ad handling.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum StreamRoute: Equatable, Sendable {
  /// Signed in and Twitch sends this account no ads here (the reason: "subscribed", "Turbo").
  case twitchAdFree(String)
  case adFreeServer(String)
  case twitch

  /// Twitch may stitch ads into this stream (the playlist came straight from Twitch with ads).
  var adsPossible: Bool {
    if case .twitch = self { return true }
    return false
  }

  var summary: String {
    switch self {
    case .twitchAdFree(let reason): return "none needed (\(reason))"
    case .adFreeServer(let host): return "ad-free server \(host)"
    case .twitch: return "Kestrel filter"
    }
  }
}

extension PlaybackToken {
  /// Why Twitch won't show this signed-in session ads, or nil if it may.
  var adFreeReason: String? {
    guard let info, info.signedIn, info.hideAds == true || info.showAds == false else { return nil }
    if info.turbo == true { return "Turbo" }
    if info.subscriber == true { return "subscribed" }
    return "no ads for your account"
  }
}

enum MasterPlaylistFetch {
  struct Result {
    var text: String
    var url: URL
    var route: StreamRoute
    /// Through an ad-free server: Twitch's playlist server near the viewer, to try instead of the
    /// one near the ad-free server (see `NearbyPlaylists`).
    var nearbyHost: String?
  }

  /// - Parameter checkAccountFirst: signed in: ask Twitch first and skip the ad-free servers when
  ///   it says this account gets no ads (keeps sub-only qualities and Twitch's own low latency).
  static func fetch(
    login: String, codecs: String, lowLatency: Bool, proxies: [String], checkAccountFirst: Bool, playerType: String,
    http: HTTPClient, tokens: PlaybackTokenProvider, log: ActivityLog
  ) async throws -> Result {
    var token: PlaybackToken?
    if checkAccountFirst {
      token = try? await tokens.streamToken(login: login, playerType: playerType, platform: "web")
      if let token, let reason = token.adFreeReason {
        log.add("Twitch shows you no ads on this channel (\(reason)): playing straight from Twitch")
        let (text, url) = try await usher(login: login, token: token, codecs: codecs, lowLatency: lowLatency, http: http)
        NearbyPlaylists.learn(fromMaster: text, base: url)
        return Result(text: text, url: url, route: .twitchAdFree(reason))
      }
    }
    if !proxies.isEmpty {
      // Meanwhile, unless it's known already: which playlist server Twitch would use for this
      // viewer directly (asked in parallel, so it costs no time).
      let known = token
      var probe: Task<String?, Never>?
      if NearbyPlaylists.freshHost == nil {
        probe = Task { () -> String? in
          var direct = known
          if direct == nil { direct = try? await tokens.streamToken(login: login, playerType: playerType, platform: "web") }
          guard let direct,
            let master = try? await usher(login: login, token: direct, codecs: codecs, lowLatency: lowLatency, http: http)
          else { return nil }
          return NearbyPlaylists.learn(fromMaster: master.0, base: master.1)
        }
      }
      if let proxied = await AdFreeProxy.fetchMaster(
        login: login, codecs: codecs, lowLatency: lowLatency, hosts: proxies, http: http, log: log)
      {
        var nearby = NearbyPlaylists.freshHost
        if nearby == nil, let probe { nearby = await NearbyPlaylists.value(of: probe, waitingUpTo: 0.7) }
        return Result(
          text: proxied.text, url: proxied.url, route: .adFreeServer(proxied.host), nearbyHost: nearby ?? NearbyPlaylists.cachedHost)
      }
      probe?.cancel()
    }
    let direct: PlaybackToken
    if let token {
      direct = token
    } else {
      direct = try await tokens.streamToken(login: login, playerType: playerType, platform: "web")
    }
    log.add(direct.summary)
    let (text, url) = try await usher(login: login, token: direct, codecs: codecs, lowLatency: lowLatency, http: http)
    NearbyPlaylists.learn(fromMaster: text, base: url)
    return Result(text: text, url: url, route: .twitch)
  }

  private static func usher(login: String, token: PlaybackToken, codecs: String, lowLatency: Bool, http: HTTPClient)
    async throws -> (String, URL)
  {
    let url = Usher.live(login: login, token: token, codecs: codecs, lowLatency: lowLatency)
    let (data, response) = try await http.data(for: Usher.playlistRequest(url))
    guard response.statusCode == 200, HLS.looksLikePlaylist(data), let text = String(data: data, encoding: .utf8) else {
      throw response.statusCode == 404 ? StreamSession.StartError.offline : StreamSession.StartError.usher(response.statusCode)
    }
    return (text, response.url ?? url)
  }
}

/// Twitch's playlist servers near the viewer.
///
/// An ad-free server asks Twitch for the stream from another country, so Twitch hands out a
/// playlist server near *it* (Frankfurt, say), and that server lists video from servers near it
/// too. For a viewer in America that adds delay, and one connection across the ocean rarely
/// carries more than a megabit or two on mobile data, so auto quality sinks and stalls. The
/// playlist's address carries the stream's ad-free session, so the same address is tried on the
/// playlist server Twitch picks for this viewer when asked directly; if that server won't take
/// it, nothing changes.
enum NearbyPlaylists {
  private static let lock = NSLock()
  private static let hostKey = "kestrel.nearbyPlaylistHost"
  private static let dateKey = "kestrel.nearbyPlaylistHostDate"
  /// Asked again after this long (the viewer may have moved).
  static let freshFor: TimeInterval = 30 * 60

  /// The last nearby playlist server seen, however old.
  static var cachedHost: String? {
    lock.lock()
    defer { lock.unlock() }
    return UserDefaults.standard.string(forKey: hostKey)
  }

  /// The last nearby playlist server seen, if seen recently.
  static var freshHost: String? {
    lock.lock()
    defer { lock.unlock() }
    let seen = UserDefaults.standard.double(forKey: dateKey)
    guard seen > 0, Date().timeIntervalSince1970 - seen < freshFor else { return nil }
    return UserDefaults.standard.string(forKey: hostKey)
  }

  /// Notes the playlist server of a master playlist asked for directly (so it's near the viewer).
  @discardableResult
  static func learn(fromMaster text: String, base: URL?) -> String? {
    guard let host = host(inMaster: text, base: base) else { return nil }
    lock.lock()
    UserDefaults.standard.set(host, forKey: hostKey)
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: dateKey)
    lock.unlock()
    return host
  }

  /// The playlist server a master playlist's renditions are on, if it's one of Twitch's.
  static func host(inMaster text: String, base: URL?) -> String? {
    let master = HLSMaster.parse(text, base: base)
    guard let uri = master.variants.first(where: { !$0.isAudioOnly })?.uri ?? master.variants.first?.uri,
      let host = URL(string: uri)?.host, isTwitchPlaylistHost(host)
    else { return nil }
    return host
  }

  static func isTwitchPlaylistHost(_ host: String) -> Bool {
    let host = host.lowercased()
    return host.hasSuffix(".playlist.ttvnw.net") || host.hasSuffix(".hls.ttvnw.net")
      || host.hasSuffix(".playlist.live-video.net")
  }

  private static let refusedHostKey = "kestrel.nearbyPlaylistRefusedHost"
  private static let refusedDateKey = "kestrel.nearbyPlaylistRefusedDate"
  /// A server that turned a stream away isn't asked again for this long.
  static let refusalLasts: TimeInterval = 6 * 60 * 60

  /// That server turned an ad-free server's playlist away: don't keep asking it.
  static func refused(_ host: String) {
    lock.lock()
    UserDefaults.standard.set(host, forKey: refusedHostKey)
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: refusedDateKey)
    lock.unlock()
  }

  /// Whether to try that server (it hasn't turned a stream away lately).
  static func worthTrying(_ host: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard UserDefaults.standard.string(forKey: refusedHostKey) == host else { return true }
    return Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: refusedDateKey) > refusalLasts
  }

  /// The same address on another server.
  static func replacingHost(_ uri: String, with host: String) -> String {
    guard var components = URLComponents(string: uri) else { return uri }
    components.host = host
    return components.string ?? uri
  }

  /// A task's result, or nil if it isn't ready within `seconds`.
  static func value(of task: Task<String?, Never>, waitingUpTo seconds: TimeInterval) async -> String? {
    let signal = OneShotSignal()
    let box = ResultBox()
    Task {
      box.set(await task.value)
      signal.fire()
    }
    await signal.wait(timeout: seconds)
    return box.get()
  }

  private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ newValue: String?) {
      lock.lock()
      value = newValue
      lock.unlock()
    }
    func get() -> String? {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }
}

// MARK: - VOD seek previews

/// Twitch's VOD storyboards: sprite sheets of thumbnails (`seekPreviewsURL` points at the JSON).
struct Storyboard: Equatable {
  var images: [URL]
  var columns: Int
  var rows: Int
  var count: Int
  /// Pixel size of one thumbnail.
  var width: Int
  var height: Int
  /// Seconds between thumbnails.
  var interval: Double

  struct Frame: Equatable {
    var image: URL
    var column: Int
    var row: Int
  }

  /// Picks the sharpest storyboard in the JSON. `duration` is needed when the JSON has no interval.
  static func parse(_ data: Data, base: URL, duration: Double?) -> Storyboard? {
    guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) } }
    func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap { Double($0) } }
    let boards: [Storyboard] = list.compactMap { entry in
      guard let names = entry["images"] as? [String], !names.isEmpty, let columns = int(entry["cols"]), columns > 0,
        let rows = int(entry["rows"]), rows > 0, let count = int(entry["count"]), count > 0
      else { return nil }
      let images = names.compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
      guard images.count == names.count else { return nil }
      var interval = double(entry["interval"]) ?? 0
      if interval <= 0, let duration, duration > 0 { interval = duration / Double(count) }
      guard interval > 0 else { return nil }
      return Storyboard(
        images: images, columns: columns, rows: rows, count: count, width: int(entry["width"]) ?? 0,
        height: int(entry["height"]) ?? 0, interval: interval)
    }
    return boards.max { $0.width < $1.width }
  }

  func frame(at seconds: Double) -> Frame? {
    guard seconds.isFinite, interval > 0 else { return nil }
    let index = min(count - 1, max(0, Int(seconds / interval)))
    let perImage = columns * rows
    let sheet = index / perImage
    guard sheet < images.count else { return nil }
    let cell = index % perImage
    return Frame(image: images[sheet], column: cell % columns, row: cell / columns)
  }
}
