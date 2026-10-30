import Foundation
import SwiftUI

// MARK: - Settings

/// How Kestrel keeps ads out.
enum AdBlocking: Hashable {
  /// Ad-free proxy servers, the best available one picked automatically.
  case automatic
  /// One specific ad-free proxy server.
  case server(String)
  /// The user's own HTTP proxy (in a country without Twitch ads).
  case customProxy
  /// No proxy: switch to an ad-free copy of the stream, else hide the ad.
  case basic

  init(stored: String?) {
    switch stored {
    case nil, "auto": self = .automatic
    case "custom": self = .customProxy
    case "off": self = .basic
    case let value? where value.hasPrefix("server:"): self = .server(String(value.dropFirst(7)))
    default: self = .automatic
    }
  }

  var stored: String {
    switch self {
    case .automatic: return "auto"
    case .server(let host): return "server:\(host)"
    case .customProxy: return "custom"
    case .basic: return "off"
    }
  }

  var shortTitle: String {
    switch self {
    case .automatic: return "Automatic"
    case .server: return "Ad-free server"
    case .customProxy: return "Own proxy"
    case .basic: return "Basic"
    }
  }

  var title: String {
    switch self {
    case .automatic: return "Ad-free server (automatic)"
    case .server(let host): return host
    case .customProxy: return "My own proxy"
    case .basic: return "Basic"
    }
  }
}

/// What playback has learned about the connection, kept from one stream to the next.
enum PlaybackMemory {
  private static let defaults = UserDefaults.standard

  /// The bitrate of the quality Auto last played smoothly: where Auto starts next time.
  static var autoBitrate: Int? {
    get {
      let value = defaults.integer(forKey: "kestrel.autoBitrate")
      return value > 0 ? value : nil
    }
    set { defaults.set(newValue ?? 0, forKey: "kestrel.autoBitrate") }
  }
}

final class AppSettings: ObservableObject {
  static let shared = AppSettings()
  private let defaults = UserDefaults.standard

  @Published var lowLatency: Bool { didSet { defaults.set(lowLatency, forKey: "lowLatency") } }
  @Published var adBlocking: AdBlocking { didSet { defaults.set(adBlocking.stored, forKey: "adBlocking"); applyProxy() } }
  @Published var backgroundAudio: Bool { didSet { defaults.set(backgroundAudio, forKey: "backgroundAudio") } }
  @Published var showVideoStats: Bool { didSet { defaults.set(showVideoStats, forKey: "showVideoStats") } }
  @Published var chatFontSize: Double { didSet { defaults.set(chatFontSize, forKey: "chatFontSize") } }
  /// Live streams start on Auto quality (once Auto has been picked) instead of the best quality.
  @Published var autoQuality: Bool { didSet { defaults.set(autoQuality, forKey: "autoQuality") } }
  /// Through an ad-free server: move the stream to Twitch's servers near you when they accept it.
  @Published var nearbyServers: Bool { didSet { defaults.set(nearbyServers, forKey: "nearbyServers") } }
  // The user's own HTTP proxy (AdBlocking.customProxy).
  @Published var proxyHost: String { didSet { defaults.set(proxyHost, forKey: "proxyHost"); applyProxy() } }
  @Published var proxyPort: String { didSet { defaults.set(proxyPort, forKey: "proxyPort"); applyProxy() } }
  @Published var proxyUsername: String { didSet { defaults.set(proxyUsername, forKey: "proxyUsername"); applyProxy() } }
  @Published var proxyPassword: String {
    didSet {
      SecretStore.set(proxyPassword.isEmpty ? nil : Data(proxyPassword.utf8), for: "proxy")
      applyProxy()
    }
  }

  // Fixed choices (no longer settings): always try an ad-free copy, 360p if that's all there is;
  // ask for HEVC/AV1 when the device decodes them; 7TV/BTTV/FFZ emotes on.
  let backupStreams = true
  let allowLowQualityBackup = true
  let thirdPartyEmotes = true
  let chatTimestamps = false

  private var initialized = false

  private init() {
    defaults.register(defaults: [
      "lowLatency": true, "nearbyServers": true, "adBlocking": "auto", "backgroundAudio": true, "showVideoStats": false, "chatFontSize": 15.0,
    ])
    lowLatency = defaults.bool(forKey: "lowLatency")
    adBlocking = AdBlocking(stored: defaults.string(forKey: "adBlocking"))
    backgroundAudio = defaults.bool(forKey: "backgroundAudio")
    showVideoStats = defaults.bool(forKey: "showVideoStats")
    chatFontSize = defaults.double(forKey: "chatFontSize")
    autoQuality = defaults.bool(forKey: "autoQuality")
    nearbyServers = defaults.bool(forKey: "nearbyServers")
    proxyHost = defaults.string(forKey: "proxyHost") ?? ""
    proxyPort = defaults.string(forKey: "proxyPort") ?? ""
    proxyUsername = defaults.string(forKey: "proxyUsername") ?? ""
    proxyPassword = SecretStore.get("proxy").flatMap { String(data: $0, encoding: .utf8) } ?? ""
    initialized = true
    applyProxy()
  }

  /// Ad-free proxy servers to try for a stream, in order (none when they're off).
  var adFreeProxyHosts: [String] {
    switch adBlocking {
    case .automatic: return AdFreeProxy.automaticHosts
    case .server(let host): return [host] + AdFreeProxy.automaticHosts.filter { $0 != host }
    case .customProxy, .basic: return []
    }
  }

  /// The user's own proxy for playback requests, when chosen and filled in.
  var playbackProxy: HTTPProxy? {
    let host = proxyHost.trimmingCharacters(in: .whitespaces)
    guard adBlocking == .customProxy, !host.isEmpty, let port = Int(proxyPort.trimmingCharacters(in: .whitespaces)), port > 0
    else { return nil }
    return HTTPProxy(
      host: host, port: port, username: proxyUsername.isEmpty ? nil : proxyUsername,
      password: proxyPassword.isEmpty ? nil : proxyPassword)
  }

  /// HTTP client for Twitch tokens and playlists (through the user's proxy when one is set).
  func playbackClient(timeout: TimeInterval = 8) -> HTTPClient {
    URLSessionHTTPClient(timeout: timeout, proxy: playbackProxy)
  }

  /// Playback tokens go through the user's proxy too: Twitch decides about ads by where the
  /// token request comes from.
  func applyProxy() {
    guard initialized else { return }
    TwitchAPI.shared.playbackHTTP = playbackProxy.map { URLSessionHTTPClient(timeout: 12, proxy: $0) }
  }

  /// Twitch's `supported_codecs`: everything this device decodes in hardware.
  var codecs: String { DeviceCodecs.enhanced }

  /// What the stats overlay shows as the ad route.
  var adBlockingSummary: String {
    switch adBlocking {
    case .automatic, .server: return "ad-free server"
    case .customProxy: return playbackProxy.map { "own proxy \($0.description)" } ?? "own proxy (not set up)"
    case .basic: return "basic"
    }
  }

  /// Settings for the Apple player's stream session.
  var sessionConfig: StreamSessionConfig {
    var config = StreamSessionConfig()
    config.backupStreams = backupStreams
    config.allowLowQualityBackup = allowLowQualityBackup
    config.fallback = .muteAndCover
    config.codecs = codecs
    return config
  }
}

// MARK: - Followed channels (stored on the device)

final class FavoritesStore: ObservableObject {
  static let shared = FavoritesStore()
  @Published private(set) var channels: [Channel] = []
  private let key = "favorites.v1"

  private init() {
    if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([Channel].self, from: data) {
      channels = saved
    }
  }

  func contains(_ channel: Channel) -> Bool { channels.contains { $0.id == channel.id } }

  func toggle(_ channel: Channel) {
    if let index = channels.firstIndex(where: { $0.id == channel.id }) {
      channels.remove(at: index)
    } else {
      channels.append(channel)
    }
    save()
  }

  /// Keeps names/avatars fresh when we see newer data.
  func refresh(_ updated: [Channel]) {
    var changed = false
    for channel in updated {
      if let index = channels.firstIndex(where: { $0.id == channel.id }), channels[index] != channel {
        channels[index] = channel
        changed = true
      }
    }
    if changed { save() }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(channels) { UserDefaults.standard.set(data, forKey: key) }
  }
}

// MARK: - Navigation / playback routing

enum PlaybackTarget: Identifiable, Hashable {
  case live(Channel)
  case video(Video)

  var id: String {
    switch self {
    case .live(let channel): return "live-\(channel.id)"
    case .video(let video): return "vod-\(video.id)"
    }
  }
}

/// The app's sections (not `Tab`: that's a SwiftUI type in newer SDKs).
enum AppTab: Hashable {
  case following, browse, search, settings
}

/// A page in a section's navigation stack.
enum Route: Hashable {
  case channel(Channel)
  case category(Category)

  /// Same page, even if the channel's details changed since.
  var key: String {
    switch self {
    case .channel(let channel): return "channel-" + channel.id
    case .category(let category): return "category-" + category.id
    }
  }
}

final class AppModel: ObservableObject {
  static let shared = AppModel()
  /// What's playing. Setting it (even to what's already in the mini player) opens the player.
  @Published var playing: PlaybackTarget? {
    didSet { if playing != nil { playerMinimized = false } }
  }
  /// The player is shrunk into the mini player above the tab bar.
  @Published var playerMinimized = false
  @Published var tab: AppTab = .following
  // Each section's pages (so the player can open a channel page in the one you're in).
  @Published var followingPath: [Route] = []
  @Published var browsePath: [Route] = []
  @Published var searchPath: [Route] = []
  /// Height the tab bar takes up from the bottom of the screen (measured: it differs between
  /// iOS versions; the floating glass bar of iOS 26 is taller).
  @Published var tabBarHeight: CGFloat = 49

  /// Shrinks the player and opens the channel's page in the current section.
  func openChannel(_ channel: Channel) {
    playerMinimized = true
    if tab == .settings { tab = .following }
    push(.channel(channel))
  }

  /// Shrinks the player and opens a category's page in the current section.
  func openCategory(_ category: Category) {
    playerMinimized = true
    if tab == .settings { tab = .following }
    push(.category(category))
  }

  /// Opens a page in the current section. A page that's already open there is gone back to,
  /// never stacked a second time.
  func push(_ route: Route) {
    func apply(_ path: inout [Route]) {
      if let index = path.firstIndex(where: { $0.key == route.key }) {
        if index + 1 < path.count { path.removeSubrange((index + 1)...) }
      } else {
        path.append(route)
      }
    }
    switch tab {
    case .following: apply(&followingPath)
    case .browse: apply(&browsePath)
    case .search, .settings: apply(&searchPath)
    }
  }
}

// MARK: - Formatting

enum Format {
  static func viewers(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 10_000 { return "\(n / 1000)K" }
    if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
    return "\(n)"
  }

  static func duration(_ seconds: Int) -> String {
    let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  static func uptime(since date: Date?) -> String? {
    guard let date else { return nil }
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    return String(format: "%d:%02d", seconds / 3600, seconds % 3600 / 60)
  }

  static func relative(_ date: Date?) -> String {
    guard let date else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

extension Color {
  static let accentTeal = Color(red: 0.16, green: 0.78, blue: 0.72)
  static let liveRed = Color(red: 0.92, green: 0.20, blue: 0.27)
}
