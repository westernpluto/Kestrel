// The watch's player: a live stream as a queue of small MP4 files.
//
// watchOS plays MP4 files with AVPlayer, but not live HLS video and there's no picture layer to
// feed frames to (as the iPhone's own player does). So: the ad-free session gives the stream's
// playlist (LowLatencySession, as on the iPhone and Apple TV), each segment is downloaded as soon
// as it's listed (the one still being made too, as it's made), unpacked (TSDemuxer), rewritten
// as an MP4 (MP4Writer) and queued on an AVQueuePlayer. It starts two segments back from the
// newest, a few seconds behind live, so a slow download doesn't run it dry.

import AVFoundation
import Foundation

@MainActor
final class WatchPlayer: ObservableObject {
  enum Phase: Equatable {
    case loading, playing, offline
    case failed(String)
  }

  @Published private(set) var phase: Phase = .loading
  let player = AVQueuePlayer()

  private var session: LowLatencySession?
  private var loop: Task<Void, Never>?
  private var running = false
  private var started = false
  /// The files queued, oldest first (each deleted once it's played).
  private var files: [URL] = []
  private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KestrelSegments", isDirectory: true)
  private let downloads: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }()

  /// More queued than this (after a pause, or a burst of downloads): the oldest are dropped, to
  /// stay close to live.
  private static let mostQueued = 4

  func start(login: String, maxHeight: Int) async {
    guard !running else { return }
    running = true
    phase = .loading
    try? FileManager.default.removeItem(at: folder)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    player.actionAtItemEnd = .advance
    player.automaticallyWaitsToMinimizeStalling = false
    await activateAudio()

    var config = LowLatencyConfig()
    // H.264 in transport streams: what this player rewrites (no AV1 or fragmented MP4).
    config.codecs = "h264"
    config.adFreeProxies = AdFreeProxy.automaticHosts
    config.adFreeServersForAdsOnly = true
    config.checkAccountFirst = TwitchAuth.shared.session != nil
    let session = LowLatencySession(login: login, config: config, http: URLSessionHTTPClient(timeout: 10), tokens: TwitchAPI.shared)
    let variants: [HLSVariant]
    do {
      variants = try await session.start()
    } catch StreamSession.StartError.offline {
      phase = .offline
      return
    } catch {
      phase = .failed(error.localizedDescription)
      return
    }
    guard running else { return }
    self.session = session
    // The tallest picture up to the setting (else the smallest there is).
    let videos = variants.indices.filter { !variants[$0].isAudioOnly && variants[$0].height > 0 }
      .sorted { variants[$0].height < variants[$1].height }
    guard let smallest = videos.first else {
      phase = .failed("No quality this watch can play.")
      return
    }
    let rendition = videos.last { variants[$0].height <= maxHeight } ?? smallest
    ActivityLog.shared.add("Watch player: \(login) at \(variants[rendition].label)")
    loop = Task { [weak self] in await self?.run(session: session, rendition: rendition) }
  }

  func stop() {
    running = false
    loop?.cancel()
    loop = nil
    player.pause()
    player.removeAllItems()
    for file in files { try? FileManager.default.removeItem(at: file) }
    files = []
  }

  // MARK: Segments

  private func run(session: LowLatencySession, rendition: Int) async {
    var planner = LiveSegmentPlanner(startBack: 1)
    var failures = 0
    while running, !Task.isCancelled {
      let playlist = await session.mediaPlaylist(rendition)
      if playlist.status == 200 {
        failures = 0
        for segment in planner.plan(playlist.body) {
          guard running, !Task.isCancelled else { return }
          await load(segment)
        }
      } else {
        failures += 1
        // The playlist gone for a while: the stream ended.
        if failures >= 6 {
          phase = .offline
          return
        }
      }
      try? await Task.sleep(nanoseconds: 800_000_000)
    }
  }

  private func load(_ segment: LiveSegmentPlanner.Planned) async {
    guard let url = URL(string: segment.uri) else { return }
    var request = URLRequest(url: url)
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await downloads.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200, running
    else { return }
    let file = folder.appendingPathComponent("\(segment.sequence)-\(UUID().uuidString.prefix(6)).mp4")
    // Unpacked and rewritten away from the main thread.
    let written = await Task.detached(priority: .userInitiated) { () -> Bool in
      var demuxer = TSDemuxer()
      let frames = demuxer.feed(data) + demuxer.flush()
      var video: [VideoFrame] = []
      var audio: [AudioFrame] = []
      for frame in frames {
        switch frame {
        case .video(let v): video.append(v)
        case .audio(let a): audio.append(a)
        }
      }
      guard let mp4 = MP4Writer.file(.init(video: video, audio: audio)) else { return false }
      return (try? mp4.write(to: file)) != nil
    }.value
    guard written, running else { return }
    enqueue(file)
  }

  private func enqueue(_ file: URL) {
    // (Empty only when it played through everything: paused, it doesn't use up the queue.)
    let ranDry = player.items().isEmpty
    player.insert(AVPlayerItem(url: file), after: nil)
    files.append(file)
    // Behind (paused a while, or downloads bunched up): on to the newer ones.
    while player.items().count > Self.mostQueued { player.advanceToNextItem() }
    removePlayedFiles()
    if !started, player.items().count >= 2 {
      started = true
      player.play()
      phase = .playing
    } else if started, ranDry {
      // Ran dry and stopped at the end of the queue: on again with the new segment.
      player.play()
    }
  }

  private func removePlayedFiles() {
    let queued = Set(player.items().compactMap { ($0.asset as? AVURLAsset)?.url })
    for file in files where !queued.contains(file) { try? FileManager.default.removeItem(at: file) }
    files.removeAll { !queued.contains($0) }
  }

  // MARK: Sound

  /// Playback through the watch's speaker or headphones. (While it's active, watchOS also allows
  /// chat's connection.)
  private func activateAudio() async {
    let audio = AVAudioSession.sharedInstance()
    try? audio.setCategory(.playback, mode: .moviePlayback, policy: .default, options: [])
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      audio.activate(options: []) { _, error in
        if let error { ActivityLog.shared.add("Watch player: sound didn't start (\(error.localizedDescription))") }
        done.resume()
      }
    }
  }
}

/// The stream's chat, read-only (Twitch's anonymous chat login).
@MainActor
final class WatchChat: ObservableObject {
  @Published private(set) var messages: [ChatMessage] = []
  private var socket: URLSessionWebSocketTask?
  private var channel: String?
  private var reconnect: Task<Void, Never>?

  func connect(to login: String) {
    channel = login.lowercased()
    guard socket == nil, let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
    let socket = URLSession.shared.webSocketTask(with: url)
    self.socket = socket
    socket.resume()
    for line in [
      "CAP REQ :twitch.tv/tags twitch.tv/commands", "PASS SCHMOOPIIE", "NICK justinfan\(Int.random(in: 10_000...99_999))",
      "JOIN #\(login.lowercased())",
    ] {
      socket.send(.string(line)) { _ in }
    }
    receive(on: socket)
  }

  func disconnect() {
    channel = nil
    reconnect?.cancel()
    reconnect = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }

  private func receive(on socket: URLSessionWebSocketTask) {
    socket.receive { [weak self] result in
      Task { @MainActor in
        guard let self, self.socket === socket else { return }
        switch result {
        case .success(.string(let text)):
          self.handle(text, on: socket)
          self.receive(on: socket)
        case .success:
          self.receive(on: socket)
        case .failure:
          // Dropped (the watch went to sleep, the connection changed): again in a few seconds.
          self.socket = nil
          guard let channel = self.channel else { return }
          self.reconnect = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.channel == channel else { return }
            self.connect(to: channel)
          }
        }
      }
    }
  }

  private func handle(_ text: String, on socket: URLSessionWebSocketTask) {
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = String(raw)
      if line.hasPrefix("PING") {
        socket.send(.string("PONG" + line.dropFirst(4))) { _ in }
        continue
      }
      guard let irc = IRCMessage.parse(line), let message = ChatMessage(irc: irc) else { continue }
      messages.append(message)
    }
    if messages.count > 120 { messages.removeFirst(messages.count - 120) }
  }
}
