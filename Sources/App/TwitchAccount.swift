import Foundation
import Security
import SwiftUI
import WebKit

/// Small Keychain wrapper for secrets (Twitch token, proxy password).
enum SecretStore {
  private static let service = "Kestrel"

  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  /// Some sideloading setups sign apps without Keychain access; then the secret goes to a file
  /// the system keeps encrypted until the phone is first unlocked.
  private static func fallbackURL(_ account: String) -> URL {
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("secret-\(account)")
  }

  static func set(_ data: Data?, for account: String) {
    SecItemDelete(query(account) as CFDictionary)
    try? FileManager.default.removeItem(at: fallbackURL(account))
    guard let data else { return }
    var item = query(account)
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    if SecItemAdd(item as CFDictionary, nil) != errSecSuccess {
      try? data.write(to: fallbackURL(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
  }

  /// Everything Kestrel keeps in the Keychain (and the file fallbacks).
  static func removeAll() {
    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as [String: Any] as CFDictionary)
    for account in ["twitch", "proxy"] { try? FileManager.default.removeItem(at: fallbackURL(account)) }
  }

  static func get(_ account: String) -> Data? {
    var item = query(account)
    item[kSecReturnData as String] = true
    item[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    if SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data { return data }
    return try? Data(contentsOf: fallbackURL(account))
  }
}

@MainActor
final class TwitchAccount: ObservableObject {
  static let shared = TwitchAccount()

  @Published private(set) var session: TwitchAuth.Session?
  /// nil while unknown.
  @Published private(set) var hasTurbo: Bool?

  private init() {
    if let data = SecretStore.get("twitch"), let saved = try? JSONDecoder().decode(TwitchAuth.Session.self, from: data) {
      session = saved
      TwitchAuth.shared.update(saved)
      Task { await refreshTurbo() }
    }
  }

  func signIn(token rawToken: String, deviceID: String?) async throws {
    let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"'")).replacingOccurrences(of: "OAuth ", with: "")
    let (login, userID) = try await TwitchAuth.validate(token: token, http: URLSessionHTTPClient(timeout: 10))
    let session = TwitchAuth.Session(token: token, login: login, userID: userID, deviceID: deviceID)
    SecretStore.set(try? JSONEncoder().encode(session), for: "twitch")
    TwitchAuth.shared.update(session)
    self.session = session
    ActivityLog.shared.add("Signed in to Twitch as \(login)")
    await refreshTurbo()
  }

  func refreshTurbo() async {
    hasTurbo = await TwitchAPI.shared.currentUserHasTurbo()
  }

  func signOut() {
    SecretStore.set(nil, for: "twitch")
    TwitchAuth.shared.update(nil)
    session = nil
    hasTurbo = nil
    // Forget the website login too, so the next sign-in starts fresh.
    let store = WKWebsiteDataStore.default()
    store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
      store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.contains("twitch") }) {}
    }
    ActivityLog.shared.add("Signed out of Twitch")
  }
}

// MARK: - Sign-in screen

/// twitch.tv's own login page; once it sets the `auth-token` cookie, Kestrel takes it.
struct TwitchLoginView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var account = TwitchAccount.shared
  @State private var error: String? = nil
  @State private var working = false
  @State private var pasting = false
  @State private var pasted = ""

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let error {
          Text(error).font(.footnote).foregroundColor(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        if pasting {
          Form {
            Section {
              SecureField("auth-token", text: $pasted)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
              Button("Paste from clipboard") { pasted = UIPasteboard.general.string ?? "" }
            } footer: {
              Text("On a computer: sign in on twitch.tv, open the browser's developer tools, and copy the value of the auth-token cookie (Application → Cookies). It gives full access to your account, so only paste it here.")
            }
            Section {
              Button(working ? "Checking…" : "Sign in") { Task { await submit(pasted, deviceID: nil) } }
                .disabled(pasted.isEmpty || working)
            }
          }
        } else {
          TwitchLoginWebView { token, deviceID in
            Task { await submit(token, deviceID: deviceID) }
          }
          .overlay {
            if working {
              ProgressView("Signing in…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
          }
        }
      }
      .navigationTitle("Sign in to Twitch")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          Button(pasting ? "Use login page" : "Paste token") { pasting.toggle() }
        }
      }
    }
  }

  private func submit(_ token: String, deviceID: String?) async {
    guard !working else { return }
    working = true
    error = nil
    defer { working = false }
    do {
      try await account.signIn(token: token, deviceID: deviceID)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct TwitchLoginWebView: UIViewRepresentable {
  var found: (_ token: String, _ deviceID: String?) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(found: found) }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.customUserAgent = Browser.userAgent  // the full website, not "open the app"
    view.navigationDelegate = context.coordinator
    context.coordinator.webView = view
    view.load(URLRequest(url: URL(string: "https://www.twitch.tv/login")!))
    context.coordinator.startPolling()
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {}

  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.stopPolling()
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    let found: (String, String?) -> Void
    private var timer: Timer?
    private var reported = false

    init(found: @escaping (String, String?) -> Void) { self.found = found }

    func startPolling() {
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
    }

    func stopPolling() {
      timer?.invalidate()
      timer = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check() }

    private func check() {
      guard !reported, let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
      store.getAllCookies { [weak self] cookies in
        guard let self, !self.reported else { return }
        let twitch = cookies.filter { $0.domain.hasSuffix("twitch.tv") }
        guard let token = twitch.first(where: { $0.name == "auth-token" })?.value, !token.isEmpty else { return }
        self.reported = true
        self.stopPolling()
        let deviceID = twitch.first(where: { $0.name == "unique_id" })?.value
        DispatchQueue.main.async { self.found(token, deviceID) }
      }
    }
  }
}
