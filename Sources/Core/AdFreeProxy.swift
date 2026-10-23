// Ad-free playlist proxies (the "v1" servers listed by TTV LOL PRO, running luminous-ttv).
// The server asks Twitch for the stream from a country where Twitch doesn't run ads and returns
// that master playlist. Kestrel then loads the playlists and video from Twitch directly.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct AdFreeProxy: Hashable, Sendable {
  let host: String
  /// Where Twitch thinks the viewer is.
  let country: String

  /// From https://wiki.cdn-perfprod.com/v1/must-read/proxies (operators: PerfProd, Luminous).
  /// Order for "Automatic": the ones recommended for mobile and routed to known ad-free countries
  /// first.
  static let all: [AdFreeProxy] = [
    AdFreeProxy(host: "lb-eu3.cdn-perfprod.com", country: "Russia"),
    AdFreeProxy(host: "eu.luminous.dev", country: "Russia"),
    AdFreeProxy(host: "eu2.luminous.dev", country: "Ukraine"),
    AdFreeProxy(host: "eu3.luminous.dev", country: "Bulgaria"),
    AdFreeProxy(host: "as.luminous.dev", country: "Kazakhstan"),
    AdFreeProxy(host: "lb-eu.cdn-perfprod.com", country: "various"),
    AdFreeProxy(host: "lb-eu2.cdn-perfprod.com", country: "various"),
    AdFreeProxy(host: "lb-eu4.cdn-perfprod.com", country: "various"),
    AdFreeProxy(host: "lb-eu5.cdn-perfprod.com", country: "various"),
    AdFreeProxy(host: "lb-as.cdn-perfprod.com", country: "various"),
    AdFreeProxy(host: "lb-na.cdn-perfprod.com", country: "US (Phoenix)"),
    AdFreeProxy(host: "lb-sa.cdn-perfprod.com", country: "US (New York)"),
  ]

  static func masterURL(host: String, login: String, codecs: String, lowLatency: Bool) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = "/live/\(login.lowercased())"
    components.queryItems = [
      URLQueryItem(name: "allow_source", value: "true"),
      URLQueryItem(name: "allow_audio_only", value: "true"),
      URLQueryItem(name: "playlist_include_framerate", value: "true"),
      URLQueryItem(name: "platform", value: "web"),
      URLQueryItem(name: "supported_codecs", value: codecs),
      URLQueryItem(name: "player_backend", value: "mediaplayer"),
    ] + (lowLatency ? [URLQueryItem(name: "fast_bread", value: "true")] : [])
    return components.url
  }

  /// `USER-COUNTRY` from the master playlist's `#EXT-X-TWITCH-INFO` (where Twitch thinks you are).
  static func userCountry(_ master: String) -> String? {
    for line in HLS.lines(master) where line.hasPrefix("#EXT-X-TWITCH-INFO") {
      if let country = HLS.attributes(line)["USER-COUNTRY"], !country.isEmpty { return country }
    }
    return nil
  }

  /// Tries the hosts in order; returns the first master playlist one of them delivers.
  static func fetchMaster(
    login: String, codecs: String, lowLatency: Bool, hosts: [String], http: HTTPClient, log: ActivityLog,
    timeout: TimeInterval = 6
  ) async -> (text: String, url: URL, host: String)? {
    for host in hosts.prefix(4) {
      guard let url = masterURL(host: host, login: login, codecs: codecs, lowLatency: lowLatency) else { continue }
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
      request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
      do {
        let (data, response) = try await http.data(for: request)
        if response.statusCode == 200, HLS.looksLikePlaylist(data), let text = String(data: data, encoding: .utf8),
          text.contains("#EXT-X-STREAM-INF")
        {
          let country = userCountry(text).map { ", Twitch sees \($0)" } ?? ""
          log.add("Ad-free proxy \(host) delivered the stream\(country)")
          lastWorkingHost = host
          return (text, response.url ?? url, host)
        }
        if response.statusCode == 404 {
          // The channel is offline (or doesn't exist): no point asking the others.
          log.add("Ad-free proxy \(host): channel not live")
          return nil
        }
        log.add("Ad-free proxy \(host) answered HTTP \(response.statusCode), trying the next")
      } catch {
        log.add("Ad-free proxy \(host) didn't answer (\(error.localizedDescription)), trying the next")
      }
    }
    return nil
  }

  /// Remembered across streams so the next one starts with the server that worked.
  private static let lock = NSLock()
  private static var _lastWorkingHost: String? = UserDefaults.standard.string(forKey: "kestrel.lastProxyHost")
  static var lastWorkingHost: String? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _lastWorkingHost
    }
    set {
      lock.lock()
      _lastWorkingHost = newValue
      lock.unlock()
      UserDefaults.standard.set(newValue, forKey: "kestrel.lastProxyHost")
    }
  }

  /// "Automatic" order, starting with the server that worked last time.
  static var automaticHosts: [String] {
    var hosts = all.map(\.host)
    if let last = lastWorkingHost, let index = hosts.firstIndex(of: last) {
      hosts.remove(at: index)
      hosts.insert(last, at: 0)
    }
    return hosts
  }
}
