// Kestrel for Apple TV: Twitch with the Siri Remote. It shares the iPhone app's core (the
// ad-free stream sessions, the local playlist server, the Twitch API and chat parsing) and has an
// interface of its own made for the TV: focusable cards in a grid, a full-screen player with chat
// beside it, and signing in with a code at twitch.tv/activate instead of typing a password.
//
// Apple TV has no Amazon IVS player, so streams play in the Apple player, kept as close to live as
// it will go (see TVPlayerModel).

import AVFoundation
import Security
import SwiftUI

@main
struct KestrelTVApp: App {
  @StateObject private var store = TVStore.shared

  var body: some Scene {
    WindowGroup {
      TVRootView()
        .environmentObject(store)
        .task { await store.launch() }
    }
  }
}

struct TVRootView: View {
  @EnvironmentObject private var store: TVStore

  var body: some View {
    TabView(selection: $store.tab) {
      TVFollowingView()
        .tabItem { Label("Following", systemImage: "heart") }
        .tag(TVTab.following)
      TVBrowseView()
        .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }
        .tag(TVTab.live)
      TVCategoriesView()
        .tabItem { Label("Categories", systemImage: "square.grid.2x2") }
        .tag(TVTab.categories)
      TVSearchView()
        .tabItem { Label("Search", systemImage: "magnifyingglass") }
        .tag(TVTab.search)
      TVSettingsView()
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(TVTab.settings)
    }
    .fullScreenCover(item: $store.watching) { channel in
      TVPlayerView(channel: channel)
        .environmentObject(store)
    }
  }
}

enum TVTab: Hashable {
  case following, live, categories, search, settings
}

/// The app's state: the account, what's playing, and the few settings.
@MainActor
final class TVStore: ObservableObject {
  static let shared = TVStore()

  @Published var tab: TVTab = .live
  /// The stream open in the player.
  @Published var watching: Channel?
  @Published private(set) var session: TwitchAuth.Session?
  /// Through the ad-free servers (as the iPhone app's Automatic), or straight from Twitch.
  @Published var adBlocking: Bool { didSet { UserDefaults.standard.set(adBlocking, forKey: "tv.adBlocking") } }
  /// Chat beside the video when a stream opens.
  @Published var chatShown: Bool { didSet { UserDefaults.standard.set(chatShown, forKey: "tv.chatShown") } }

  private init() {
    UserDefaults.standard.register(defaults: ["tv.adBlocking": true, "tv.chatShown": true])
    adBlocking = UserDefaults.standard.bool(forKey: "tv.adBlocking")
    chatShown = UserDefaults.standard.bool(forKey: "tv.chatShown")
    if let data = TVKeychain.get("session"), let saved = try? JSONDecoder().decode(TwitchAuth.Session.self, from: data) {
      session = saved
      TwitchAuth.shared.update(saved)
    }
  }

  /// At launch: the saved sign-in still good (refreshed if its token ran out), and the playlist
  /// server running.
  func launch() async {
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    _ = try? StreamProxy.shared.ensureRunning()
    guard let current = session else { return }
    let http = URLSessionHTTPClient(timeout: 10)
    if (try? await TwitchAuth.validate(token: current.token, http: http, clientID: current.clientID ?? TwitchAPI.webClientID)) != nil {
      if tab == .live { tab = .following }
      return
    }
    if let refresh = current.refreshToken,
      let grant = try? await TwitchDeviceLogin.refresh(refresh, clientID: current.clientID ?? TwitchDeviceLogin.clientID, http: http)
    {
      var renewed = current
      renewed.token = grant.accessToken
      renewed.refreshToken = grant.refreshToken ?? refresh
      save(renewed)
      if tab == .live { tab = .following }
    } else {
      ActivityLog.shared.add("Twitch no longer accepts the saved sign-in: signed out")
      signOut()
    }
  }

  func save(_ new: TwitchAuth.Session) {
    session = new
    TwitchAuth.shared.update(new)
    if let data = try? JSONEncoder().encode(new) { TVKeychain.set(data, for: "session") }
  }

  func signOut() {
    session = nil
    TwitchAuth.shared.update(nil)
    TVKeychain.set(nil, for: "session")
  }

  func watch(_ channel: Channel) {
    watching = channel
  }
}

/// The Twitch sign-in, kept in the Keychain.
enum TVKeychain {
  private static let service = "app.kestrel.tv"

  static func get(_ key: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  static func set(_ data: Data?, for key: String) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
    ]
    SecItemDelete(base as CFDictionary)
    guard let data else { return }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(add as CFDictionary, nil)
  }
}
