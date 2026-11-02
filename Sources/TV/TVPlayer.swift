// Kestrel for Apple TV: the player. The stream comes through the same ad-free session and local
// playlist server as the iPhone app's Apple player; chat sits beside the video. On the Siri
// Remote: play/pause pauses, left or right shows or hides chat, a click shows what's playing, and
// Back closes the player.

import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class TVPlayerModel: ObservableObject {
  enum Phase: Equatable {
    case loading
    case playing
    case offline
    case failed(String)
  }

  let player = AVPlayer()
  @Published private(set) var phase: Phase = .loading
  @Published private(set) var paused = false
  /// An ad is in the stream and no ad-free copy was found: covered and muted meanwhile.
  @Published private(set) var coveringAd = false
  @Published private(set) var info: ChannelPage?
  private var session: StreamSession?
  private var statusObservation: NSKeyValueObservation?
  private var stopped = false

  /// How far behind live to play. The Apple player keeps a few segments in hand (Twitch's are two
  /// seconds each): asked to stay this close, it does, instead of drifting back to its default
  /// of about three times the segment length plus whatever a stall cost.
  static let behindLive: Double = 4.5

  func start(_ channel: Channel, adBlocking: Bool) async {
    guard session == nil, !stopped else { return }
    Task { [weak self] in
      let page = try? await TwitchAPI.shared.channelPage(login: channel.login)
      self?.info = page
    }
    var config = StreamSessionConfig()
    // Apple TV 4K decodes HEVC in hardware: Enhanced Broadcasting channels' sharper renditions too.
    config.codecs = "h265,h264"
    config.adFreeProxies = adBlocking ? AdFreeProxy.automaticHosts : []
    config.checkAccountFirst = TwitchAuth.shared.session != nil
    config.fallback = .muteAndCover
    let session = StreamSession(
      login: channel.login, config: config, http: URLSessionHTTPClient(timeout: 8), tokens: TwitchAPI.shared
    ) { [weak self] state, _ in
      Task { @MainActor in self?.adStateChanged(state) }
    }
    do {
      _ = try await session.start()
      guard !stopped else { return }
      self.session = session
      let url = try StreamProxy.shared.register(session)
      play(url)
    } catch StreamSession.StartError.offline {
      phase = .offline
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  private func play(_ url: URL) {
    let item = AVPlayerItem(url: url)
    item.automaticallyPreservesTimeOffsetFromLive = true
    item.configuredTimeOffsetFromLive = CMTime(seconds: Self.behindLive, preferredTimescale: 1000)
    item.preferredForwardBufferDuration = 2
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      let status = item.status
      let message = item.error?.localizedDescription ?? "Playback failed."
      Task { @MainActor in
        guard let model = self else { return }
        switch status {
        case .readyToPlay: model.phase = .playing
        case .failed: model.phase = .failed(message)
        default: break
        }
      }
    }
    player.automaticallyWaitsToMinimizeStalling = true
    player.replaceCurrentItem(with: item)
    player.play()
  }

  private func adStateChanged(_ state: AdState) {
    let covering = state == .covering
    guard covering != coveringAd else { return }
    coveringAd = covering
    player.isMuted = covering
  }

  func togglePause() {
    guard phase == .playing else { return }
    if paused {
      // Back to live, not to where it was paused.
      if let item = player.currentItem, let end = item.seekableTimeRanges.last?.timeRangeValue.end {
        player.seek(to: end - CMTime(seconds: Self.behindLive, preferredTimescale: 1000))
      }
      player.play()
    } else {
      player.pause()
    }
    paused.toggle()
  }

  func stop() {
    stopped = true
    player.pause()
    player.replaceCurrentItem(with: nil)
    statusObservation = nil
    if let session { StreamProxy.shared.remove(session.id) }
    session = nil
  }
}

/// The video, filling its frame (black bars where the shape differs).
struct TVVideoSurface: UIViewRepresentable {
  let player: AVPlayer

  final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  }

  func makeUIView(context: Context) -> PlayerView {
    let view = PlayerView()
    view.backgroundColor = .black
    view.playerLayer.videoGravity = .resizeAspect
    view.playerLayer.player = player
    return view
  }

  func updateUIView(_ view: PlayerView, context: Context) {
    if view.playerLayer.player !== player { view.playerLayer.player = player }
  }
}

struct TVPlayerView: View {
  let channel: Channel
  @EnvironmentObject private var store: TVStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model = TVPlayerModel()
  @StateObject private var chat = TVChat()
  @State private var chatShown = true
  @State private var infoShown = false
  @State private var hideInfo: Task<Void, Never>?

  var body: some View {
    HStack(spacing: 0) {
      ZStack {
        TVVideoSurface(player: model.player)
        overlay
      }
      if chatShown {
        TVChatPanel(chat: chat, channel: channel)
          .frame(width: 560)
          .transition(.move(edge: .trailing))
      }
    }
    .background(Color.black)
    .ignoresSafeArea()
    .focusable()
    .onPlayPauseCommand { model.togglePause() }
    .onMoveCommand { direction in
      guard direction == .left || direction == .right else { return }
      withAnimation(.easeInOut(duration: 0.3)) { chatShown.toggle() }
    }
    .onTapGesture { showInfo() }
    .onExitCommand { dismiss() }
    .task {
      chatShown = store.chatShown
      chat.start(channel.login)
      await model.start(channel, adBlocking: store.adBlocking)
      showInfo()
    }
    .onDisappear {
      model.stop()
      chat.stop()
    }
  }

  @ViewBuilder private var overlay: some View {
    switch model.phase {
    case .loading:
      ProgressView().scaleEffect(1.5)
    case .offline:
      message("\(channel.name) is offline", systemImage: "moon.zzz.fill")
    case .failed(let text):
      message(text, systemImage: "exclamationmark.triangle.fill")
    case .playing:
      ZStack {
        if model.coveringAd {
          Color.black
          VStack(spacing: 16) {
            ProgressView()
            Text("Skipping an ad…").font(.headline)
          }
        }
        if model.paused {
          Image(systemName: "pause.fill").font(.system(size: 90)).foregroundStyle(.white.opacity(0.85))
        }
        if infoShown { infoBar }
      }
    }
  }

  /// Who and what, along the bottom of the video (shown on a click and when the stream opens).
  private var infoBar: some View {
    VStack {
      Spacer()
      HStack(alignment: .bottom, spacing: 24) {
        AsyncImage(url: channel.profileImageURL.flatMap(URL.init(string:))) { image in
          image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
          Color.white.opacity(0.1)
        }
        .frame(width: 90, height: 90)
        .clipShape(Circle())
        VStack(alignment: .leading, spacing: 6) {
          Text(channel.name).font(.title3.weight(.bold))
          if let stream = model.info?.stream {
            Text(stream.title).font(.callout).lineLimit(2)
            Text([stream.category?.name, "\(TVFormat.viewers(stream.viewers)) watching"].compactMap { $0 }.joined(separator: " · "))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
      }
      .padding(50)
      .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
    }
    .transition(.opacity)
  }

  private func message(_ text: String, systemImage: String) -> some View {
    VStack(spacing: 20) {
      Image(systemName: systemImage).font(.system(size: 60))
      Text(text).font(.title3)
      Text("Press Back to return").font(.caption).foregroundStyle(.secondary)
    }
    .foregroundStyle(.white)
  }

  private func showInfo() {
    withAnimation(.easeInOut(duration: 0.25)) { infoShown = true }
    hideInfo?.cancel()
    hideInfo = Task {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.4)) { infoShown = false }
    }
  }
}

// MARK: - Chat

/// The channel's chat, read-only (anonymously over Twitch's IRC WebSocket): the last couple of
/// hundred messages, starting with the recent ones from before it was opened.
@MainActor
final class TVChat: ObservableObject {
  @Published private(set) var messages: [ChatMessage] = []
  private var socket: URLSessionWebSocketTask?
  private var login = ""
  private var stopped = false
  private static let keep = 200

  func start(_ login: String) {
    self.login = login.lowercased()
    stopped = false
    Task { [weak self] in
      let recent = await ThirdPartyEmotes.recentMessages(login: login.lowercased(), http: URLSessionHTTPClient(timeout: 8))
      guard let self, !self.stopped else { return }
      let earlier = recent.compactMap { ChatMessage(irc: $0) }.filter { $0.kind != .notice }
      self.messages = Array((earlier + self.messages).suffix(Self.keep))
    }
    connect()
  }

  func stop() {
    stopped = true
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }

  private func connect() {
    guard !stopped else { return }
    let task = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
    socket = task
    task.resume()
    for line in [
      "CAP REQ :twitch.tv/tags twitch.tv/commands", "PASS SCHMOOPIIE", "NICK justinfan\(Int.random(in: 10_000...99_999))",
      "JOIN #\(login)",
    ] {
      task.send(.string(line)) { _ in }
    }
    receive(task)
  }

  private func receive(_ task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self, self.socket === task, !self.stopped else { return }
        switch result {
        case .success(let message):
          if case .string(let text) = message { self.handle(text, on: task) }
          self.receive(task)
        case .failure:
          // Dropped: join again in a moment.
          self.socket = nil
          try? await Task.sleep(nanoseconds: 3_000_000_000)
          self.connect()
        }
      }
    }
  }

  private func handle(_ text: String, on task: URLSessionWebSocketTask) {
    var added: [ChatMessage] = []
    for line in text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }) {
      guard let irc = IRCMessage.parse(String(line)) else { continue }
      switch irc.command {
      case "PING":
        task.send(.string("PONG :\(irc.trailing ?? "tmi.twitch.tv")")) { _ in }
      case "PRIVMSG", "USERNOTICE":
        if let message = ChatMessage(irc: irc) { added.append(message) }
      case "CLEARCHAT", "CLEARMSG":
        // Deleted messages and timeouts: taken out of the list.
        if let id = irc.tags["target-msg-id"] {
          messages.removeAll { $0.id == id }
        } else if let user = irc.trailing?.lowercased(), irc.params.count > 1 {
          messages.removeAll { $0.login == user }
        }
      default:
        break
      }
    }
    guard !added.isEmpty else { return }
    messages = Array((messages + added).suffix(Self.keep))
  }
}

struct TVChatPanel: View {
  @ObservedObject var chat: TVChat
  let channel: Channel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Chat").font(.headline).padding(.horizontal, 30).padding(.top, 40).padding(.bottom, 16)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(chat.messages) { message in
              TVChatLine(message: message).id(message.id)
            }
          }
          .padding(.horizontal, 30)
          .padding(.bottom, 40)
        }
        .onChange(of: chat.messages.last?.id) { _, last in
          guard let last else { return }
          proxy.scrollTo(last, anchor: .bottom)
        }
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color(white: 0.07))
  }
}

struct TVChatLine: View {
  let message: ChatMessage

  var body: some View {
    if message.kind == .system {
      Text(message.systemText ?? message.text)
        .font(.system(size: 24))
        .foregroundStyle(.purple)
    } else {
      (Text(message.displayName).bold().foregroundColor(Self.color(message.color))
        + Text(message.kind == .action ? " " : ": ")
        + Text(message.text).foregroundColor(message.kind == .action ? Self.color(message.color) : .white))
        .font(.system(size: 24))
    }
  }

  /// A name's colour from chat (#RRGGBB), lightened a little if it's too dark on black.
  static func color(_ hex: String?) -> Color {
    guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else {
      return Color(red: 0.6, green: 0.55, blue: 1)
    }
    var r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
    let light = 0.299 * r + 0.587 * g + 0.114 * b
    if light < 0.35 {
      r = r + (1 - r) * 0.45
      g = g + (1 - g) * 0.45
      b = b + (1 - b) * 0.45
    }
    return Color(red: r, green: g, blue: b)
  }
}
