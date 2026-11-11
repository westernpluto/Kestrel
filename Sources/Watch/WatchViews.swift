// The watch's screens: the lists of live channels, sign-in, settings, and the player with its chat.

import AVKit
import SwiftUI
import WatchKit

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
        ForEach(WatchStore.heights, id: \.self) { Text(store.fixedQuality ? "\($0)p" : "Up to \($0)p").tag($0) }
      }
      Toggle("Always this quality", isOn: $store.fixedQuality)
      Toggle("Chat", isOn: $store.chatShown)
      if let session = store.session {
        Section {
          Button("Sign out \(session.login)", role: .destructive) { store.signOut() }
        }
      }
      Section {
        Text("Higher qualities use more data and battery. 360p is sharp on the watch's screen. Off, Always this quality starts a step lower and moves with the connection, up to the quality set; on, it plays the quality set (or the nearest below it the stream has), even if it stalls. The quality button on the player picks one for that stream.")
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
  /// The picture on the whole screen, and zoomed to fill it (the sides cropped).
  @State private var full = false
  @State private var zoomed = false
  /// Full screen: the controls showing (a tap brings them up; they go after a few seconds).
  @State private var controlsShown = false
  @State private var hideControls: Task<Void, Never>?
  @State private var choosingQuality = false

  var body: some View {
    Group {
      if full {
        fullScreen
      } else {
        page
      }
    }
    .navigationTitle(stream.channel.name)
    .toolbar(full ? .hidden : .automatic, for: .navigationBar)
    .sheet(isPresented: $choosingQuality) {
      List {
        Button {
          player.choose(step: nil)
          choosingQuality = false
        } label: {
          HStack {
            Text("Auto (up to \(store.maxHeight)p)")
            Spacer()
            if !player.lockedQuality { Image(systemName: "checkmark") }
          }
        }
        ForEach(player.qualities.reversed(), id: \.step) { option in
          Button {
            player.choose(step: option.step)
            choosingQuality = false
          } label: {
            HStack {
              Text(option.label)
              Spacer()
              if player.lockedQuality, player.step == option.step { Image(systemName: "checkmark") }
            }
          }
        }
      }
      .navigationTitle("Quality")
    }
    .task {
      await player.start(login: stream.channel.login, maxHeight: store.maxHeight, fixed: store.fixedQuality)
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

  private var page: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        GeometryReader { geometry in
          picture(width: geometry.size.width, height: geometry.size.width * 9 / 16, fill: false)
            .onTapGesture { player.togglePause() }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        HStack(spacing: 6) {
          VolumeControl().frame(width: 30, height: 30)
          Spacer()
          Button {
            choosingQuality = true
          } label: {
            Image(systemName: "slider.horizontal.3")
          }
          .buttonStyle(.bordered)
          .frame(width: 44, height: 30)
          .accessibilityLabel("Quality")
          .disabled(player.qualities.isEmpty)
          Button {
            withAnimation { full = true }
            showControls()
          } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
          }
          .buttonStyle(.bordered)
          .frame(width: 44, height: 30)
          .accessibilityLabel("Full screen")
        }
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
  }

  private var fullScreen: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black
        picture(width: geometry.size.width, height: geometry.size.height, fill: zoomed)
        if controlsShown {
          VStack {
            HStack {
              controlButton("xmark", label: "Exit full screen") {
                withAnimation { full = false }
                zoomed = false
              }
              Spacer()
              controlButton(zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                label: zoomed ? "Fit" : "Fill") {
                withAnimation { zoomed.toggle() }
              }
            }
            Spacer()
            HStack {
              VolumeControl().frame(width: 32, height: 32)
              Spacer()
              controlButton(player.userPaused ? "play.fill" : "pause.fill", label: player.userPaused ? "Play" : "Pause") {
                player.togglePause()
              }
            }
          }
          .padding(6)
          .transition(.opacity)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { controlsShown ? hideNow() : showControls() }
    }
    .ignoresSafeArea()
  }

  /// The video, `width` wide in a `height` tall space: fitted, or filling it (cropped).
  ///
  /// watchOS draws video only through its own player view, which puts a Done button in its top
  /// left corner that does nothing here (and can't be turned off). The view is made taller than the
  /// picture, which it centres, and the extra cut off: the picture shows whole, the button doesn't.
  private func picture(width: CGFloat, height: CGFloat, fill: Bool) -> some View {
    let aspect: CGFloat = 16 / 9
    // The picture's own size in the space.
    let fitsWidth = width / height < aspect
    let fitWidth = fitsWidth ? width : height * aspect
    let fillWidth = fitsWidth ? height * aspect : width
    let videoWidth = fill ? fillWidth : fitWidth
    let videoHeight = videoWidth / aspect
    let margin: CGFloat = 60
    return ZStack {
      VideoPlayer(player: player.player)
        .frame(width: videoWidth, height: videoHeight + margin * 2)
        .allowsHitTesting(false)
        .frame(width: videoWidth, height: videoHeight)
        .clipped()
      if player.userPaused, !full || !controlsShown {
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
    .frame(width: width, height: height)
    .clipped()
    .contentShape(Rectangle())
  }

  private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button {
      action()
      showControls()
    } label: {
      Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
        .background(.black.opacity(0.55), in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func showControls() {
    withAnimation { controlsShown = true }
    hideControls?.cancel()
    hideControls = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled else { return }
      withAnimation { controlsShown = false }
    }
  }

  private func hideNow() {
    hideControls?.cancel()
    withAnimation { controlsShown = false }
  }
}

/// The watch's own volume (the Digital Crown turns it once it's tapped).
struct VolumeControl: WKInterfaceObjectRepresentable {
  func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
    WKInterfaceVolumeControl(origin: .local)
  }

  func updateWKInterfaceObject(_ object: WKInterfaceVolumeControl, context: Context) {}
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
