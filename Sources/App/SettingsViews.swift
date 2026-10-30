import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject private var account = TwitchAccount.shared
  @ObservedObject private var notifier = LiveNotifier.shared
  @ObservedObject private var instantAlerts = InstantAlerts.shared
  @State private var imageCacheCleared = false
  @State private var showLogin = false
  @State private var confirmSignOut = false
  @State private var confirmReset = false
  @State private var resetting = false

  var body: some View {
    Form {
      Section {
        if let session = account.session {
          HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 34)).foregroundColor(.accentTeal)
            VStack(alignment: .leading, spacing: 2) {
              Text(session.login).font(.body.weight(.semibold))
              Text(turboText).font(.footnote).foregroundColor(.secondary)
            }
          }
          Button("Sign out", role: .destructive) { confirmSignOut = true }
        } else {
          Button {
            showLogin = true
          } label: {
            Label("Sign in with Twitch", systemImage: "person.crop.circle.badge.plus")
          }
        }
      } header: {
        Text("Twitch account")
      } footer: {
        if account.session == nil {
          Text("Sign in to chat as yourself and see who you follow. Your login stays on this iPhone and only goes to Twitch.")
        }
      }

      Section {
        if PlayerEngine.isLowLatencyBuilt {
          Toggle("Low latency", isOn: $settings.lowLatency)
        }
        NavigationLink {
          AdBlockingView()
        } label: {
          LabeledContent("Ad blocking", value: settings.adBlocking.shortTitle)
        }
        Toggle("Background audio", isOn: $settings.backgroundAudio)
        NavigationLink {
          RecordingsView()
        } label: {
          Label("Recordings", systemImage: "record.circle")
        }
      } header: {
        Text("Playback")
      } footer: {
        Text(
          "Low latency keeps streams as close to live as your connection allows: when one falls behind, it plays slightly faster for a few seconds to catch up. Streams start at the highest quality; pick Auto in the player's gear menu and they start on Auto from then on, which settles on a quality your connection keeps up with instead of bouncing between them. Video stats are in the gear menu too."
        )
      }

      Section {
        Toggle("Go-live alerts", isOn: Binding(get: { notifier.enabled }, set: { on in Task { await notifier.setEnabled(on) } }))
        if notifier.permission == .denied {
          Button("Allow notifications in iOS Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          }
        }
        NavigationLink {
          InstantAlertsView()
        } label: {
          LabeledContent("Instant alerts (ntfy)", value: instantAlerts.active ? "On" : "Off")
        }
      } header: {
        Text("Notifications")
      } footer: {
        Text(
          "Go-live alerts: a notification when a channel you follow goes live (your Twitch follows and the channels you heart); tap it to watch. Kestrel checks every minute while it's open or playing; once it's closed, iOS decides when it may check (often every 15–30 minutes), so alerts can come late. Instant alerts arrive within about a minute, closed or not, through the ntfy app."
        )
      }

      Section("Chat") {
        Stepper(value: $settings.chatFontSize, in: 12...22, step: 1) {
          LabeledContent("Text size", value: "\(Int(settings.chatFontSize)) pt")
        }
      }

      Section {
        NavigationLink("Activity log") { ActivityLogView() }
        Button(imageCacheCleared ? "Image cache cleared" : "Clear image cache") {
          ImagePipeline.shared.clear()
          imageCacheCleared = true
        }
        .disabled(imageCacheCleared)
      } footer: {
        Text("Kestrel \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
      }

      Section {
        Button(role: .destructive) {
          confirmReset = true
        } label: {
          if resetting {
            HStack { ProgressView(); Text("Erasing…") }
          } else {
            Text("Reset Kestrel")
          }
        }
        .disabled(resetting)
      } footer: {
        Text("Erases everything Kestrel has stored on this iPhone: your Twitch login, follows added in Kestrel, watch progress, search history, settings and caches. Kestrel closes when it's done; open it again to start fresh.")
      }
      Section { MiniPlayerSpacer() }
    }
    .environment(\.defaultMinListRowHeight, 1)
    .navigationTitle("Settings")
    .sheet(isPresented: $showLogin) { TwitchLoginView() }
    .confirmationDialog("Erase everything and start fresh?", isPresented: $confirmReset, titleVisibility: .visible) {
      Button("Erase and close Kestrel", role: .destructive) {
        resetting = true
        Task {
          await AppReset.eraseEverything()
          // Everything in memory goes too: Kestrel closes, and opens fresh next time.
          try? await Task.sleep(nanoseconds: 300_000_000)
          exit(0)
        }
      }
    } message: {
      Text("Your Twitch login, follows added in Kestrel, watch progress, search history and settings are deleted. Your Twitch account itself isn't changed.")
    }
    .confirmationDialog("Sign out of Twitch?", isPresented: $confirmSignOut, titleVisibility: .visible) {
      Button("Sign out", role: .destructive) { account.signOut() }
    }
  }

  private var turboText: String {
    switch account.hasTurbo {
    case true?: return "Turbo: Twitch sends you no ads"
    case false?: return "Signed in"
    case nil: return "Checking…"
    }
  }
}

struct AdBlockingView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject private var account = TwitchAccount.shared

  var body: some View {
    Form {
      if account.session != nil {
        Section {
          Label(
            account.hasTurbo == true
              ? "You have Turbo, so Twitch shows you no ads anywhere: Kestrel plays straight from Twitch."
              : "On channels you're subscribed to, Twitch shows you no ads, so Kestrel plays those straight from Twitch (every quality, Twitch's own low latency). The setting below is for everything else.",
            systemImage: "checkmark.seal.fill"
          )
          .font(.footnote)
        }
      }

      Section {
        choice(.automatic, title: "Automatic", detail: "The ad-free server that answers first (recommended)")
        choice(.customProxy, title: "My own proxy", detail: "An HTTP proxy in a country without Twitch ads")
        choice(.basic, title: "Basic", detail: "No server: skip ad breaks Kestrel can see, hide the rest")
      } footer: {
        Text("Ad-free servers ask Twitch for the stream from a country where Twitch doesn't run ads (the TTV LOL PRO v1 servers). Only the playlist request goes through them; the video comes straight from Twitch at full quality. Applies to the next stream you open.")
      }

      Section {
        Toggle("Twitch servers near me", isOn: $settings.nearbyServers)
      } footer: {
        Text("Twitch serves an ad-free server's stream from its own servers near that server (usually in Europe), which adds delay and can limit quality far from there. With this on, Kestrel moves the stream to Twitch's servers near you when they accept it. Video stats show which are in use.")
      }

      Section {
        ForEach(AdFreeProxy.all, id: \.host) { server in
          Button {
            settings.adBlocking = .server(server.host)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(server.host).foregroundColor(.primary)
                Text(serverDetail(server)).font(.caption).foregroundColor(.secondary)
              }
              Spacer()
              if settings.adBlocking == .server(server.host) {
                Image(systemName: "checkmark").foregroundColor(.accentTeal)
              }
            }
          }
        }
      } header: {
        Text("Or pick a server")
      } footer: {
        Text("If the chosen server is down, Kestrel tries the others.")
      }

      if settings.adBlocking == .customProxy {
        Section {
          TextField("Host", text: $settings.proxyHost)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
          TextField("Port", text: $settings.proxyPort).keyboardType(.numberPad)
          TextField("Username (optional)", text: $settings.proxyUsername)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          SecureField("Password (optional)", text: $settings.proxyPassword)
        } header: {
          Text("Your proxy")
        } footer: {
          Text("Twitch's playback requests go through it; video still comes straight from Twitch.")
        }
      }
    }
    .navigationTitle("Ad blocking")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func serverDetail(_ server: AdFreeProxy) -> String {
    var parts = ["Twitch sees: \(server.country)"]
    if server.host == AdFreeProxy.lastWorkingHost { parts.append("last used") }
    return parts.joined(separator: " · ")
  }

  private func choice(_ value: AdBlocking, title: String, detail: String) -> some View {
    Button {
      settings.adBlocking = value
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).foregroundColor(.primary)
          Text(detail).font(.caption).foregroundColor(.secondary)
        }
        Spacer()
        if settings.adBlocking == value {
          Image(systemName: "checkmark").foregroundColor(.accentTeal)
        }
      }
    }
  }
}

final class ActivityLogModel: ObservableObject {
  @Published var entries: [ActivityLog.Entry] = ActivityLog.shared.all.reversed()

  init() {
    ActivityLog.shared.onChange = { [weak self] in
      guard let model = self else { return }
      DispatchQueue.main.async { model.entries = ActivityLog.shared.all.reversed() }
    }
  }

  deinit { ActivityLog.shared.onChange = nil }
}

struct ActivityLogView: View {
  @StateObject private var model = ActivityLogModel()
  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  var body: some View {
    List {
      if model.entries.isEmpty {
        Text("Nothing yet. Open a stream: ad breaks and how they were handled show up here.")
          .foregroundColor(.secondary)
      }
      ForEach(model.entries) { entry in
        VStack(alignment: .leading, spacing: 2) {
          Text(Self.formatter.string(from: entry.date)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
          Text(entry.message).font(.footnote)
        }
      }
    }
    .navigationTitle("Activity log")
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button {
          UIPasteboard.general.string = model.entries.reversed()
            .map { "\(Self.formatter.string(from: $0.date))  \($0.message)" }.joined(separator: "\n")
        } label: {
          Image(systemName: "doc.on.doc")
        }
        Button("Clear") { ActivityLog.shared.clear() }
      }
    }
  }
}
