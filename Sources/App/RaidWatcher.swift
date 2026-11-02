// Watches the channel being played for raids (see Sources/Twitch/Raids.swift) and offers or
// follows them, per Settings › Playback › Raids.

import Foundation
import SwiftUI

/// What happens when the channel you're watching raids another.
enum RaidMode: String, CaseIterable, Identifiable {
  /// Like Twitch: a countdown banner, then on to the raided channel (unless you tap Stay).
  case follow
  /// A banner with the raided channel; you decide.
  case ask
  /// Nothing.
  case off

  var id: String { rawValue }

  var title: String {
    switch self {
    case .follow: return "Follow automatically"
    case .ask: return "Ask me"
    case .off: return "Off"
    }
  }

  var shortTitle: String {
    switch self {
    case .follow: return "Follow"
    case .ask: return "Ask"
    case .off: return "Off"
    }
  }
}

@MainActor
final class RaidWatcher: ObservableObject {
  /// A raid that's counting down.
  @Published private(set) var pending: RaidEvent?
  /// When it goes by itself (Twitch's countdown), if known.
  @Published private(set) var deadline: Date?
  /// A raid that went, offered with a Watch button (Ask mode, or after Stay).
  @Published private(set) var happened: RaidEvent?
  /// Stay here: this raid isn't followed.
  @Published private(set) var declined = false

  /// Opens the raided channel.
  var follow: ((Channel) -> Void)?

  private var channelID = ""
  private var channelName = ""
  private var socket: URLSessionWebSocketTask?
  private var session: URLSession?
  private var watchdog: Task<Void, Never>?
  private var lastHeard = Date()
  private var keepalive: TimeInterval = 10
  private var failures = 0
  private var stopped = true
  private var followed = false

  var mode: RaidMode { AppSettings.shared.raidMode }

  /// (Made by PlayerSession, which isn't on the main actor; nothing here needs it yet.)
  nonisolated init() {}

  func start(channel: Channel) {
    guard stopped, !channel.id.isEmpty, mode != .off else { return }
    stopped = false
    channelID = channel.id
    channelName = channel.name
    connect(to: Hermes.url)
  }

  func stop() {
    stopped = true
    watchdog?.cancel()
    watchdog = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    session?.invalidateAndCancel()
    session = nil
  }

  /// Stay on this channel.
  func stay() {
    declined = true
    if let pending { ActivityLog.shared.add("Staying on \(channelName) instead of following the raid to \(pending.targetDisplayName)") }
  }

  /// Go to the raided channel now.
  func goNow() {
    guard let target = (pending ?? happened)?.target else { return }
    open(target)
  }

  func dismiss() {
    pending = nil
    deadline = nil
    happened = nil
  }

  private func open(_ target: Channel) {
    guard !followed else { return }
    followed = true
    pending = nil
    happened = nil
    guard target.id.isEmpty else {
      follow?(target)
      return
    }
    // The raid didn't say the channel's ID (everything else goes by it): look it up by name.
    Task { [weak self] in
      let found = try? await TwitchAPI.shared.channelPage(login: target.login)
      guard let self, !self.stopped, let channel = found?.channel, !channel.id.isEmpty else {
        ActivityLog.shared.add("Couldn't find \(target.name) to follow the raid")
        return
      }
      self.follow?(channel)
    }
  }

  // MARK: Socket

  private func connect(to url: URL) {
    guard !stopped else { return }
    socket?.cancel(with: .goingAway, reason: nil)
    if session == nil { session = URLSession(configuration: .default) }
    guard let session else { return }
    var request = URLRequest(url: url)
    request.setValue("https://www.twitch.tv", forHTTPHeaderField: "Origin")
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    let task = session.webSocketTask(with: request)
    socket = task
    lastHeard = Date()
    task.resume()
    send(Hermes.subscribe(topic: Hermes.raidTopic(channelID: channelID)), on: task)
    receive(on: task)
    startWatchdog()
  }

  private func send(_ text: String, on task: URLSessionWebSocketTask) {
    task.send(.string(text)) { [weak self] error in
      guard error != nil else { return }
      Task { @MainActor in self?.dropped(task) }
    }
  }

  private func receive(on task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self, self.socket === task, !self.stopped else { return }
        switch result {
        case .success(let message):
          switch message {
          case .string(let text): self.handle(Hermes.parse(text))
          case .data(let data): self.handle(Hermes.parse(String(decoding: data, as: UTF8.self)))
          @unknown default: break
          }
          self.receive(on: task)
        case .failure:
          self.dropped(task)
        }
      }
    }
  }

  private func handle(_ message: Hermes.Message) {
    lastHeard = Date()
    switch message {
    case .welcome(let seconds):
      keepalive = max(5, seconds)
      failures = 0
    case .reconnect(let url):
      connect(to: url ?? Hermes.url)
    case .raid(let event):
      handle(event)
    case .keepalive, .subscribed, .other:
      break
    }
  }

  private func handle(_ event: RaidEvent) {
    guard event.sourceID.isEmpty || event.sourceID == channelID, mode != .off else { return }
    switch event.kind {
    case .update:
      if pending?.raidID != event.raidID {
        declined = false
        deadline = Date().addingTimeInterval(TimeInterval(event.forceRaidNowSeconds ?? 90))
        ActivityLog.shared.add("\(channelName) is raiding \(event.targetDisplayName)")
      }
      pending = event
    case .go:
      ActivityLog.shared.add("\(channelName) raided \(event.targetDisplayName)")
      pending = nil
      deadline = nil
      if mode == .follow, !declined {
        open(event.target)
      } else {
        happened = event
      }
    case .cancel:
      if pending?.raidID == event.raidID || event.raidID.isEmpty {
        pending = nil
        deadline = nil
      }
    }
  }

  private func dropped(_ task: URLSessionWebSocketTask) {
    guard socket === task, !stopped else { return }
    socket = nil
    failures += 1
    // Back off: 2, 4, 8 … up to 60 seconds.
    let delay = min(60, pow(2, Double(min(failures, 6))))
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self, !self.stopped, self.socket == nil else { return }
      self.connect(to: Hermes.url)
    }
  }

  /// Hermes sends a keepalive every few seconds; silence for a while means the socket's dead.
  private func startWatchdog() {
    guard watchdog == nil else { return }
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard let self, !self.stopped else { return }
        if let socket = self.socket, Date().timeIntervalSince(self.lastHeard) > self.keepalive * 3 + 5 {
          self.dropped(socket)
        }
      }
    }
  }
}

/// The raid offer over the video: "Raiding <channel> · 0:42", with Stay and Go now; after a raid
/// that wasn't followed, "Raided <channel>" with Watch.
struct RaidBanner: View {
  @ObservedObject var raids: RaidWatcher

  var body: some View {
    if let event = raids.pending, !raids.declined {
      banner(event, title: "Raiding \(event.targetDisplayName)", countdown: true) {
        Button("Stay") { withAnimation { raids.stay() } }
          .buttonStyle(RaidButtonStyle(prominent: false))
        Button("Go now") { raids.goNow() }
          .buttonStyle(RaidButtonStyle(prominent: true))
      }
    } else if let event = raids.happened ?? (raids.declined ? raids.pending : nil) {
      banner(event, title: raids.happened == nil ? "Raiding \(event.targetDisplayName)" : "Raided \(event.targetDisplayName)", countdown: false) {
        Button("Watch") { raids.goNow() }
          .buttonStyle(RaidButtonStyle(prominent: true))
        Button {
          withAnimation { raids.dismiss() }
        } label: {
          Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
        }
        .buttonStyle(RaidButtonStyle(prominent: false))
        .accessibilityLabel("Dismiss")
      }
    }
  }

  private func banner<Buttons: View>(
    _ event: RaidEvent, title: String, countdown: Bool, @ViewBuilder buttons: () -> Buttons
  ) -> some View {
    HStack(spacing: 10) {
      Avatar(url: event.targetProfileImage, size: 30)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.subheadline.weight(.bold)).lineLimit(1)
        if countdown, let deadline = raids.deadline {
          RaidCountdown(deadline: deadline, viewers: event.viewerCount)
        } else if event.viewerCount > 0 {
          Text("\(Format.viewers(event.viewerCount)) viewers").font(.caption).foregroundColor(.white.opacity(0.7))
        }
      }
      Spacer(minLength: 4)
      buttons()
    }
    .foregroundColor(.white)
    .padding(.leading, 8)
    .padding(.trailing, 8)
    .padding(.vertical, 7)
    .background(.ultraThinMaterial, in: Capsule())
    .background(Color.black.opacity(0.35), in: Capsule())
    .environment(\.colorScheme, .dark)
    .frame(maxWidth: 440)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }
}

private struct RaidCountdown: View {
  let deadline: Date
  let viewers: Int

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded()))
      let who = viewers > 0 ? " · \(Format.viewers(viewers)) viewers" : ""
      Text(left > 0 ? "in \(Format.duration(left))\(who)" : "any moment\(who)")
        .font(.caption.monospacedDigit())
        .foregroundColor(.white.opacity(0.7))
    }
  }
}

private struct RaidButtonStyle: ButtonStyle {
  var prominent: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.bold))
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(prominent ? Color.accentTeal : Color.white.opacity(0.18), in: Capsule())
      .foregroundColor(prominent ? .black : .white)
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
