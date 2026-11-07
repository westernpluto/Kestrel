// Word the moment a channel goes live: Twitch's `video-playback-by-id.<channel id>` topic on
// Hermes (the socket twitch.tv uses, see Sources/Twitch/Raids.swift) says "stream-up" as the
// broadcast starts. Used while an offline channel's page is open (asking Twitch's API every half a
// minute instead, a channel showed as live 40 to 50 seconds after it went: the API lists a stream
// a while after it starts), and for go-live alerts (one socket watches up to 50 channels).

import Foundation

@MainActor
final class LiveWatch {
  private let channelIDs: [String]
  private let onStreamUp: (String) -> Void
  private var socket: URLSessionWebSocketTask?
  private var session: URLSession?
  private var watchdog: Task<Void, Never>?
  private var lastHeard = Date()
  private var keepalive: TimeInterval = 10
  private var failures = 0
  private var stopped = false

  /// Channels one socket watches at most (Twitch's old PubSub took 50 topics a connection).
  static let perSocket = 50

  /// - Parameter onStreamUp: called with the channel's ID when one goes live.
  init(channelIDs: [String], onStreamUp: @escaping (String) -> Void) {
    self.channelIDs = Array(channelIDs.filter { !$0.isEmpty }.prefix(Self.perSocket))
    self.onStreamUp = onStreamUp
  }

  func start() {
    guard !channelIDs.isEmpty else { return }
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
    for id in channelIDs {
      let message = Hermes.subscribe(topic: Hermes.playbackTopic(channelID: id), subscriptionID: Hermes.playbackSubscription(channelID: id))
      task.send(.string(message)) { [weak self] error in
        guard error != nil else { return }
        Task { @MainActor in self?.dropped(task) }
      }
    }
    receive(on: task)
    startWatchdog()
  }

  private func receive(on task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self, self.socket === task, !self.stopped else { return }
        switch result {
        case .success(let message):
          let text: String
          switch message {
          case .string(let string): text = string
          case .data(let data): text = String(decoding: data, as: UTF8.self)
          @unknown default: text = ""
          }
          self.handle(Hermes.parse(text))
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
    case .streamUp(let subscription):
      // (Watching one channel: it's that one whatever the subscription says.)
      if let id = Hermes.channel(ofPlaybackSubscription: subscription) ?? (channelIDs.count == 1 ? channelIDs[0] : nil) {
        onStreamUp(id)
      }
    case .keepalive, .subscribed, .raid, .streamDown, .other:
      break
    }
  }

  private func dropped(_ task: URLSessionWebSocketTask) {
    guard socket === task, !stopped else { return }
    socket = nil
    failures += 1
    // Back off: 2, 4, 8 … up to 60 seconds (the playlist check carries on meanwhile).
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
