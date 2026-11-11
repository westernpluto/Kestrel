// Kestrel for Apple Watch: live Twitch streams (picture and sound) and their chat, on the wrist.
//
// It shares the iPhone app's core (the ad-free stream sessions, the Twitch API, chat parsing) and
// works on its own: it signs in with its own code at twitch.tv/activate, and plays over the
// watch's own connection (Wi-Fi or cellular, or the iPhone's when it's near). It ships inside the
// iPhone app and installs from the Watch app, but doesn't need the iPhone app running.
//
// watchOS has no picture layer to hand frames to and doesn't play live HLS video, so the player
// here (WatchPlayer) downloads each two-second segment, rewrites it as a small MP4 file
// (MP4Writer) and plays the files back to back.

import AVFoundation
import Security
import SwiftUI

@main
struct KestrelWatchApp: App {
  @StateObject private var store = WatchStore.shared

  var body: some Scene {
    WindowGroup {
      NavigationStack {
        HomeView()
      }
      .environmentObject(store)
      .task { await store.launch() }
    }
  }
}

/// What the watch app keeps: the sign-in, and the lists on the home screen.
@MainActor
final class WatchStore: ObservableObject {
  static let shared = WatchStore()

  @Published private(set) var session: TwitchAuth.Session?
  @Published private(set) var following: [LiveStream] = []
  @Published private(set) var popular: [LiveStream] = []
  @Published private(set) var loading = false
  @Published private(set) var message: String?
  /// The tallest picture to play (pixels): small screens, and the watch's connection.
  @Published var maxHeight: Int { didSet { UserDefaults.standard.set(maxHeight, forKey: "watch.maxHeight") } }
  @Published var chatShown: Bool { didSet { UserDefaults.standard.set(chatShown, forKey: "watch.chatShown") } }
  /// Play the quality set, as it is (off: Auto, stepped down when the connection can't carry it).
  @Published var fixedQuality: Bool { didSet { UserDefaults.standard.set(fixedQuality, forKey: "watch.fixedQuality") } }

  static let heights = [160, 360, 480, 720]

  private init() {
    UserDefaults.standard.register(defaults: ["watch.maxHeight": 360, "watch.chatShown": true])
    maxHeight = UserDefaults.standard.integer(forKey: "watch.maxHeight")
    chatShown = UserDefaults.standard.bool(forKey: "watch.chatShown")
    fixedQuality = UserDefaults.standard.bool(forKey: "watch.fixedQuality")
    if let data = WatchKeychain.get("session"), let saved = try? JSONDecoder().decode(TwitchAuth.Session.self, from: data) {
      session = saved
      TwitchAuth.shared.update(saved)
    }
  }

  /// At launch: the saved sign-in still good (refreshed if its token ran out), then the lists.
  func launch() async {
    if let current = session {
      let http = URLSessionHTTPClient(timeout: 10)
      let clientID = current.clientID ?? TwitchAPI.webClientID
      if (try? await TwitchAuth.validate(token: current.token, http: http, clientID: clientID)) == nil {
        if let refresh = current.refreshToken,
          let grant = try? await TwitchDeviceLogin.refresh(refresh, clientID: current.clientID ?? TwitchDeviceLogin.clientID, http: http)
        {
          var renewed = current
          renewed.token = grant.accessToken
          renewed.refreshToken = grant.refreshToken ?? refresh
          save(renewed)
        } else {
          signOut()
        }
      }
    }
    await refresh()
  }

  func refresh() async {
    guard !loading else { return }
    loading = true
    defer { loading = false }
    message = nil
    async let top = try? TwitchAPI.shared.topStreams(first: 20)
    if session != nil {
      do {
        let followed = try await TwitchAPI.shared.followedChannels()
        following = followed.compactMap(\.stream).sorted { $0.viewers > $1.viewers }
      } catch {
        message = error.localizedDescription
      }
    } else {
      following = []
    }
    if let page = await top { popular = page.items }
    if popular.isEmpty, following.isEmpty, message == nil { message = "Couldn't reach Twitch." }
  }

  func save(_ new: TwitchAuth.Session) {
    session = new
    TwitchAuth.shared.update(new)
    if let data = try? JSONEncoder().encode(new) { WatchKeychain.set(data, for: "session") }
  }

  func signOut() {
    session = nil
    following = []
    TwitchAuth.shared.update(nil)
    WatchKeychain.set(nil, for: "session")
  }
}

/// The sign-in, kept in the watch's Keychain.
enum WatchKeychain {
  private static let service = "app.kestrel.watch"

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
