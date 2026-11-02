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

/// How much video each channel's stream has needed in hand lately (see LiveCatchUp), so watching
/// it again starts there instead of learning it over with a stall or two. Kept for three days, and
/// only for streams that needed more than usual.
enum ChannelMargins {
  private static let key = "kestrel.channelMargins"
  /// What a channel needed is a good start for a while (its upload and the route to it stay
  /// much the same), not for days: an old hiccup kept every later visit further behind.
  private static let keepFor: TimeInterval = 12 * 3600
  /// Never started further back than this: it's learned again within seconds if it's needed.
  private static let mostToStartWith = 2.0

  private static func all() -> [String: [Double]] {
    let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
    let now = Date().timeIntervalSince1970
    return stored.filter { $0.value.count == 2 && now - $0.value[1] < keepFor }
  }

  /// Kept apart for cellular (it hiccups more than Wi-Fi: what a channel needed there says little
  /// about Wi-Fi).
  private static func entry(_ login: String, network: String) -> String {
    network == "cell" ? login.lowercased() + "@cell" : login.lowercased()
  }

  static func margin(for login: String, network: String) -> Double? {
    all()[entry(login, network: network)]?.first.map { min($0, mostToStartWith) }
  }

  static func remember(_ margin: Double, for login: String, network: String) {
    var stored = all()
    stored[entry(login, network: network)] =
      margin > LiveCatchUp.minBuffer + 0.25 ? [margin, Date().timeIntervalSince1970] : nil
    UserDefaults.standard.set(stored, forKey: key)
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
  /// VODs: jump past the parts Twitch muted for copyright as playback reaches them.
  @Published var skipMutedParts: Bool { didSet { defaults.set(skipMutedParts, forKey: "skipMutedParts") } }
  /// Multi-view's Picture in Picture shows every stream together (experimental) instead of the
  /// picked one.
  @Published var multiviewPiPAll: Bool { didSet { defaults.set(multiviewPiPAll, forKey: "multiviewPiPAll") } }
  /// When the channel you're watching raids another: follow it (like Twitch), ask, or nothing.
  @Published var raidMode: RaidMode { didSet { defaults.set(raidMode.rawValue, forKey: "raidMode") } }
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
  // ask for HEVC/AV1 when the device decodes them.
  let backupStreams = true
  let allowLowQualityBackup = true

  private var initialized = false

  private init() {
    defaults.register(defaults: [
      "lowLatency": true, "nearbyServers": true, "adBlocking": "auto", "backgroundAudio": true, "showVideoStats": false, "chatFontSize": 15.0,
      "multiviewPiPAll": true, "raidMode": RaidMode.follow.rawValue,
    ])
    lowLatency = defaults.bool(forKey: "lowLatency")
    adBlocking = AdBlocking(stored: defaults.string(forKey: "adBlocking"))
    backgroundAudio = defaults.bool(forKey: "backgroundAudio")
    showVideoStats = defaults.bool(forKey: "showVideoStats")
    chatFontSize = defaults.double(forKey: "chatFontSize")
    autoQuality = defaults.bool(forKey: "autoQuality")
    nearbyServers = defaults.bool(forKey: "nearbyServers")
    skipMutedParts = defaults.bool(forKey: "skipMutedParts")
    multiviewPiPAll = defaults.bool(forKey: "multiviewPiPAll")
    raidMode = RaidMode(rawValue: defaults.string(forKey: "raidMode") ?? "") ?? .follow
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

  private let sharedLock = NSLock()
  private var sharedPlayback: (proxy: HTTPProxy?, client: HTTPClient)?

  /// One client for every live stream's playlists (per proxy setting): its connections to Twitch's
  /// and the ad-free server's servers stay open from one stream to the next, and are opened ahead
  /// (PlaybackWarmup), so a stream starts closer to live. (Each stream had its own, and paid for
  /// new connections every time; on a fresh start that put it a few seconds further behind.)
  func sharedPlaybackClient() -> HTTPClient {
    let proxy = playbackProxy
    sharedLock.lock()
    defer { sharedLock.unlock() }
    if let sharedPlayback, sharedPlayback.proxy == proxy { return sharedPlayback.client }
    let client = URLSessionHTTPClient(timeout: 8, proxy: proxy)
    sharedPlayback = (proxy, client)
    return client
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
  case recordings

  /// Same page, even if the channel's details changed since.
  var key: String {
    switch self {
    case .channel(let channel): return "channel-" + channel.id
    case .category(let category): return "category-" + category.id
    case .recordings: return "recordings"
    }
  }
}

/// The app's section and each section's pages (see `AppModel.navigation`).
final class AppNavigation: ObservableObject {
  @Published var tab: AppTab = .following
  @Published var followingPath: [Route] = []
  @Published var browsePath: [Route] = []
  @Published var searchPath: [Route] = []
}

final class AppModel: ObservableObject {
  static let shared = AppModel()
  /// What's playing. Setting it (even to what's already in the mini player) opens the player.
  /// (Multi-view, if it's open, steps aside into its dock, stopped: one thing plays at a time.)
  @Published var playing: PlaybackTarget? {
    didSet {
      if playing != nil { playerMinimized = false }
      if playing?.id != oldValue?.id {
        presentation += 1
        // Whatever played before stops now (also caught when the view notices the change, but a
        // stream closed and reopened within one update would slip past that).
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.stopPlayers(except: self.playerKey)
        }
      }
    }
  }
  /// Counts openings of the player. Each opening gets its own player screen (`playerKey`): keyed by
  /// the stream alone, reopening a stream just closed brought back its closing, stopped screen
  /// while that was still fading away (invisible, nothing playing) until another stream was opened.
  private(set) var presentation = 0
  /// What identifies the player screen open now.
  var playerKey: String? { playing.map { "\($0.id)#\(presentation)" } }
  /// Multi-view (several live streams at once): open, on screen or tucked into its dock; nil while
  /// closed.
  @Published private(set) var multiview: MultiviewModel?
  /// Multi-view is tucked away: a row of the streamers' pictures where the mini player sits.
  @Published var multiviewMinimized = false
  /// The player screens that exist, keyed by what they play, and how to stop each. Opening
  /// another stream stops the old one here, right away: the old screen leaves with an animation,
  /// and SwiftUI doesn't always tell it it's gone (onDisappear) until something else redraws
  /// (e.g. shrinking the new one into the mini player), so its sound carried on until then.
  private var playerStops: [String: @MainActor () -> Void] = [:]

  @MainActor
  func registerPlayer(_ id: String, stop: @escaping @MainActor () -> Void) {
    playerStops[id] = stop
  }

  @MainActor
  func unregisterPlayer(_ id: String) {
    playerStops[id] = nil
  }

  /// Stops every player screen except the one for `id` (all of them for nil).
  @MainActor
  func stopPlayers(except id: String?) {
    for (key, stop) in playerStops where key != id {
      stop()
      playerStops[key] = nil
    }
  }

  /// A recording is open in its own player (which isn't `playing`).
  var watchingRecording = false

  /// Kestrel is playing something itself: the player, multi-view or a recording. The audio session
  /// is left on meanwhile (switching it off stops every sound playing, which is how multi-view went
  /// silent on coming back from the background).
  @MainActor
  var playsMedia: Bool { playing != nil || (multiview?.running ?? false) || watchingRecording }

  /// Opens multi-view on screen with these streams added (the player closes: its stream can be
  /// one of them).
  @MainActor
  func openMultiview(_ channels: [Channel]) {
    playing = nil
    let session = multiview ?? MultiviewModel()
    for channel in channels { session.add(channel) }
    if channels.count < 2 || session.tiles.count < 2 { session.wantsPicker = true }
    multiview = session
    multiviewMinimized = false
  }

  /// Adds a stream to multi-view without leaving what you're doing: it's collected in the dock
  /// (which appears if it wasn't open), to watch together once the dock is tapped.
  @MainActor
  func addToMultiview(_ channel: Channel) {
    if let session = multiview {
      session.add(channel)
    } else {
      let session = MultiviewModel()
      session.add(channel)
      multiviewMinimized = true
      multiview = session
    }
  }

  @MainActor
  func closeMultiview() {
    multiview?.stopAll()
    multiview = nil
    multiviewMinimized = false
  }
  /// The player is shrunk into the mini player above the tab bar.
  @Published var playerMinimized = false
  /// The section and each section's pages live in `navigation`: published from AppModel, every
  /// page opened or tab switched rebuilt the screens watching AppModel, the player (open or in the
  /// mini player) above all, which made browsing feel slow on iPhone Duo's big screen.
  let navigation = AppNavigation()
  var tab: AppTab {
    get { navigation.tab }
    set { navigation.tab = newValue }
  }
  // Each section's pages (so the player can open a channel page in the one you're in).
  var followingPath: [Route] {
    get { navigation.followingPath }
    set { navigation.followingPath = newValue }
  }
  var browsePath: [Route] {
    get { navigation.browsePath }
    set { navigation.browsePath = newValue }
  }
  var searchPath: [Route] {
    get { navigation.searchPath }
    set { navigation.searchPath = newValue }
  }
  /// Height the tab bar takes up from the bottom of the screen (measured: it differs between
  /// iOS versions; the floating glass bar of iOS 26 is taller).
  @Published var tabBarHeight: CGFloat = 49
  /// The tab bar when it runs down a side instead (iPhone Duo's inner screen), in window
  /// coordinates; `.null` otherwise. The mini player sits beside it, never over it.
  @Published var tabRail: CGRect = .null

  /// An offline channel's chat, in the player folded down to it (it offers the stream once they
  /// go live).
  @MainActor
  func openChat(_ channel: Channel) {
    PlayerModel.openedOffline.insert(channel.login.lowercased())
    playing = .live(channel)
  }

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

  /// "2:03:15": hours, minutes and seconds (hours always shown, as for how long a stream's been live).
  static func clock(_ seconds: Int) -> String {
    String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
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
