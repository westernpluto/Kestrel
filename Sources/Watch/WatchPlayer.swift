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
  /// Ran out of segments and waiting for a couple more.
  @Published private(set) var buffering = false
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

  /// More files queued than this, about 24 s (a long pause, or a burst of downloads): the oldest
  /// are dropped, to stay within reach of live. (At 8 s it dropped some after every slow patch.)
  private static let mostQueued = 6
  /// Files in hand before playing starts, and again after running out (each two segments, about
  /// four seconds).
  private static let startWith = 2

  /// The stream's renditions, and the ones with a picture, smallest first.
  private var variants: [HLSVariant] = []
  private var videos: [Int] = []
  /// Where in `videos` it's playing, and the highest it may go (the setting).
  @Published private(set) var step = 0
  private var topStep = 0
  /// How fast segments have downloaded lately, against what each quality needs.
  private var slowSegments = 0
  private var fastSegments = 0
  private var steppedAt = Date.distantPast

  /// The quality playing ("360p30").
  var qualityLabel: String { videos.indices.contains(step) ? variants[videos[step]].label : "" }

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
    let found: [HLSVariant]
    do {
      found = try await session.start()
    } catch StreamSession.StartError.offline {
      phase = .offline
      return
    } catch {
      phase = .failed(error.localizedDescription)
      return
    }
    guard running else { return }
    self.session = session
    variants = found
    videos = found.indices.filter { !found[$0].isAudioOnly && found[$0].height > 0 }
      .sorted { (found[$0].height, found[$0].bandwidth) < (found[$1].height, found[$1].bandwidth) }
    guard !videos.isEmpty else {
      phase = .failed("No quality this watch can play.")
      return
    }
    // Up to the setting; starting one below it (when there is one) for a quick, steady start,
    // going up once the downloads show the connection carries it.
    topStep = videos.lastIndex { found[$0].height <= maxHeight } ?? 0
    step = max(0, topStep - 1)
    ActivityLog.shared.add("Watch player: \(login) at \(qualityLabel)")
    loop = Task { [weak self] in await self?.run(session: session) }
  }

  func stop() {
    running = false
    aheadTimer?.invalidate()
    aheadTimer = nil
    itemWatches = [:]
    loop?.cancel()
    loop = nil
    player.pause()
    player.removeAllItems()
    for file in files { try? FileManager.default.removeItem(at: file) }
    files = []
  }

  // MARK: Segments

  private func run(session: LowLatencySession) async {
    // Two complete segments back from the newest, plus the ones being made: a few seconds in hand.
    var planner = LiveSegmentPlanner(startBack: 2)
    var failures = 0
    // (With the quality each came from: only the same quality goes in one file.)
    var pending: [(segment: LiveSegmentPlanner.Planned, step: Int)] = []
    while running, !Task.isCancelled {
      let playlist = await session.mediaPlaylist(videos[step])
      if playlist.status == 200 {
        failures = 0
        let at = step
        pending += planner.plan(playlist.body).map { ($0, at) }
      } else {
        failures += 1
        // The playlist gone for a while: the stream ended.
        if failures >= 6 {
          phase = .offline
          return
        }
      }
      // Two at a time (each request's round trip, through the iPhone over Bluetooth especially,
      // added up one after another), and the two in one file: half as many joins between files,
      // where the player can hitch.
      // (A lone one waits for the next to be listed, unless what's queued is running low.)
      while running, !Task.isCancelled, pending.count >= 2 || (pending.count == 1 && started && player.items().count < 2) {
        let (first, firstStep) = pending.removeFirst()
        var parts: [Frames] = []
        if let (second, secondStep) = pending.first, !second.discontinuity, secondStep == firstStep {
          pending.removeFirst()
          async let a = load(first)
          async let b = load(second)
          let framesA = await a
          let framesB = await b
          parts = [framesA, framesB].compactMap { $0 }
        } else if let frames = await load(first) {
          parts = [frames]
        }
        guard !parts.isEmpty, running else { continue }
        if first.discontinuity { lastAudio = nil }
        if let file = await write(parts, name: "\(first.sequence)") { enqueue(file) }
      }
      try? await Task.sleep(nanoseconds: 700_000_000)
    }
  }

  typealias Frames = (video: [VideoFrame], audio: [AudioFrame])
  /// The last sound frame written (the next file starts its decoder with it: see MP4Writer).
  private var lastAudio: AudioFrame?

  /// One segment downloaded (tried twice) and unpacked.
  private func load(_ segment: LiveSegmentPlanner.Planned) async -> Frames? {
    guard let url = URL(string: segment.uri) else { return nil }
    var request = URLRequest(url: url)
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    var fetched: Data?
    for attempt in 0..<2 where fetched == nil && running {
      let asked = Date()
      if let (data, response) = try? await downloads.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
        fetched = data
        // (The one being made arrives as it's made: its time says nothing about the connection.)
        if !segment.live { measure(bytes: data.count, seconds: Date().timeIntervalSince(asked)) }
      } else if attempt == 0 {
        try? await Task.sleep(nanoseconds: 300_000_000)
      }
    }
    guard let data = fetched, running else { return nil }
    // Unpacked away from the main thread.
    return await Task.detached(priority: .userInitiated) { () -> Frames in
      var demuxer = TSDemuxer()
      var video: [VideoFrame] = []
      var audio: [AudioFrame] = []
      for frame in demuxer.feed(data) + demuxer.flush() {
        switch frame {
        case .video(let v): video.append(v)
        case .audio(let a): audio.append(a)
        }
      }
      return (video, audio)
    }.value
  }

  /// Segments (one after another, the same quality) as one MP4 file.
  private func write(_ parts: [Frames], name: String) async -> URL? {
    let video = parts.flatMap(\.video)
    let audio = parts.flatMap(\.audio)
    let primer = lastAudio
    if let last = audio.last { lastAudio = last }
    let file = folder.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).mp4")
    let written = await Task.detached(priority: .userInitiated) { () -> Bool in
      guard let mp4 = MP4Writer.file(.init(video: video, audio: audio, audioPrimer: primer)) else { return false }
      return (try? mp4.write(to: file)) != nil
    }.value
    return written && running ? file : nil
  }

  /// Steps the quality to what the connection carries: down after two segments that came in
  /// barely faster than this quality needs, up after a run of them well over the next one's
  /// (never past the setting). From the next playlist on (Twitch's qualities share segment numbers).
  private func measure(bytes: Int, seconds: Double) {
    guard seconds > 0.05, videos.indices.contains(step) else { return }
    let speed = Double(bytes * 8) / seconds  // bits a second
    let needs = Double(max(variants[videos[step]].bandwidth, 1))
    if speed < needs * 1.4 {
      slowSegments += 1
      fastSegments = 0
    } else {
      slowSegments = 0
      if step < topStep, speed > Double(max(variants[videos[step + 1]].bandwidth, 1)) * 2.2 { fastSegments += 1 } else { fastSegments = 0 }
    }
    let now = Date()
    if slowSegments >= 2, step > 0 {
      step -= 1
      slowSegments = 0
      steppedAt = now
      ActivityLog.shared.add("Watch player: downloads too slow; down to \(qualityLabel)")
    } else if fastSegments >= 6, step < topStep, now.timeIntervalSince(steppedAt) > 30 {
      step += 1
      fastSegments = 0
      steppedAt = now
      ActivityLog.shared.add("Watch player: downloads keeping up; up to \(qualityLabel)")
    }
  }

  private func enqueue(_ file: URL) {
    // (Empty only when it played through everything: paused, it doesn't use up the queue.) Held
    // until there's a little in hand again: the queue would otherwise start on the one file and
    // run dry again as soon as it ended.
    if started, !buffering, player.items().isEmpty {
      buffering = true
      stalls += 1
      player.pause()
    }
    let item = AVPlayerItem(url: file)
    watch(item)
    player.insert(item, after: nil)
    files.append(file)
    // Far behind (a long pause, or downloads bunched up): on to the newer ones.
    while player.items().count > Self.mostQueued {
      player.advanceToNextItem()
      dropped += 1
    }
    removePlayedFiles()
    if !started, player.items().count >= Self.startWith {
      started = true
      if !userPaused { player.play() }
      phase = .playing
    } else if buffering, player.items().count >= Self.startWith {
      buffering = false
      if !userPaused { player.play() }
    }
  }

  // MARK: Play and pause, and what's going on

  /// Paused with a tap on the picture.
  @Published private(set) var userPaused = false
  /// Times it ran out, files dropped to stay near live, and files the watch couldn't play.
  @Published private(set) var stalls = 0
  @Published private(set) var dropped = 0
  @Published private(set) var failed = 0
  @Published private(set) var lastError: String?
  /// Seconds queued ahead of what's playing.
  @Published private(set) var ahead: Double = 0
  private var itemWatches: [ObjectIdentifier: NSKeyValueObservation] = [:]
  private var aheadTimer: Timer?

  func togglePause() {
    userPaused.toggle()
    if userPaused {
      player.pause()
    } else if started, !buffering {
      player.play()
    }
  }

  /// A file the watch's player won't take is skipped by it: counted, with its reason, for the
  /// line under the picture.
  private func watch(_ item: AVPlayerItem) {
    let key = ObjectIdentifier(item)
    itemWatches[key] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard item.status == .failed else { return }
      let reason = item.error?.localizedDescription ?? "unknown"
      Task { @MainActor in
        guard let self else { return }
        self.failed += 1
        self.lastError = reason
        ActivityLog.shared.add("Watch player: a file didn't play (\(reason))")
      }
    }
    if aheadTimer == nil {
      aheadTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.measureAhead() }
      }
    }
  }

  private func measureAhead() {
    let items = player.items()
    var seconds = 0.0
    for (index, item) in items.enumerated() {
      let length = item.asset.duration.seconds
      guard length.isFinite else { continue }
      seconds += index == 0 ? max(0, length - item.currentTime().seconds) : length
    }
    ahead = seconds
    let live = Set(items.map(ObjectIdentifier.init))
    itemWatches = itemWatches.filter { live.contains($0.key) }
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
