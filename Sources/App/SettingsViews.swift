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
        NavigationLink {
          PlaybackSettingsView()
        } label: {
          SettingsRow(title: "Playback", systemImage: "play.fill", color: .accentTeal,
            value: settings.kestrelPlayer ? "Kestrel" : "Apple")
        }
        NavigationLink {
          AdBlockingView()
        } label: {
          SettingsRow(title: "Ad blocking", systemImage: "hand.raised.fill", color: .red, value: settings.adBlocking.shortTitle)
        }
        NavigationLink {
          PictureInPictureSettingsView()
        } label: {
          SettingsRow(title: "Picture in Picture", systemImage: "pip.fill", color: .blue,
            value: settings.pipControls ? "With controls" : "Seamless")
        }
        NavigationLink {
          RaidSettingsView()
        } label: {
          SettingsRow(title: "Raids", systemImage: "person.3.fill", color: .purple, value: settings.raidMode.shortTitle)
        }
        NavigationLink {
          ChatSettingsView()
        } label: {
          SettingsRow(title: "Chat", systemImage: "bubble.left.and.bubble.right.fill", color: .green,
            value: "\(Int(settings.chatFontSize)) pt")
        }
      }

      Section {
        NavigationLink {
          NotificationSettingsView()
        } label: {
          SettingsRow(title: "Notifications", systemImage: "bell.badge.fill", color: .orange,
            value: notifier.enabled || instantAlerts.active ? "On" : "Off")
        }
        NavigationLink {
          RecordingsView()
        } label: {
          SettingsRow(title: "Recordings", systemImage: "record.circle", color: .pink)
        }
      }

      Section {
        NavigationLink {
          ActivityLogView()
        } label: {
          SettingsRow(title: "Activity log", systemImage: "list.bullet.rectangle", color: .gray)
        }
        Button {
          ImagePipeline.shared.clear()
          imageCacheCleared = true
        } label: {
          SettingsRow(title: imageCacheCleared ? "Image cache cleared" : "Clear image cache", systemImage: "photo.stack", color: .gray)
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

/// A row in Settings like the system's own: a coloured symbol, the title, and what it's set to.
struct SettingsRow: View {
  let title: String
  let systemImage: String
  let color: Color
  var value: String? = nil

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(.white)
        .frame(width: 29, height: 29)
        .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      Text(title).foregroundColor(.primary)
      Spacer(minLength: 8)
      if let value { Text(value).foregroundColor(.secondary).lineLimit(1) }
    }
  }
}

struct PlaybackSettingsView: View {
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    Form {
      Section {
        Picker("Player", selection: $settings.kestrelPlayer) {
          Text("Kestrel").tag(true)
          Text("Apple").tag(false)
        }
      } footer: {
        Text("Kestrel's own player downloads each piece of the stream while it's still being made and shows it as it arrives, aiming at about a second behind live. Apple's player is further behind (several seconds) but is there if a stream misbehaves. Applies from the next stream you open, multi-view included. Its audio compressor (the waveform button on the video) evens out the volume, as FrankerFaceZ's does.")
      }
      Section {
        Toggle("Background audio", isOn: $settings.backgroundAudio)
      } footer: {
        Text("Keeps the sound playing when you leave Kestrel or lock the phone.")
      }
      Section {
        Toggle("Video stats", isOn: $settings.showVideoStats)
      } footer: {
        Text("Quality, latency, buffer and more over the video (also in the player's gear menu). Streams start at the highest quality; pick Auto in the gear menu and they start on Auto from then on.")
      }
      Section { MiniPlayerSpacer() }
    }
    .environment(\.defaultMinListRowHeight, 1)
    .navigationTitle("Playback")
  }
}

struct PictureInPictureSettingsView: View {
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    Form {
      Section {
        Toggle("Playback controls", isOn: $settings.pipControls)
      } footer: {
        Text("On: the regular window with play and pause; the picture can show black for a moment when you come back to the app. Off: no buttons in the window, but the stream comes back without the black (pause from the lock screen, Control Center or headphones). For both players. Applies from the next stream you open.")
      }
      if settings.kestrelPlayer {
        Section {
          Toggle("Multi-view: all streams together", isOn: $settings.multiviewPiPAll)
        } footer: {
          Text(
            "Multi-view's Picture in Picture shows every stream at once, laid out as on screen (experimental). Off, or with Playback controls off, it shows the picked stream. The window has play and pause."
          )
        }
      }
      Section { MiniPlayerSpacer() }
    }
    .environment(\.defaultMinListRowHeight, 1)
    .navigationTitle("Picture in Picture")
  }
}

struct RaidSettingsView: View {
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    Form {
      Section {
        Picker("When a channel raids", selection: $settings.raidMode) {
          ForEach(RaidMode.allCases) { mode in Text(mode.title).tag(mode) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } header: {
        Text("When the channel you're watching raids another")
      } footer: {
        Text("Follow automatically counts down like Twitch, then takes you to the raided channel (tap Stay to remain). Ask me shows the raided channel with a Watch button. Off ignores raids.")
      }
      Section { MiniPlayerSpacer() }
    }
    .environment(\.defaultMinListRowHeight, 1)
    .navigationTitle("Raids")
  }
}

struct ChatSettingsView: View {
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    Form {
      Section {
        Stepper(value: $settings.chatFontSize, in: 12...22, step: 1) {
          LabeledContent("Text size", value: "\(Int(settings.chatFontSize)) pt")
        }
      }
      Section { MiniPlayerSpacer() }
    }
    .environment(\.defaultMinListRowHeight, 1)
    .navigationTitle("Chat")
  }
}

struct NotificationSettingsView: View {
  @ObservedObject private var notifier = LiveNotifier.shared
  @ObservedObject private var instantAlerts = InstantAlerts.shared

  var body: some View {
    Form {
      Section {
        Toggle("Go-live alerts", isOn: Binding(get: { notifier.enabled }, set: { on in Task { await notifier.setEnabled(on) } }))
        if notifier.enabled {
          Toggle("Keep checking in the background", isOn: $notifier.backgroundChecks)
        }
        if notifier.permission == .denied {
          Button("Allow notifications in iOS Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          }
        }
      } footer: {
        Text("A notification when a channel you follow (or hearted) goes live; tap it to watch. Kestrel checks every minute while it runs. Keep checking in the background keeps it running after you leave by playing silence under your other audio (fine for apps you install yourself; uses some battery). Swiped away or after a restart, checks stop until Kestrel is opened.")
      }
      Section {
        NavigationLink {
          InstantAlertsView()
        } label: {
          LabeledContent("Instant alerts (ntfy)", value: instantAlerts.active ? "On" : "Off")
        }
      } footer: {
        Text("Alerts within about a minute even when Kestrel is closed, through the ntfy app.")
      }
      Section { MiniPlayerSpacer() }
    }
    .environment(\.defaultMinListRowHeight, 1)
    .navigationTitle("Notifications")
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
          Picker("Playlists through it", selection: $settings.proxyPlaylists) {
            Text("Never").tag(AppSettings.ProxyPlaylists.never)
            Text("During ad breaks").tag(AppSettings.ProxyPlaylists.duringAds)
            Text("Always").tag(AppSettings.ProxyPlaylists.always)
          }
          ProxyTestRow(proxy: settings.playbackProxy)
        } header: {
          Text("Your proxy")
        } footer: {
          Text("The stream's token and address always go through it (a few small requests when a stream starts); the video, recordings and downloads never do. The playlists (asked for every second or so): During ad breaks sends them through it only from the moment a break shows until shortly after (a couple of hundred KB a break, with Kestrel's player); Always, the whole time (about 20 MB an hour); Never, not at all. The test asks Twitch for a stream through it and without it, and shows the address Twitch saw each time.")
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

/// Checks the user's proxy: a playback token asked for through it and straight, and what Twitch
/// saw each time (the address it came from; whether it would show ads). The setting alone didn't
/// show whether anything went through it.
struct ProxyTestRow: View {
  let proxy: HTTPProxy?
  @State private var testing = false
  @State private var result: (ok: Bool, text: String)?

  var body: some View {
    Button {
      Task { await run() }
    } label: {
      HStack {
        Text(testing ? "Testing…" : "Test the proxy")
        Spacer()
        if testing { ProgressView() }
      }
    }
    .disabled(testing || proxy == nil)
    if let result {
      Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .font(.footnote)
        .foregroundColor(result.ok ? .green : .orange)
    } else if proxy == nil {
      Text("Fill in the host and port to test it.").font(.footnote).foregroundColor(.secondary)
    }
  }

  private func run() async {
    guard let proxy else { return }
    testing = true
    defer { testing = false }
    result = nil
    let viaProxy = URLSessionHTTPClient(timeout: 12, proxy: proxy)
    async let direct = try? TwitchAPI.shared.probeToken(login: "twitch", through: nil)
    let proxied: PlaybackToken
    do {
      proxied = try await TwitchAPI.shared.probeToken(login: "twitch", through: viaProxy)
    } catch {
      _ = await direct
      result = (false, "Couldn't get through \(proxy.description): \(error.localizedDescription)")
      ActivityLog.shared.add("Proxy test: couldn't get through \(proxy.description) (\(error.localizedDescription))")
      return
    }
    let straight = await direct
    let seen = proxied.info?.userIP
    let own = straight?.info?.userIP
    let ads = proxied.info.map { $0.hideAds == true || $0.showAds == false } == true ? "Twitch says no ads through it." : "Twitch may show ads through it."
    if let seen, let own, seen == own {
      result = (false, "Twitch saw your own address (\(seen)) through it: requests aren't going through the proxy.")
      ActivityLog.shared.add("Proxy test: Twitch saw the same address through \(proxy.description) as without it")
    } else if let seen {
      result = (true, "Working: Twitch sees \(seen)" + (own.map { " instead of your \($0)" } ?? "") + ". " + ads)
      ActivityLog.shared.add("Proxy test: \(proxy.description) works (Twitch sees a different address). \(ads)")
    } else {
      result = (true, "Got through \(proxy.description) (Twitch didn't say which address it saw). " + ads)
    }
  }
}
