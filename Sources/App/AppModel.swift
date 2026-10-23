import Foundation
import SwiftUI

// MARK: - Settings

final class AppSettings: ObservableObject {
  static let shared = AppSettings()
  private let defaults = UserDefaults.standard

  @Published var backupStreams: Bool { didSet { defaults.set(backupStreams, forKey: "backupStreams") } }
  @Published var allowLowQualityBackup: Bool { didSet { defaults.set(allowLowQualityBackup, forKey: "allowLowQualityBackup") } }
  @Published var adFallback: AdFallback { didSet { defaults.set(adFallback.rawValue, forKey: "adFallback") } }
  @Published var lowLatency: Bool { didSet { defaults.set(lowLatency, forKey: "lowLatency") } }
  /// Ask for HEVC/AV1 renditions (1440p on Enhanced Broadcasting channels) when the device decodes them.
  @Published var enhancedCodecs: Bool { didSet { defaults.set(enhancedCodecs, forKey: "enhancedCodecs") } }
  @Published var backgroundAudio: Bool { didSet { defaults.set(backgroundAudio, forKey: "backgroundAudio") } }
  /// Use the Apple player when a stream's best rendition (e.g. 1440p HEVC/AV1) is one the
  /// low-latency player can't decode.
  @Published var highestQualityOverLatency: Bool {
    didSet { defaults.set(highestQualityOverLatency, forKey: "highestQualityOverLatency") }
  }
  @Published var playerEngine: PlayerEngine { didSet { defaults.set(playerEngine.rawValue, forKey: "playerEngine") } }
  // Proxy for Twitch playback requests (tokens and playlists, not video).
  @Published var proxyEnabled: Bool { didSet { defaults.set(proxyEnabled, forKey: "proxyEnabled"); applyProxy() } }
  @Published var proxyHost: String { didSet { defaults.set(proxyHost, forKey: "proxyHost"); applyProxy() } }
  @Published var proxyPort: String { didSet { defaults.set(proxyPort, forKey: "proxyPort"); applyProxy() } }
  @Published var proxyUsername: String { didSet { defaults.set(proxyUsername, forKey: "proxyUsername"); applyProxy() } }
  @Published var proxyPassword: String {
    didSet {
      SecretStore.set(proxyPassword.isEmpty ? nil : Data(proxyPassword.utf8), for: "proxy")
      applyProxy()
    }
  }
  @Published var showVideoStats: Bool { didSet { defaults.set(showVideoStats, forKey: "showVideoStats") } }
  @Published var chatEnabled: Bool { didSet { defaults.set(chatEnabled, forKey: "chatEnabled") } }
  @Published var thirdPartyEmotes: Bool { didSet { defaults.set(thirdPartyEmotes, forKey: "thirdPartyEmotes") } }
  @Published var chatTimestamps: Bool { didSet { defaults.set(chatTimestamps, forKey: "chatTimestamps") } }
  @Published var chatFontSize: Double { didSet { defaults.set(chatFontSize, forKey: "chatFontSize") } }

  private init() {
    defaults.register(defaults: [
      "backupStreams": true, "allowLowQualityBackup": true, "adFallback": AdFallback.muteAndCover.rawValue,
      "lowLatency": true, "enhancedCodecs": true, "highestQualityOverLatency": false, "proxyEnabled": false,
      "showVideoStats": false, "backgroundAudio": true, "chatEnabled": true,
      "thirdPartyEmotes": true, "chatTimestamps": false, "chatFontSize": 15.0,
    ])
    backupStreams = defaults.bool(forKey: "backupStreams")
    allowLowQualityBackup = defaults.bool(forKey: "allowLowQualityBackup")
    adFallback = AdFallback(rawValue: defaults.string(forKey: "adFallback") ?? "") ?? .muteAndCover
    lowLatency = defaults.bool(forKey: "lowLatency")
    enhancedCodecs = defaults.bool(forKey: "enhancedCodecs")
    backgroundAudio = defaults.bool(forKey: "backgroundAudio")
    highestQualityOverLatency = defaults.bool(forKey: "highestQualityOverLatency")
    playerEngine = PlayerEngine.resolve(defaults.string(forKey: "playerEngine"))
    proxyEnabled = defaults.bool(forKey: "proxyEnabled")
    proxyHost = defaults.string(forKey: "proxyHost") ?? ""
    proxyPort = defaults.string(forKey: "proxyPort") ?? ""
    proxyUsername = defaults.string(forKey: "proxyUsername") ?? ""
    proxyPassword = SecretStore.get("proxy").flatMap { String(data: $0, encoding: .utf8) } ?? ""
    showVideoStats = defaults.bool(forKey: "showVideoStats")
    chatEnabled = defaults.bool(forKey: "chatEnabled")
    thirdPartyEmotes = defaults.bool(forKey: "thirdPartyEmotes")
    chatTimestamps = defaults.bool(forKey: "chatTimestamps")
    chatFontSize = defaults.double(forKey: "chatFontSize")
    initialized = true
    applyProxy()
  }

  /// The proxy for playback requests, when it's switched on and filled in.
  var playbackProxy: HTTPProxy? {
    let host = proxyHost.trimmingCharacters(in: .whitespaces)
    guard proxyEnabled, !host.isEmpty, let port = Int(proxyPort.trimmingCharacters(in: .whitespaces)), port > 0 else { return nil }
    return HTTPProxy(
      host: host, port: port, username: proxyUsername.isEmpty ? nil : proxyUsername,
      password: proxyPassword.isEmpty ? nil : proxyPassword)
  }

  /// HTTP client for Twitch tokens and playlists (through the proxy when one is set).
  func playbackClient(timeout: TimeInterval = 8) -> HTTPClient {
    URLSessionHTTPClient(timeout: timeout, proxy: playbackProxy)
  }

  private var initialized = false

  /// Playback tokens go through the proxy too: Twitch decides about ads by where the token
  /// request comes from.
  func applyProxy() {
    guard initialized else { return }
    TwitchAPI.shared.playbackHTTP = playbackProxy.map { URLSessionHTTPClient(timeout: 12, proxy: $0) }
  }

  /// Twitch's `supported_codecs` for new playbacks.
  var codecs: String { enhancedCodecs ? DeviceCodecs.enhanced : "h264" }

  /// Settings for the Apple player's stream session.
  var sessionConfig: StreamSessionConfig {
    var config = StreamSessionConfig()
    config.backupStreams = backupStreams
    config.allowLowQualityBackup = allowLowQualityBackup
    config.fallback = adFallback
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

final class AppModel: ObservableObject {
  static let shared = AppModel()
  @Published var playing: PlaybackTarget?
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
