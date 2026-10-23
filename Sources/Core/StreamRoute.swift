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
        return Result(text: text, url: url, route: .twitchAdFree(reason))
      }
    }
    if !proxies.isEmpty,
      let proxied = await AdFreeProxy.fetchMaster(
        login: login, codecs: codecs, lowLatency: lowLatency, hosts: proxies, http: http, log: log)
    {
      return Result(text: proxied.text, url: proxied.url, route: .adFreeServer(proxied.host))
    }
    let direct: PlaybackToken
    if let token {
      direct = token
    } else {
      direct = try await tokens.streamToken(login: login, playerType: playerType, platform: "web")
    }
    log.add(direct.summary)
    let (text, url) = try await usher(login: login, token: direct, codecs: codecs, lowLatency: lowLatency, http: http)
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
