// What the connection is: Wi-Fi, cellular or wired, Low Data Mode, and when it last changed.
//
// iOS doesn't let apps read signal strength (Wi-Fi bars or cellular bars), so the players go by what
// can be known: the kind of connection (cellular hiccups more than Wi-Fi, so a little more video is
// kept in hand there from the start), each stream's own arrival (LiveCatchUp learns from it), and
// changes of connection (moving between Wi-Fi and cellular drops connections for a moment: that
// stall isn't the stream's doing, so it isn't learned from).

import Foundation
import Network

final class NetworkWatch: @unchecked Sendable {
  static let shared = NetworkWatch()
  /// Posted on the main queue when the connection changes.
  static let changed = Notification.Name("kestrel.networkChanged")

  enum Kind: String, Sendable {
    case wifi = "Wi-Fi"
    case cellular = "Cellular"
    case wired = "Wired"
    case other = "Other"
    case none = "Offline"
  }

  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var current: (kind: Kind, constrained: Bool, changedAt: Date) = (.other, false, .distantPast)
  private var started = false

  private init() {}

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard !started else { return }
    started = true
    monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
    monitor.start(queue: DispatchQueue(label: "kestrel.network"))
  }

  var kind: Kind {
    lock.lock()
    defer { lock.unlock() }
    return current.kind
  }

  /// Low Data Mode.
  var constrained: Bool {
    lock.lock()
    defer { lock.unlock() }
    return current.constrained
  }

  /// Seconds since the connection last changed (a long time when it never has).
  var sinceChange: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return Date().timeIntervalSince(current.changedAt)
  }

  /// The least video to keep in hand on this connection (see LiveCatchUp.setFloor).
  var floor: Double {
    lock.lock()
    defer { lock.unlock() }
    if current.constrained { return 1.2 }
    return current.kind == .cellular ? 0.9 : LiveCatchUp.minBuffer
  }

  /// A short name for remembering what each channel needed on this kind of connection.
  var memoryKey: String { kind == .cellular ? "cell" : "wifi" }

  private func update(_ path: NWPath) {
    let kind: Kind
    if path.status != .satisfied {
      kind = .none
    } else if path.usesInterfaceType(.wifi) {
      kind = .wifi
    } else if path.usesInterfaceType(.wiredEthernet) {
      kind = .wired
    } else if path.usesInterfaceType(.cellular) {
      kind = .cellular
    } else {
      kind = .other
    }
    lock.lock()
    let before = current
    let first = before.changedAt == .distantPast && before.kind == .other
    let changed = before.kind != kind || before.constrained != path.isConstrained
    if changed { current = (kind, path.isConstrained, first ? .distantPast : Date()) }
    lock.unlock()
    guard changed, !first else { return }
    DispatchQueue.main.async {
      ActivityLog.shared.add("Connection: \(kind.rawValue)\(path.isConstrained ? " (Low Data Mode)" : "")")
      NotificationCenter.default.post(name: Self.changed, object: nil)
      if kind != .none { PlaybackWarmup.run(force: true) }
    }
  }
}

/// Opens the connections a stream starts with before one's asked for: Twitch's GraphQL (the
/// stream's token), its playlist servers (usher, and the one near you) and the ad-free server. On a
/// fresh start each was a new connection (name lookup, TCP, TLS) made one after another before the
/// first picture: the stream started that much further behind live. Done when Kestrel comes to the
/// front and when the connection changes.
enum PlaybackWarmup {
  /// (Called on the main thread.)
  private static var lastRun = Date.distantPast

  static func run(force: Bool = false) {
    guard force || Date().timeIntervalSince(lastRun) > 45 else { return }
    lastRun = Date()
    let settings = AppSettings.shared
    let playback = settings.sharedPlaybackClient()
    var hosts = ["usher.ttvnw.net"]
    if let near = NearbyPlaylists.cachedHost { hosts.append(near) }
    hosts += settings.adFreeProxyHosts.prefix(1)
    let api: HTTPClient = TwitchAPI.shared.playbackHTTP ?? TwitchAPI.shared.http
    // The playlist server on this iPhone, too.
    _ = try? StreamProxy.shared.ensureRunning()
    Task.detached(priority: .utility) {
      await withTaskGroup(of: Void.self) { group in
        for host in hosts { group.addTask { await touch(host, with: playback) } }
        group.addTask { await touch("gql.twitch.tv", with: api) }
      }
    }
  }

  private static func touch(_ host: String, with client: HTTPClient) async {
    guard let url = URL(string: "https://\(host)/") else { return }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
    request.httpMethod = "HEAD"
    _ = try? await client.data(for: request)
  }
}
