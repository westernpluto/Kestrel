// Instant go-live alerts through ntfy.
//
// A sideloaded app gets no push notifications of its own, and once it's closed iOS only lets it
// check now and then (Background App Refresh: every 15 minutes at best, often much less). So the
// checking happens somewhere that never sleeps: a tiny script on Cloudflare Workers (free), which
// Kestrel puts in your own Cloudflare account with an API token you give it. Every minute it asks
// Twitch which of the channels you follow just went live, and sends each one to your ntfy topic;
// the ntfy app (on the App Store) gets it through Apple's push service within seconds, closed or
// not. Tapping it opens the stream in Kestrel (kestrel://live/<channel>).
//
// Nothing goes through Kestrel's makers: the script, its list of channel names and the topic live
// in your Cloudflare account; the notifications go through ntfy.sh (or your own ntfy server).

import Foundation
import SwiftUI
import UIKit

@MainActor
final class InstantAlerts: ObservableObject {
  static let shared = InstantAlerts()
  static let scriptName = "kestrel-live-alerts"
  static let namespaceTitle = "kestrel-live-alerts"

  /// Your ntfy topic: random, so nobody else stumbles on it (topics on ntfy.sh are public by name).
  @Published private(set) var topic: String
  @Published var server: String {
    didSet { defaults.set(server, forKey: "instantAlerts.server") }
  }
  /// The relay is set up in Cloudflare.
  @Published private(set) var active: Bool
  /// How many channels it watches.
  @Published private(set) var watching: Int
  @Published private(set) var lastSynced: Date?
  @Published private(set) var busy = false
  @Published private(set) var problem: String?

  private let defaults = UserDefaults.standard
  private var accountID: String? {
    get { defaults.string(forKey: "instantAlerts.account") }
    set { defaults.set(newValue, forKey: "instantAlerts.account") }
  }
  private var namespaceID: String? {
    get { defaults.string(forKey: "instantAlerts.namespace") }
    set { defaults.set(newValue, forKey: "instantAlerts.namespace") }
  }
  /// The channel list last written (so it's only written when it changes).
  private var syncedChannels: [String] {
    get { defaults.stringArray(forKey: "instantAlerts.channels") ?? [] }
    set { defaults.set(newValue, forKey: "instantAlerts.channels") }
  }

  private init() {
    if let saved = defaults.string(forKey: "instantAlerts.topic"), !saved.isEmpty {
      topic = saved
    } else {
      let made = "kestrel-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
      defaults.set(made, forKey: "instantAlerts.topic")
      topic = made
    }
    server = defaults.string(forKey: "instantAlerts.server") ?? "https://ntfy.sh"
    active = defaults.bool(forKey: "instantAlerts.active")
    watching = (defaults.stringArray(forKey: "instantAlerts.channels") ?? []).count
    lastSynced = defaults.object(forKey: "instantAlerts.synced") as? Date
  }

  private var token: String? {
    SecretStore.get("cloudflare").flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
  }

  var serverURL: URL? {
    var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.contains("://") { text = "https://" + text }
    while text.hasSuffix("/") { text.removeLast() }
    return URL(string: text)
  }

  /// Opens the topic in the ntfy app to subscribe (or the topic's web page if it isn't installed).
  var subscribeURL: URL? {
    guard let serverURL, let host = serverURL.host else { return nil }
    return URL(string: "ntfy://\(host)/\(topic)")
  }

  // MARK: Setting up

  /// Puts the relay in the Cloudflare account the token belongs to (or updates it), and hands it
  /// the channels to watch.
  func setUp(token newToken: String, channels: [String]) async {
    let token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return }
    busy = true
    problem = nil
    defer { busy = false }
    do {
      let cloudflare = Cloudflare(token: token)
      let account = try await cloudflare.accountID()
      let namespace = try await cloudflare.namespace(account: account, title: Self.namespaceTitle)
      try await cloudflare.uploadWorker(account: account, name: Self.scriptName, script: Self.workerScript, namespace: namespace)
      try await cloudflare.setSchedule(account: account, name: Self.scriptName, cron: "* * * * *")
      SecretStore.set(Data(token.utf8), for: "cloudflare")
      accountID = account
      namespaceID = namespace
      try await writeConfig(channels, cloudflare: cloudflare, account: account, namespace: namespace, fresh: true)
      active = true
      defaults.set(true, forKey: "instantAlerts.active")
      ActivityLog.shared.add("Instant alerts: relay set up in Cloudflare, watching \(channels.count) channels")
    } catch {
      problem = error.localizedDescription
      ActivityLog.shared.add("Instant alerts: setup failed (\(error.localizedDescription))")
    }
  }

  /// The follows list changed: the relay watches the new one.
  func followsChanged(_ channels: [String]) async {
    guard active, !busy else { return }
    let list = Array(Set(channels)).sorted()
    guard list != syncedChannels, let token, let accountID, let namespaceID else { return }
    do {
      try await writeConfig(list, cloudflare: Cloudflare(token: token), account: accountID, namespace: namespaceID, fresh: false)
    } catch {
      ActivityLog.shared.add("Instant alerts: couldn't update the relay's channel list (\(error.localizedDescription))")
    }
  }

  /// Writes the topic, server and channels for the relay. `fresh`: only streams that start from
  /// now on are announced (not everyone who's already live).
  private func writeConfig(_ channels: [String], cloudflare: Cloudflare, account: String, namespace: String, fresh: Bool) async throws {
    let list = Array(Set(channels.map { $0.lowercased() })).sorted()
    var config: [String: Any] = ["topic": topic, "server": serverURL?.absoluteString ?? "https://ntfy.sh", "channels": list]
    let since = fresh ? Date() : (defaults.object(forKey: "instantAlerts.since") as? Date ?? Date())
    if fresh { defaults.set(since, forKey: "instantAlerts.since") }
    config["since"] = Int(since.timeIntervalSince1970 * 1000)
    let data = try JSONSerialization.data(withJSONObject: config)
    try await cloudflare.putValue(account: account, namespace: namespace, key: "config", value: data)
    syncedChannels = list
    watching = list.count
    lastSynced = Date()
    defaults.set(lastSynced, forKey: "instantAlerts.synced")
  }

  /// The server or topic changed: tell the relay.
  func resync(channels: [String]) async {
    guard active, let token, let accountID, let namespaceID else { return }
    busy = true
    defer { busy = false }
    do {
      try await writeConfig(channels, cloudflare: Cloudflare(token: token), account: accountID, namespace: namespaceID, fresh: false)
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }

  /// Takes the relay out of Cloudflare and forgets the token.
  func turnOff() async {
    busy = true
    defer { busy = false }
    if let token, let accountID {
      let cloudflare = Cloudflare(token: token)
      try? await cloudflare.deleteWorker(account: accountID, name: Self.scriptName)
      if let namespaceID { try? await cloudflare.deleteNamespace(account: accountID, namespace: namespaceID) }
    }
    SecretStore.set(nil, for: "cloudflare")
    accountID = nil
    namespaceID = nil
    syncedChannels = []
    watching = 0
    active = false
    defaults.set(false, forKey: "instantAlerts.active")
    problem = nil
    ActivityLog.shared.add("Instant alerts: relay removed from Cloudflare")
  }

  /// A notification to the topic straight from here, to check the ntfy app gets it.
  func sendTest() async -> Bool {
    guard let serverURL else { return false }
    let link = "kestrel://following"
    let body: [String: Any] = [
      "topic": topic, "title": "Kestrel test", "message": "Instant alerts reach this iPhone. Tap to open Kestrel.",
      "click": link, "tags": ["white_check_mark"],
    ]
    var request = URLRequest(url: serverURL, timeoutInterval: 12)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
    return (response as? HTTPURLResponse)?.statusCode == 200
  }

  /// "My topic" with a new random name (e.g. if someone else found it).
  func newTopic(channels: [String]) async {
    let made = "kestrel-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    defaults.set(made, forKey: "instantAlerts.topic")
    topic = made
    await resync(channels: channels)
  }

  // MARK: The relay

  /// Runs every minute in Cloudflare (see the top of this file). Notifies each followed stream
  /// once, from the moment the relay was set up; remembers what it sent for two days.
  static let workerScript = #"""
    const GQL = "https://gql.twitch.tv/gql";
    const CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko";
    const QUERY = "query($logins:[String!]){users(logins:$logins){id login displayName profileImageURL(width:150) stream{id createdAt title viewersCount game{displayName}}}}";

    export default {
      async scheduled(event, env, ctx) {
        ctx.waitUntil(check(env));
      },
      async fetch(request, env) {
        const config = await env.KESTREL.get("config", "json");
        const body = { ok: true, channels: config && config.channels ? config.channels.length : 0 };
        return new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });
      },
    };

    async function check(env) {
      const config = await env.KESTREL.get("config", "json");
      if (!config || !config.topic || !Array.isArray(config.channels) || config.channels.length === 0) return;
      const server = String(config.server || "https://ntfy.sh").replace(/\/+$/, "");
      const now = Date.now();
      for (let i = 0; i < config.channels.length; i += 100) {
        const logins = config.channels.slice(i, i + 100);
        let users = [];
        try {
          const response = await fetch(GQL, {
            method: "POST",
            headers: { "Client-Id": CLIENT_ID, "Content-Type": "text/plain;charset=UTF-8" },
            body: JSON.stringify({ query: QUERY, variables: { logins } }),
          });
          if (!response.ok) continue;
          const json = await response.json();
          users = (json && json.data && json.data.users) || [];
        } catch (error) {
          continue;
        }
        for (const user of users) {
          const stream = user && user.stream;
          if (!stream || !stream.id) continue;
          const started = Date.parse(stream.createdAt);
          // Only streams that started lately, and not before the relay was set up.
          if (!(now - started < 30 * 60 * 1000)) continue;
          if (config.since && started < config.since - 60 * 1000) continue;
          const key = "sent:" + stream.id;
          if (await env.KESTREL.get(key)) continue;
          await env.KESTREL.put(key, "1", { expirationTtl: 2 * 86400 });
          await publish(server, config.topic, user, stream);
        }
      }
    }

    async function publish(server, topic, user, stream) {
      const name = user.displayName || user.login;
      const link = "kestrel://live/" + encodeURIComponent(user.login) + "?id=" + encodeURIComponent(user.id) +
        "&name=" + encodeURIComponent(name);
      const lines = [stream.title, stream.game && stream.game.displayName].filter(Boolean);
      const message = {
        topic,
        title: name + " is live",
        message: lines.length ? lines.join("\n") : "Started streaming",
        click: link,
        tags: ["red_circle"],
        priority: 4,
        actions: [{ action: "view", label: "Watch in Kestrel", url: link, clear: true }],
      };
      if (user.profileImageURL) message.icon = user.profileImageURL;
      try {
        await fetch(server, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(message) });
      } catch (error) {}
    }
    """#
}

// MARK: - Cloudflare's API (just what the relay needs)

struct Cloudflare {
  let token: String

  struct Failure: LocalizedError {
    var errorDescription: String?
  }

  private func call(
    _ method: String, _ path: String, body: Data? = nil, contentType: String? = "application/json"
  ) async throws -> JSONValue {
    guard let url = URL(string: "https://api.cloudflare.com/client/v4" + path) else { throw Failure(errorDescription: "Bad address") }
    var request = URLRequest(url: url, timeoutInterval: 25)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    let json = JSONValue(try? JSONSerialization.jsonObject(with: data))
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if json["success"].bool == true, (200..<300).contains(status) { return json["result"] }
    let messages = json["errors"].array.compactMap { error -> String? in
      guard let message = error["message"].string else { return nil }
      return error["code"].int.map { "\(message) (\($0))" } ?? message
    }
    if status == 401 || status == 403 || messages.contains(where: { $0.localizedCaseInsensitiveContains("authentication") }) {
      throw Failure(
        errorDescription: "Cloudflare didn't accept the token. Make one from the “Edit Cloudflare Workers” template. "
          + messages.joined(separator: "; "))
    }
    throw Failure(errorDescription: messages.isEmpty ? "Cloudflare answered HTTP \(status)" : messages.joined(separator: "; "))
  }

  private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

  /// The account the token works with (the first, if several).
  func accountID() async throws -> String {
    let accounts = try await call("GET", "/accounts?per_page=50", contentType: nil)
    guard let id = accounts.array.first?["id"].string else {
      throw Failure(errorDescription: "The token doesn't give access to any Cloudflare account.")
    }
    return id
  }

  /// The relay's storage (made the first time).
  func namespace(account: String, title: String) async throws -> String {
    let list = try await call("GET", "/accounts/\(account)/storage/kv/namespaces?per_page=100", contentType: nil)
    if let existing = list.array.first(where: { $0["title"].string == title })?["id"].string { return existing }
    let made = try await call("POST", "/accounts/\(account)/storage/kv/namespaces", body: try json(["title": title]))
    guard let id = made["id"].string else { throw Failure(errorDescription: "Cloudflare didn't make the storage.") }
    return id
  }

  func uploadWorker(account: String, name: String, script: String, namespace: String) async throws {
    let boundary = "kestrel-\(UUID().uuidString)"
    let metadata: [String: Any] = [
      "main_module": "worker.js", "compatibility_date": "2024-09-23",
      "bindings": [["type": "kv_namespace", "name": "KESTREL", "namespace_id": namespace]],
    ]
    var body = Data()
    func part(_ header: String, _ content: Data) {
      body.append(Data("--\(boundary)\r\n\(header)\r\n\r\n".utf8))
      body.append(content)
      body.append(Data("\r\n".utf8))
    }
    part("Content-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json", try json(metadata))
    part(
      "Content-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\nContent-Type: application/javascript+module",
      Data(script.utf8))
    body.append(Data("--\(boundary)--\r\n".utf8))
    _ = try await call(
      "PUT", "/accounts/\(account)/workers/scripts/\(name)", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
  }

  func setSchedule(account: String, name: String, cron: String) async throws {
    _ = try await call("PUT", "/accounts/\(account)/workers/scripts/\(name)/schedules", body: try json([["cron": cron]]))
  }

  func putValue(account: String, namespace: String, key: String, value: Data) async throws {
    _ = try await call(
      "PUT", "/accounts/\(account)/storage/kv/namespaces/\(namespace)/values/\(key)", body: value, contentType: "text/plain")
  }

  func deleteWorker(account: String, name: String) async throws {
    _ = try await call("DELETE", "/accounts/\(account)/workers/scripts/\(name)", contentType: nil)
  }

  func deleteNamespace(account: String, namespace: String) async throws {
    _ = try await call("DELETE", "/accounts/\(account)/storage/kv/namespaces/\(namespace)", contentType: nil)
  }
}

// MARK: - Links into Kestrel

/// kestrel://live/<channel>?id=…&name=… opens a stream (the relay's notifications);
/// kestrel://recordings, kestrel://following open those pages.
enum DeepLink {
  @MainActor
  static func open(_ url: URL) {
    guard url.scheme?.lowercased() == "kestrel" else { return }
    let app = AppModel.shared
    let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
    switch parts.first?.lowercased() {
    case "live", "watch":
      guard parts.count > 1 else { return }
      let login = parts[1].lowercased()
      if let id = value("id") {
        app.playing = .live(Channel(id: id, login: login, displayName: value("name") ?? login, profileImageURL: nil))
      } else {
        Task {
          // The channel's details first (chat needs its id).
          let found = try? await TwitchAPI.shared.users(logins: [login])
          if let channel = found?.first?.0 { app.playing = .live(channel) }
        }
      }
    case "recordings":
      app.playerMinimized = app.playing != nil
      app.tab = .following
      app.push(.recordings)
    case "following":
      app.tab = .following
    default:
      break
    }
  }
}

// MARK: - Settings

struct InstantAlertsView: View {
  @ObservedObject private var alerts = InstantAlerts.shared
  @ObservedObject private var following = FollowingStore.shared
  @State private var token = ""
  @State private var testResult: String?
  @State private var confirmOff = false

  private var channels: [String] {
    (following.live.map(\.channel.login) + following.offline.map(\.channel.login)).map { $0.lowercased() }
  }

  var body: some View {
    Form {
      Section {
        Label {
          Text("Go-live alerts within about a minute, even with Kestrel closed: a small relay in your own free Cloudflare account checks Twitch every minute and sends the alert through ntfy, which delivers it instantly. Tap one to open the stream in Kestrel.")
        } icon: {
          Image(systemName: "bolt.badge.clock.fill").foregroundColor(.accentTeal)
        }
        .font(.footnote)
      }

      Section {
        Link(destination: URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!) {
          Label("Get the ntfy app", systemImage: "arrow.down.app")
        }
        LabeledContent("Your topic") {
          Text(alerts.topic).font(.footnote.monospaced()).textSelection(.enabled)
        }
        Button {
          if let url = alerts.subscribeURL, UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
          } else {
            UIPasteboard.general.string = alerts.topic
            testResult = "Topic copied: in ntfy, tap + and paste it."
          }
        } label: {
          Label("Subscribe in ntfy", systemImage: "bell.badge")
        }
        Button {
          UIPasteboard.general.string = alerts.topic
          testResult = "Topic copied."
        } label: {
          Label("Copy topic", systemImage: "doc.on.doc")
        }
        Button {
          Task {
            let sent = await alerts.sendTest()
            testResult = sent ? "Sent: it should be on your iPhone now." : "Couldn't reach \(alerts.server)."
          }
        } label: {
          Label("Send a test alert", systemImage: "paperplane")
        }
        if let testResult {
          Text(testResult).font(.footnote).foregroundColor(.secondary)
        }
      } header: {
        Text("1 · ntfy")
      } footer: {
        Text("Install ntfy and subscribe to this topic (keep the server as ntfy.sh). Topics are public by name, so this one's random; anyone who knew it could only send you alerts.")
      }

      Section {
        if alerts.active {
          LabeledContent("Watching", value: "\(alerts.watching) channels")
          if let synced = alerts.lastSynced {
            LabeledContent("List updated", value: Format.relative(synced))
          }
          Button("Update the relay now") {
            Task { await alerts.resync(channels: channels) }
          }
          Button("Turn off and remove the relay", role: .destructive) { confirmOff = true }
        } else {
          SecureField("Cloudflare API token", text: $token)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button {
            Task {
              await following.refreshIfStale()
              await alerts.setUp(token: token, channels: channels)
              if alerts.active { token = "" }
            }
          } label: {
            HStack {
              Text("Set up the relay")
              if alerts.busy {
                Spacer()
                ProgressView()
              }
            }
          }
          .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || alerts.busy)
          Link(destination: URL(string: "https://dash.cloudflare.com/profile/api-tokens")!) {
            Label("Make a token (free account)", systemImage: "key")
          }
        }
        if let problem = alerts.problem {
          Text(problem).font(.footnote).foregroundColor(.orange)
        }
      } header: {
        Text("2 · Relay")
      } footer: {
        Text(
          alerts.active
            ? "It runs every minute in your Cloudflare account and follows your follows list (and hearted channels) as Kestrel sees it change. With it on, you may want Kestrel's own go-live alerts off, or you'll get both."
            : "In Cloudflare: My Profile → API Tokens → Create Token → “Edit Cloudflare Workers” template → Continue → Create, then paste the token here. Kestrel puts a small script (kestrel-live-alerts) in your account and keeps the token on this iPhone only. Cloudflare's free plan covers it."
        )
      }

      Section {
        TextField("Server", text: $alerts.server)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .onSubmit { Task { await alerts.resync(channels: channels) } }
        Button("New random topic") {
          Task { await alerts.newTopic(channels: channels) }
        }
      } header: {
        Text("Advanced")
      } footer: {
        Text("Your own ntfy server works too; for it to reach iPhones instantly, it needs upstream-base-url set to https://ntfy.sh.")
      }
      Section { MiniPlayerSpacer() }
    }
    .environment(\.defaultMinListRowHeight, 1)
    .navigationTitle("Instant alerts")
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("Remove the relay from Cloudflare?", isPresented: $confirmOff, titleVisibility: .visible) {
      Button("Remove", role: .destructive) { Task { await alerts.turnOff() } }
    } message: {
      Text("Instant alerts stop. Kestrel's own go-live alerts carry on as before.")
    }
  }
}
