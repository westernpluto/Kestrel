// The watch's screens: the lists of live channels, sign-in, settings, and the player with its chat.

import AVKit
import SwiftUI

struct HomeView: View {
  @EnvironmentObject private var store: WatchStore
  @State private var search = ""
  @State private var results: [LiveStream] = []
  @State private var searching = false

  var body: some View {
    List {
      Section {
        TextField("Channel", text: $search)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onSubmit { Task { await runSearch() } }
        ForEach(results) { stream in StreamRow(stream: stream) }
        if searching { ProgressView() }
      }
      if store.session != nil {
        Section("Following") {
          if store.following.isEmpty, !store.loading {
            Text("No one you follow is live.").font(.footnote).foregroundStyle(.secondary)
          }
          ForEach(store.following) { stream in StreamRow(stream: stream) }
        }
      }
      Section("Popular") {
        ForEach(store.popular) { stream in StreamRow(stream: stream) }
      }
      if let message = store.message {
        Text(message).font(.footnote).foregroundStyle(.secondary)
      }
      Section {
        if store.session == nil {
          NavigationLink("Sign in with Twitch") { SignInView() }
        }
        NavigationLink("Settings") { WatchSettingsView() }
      }
    }
    .navigationTitle("Kestrel")
    .navigationDestination(for: LiveStream.self) { stream in PlayerView(stream: stream) }
    .refreshable { await store.refresh() }
    .overlay {
      if store.loading, store.popular.isEmpty { ProgressView() }
    }
  }

  /// A login typed (or dictated): that channel if it's live, else channels matching the name.
  private func runSearch() async {
    let text = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "")
    guard !text.isEmpty else {
      results = []
      return
    }
    searching = true
    defer { searching = false }
    if let found = try? await TwitchAPI.shared.users(logins: [text]), let live = found.compactMap(\.1).first {
      results = [live]
      return
    }
    let matches = (try? await TwitchAPI.shared.searchChannels(text, first: 10)) ?? []
    let logins = matches.map(\.channel.login)
    let live = (try? await TwitchAPI.shared.users(logins: logins)) ?? []
    results = live.compactMap(\.1)
  }
}

struct StreamRow: View {
  let stream: LiveStream

  var body: some View {
    NavigationLink(value: stream) {
      HStack(spacing: 8) {
        AsyncImage(url: stream.channel.profileImageURL.flatMap(URL.init(string:))) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          Color.gray.opacity(0.3)
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        VStack(alignment: .leading, spacing: 1) {
          Text(stream.channel.name).font(.headline).lineLimit(1)
          Text(stream.category?.name ?? stream.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
          Text("\(stream.viewers.formatted()) watching").font(.caption2).foregroundStyle(.red).lineLimit(1)
        }
      }
    }
  }
}

struct SignInView: View {
  @EnvironmentObject private var store: WatchStore
  @Environment(\.dismiss) private var dismiss
  @State private var code: TwitchDeviceLogin.Code?
  @State private var message: String?

  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        Text("On your phone or computer, go to").font(.footnote).multilineTextAlignment(.center)
        Text("twitch.tv/activate").font(.headline).foregroundStyle(.purple)
        Text("and enter").font(.footnote)
        if let code {
          Text(code.userCode).font(.system(.title2, design: .monospaced).weight(.bold)).minimumScaleFactor(0.5)
        } else {
          ProgressView()
        }
        if let message { Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
      }
      .padding(.horizontal, 4)
    }
    .navigationTitle("Sign in")
    .task { await run() }
  }

  private func run() async {
    let http = URLSessionHTTPClient(timeout: 15)
    while !Task.isCancelled {
      do {
        let fresh = try await TwitchDeviceLogin.start(http: http)
        code = fresh
        message = nil
        var interval = fresh.interval
        polling: while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
          switch await TwitchDeviceLogin.poll(fresh, http: http) {
          case .pending:
            if Date() > fresh.expiresAt { break polling }
          case .slowDown:
            interval += 5
          case .expired:
            break polling
          case .refused(let reason):
            message = "Twitch said: \(reason)"
            return
          case .done(let grant):
            do {
              let who = try await TwitchAuth.validate(token: grant.accessToken, http: http, clientID: TwitchDeviceLogin.clientID)
              store.save(
                TwitchAuth.Session(
                  token: grant.accessToken, login: who.login, userID: who.userID, deviceID: nil,
                  clientID: TwitchDeviceLogin.clientID, refreshToken: grant.refreshToken))
              await store.refresh()
              dismiss()
            } catch {
              message = error.localizedDescription
            }
            return
          }
        }
      } catch {
        message = error.localizedDescription
        try? await Task.sleep(nanoseconds: 5_000_000_000)
      }
    }
  }
}

struct WatchSettingsView: View {
  @EnvironmentObject private var store: WatchStore

  var body: some View {
    List {
      Picker("Quality", selection: $store.maxHeight) {
        ForEach(WatchStore.heights, id: \.self) { Text("Up to \($0)p").tag($0) }
      }
      Toggle("Chat", isOn: $store.chatShown)
      if let session = store.session {
        Section {
          Button("Sign out \(session.login)", role: .destructive) { store.signOut() }
        }
      }
      Section {
        Text("Higher qualities use more data and battery. 360p is sharp on the watch's screen.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Settings")
  }
}

struct PlayerView: View {
  let stream: LiveStream
  @EnvironmentObject private var store: WatchStore
  @StateObject private var player = WatchPlayer()
  @StateObject private var chat = WatchChat()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        ZStack {
          // The system's controls off (their Done button did nothing here): a tap pauses and plays.
          VideoPlayer(player: player.player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .allowsHitTesting(false)
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture { player.togglePause() }
          if player.userPaused {
            Image(systemName: "play.fill").font(.title2).padding(10).background(.black.opacity(0.5), in: Circle())
              .allowsHitTesting(false)
          }
          switch player.phase {
          case .loading:
            ProgressView()
          case .offline:
            Text("Offline").font(.footnote)
          case .failed(let message):
            Text(message).font(.caption2).multilineTextAlignment(.center).padding(4)
          case .playing:
            if player.buffering { ProgressView() }
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        Text(player.qualityLabel.isEmpty ? stream.title : "\(player.qualityLabel) · \(stream.title)")
          .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        if player.phase == .playing {
          // What's going on, to tell stalls from files the watch won't play.
          Text(
            String(format: "%.0f s in hand · %d stalls · %d dropped · %d failed", player.ahead, player.stalls, player.dropped, player.failed)
              + (player.lastError.map { "\n\($0)" } ?? "")
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if store.chatShown {
          ForEach(chat.messages.suffix(60)) { message in
            ChatLine(message: message)
          }
        }
      }
    }
    .navigationTitle(stream.channel.name)
    .task {
      await player.start(login: stream.channel.login, maxHeight: store.maxHeight)
    }
    .onChange(of: player.phase) { _, phase in
      // Chat's connection is allowed while sound plays (watchOS keeps other connections for that).
      if store.chatShown, phase == .playing { chat.connect(to: stream.channel.login) }
    }
    .onDisappear {
      player.stop()
      chat.disconnect()
    }
  }
}

struct ChatLine: View {
  let message: ChatMessage

  var body: some View {
    (Text(message.displayName).foregroundColor(Self.color(message.color)).bold()
      + Text(message.kind == .action ? " " : ": ")
      + Text(message.systemText.map { $0 + (message.text.isEmpty ? "" : " ") } ?? "").italic()
      + Text(message.text))
      .font(.caption2)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// The name's color (#RRGGBB), lifted a little when it's too dark for the black background.
  static func color(_ hex: String?) -> Color {
    guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return .purple }
    var r = Double((value >> 16) & 0xFF) / 255
    var g = Double((value >> 8) & 0xFF) / 255
    var b = Double(value & 0xFF) / 255
    let light = 0.299 * r + 0.587 * g + 0.114 * b
    if light < 0.35 {
      let lift = 0.35 - light
      r = min(1, r + lift)
      g = min(1, g + lift)
      b = min(1, b + lift)
    }
    return Color(red: r, green: g, blue: b)
  }
}
