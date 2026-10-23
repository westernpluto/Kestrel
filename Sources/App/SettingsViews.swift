import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject private var account = TwitchAccount.shared
  @State private var imageCacheCleared = false
  @State private var showLogin = false
  @State private var confirmSignOut = false

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
      } header: {
        Text("Playback")
      } footer: {
        Text("Streams always start at the highest quality. Quality and video stats are in the player's gear menu.")
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
    }
    .navigationTitle("Settings")
    .sheet(isPresented: $showLogin) { TwitchLoginView() }
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
      if account.hasTurbo == true {
        Section {
          Label("You have Turbo, so Twitch doesn't send you ads. Kestrel skips the ad-free servers and plays straight from Twitch.", systemImage: "checkmark.seal.fill")
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
